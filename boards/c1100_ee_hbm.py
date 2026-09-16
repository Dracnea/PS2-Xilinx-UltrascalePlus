#!/usr/bin/env python3
#
# c1100_ee_hbm.py -- the Emotion Engine with its real 32 MB of main memory.
#
# The difference from c1100_ee.py is the whole point of this file. That target
# builds `ee_bringup`: the R5900 with 64 KB of UltraRAM and a memory that
# answers in one cycle and has no behaviour of its own, so that a failure there
# is a failure of the core rather than of anything around it. That was the right
# shape while the core itself was suspect, and it found two bugs that way.
#
# This one builds `ee_top`: the same core joined to `ee_ram`, which is 32 MB in
# HBM behind a 32 KB direct-mapped cache. The PS2 has 32 MB of RDRAM and 32 MB
# is 1024 UltraRAM blocks -- 160 % of this card's entire supply -- so HBM is not
# an optimisation here, it is the precondition for an Emotion Engine existing on
# this part at all, and every EE block above the core is downstream of it.
#
# **Two clocks, and a converter between them.**
#
# `ee_top` has one clock for both the core and its AXI master, and the core runs
# at the console's 294.912 MHz. The HBM IP's user ports run at 250 MHz
# (`USER_AXI_CLK_FREQ` in ip/hbm/gen_hbm.tcl), and that IP is shared with
# c1100_ps2_iop.py, whose disc path is proven on silicon past 4 GiB. Raising the
# IP to 294.912 would remove this converter and is the better silicon, but it
# regenerates a part that working hardware depends on. So the first version
# crosses the domains instead: LiteX's AXIClockDomainCrossing between `cd_ee`
# and `cd_axi`, costing some fabric and a few cycles on a path that already
# costs 100-150 ns and has a cache in front of it for that reason.
#
# **How a program gets into memory.**
#
# `ee_bringup` has a host write port; `ee_top` has none -- its only way out is
# the AXI master. So the host writes HBM through a *second* HBM port, using the
# HBMProbe that the HBM test board already uses, while the core is held in
# reset. That is safe without a cache flush because `ee_ram` clears every valid
# bit on reset (rtl/ee/ee_ram.vhd:198): the core comes out of reset with a cold
# cache and cannot be holding a stale line.
#
# **This costs 17.6 W.** Instantiating HBM makes `hbm_cattrip` the real
# over-temperature output rather than a pin tied low, which the GS target
# measured at 17.6 W of 22.1 W. That is the price of the memory, and it is worth
# stating where the build is rather than discovering it on a power rail.
#
# SPDX-License-Identifier: BSD-2-Clause
import sys
from os.path import join, dirname, abspath

sys.path.insert(0, dirname(abspath(__file__)))
sys.path.insert(0, join(dirname(abspath(__file__)), "..", "platforms"))

from migen import *
from litex.gen.fhdl.module import LiteXModule
from litex.soc.integration.builder import Builder
from litex.soc.integration.soc_core import SoCMini
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField, AutoCSR
from litex.soc.interconnect import axi
from litepcie.phy.usppciephy import USPHBMPCIEPHY
from litepcie.software import generate_litepcie_software

import xilinx_c1100
from litex.soc.cores.clock import USPMMCM
from migen.genlib.cdc import MultiReg, GrayCounter, GrayDecoder
from ps2_clocks import PS2Clocks
from hbm_common import HBM, HBMProbe

SYS_CLK_FREQ = int(125e6)
REPO_ROOT = abspath(join(dirname(abspath(__file__)), ".."))


def add_ee_sources(platform, root=REPO_ROOT):
    rtl = join(root, "rtl", "ee")
    for f in ("ee_core.vhd", "ee_ram.vhd", "ee_top.vhd"):
        platform.add_source(join(rtl, f), language="vhdl")


class _EEHBMCRG(LiteXModule):
    """`sys` and the three clocks the HBM IP wants, with the console's beside them.

    The HBM clocks are exactly c1100_hbm_test.py's, for the same reason: 250 MHz
    is above the IP's 225 MHz floor and matches USER_AXI_CLK_FREQ. `cd_ee` comes
    off the PS2 clock tree as it does in c1100_ee.py and is not negotiable --
    a block running at the wrong rate is wrong, not slow.
    """
    def __init__(self, platform, sys_clk_freq):
        self.rst        = Signal()
        self.cd_sys     = ClockDomain()
        self.cd_hbm_ref = ClockDomain()
        self.cd_apb     = ClockDomain()
        self.cd_axi     = ClockDomain()
        self.cd_ee      = ClockDomain()
        self.clk100     = Signal()

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

        self.ps2 = PS2Clocks(platform, self.clk100, self.rst,
                             domains={"ee": self.cd_ee})

        platform.add_period_constraint(pads.p, 1e9 / 100e6)

        # The same uncertainty split c1100_ee.py uses, and for the same reason:
        # the router stops when it reaches its target, so it is given one it
        # cannot quite reach, and sign-off is then told the truth separately.
        platform.toolchain.pre_placement_commands.append(
            "set_clock_uncertainty -setup 0.450 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT0]]")
        platform.toolchain.pre_routing_commands.append(
            "set_clock_uncertainty -setup 0.150 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT0]]")
        platform.toolchain.bitstream_commands.append(
            "set_clock_uncertainty -setup 0.000 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT0]]")
        platform.toolchain.bitstream_commands.append(
            "report_timing_summary -datasheet -max_paths 10 "
            "-file {build_name}_timing_signoff.rpt")


class EEWithMemory(LiteXModule, AutoCSR):
    """`ee_top` in `cd_ee`, its AXI master crossed into `cd_axi`, on CSRs.

    The CSR window is deliberately the same shape as c1100_ee.py's, minus the
    memory port, so that tools/ee/eerun.py works against either image: the same
    reset, pc_reset, retires, last_pc, dbg_sel/dbg_gpr, traps and stall. What is
    new is the cache's own account of itself -- hits and misses -- because with
    a real memory behind it, "did it run" and "did it run at a sensible speed"
    are different questions and only the second one needs those.

    The crossing patterns are c1100_ee.py's and are chosen by what a signal is:
    a level crosses in two flops, and free-running status is snapshotted in `ee`
    and announced with a toggle, because a multi-bit counter sampled directly
    reads as anything between its old and new values at a carry.
    """
    def __init__(self, platform, hbm_port, clk_locked=None):
        self.reset    = CSRStorage(1, reset=1, description="1 holds the R5900 in reset; its cache is invalidated with it")
        self.pc_reset = CSRStorage(32, description="the PC the core starts from")

        self.retires  = CSRStatus(32, description="instructions retired since reset")
        self.last_pc  = [CSRStatus(32, name=f"last_pc{i}") for i in range(2)]
        self.dbg_sel  = CSRStorage(5, description="which general register to show")
        self.dbg_gpr  = [CSRStatus(32, name=f"dbg_gpr{i}") for i in range(4)]
        self.traps    = CSRStatus(16, description="unimplemented instructions counted")
        self.stall    = CSRStatus(3,  description="what the pipeline is waiting on")
        self.hits     = CSRStatus(32, description="cache hits since reset")
        self.misses   = CSRStatus(32, description="cache misses since reset")
        self.clk_locked = CSRStatus(1,  description="both PS2 MMCMs are locked")
        self.clk_ticks  = CSRStatus(32, description="free-running cd_ee counter")

        # **Every CSR held in a list has to be bound as a named attribute too.**
        # LiteX gathers CSRs by walking attributes, and a plain list is neither a
        # CSR nor something with get_csrs(), so a list of them is silently
        # invisible: no error, and a bitstream whose CSR bank does not contain
        # them. c1100_ee.py records this costing a debugging session.
        for lst, stem in ((self.last_pc, "last_pc"), (self.dbg_gpr, "dbg_gpr")):
            for i, c in enumerate(lst):
                setattr(self, f"{stem}{i}", c)

        gc = ClockDomainsRenamer("ee")(GrayCounter(32))
        self.submodules += gc
        self.comb += gc.ce.eq(1)
        gray_s = Signal(32)
        self.specials += MultiReg(gc.q, gray_s, "sys")
        dec = GrayDecoder(32)
        self.submodules += dec
        self.comb += dec.i.eq(gray_s), self.clk_ticks.status.eq(dec.o)
        if clk_locked is not None:
            self.specials += MultiReg(clk_locked, self.clk_locked.status, "sys")

        ee_rst_s = Signal()
        ee_rst   = Signal()
        self.specials += MultiReg(self.reset.storage[0], ee_rst_s, "ee")
        self.comb += ee_rst.eq(ee_rst_s | ResetSignal("ee"))

        # ---- the core's own AXI master, in cd_ee ---------------------------
        ee_axi = axi.AXIInterface(data_width=256, address_width=33, id_width=6,
                                  clock_domain="ee")

        retire_e   = Signal()
        retire_pc_e= Signal(64)
        retires_e  = Signal(32)
        dbg_gpr_e  = Signal(128)
        dbg_hi_e   = Signal(64)
        dbg_lo_e   = Signal(64)
        dbg_hi1_e  = Signal(64)
        dbg_lo1_e  = Signal(64)
        dbg_sa_e   = Signal(4)
        traps_e    = Signal(16)
        stall_e    = Signal(3)
        hits_e     = Signal(32)
        miss_e     = Signal(32)
        last_pc_e  = Signal(64)
        dbg_sel_e  = Signal(5)
        self.specials += MultiReg(self.dbg_sel.storage, dbg_sel_e, "ee")

        # retires and last_pc are not brought out of ee_top, so they are counted
        # here from the retire pulse it does bring out -- the same two numbers
        # ee_bringup reports, derived rather than duplicated in the core.
        self.sync.ee += [
            If(ee_rst,
               retires_e.eq(0),
            ).Elif(retire_e,
               retires_e.eq(retires_e + 1),
               last_pc_e.eq(retire_pc_e),
            ),
        ]

        # ---- free-running status, snapshotted ------------------------------
        snap_cnt = Signal(6)
        snap     = Signal(32 + 64 + 128 + 16 + 3 + 32 + 32)
        snap_tog = Signal()
        self.sync.ee += [
            snap_cnt.eq(snap_cnt + 1),
            If(snap_cnt == 0,
               snap.eq(Cat(retires_e, last_pc_e, dbg_gpr_e, traps_e, stall_e,
                           hits_e, miss_e))),
            If(snap_cnt == 1, snap_tog.eq(~snap_tog)),
        ]
        tog_s, tog_d = Signal(), Signal()
        hold = Signal(len(snap))
        self.specials += MultiReg(snap_tog, tog_s, "sys")
        self.sync += [
            tog_d.eq(tog_s),
            If(tog_s != tog_d, hold.eq(snap)),
        ]
        self.comb += [
            self.retires.status.eq(hold[0:32]),
            self.last_pc[0].status.eq(hold[32:64]),
            self.last_pc[1].status.eq(hold[64:96]),
            self.dbg_gpr[0].status.eq(hold[96:128]),
            self.dbg_gpr[1].status.eq(hold[128:160]),
            self.dbg_gpr[2].status.eq(hold[160:192]),
            self.dbg_gpr[3].status.eq(hold[192:224]),
            self.traps.status.eq(hold[224:240]),
            self.stall.status.eq(hold[240:243]),
            self.hits.status.eq(hold[243:275]),
            self.misses.status.eq(hold[275:307]),
        ]

        self.specials += Instance("ee_top",
            i_clk       = ClockSignal("ee"),
            i_reset     = ee_rst,
            i_pc_reset  = self.pc_reset.storage,
            o_stat_hits = hits_e,
            o_stat_miss = miss_e,
            o_retire    = retire_e,
            o_retire_pc = retire_pc_e,
            i_dbg_sel   = dbg_sel_e,
            o_dbg_gpr   = dbg_gpr_e,
            o_dbg_hi    = dbg_hi_e,
            o_dbg_lo    = dbg_lo_e,
            o_dbg_hi1   = dbg_hi1_e,
            o_dbg_lo1   = dbg_lo1_e,
            o_dbg_sa    = dbg_sa_e,
            o_dbg_traps = traps_e,
            o_dbg_stall = stall_e,

            o_m_awaddr  = ee_axi.aw.addr,
            o_m_awlen   = ee_axi.aw.len,
            o_m_awsize  = ee_axi.aw.size,
            o_m_awburst = ee_axi.aw.burst,
            o_m_awvalid = ee_axi.aw.valid,
            i_m_awready = ee_axi.aw.ready,
            o_m_wdata   = ee_axi.w.data,
            o_m_wstrb   = ee_axi.w.strb,
            o_m_wlast   = ee_axi.w.last,
            o_m_wvalid  = ee_axi.w.valid,
            i_m_wready  = ee_axi.w.ready,
            i_m_bvalid  = ee_axi.b.valid,
            o_m_bready  = ee_axi.b.ready,
            o_m_araddr  = ee_axi.ar.addr,
            o_m_arlen   = ee_axi.ar.len,
            o_m_arsize  = ee_axi.ar.size,
            o_m_arburst = ee_axi.ar.burst,
            o_m_arvalid = ee_axi.ar.valid,
            i_m_arready = ee_axi.ar.ready,
            i_m_rdata   = ee_axi.r.data,
            i_m_rlast   = ee_axi.r.last,
            i_m_rvalid  = ee_axi.r.valid,
            o_m_rready  = ee_axi.r.ready,
        )

        # ---- cd_ee -> cd_axi ------------------------------------------------
        # The whole reason this file is not simply c1100_ee.py with ee_top in
        # it. 294.912 MHz on one side, the HBM IP's 250 on the other.
        self.cdc = axi.AXIClockDomainCrossing(ee_axi, hbm_port,
                                              cd_from="ee", cd_to="axi")
        add_ee_sources(platform)


class EEHBMSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=SYS_CLK_FREQ):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 EE HBM x{nlanes} {speed}")

        self.crg = _EEHBMCRG(platform, sys_clk_freq)

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
                      with_dma_buffering = True, dma_buffering_depth=1024,
                      with_dma_loopback  = False)

        # cattrip is the real over-temperature output here, not a pin tied low.
        self.hbm = HBM(platform, platform.request("hbm_cattrip"))

        # Port 0 carries the Emotion Engine. Port 1 is how a program gets into
        # memory before the core is let go: HBMProbe is the CSR-driven reader
        # and writer the HBM test board already uses, and ee_ram invalidates its
        # cache on reset, so nothing the host writes can be stale when the core
        # starts.
        self.ee    = EEWithMemory(platform, self.hbm.axi[0],
                                  clk_locked=self.crg.ps2.locked)
        self.probe = HBMProbe(self.hbm.axi[1])

        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_ee.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_apb.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_ee.clk,  self.crg.cd_axi.clk)


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_ee_hbm",
          place="AltSpreadLogic_low", phys="AggressiveExplore", route="Explore"):
    # -2L for the same reason c1100_ee.py uses it: this target runs at 0.85 V
    # and the speed file has to match the rail the card is actually on.
    platform = xilinx_c1100.Platform(toolchain="vivado", speed_grade="2L")
    soc      = EEHBMSoC(platform, speed=speed, nlanes=nlanes)
    effort = dict(
        vivado_place_directive               = place,
        vivado_post_place_phys_opt_directive = phys,
        vivado_route_directive               = route,
        vivado_post_route_phys_opt_directive = phys,
    )
    builder = Builder(soc, output_dir=build_dir, compile_software=False,
                      csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build, **effort)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--out", default="build/c1100_ee_hbm")
    a = ap.parse_args()
    build(do_build=a.build, build_dir=a.out)
