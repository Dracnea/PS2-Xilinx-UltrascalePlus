#!/usr/bin/env python3
#
# C1100 HBM bring-up: prove the 8 GB of HBM2 before anything depends on it.
#
#   venv/bin/python boards/c1100_hbm_test.py --build
#
# This is deliberately the smallest design that can answer "does the HBM work,
# and can the host reach all 8 GB of it": PCIe for the host, the HBM2 IP, and a
# single-beat AXI master on one pseudo-channel driven from CSRs.  No IOP, no
# CDVD, nothing that could be blamed if it fails.
#
# It exists because the disc sector source is about to move into HBM, and the
# lesson of the CDVD read path (docs/disc-path.md) is that everything between a
# host CSR and another clock domain is only ever tested on the card.  A sector
# source built directly on an unproven memory would give two candidate faults
# for every failure.
#
# Why a CSR-driven single beat rather than DMA: staging a 4 GB disc image at CSR
# speed would take half an hour, so this is not the staging path and is not
# meant to be.  It is the correctness check -- write a word at an address, read
# it back, including addresses in the second stack, which is the part the
# default 32-bit AXI addressing cannot reach.  Bulk staging over LitePCIe DMA
# comes next and can then assume the memory itself is sound.
#
# Address space: 33-bit, so one AXI port covers all 8 GB across both stacks.
# The per-stack switches are enabled in ip/hbm/gen_hbm.tcl.

import sys
from os.path import join, dirname, abspath, normpath, exists

sys.path.insert(0, dirname(abspath(__file__)))
sys.path.insert(0, normpath(join(dirname(abspath(__file__)), "..", "platforms")))

from migen import *
from migen.genlib.cdc import MultiReg, PulseSynchronizer
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen.fhdl.module import LiteXModule
from litex.soc.cores.clock import USPMMCM
from litex.soc.cores.ram.xilinx_usp_hbm2 import USPHBM2
from litex.soc.integration.soc_core import SoCMini
from litex.soc.integration.builder import Builder
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField, AutoCSR

from litepcie.phy.usppciephy import USPHBMPCIEPHY
from litepcie.software import generate_litepcie_software

import xilinx_c1100

REPO_ROOT = normpath(join(dirname(abspath(__file__)), ".."))
HBM_XCI   = join(REPO_ROOT, "ip", "hbm", "hbm_0", "hbm_0.xci")


class _HBM(USPHBM2):
    """USPHBM2 with the two things the stock wrapper leaves to the board.

    1. The .xci path.  The wrapper looks for ip/hbm/<name>.xci relative to the
       working directory; Vivado's create_ip puts it in ip/hbm/<name>/<name>.xci
       and the build may run from anywhere, so the real path is passed in.

    2. CATTRIP.  The wrapper ties both stacks' DRAM_x_STAT_CATTRIP to Open().
       On this board that signal is a real pin (BE45) feeding the satellite
       controller, and platforms/xilinx_c1100.py warns it must never float.
       Every other design here drives it low because it has no HBM; this one
       has the actual over-temperature output and should report it, so the two
       stacks are OR'ed onto the pin.  Tying it low would make a genuinely
       overheating card look healthy.
    """
    def __init__(self, platform, cattrip_pad, xci=HBM_XCI, **kwargs):
        self.xci = xci
        USPHBM2.__init__(self, platform, **kwargs)
        cattrip = Signal(2)
        for i in range(2):
            self.hbm_params[f"o_DRAM_{i:1d}_STAT_CATTRIP"] = cattrip[i]
        self.comb += cattrip_pad.eq(cattrip != 0)

    def add_sources(self, platform):
        platform.add_ip(self.xci)


class _CRG(LiteXModule):
    """125 MHz sys, plus the three clocks the HBM IP wants.

    HBM_REF_CLK is 100 MHz (the IP's PLL multiplies it), APB is 100 MHz, and
    the AXI ports run at 250 MHz -- above the IP's 225 MHz floor and matching
    USER_AXI_CLK_FREQ in ip/hbm/gen_hbm.tcl.  250 MHz on a 256-bit port is
    8 GB/s, which is absurd headroom for disc sectors; the floor is what sets
    it, not the bandwidth.
    """
    def __init__(self, platform, sys_clk_freq):
        self.rst       = Signal()
        self.cd_sys    = ClockDomain()
        self.cd_hbm_ref= ClockDomain()
        self.cd_apb    = ClockDomain()
        self.cd_axi    = ClockDomain()
        self.clk100    = Signal()

        pads   = platform.request("clk100")
        clk_se = Signal()
        self.specials += Instance("IBUFDS", i_I=pads.p, i_IB=pads.n, o_O=clk_se)
        self.specials += Instance("BUFG",   i_I=clk_se, o_O=self.clk100)

        self.mmcm = mmcm = USPMMCM(speedgrade=-2, name="sys_mmcm")
        self.comb += mmcm.reset.eq(self.rst)
        mmcm.register_clkin(self.clk100, 100e6)
        mmcm.create_clkout(self.cd_sys,     sys_clk_freq, margin=0)
        mmcm.create_clkout(self.cd_hbm_ref, 100e6,        margin=0)
        mmcm.create_clkout(self.cd_apb,     100e6,        margin=0)
        mmcm.create_clkout(self.cd_axi,     250e6,        margin=0)

        platform.add_period_constraint(pads.p, 1e9/100e6)


class HBMProbe(LiteXModule, AutoCSR):
    """One 256-bit AXI beat at a time, driven from the host.

    The engine lives entirely in the AXI domain and only three things cross:
    a go pulse in, a done pulse out, and the address/data registers.  Those
    registers are written long before `go` and never move while the transfer is
    in flight, so a MultiReg on them is sound -- the failure mode to avoid is
    crossing a value that is still changing, which is exactly the bug that put
    a disc sector one word out of place (docs/disc-path.md).
    """
    def __init__(self, axi):
        self.addr  = CSRStorage(33, description="byte address, 32-byte aligned; 33 bits reaches both stacks")
        self.wdata = CSRStorage(32, description="write port: each write pushes one 32-bit lane, 8 lanes to a beat")
        self.ctrl  = CSRStorage(fields=[
            CSRField("write", size=1, pulse=True, description="issue a write beat"),
            CSRField("read",  size=1, pulse=True, description="issue a read beat"),
            CSRField("clear", size=1, pulse=True, description="reset the lane pointer"),
        ])
        self.stat  = CSRStatus(fields=[
            CSRField("busy",  size=1),
            CSRField("done",  size=1, description="set when a beat completes, cleared by the next one"),
            CSRField("resp",  size=2, description="AXI response of the last beat; 0 is OK"),
            CSRField("lane",  size=4, description="current write-lane pointer"),
        ])
        self.rdata = CSRStatus(32, description="read port: lane selected by rlane")
        self.rlane = CSRStorage(3,  description="which 32-bit lane of the last read beat rdata shows")

        # --- host side (sys): assemble the 256-bit beat one lane at a time ----
        wbuf = Signal(256)
        lane = Signal(4)
        self.sync += [
            If(self.ctrl.fields.clear,
                lane.eq(0),
            ).Elif(self.wdata.re,
                Case(lane, {i: wbuf[32*i:32*(i+1)].eq(self.wdata.storage) for i in range(8)}),
                If(lane == 7, lane.eq(0)).Else(lane.eq(lane + 1)),
            ),
        ]
        self.comb += self.stat.fields.lane.eq(lane)

        # --- cross into the AXI domain ---------------------------------------
        go_wr = PulseSynchronizer("sys", "axi"); self.submodules += go_wr
        go_rd = PulseSynchronizer("sys", "axi"); self.submodules += go_rd
        fin   = PulseSynchronizer("axi", "sys"); self.submodules += fin
        self.comb += go_wr.i.eq(self.ctrl.fields.write), go_rd.i.eq(self.ctrl.fields.read)

        addr_axi = Signal(33)
        wbuf_axi = Signal(256)
        self.specials += MultiReg(self.addr.storage, addr_axi, "axi")
        self.specials += MultiReg(wbuf, wbuf_axi, "axi")

        rbuf_axi = Signal(256)
        resp_axi = Signal(2)
        rbuf     = Signal(256)
        resp     = Signal(2)
        self.specials += MultiReg(rbuf_axi, rbuf, "sys")
        self.specials += MultiReg(resp_axi, resp, "sys")
        self.comb += [
            self.stat.fields.resp.eq(resp),
            Case(self.rlane.storage, {i: self.rdata.status.eq(rbuf[32*i:32*(i+1)]) for i in range(8)}),
        ]

        busy = Signal()
        done = Signal()
        self.specials += MultiReg(busy, self.stat.fields.busy, "sys")
        self.sync += If(fin.o, done.eq(1)).Elif(self.ctrl.fields.write | self.ctrl.fields.read, done.eq(0))
        self.comb += self.stat.fields.done.eq(done)

        # --- the AXI master (axi domain) --------------------------------------
        # One INCR burst of one beat: len=0, size=5 (2^5 = 32 bytes = 256 bits).
        fsm = ClockDomainsRenamer("axi")(FSM(reset_state="IDLE"))
        self.submodules += fsm
        self.comb += [
            axi.aw.addr.eq(addr_axi), axi.aw.len.eq(0), axi.aw.size.eq(5),
            axi.aw.burst.eq(1), axi.aw.id.eq(0),
            axi.ar.addr.eq(addr_axi), axi.ar.len.eq(0), axi.ar.size.eq(5),
            axi.ar.burst.eq(1), axi.ar.id.eq(0),
            axi.w.data.eq(wbuf_axi), axi.w.strb.eq(2**32 - 1), axi.w.last.eq(1),
        ]
        fsm.act("IDLE",
            If(go_wr.o, NextState("AW")).Elif(go_rd.o, NextState("AR")),
        )
        fsm.act("AW",
            axi.aw.valid.eq(1),
            If(axi.aw.ready, NextState("W")),
        )
        fsm.act("W",
            axi.w.valid.eq(1),
            If(axi.w.ready, NextState("B")),
        )
        fsm.act("B",
            axi.b.ready.eq(1),
            If(axi.b.valid, NextValue(resp_axi, axi.b.resp), NextState("FIN")),
        )
        fsm.act("AR",
            axi.ar.valid.eq(1),
            If(axi.ar.ready, NextState("R")),
        )
        fsm.act("R",
            axi.r.ready.eq(1),
            If(axi.r.valid,
                NextValue(rbuf_axi, axi.r.data),
                NextValue(resp_axi, axi.r.resp),
                NextState("FIN"),
            ),
        )
        fsm.act("FIN", fin.i.eq(1), NextState("IDLE"))
        self.comb += busy.eq(~fsm.ongoing("IDLE"))


class HBMTestSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=125e6):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 HBM bring-up x{nlanes} {speed}")

        self.crg = _CRG(platform, sys_clk_freq)

        # PCIe, exactly as the IOP target (verified on hardware 2026-09-05/07).
        pcie_pads = platform.request(f"pcie_x{nlanes}")
        self.pcie_phy = USPHBMPCIEPHY(platform, pcie_pads,
                                      speed      = speed,
                                      data_width = {1:64, 4:128, 8:256, 16:512}[nlanes],
                                      bar0_size  = 0x20000)
        self.pcie_phy.update_config({
            "pf0_bar0_64bit":        "true",
            "pf0_bar0_prefetchable": "true",
        })
        self.add_pcie(phy=self.pcie_phy, ndmas=1,
                      with_dma_buffering=True, dma_buffering_depth=1024,
                      with_dma_loopback=False)

        # HBM.  Unlike every other target here, hbm_cattrip is driven by the
        # IP's real over-temperature output rather than tied low.
        if not exists(HBM_XCI):
            raise SystemExit(
                f"no HBM IP at {HBM_XCI}\n"
                f"generate it first:\n"
                f"  vivado -mode batch -source ip/hbm/gen_hbm.tcl "
                f"-tclargs xcu55n-fsvh2892-2LV-e")
        self.hbm = _HBM(platform, platform.request("hbm_cattrip"))

        # One pseudo-channel is enough to prove the memory; the switch makes the
        # whole 8 GB reachable through it.
        self.probe = HBMProbe(self.hbm.axi[0])

        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_apb.clk)

        # The HBM IP brings a debug hub whose clock Vivado does not connect on
        # its own, and implementation stops with "dbg_hub/clk has 1 unconnected
        # channels".  Corundum hits the same thing on the same IP and pins it to
        # the HBM APB clock (fpga/mqnic/Alveo/fpga_25g/hbm.xdc), which is the
        # right clock precisely because the hub then shares a domain with the
        # block it is monitoring.  This has to run after synthesis, so it is a
        # pre-placement command rather than an XDC line.
        platform.toolchain.pre_placement_commands.append(
            "connect_debug_port dbg_hub/clk [get_nets apb_clk]")


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_hbm_test"):
    platform = xilinx_c1100.Platform(toolchain="vivado")
    soc      = HBMTestSoC(platform, speed=speed, nlanes=nlanes)
    builder  = Builder(soc, output_dir=build_dir, compile_software=False,
                       csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    build(nlanes = 16 if "--x16" in sys.argv else 4,
          do_build = "--build" in sys.argv)
