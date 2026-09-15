#!/usr/bin/env python3
#
# The Emotion Engine's R5900 on a Varium C1100, at the console's 294.912 MHz.
#
# This is the Graphics Synthesizer's bring-up done again for the other
# processor, deliberately and in the same order. `sys` stays on the LiteX MMCM
# so the control plane never depends on the clock being diagnosed; PS2Clocks
# drives `cd_ee` beside it; a gray-coded counter says what that domain is
# actually running at. Every one of those decisions is there because the GS
# bring-up learned it the hard way, and two builds whose CSR space was dead
# because `sys` itself sat on an MMCM that had not locked are the reason the
# first one is phrased so strongly.
#
# **What is different from the GS, and why.**
#
# The core is `ee_bringup`, not `ee_top`. ee_top carries ee_ram, which is 32 MB
# in HBM behind a cache -- the real memory system, and a large second problem.
# ee_bringup is the core with 64 KB of UltraRAM and a memory that answers in one
# cycle and has no behaviour of its own, so that a failure here is a failure of
# the R5900 rather than of anything around it. HBM is therefore not
# instantiated and `hbm_cattrip` is driven low, exactly as the GS target does
# and for the same measured reason: 17.6 W for one pin.
#
# **The rail is 0.85 V, and that is a change.** Every timing number for this
# core until 2026-09-14 was taken at 0.72 V under the `-2LV` speed model,
# because the project has a power-parity goal and that model characterises that
# rail. The core reaches 208.8 MHz there and 297.7 MHz at 0.85 V, and the
# measured cost of the higher rail is 0.71 W -- 4.18 W to 4.89 W, against a slim
# PlayStation 2's 35 W. The power budget never excluded it; the inference that
# it did cost the clock 88 MHz. Set the rail before loading this image:
#
#     UltrascalePlusVoltageControl/changeVoltage.sh --vccint 850 --vccbram 850
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
from litepcie.phy.usppciephy import USPHBMPCIEPHY
from litepcie.software import generate_litepcie_software

import xilinx_c1100
from litex.soc.cores.clock import USPMMCM
from migen.genlib.cdc import MultiReg, GrayCounter, GrayDecoder
from ps2_clocks import PS2Clocks

REPO_ROOT    = join(dirname(abspath(__file__)), "..")
SYS_CLK_FREQ = int(125e6)
MEM_WORDS_LOG2 = 12                      # 4096 x 128 bit = 64 KB


def add_ee_sources(platform, root=REPO_ROOT):
    rtl = join(root, "rtl", "ee")
    for f in ("ee_core.vhd", "ee_bringup.vhd"):
        platform.add_source(join(rtl, f), language="vhdl")


class _EECRG(LiteXModule):
    """`sys` on the proven path, and the console's clock tree beside it."""

    def __init__(self, platform, sys_clk_freq, ee_divide=None):
        self.rst    = Signal()
        self.cd_sys = ClockDomain()
        self.cd_ee  = ClockDomain()
        self.clk100 = Signal()

        pads   = platform.request("clk100")
        clk_se = Signal()
        self.specials += Instance("IBUFDS", i_I=pads.p, i_IB=pads.n, o_O=clk_se)
        self.specials += Instance("BUFG",   i_I=clk_se, o_O=self.clk100)

        self.mmcm = mmcm = USPMMCM(speedgrade=-2, name="sys_mmcm")
        self.comb += mmcm.reset.eq(self.rst)
        mmcm.register_clkin(self.clk100, 100e6)
        mmcm.create_clkout(self.cd_sys, sys_clk_freq, margin=0)

        # Only the EE domain is asked for. The GS's 147.456 and the IOP's 36.864
        # come off the same second MMCM and will be wanted when those blocks
        # join this image; a clock domain driving nothing is a period constraint
        # on nothing.
        self.ps2 = PS2Clocks(platform, self.clk100, self.rst,
                             domains={"ee": self.cd_ee}, ee_divide=ee_divide)

        platform.add_period_constraint(pads.p, 1e9 / 100e6)

        # The uncertainty trick the GS target established: placement needs a
        # hard goal or it stops the moment it reaches zero slack, and sign-off
        # needs the truth or a fine design reads as VIOLATED. So 0.300 ns of
        # extra uncertainty through placement, zero before routing. The MMCM
        # produces 294.912 MHz throughout; nothing about the console moves.
        platform.toolchain.pre_placement_commands.append(
            "set_clock_uncertainty -setup 0.450 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT0]]")
        # **Zero before routing, as the GS target does it.**
        #
        # For a while this target kept 0.150 ns applied through routing instead,
        # on the theory that a card failing about one run in eight while passing
        # every simulation was a design with no real margin. That theory was
        # wrong: the failure was `x_valid` surviving reset, and it was
        # indifferent to margin, to the clock and to the rail. Keeping the
        # inflated target after the cause was found bought nothing and made a
        # working design report WNS -0.080 with ten violated paths that really
        # had +0.070 ns -- a sign-off that has to be explained before it can be
        # read is worse than one that is simply true.
        #
        # So sign-off is told the truth again. The clock is untouched either
        # way: the MMCM produces 294.912 MHz throughout.
        platform.toolchain.pre_routing_commands.append(
            "set_clock_uncertainty -setup 0.000 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT0]]")

        # ---- the SLR1 floorplan, tried and reverted ------------------------
        #
        # The first build put all 60,151 LUTs in SLR0 and left SLR1 empty, so
        # confining ee_bringup to SLR1 looked like the obvious fix. It worked as
        # a floorplan -- 56,346 LUTs moved across, leaving only PCIe and the CSR
        # bank behind -- and **timing got worse**: -1.139 ns became -1.564.
        #
        # It was also solving the wrong problem. Those 60,151 LUTs included
        # 29,268 of *distributed RAM*, because the bring-up memory was not
        # inferring as block RAM at all. The design did not need a bigger
        # floorplan; it needed to stop building a 64 KB memory out of lookup
        # tables. With that fixed the LUT count falls by roughly half and the
        # pressure the pblock was relieving is not there to relieve.
        #
        # Kept as a comment rather than deleted because the measurement is worth
        # something: an SLR pblock on this hierarchy binds cleanly -- no
        # carry-chain splitting, no "cells involved" warning, which is what
        # defeated the same attempt on gs_top -- so it remains available if
        # placement pressure ever becomes the real constraint.

        # Named by MMCM pin, not by net: a net name that no longer exists makes
        # Vivado print "No clocks matched" and apply nothing. After a build,
        # grep the log for "No clocks matched" and for 12-4739.
        platform.toolchain.pre_placement_commands.append(
            "set_clock_groups -asynchronous "
            "-group [get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT0]] "
            "-group [get_clocks -of_objects [get_pins ps2_mmcm1/CLKOUT0]] "
            "-group [get_clocks -of_objects [get_pins sys_mmcm/CLKOUT0]] "
            "-group [get_clocks clk100_p]")


class EEBringup(LiteXModule, AutoCSR):
    """The R5900 in `cd_ee`, and the CSR window onto it from `sys`.

    The crossing patterns are the three the GS target documents, chosen by what
    a signal *is* rather than by how wide it is:

      * a request that must happen exactly once crosses as a **toggle**;
      * data accompanying a request is **not synchronised at all** -- it sits in
        a CSR the host wrote before the request and does not touch until the
        acknowledgement returns, so it is stable for the whole crossing;
      * free-running status is **snapshotted** in `ee` and announced with a
        toggle, because a multi-bit counter sampled directly reads as anything
        between its old and new values at a carry.
    """

    def __init__(self, platform, clk_locked=None):
        # ---- control -------------------------------------------------------
        self.reset    = CSRStorage(1, reset=1, description="1 holds the R5900 in reset; memory is writable")
        self.pc_reset = CSRStorage(32, description="the PC the core starts from")

        # ---- the program and data memory, written while in reset -----------
        self.mem_addr = CSRStorage(MEM_WORDS_LOG2, description="128-bit word index")
        self.mem_w    = [CSRStorage(32, name=f"mem_w{i}") for i in range(4)]
        self.mem_go   = CSRStorage(1, description="write to perform the access")
        self.mem_we   = CSRStorage(1, description="1 writes, 0 reads")
        self.mem_r    = [CSRStatus(32, name=f"mem_r{i}") for i in range(4)]

        # ---- observation ---------------------------------------------------
        self.retires  = CSRStatus(32, description="instructions retired since reset")
        self.last_pc  = [CSRStatus(32, name=f"last_pc{i}") for i in range(2)]
        self.dbg_sel  = CSRStorage(5, description="which general register to show")
        self.dbg_gpr  = [CSRStatus(32, name=f"dbg_gpr{i}") for i in range(4)]
        self.traps    = CSRStatus(16, description="unimplemented instructions counted")
        self.stall    = CSRStatus(3,  description="what the pipeline is waiting on")
        self.status   = CSRStatus(fields=[
            CSRField("mem_busy", size=1, description="a memory access is in flight"),
        ])

        # **Every CSR held in a list has to be bound as a named attribute too.**
        #
        # LiteX gathers CSRs by walking the module's attributes and keeping the
        # ones that either *are* a CSR or have a get_csrs() of their own. A
        # plain Python list is neither, so a list of CSRs is silently invisible:
        # no error, no warning, and a bitstream whose CSR bank simply does not
        # contain them. The first EE build shipped without mem_w, mem_r,
        # last_pc or dbg_gpr, and nothing said so until a tool asked for one by
        # name and got a KeyError off csr.csv.
        #
        # c1100_gs.py does exactly this for its rd_d0..7, which is why those
        # exist and these did not.
        for lst, stem in ((self.mem_w, "mem_w"), (self.mem_r, "mem_r"),
                          (self.last_pc, "last_pc"), (self.dbg_gpr, "dbg_gpr")):
            for i, c in enumerate(lst):
                setattr(self, f"{stem}{i}", c)

        # Everything else here asserts 294.912 MHz; these two can show it.
        self.clk_locked = CSRStatus(1,  description="both PS2 MMCMs are locked")
        self.clk_ticks  = CSRStatus(32, description="free-running cd_ee counter")

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

        # ---- reset: a level, so two flops are all it needs -----------------
        ee_rst_s = Signal()
        ee_rst   = Signal()
        self.specials += MultiReg(self.reset.storage[0], ee_rst_s, "ee")
        self.comb += ee_rst.eq(ee_rst_s | ResetSignal("ee"))

        # ---- the memory handshake ------------------------------------------
        # One toggle per access. The address, the write data and the direction
        # are CSRs the host set before pulsing mem_go and does not touch until
        # mem_busy clears, so they cross unsynchronised and stable.
        mem_req    = Signal()
        mem_ack    = Signal()
        mem_ack_s  = Signal()
        mem_busy   = Signal()
        self.specials += MultiReg(mem_ack, mem_ack_s, "sys")
        self.comb += mem_busy.eq(mem_req != mem_ack_s)
        self.sync += If(self.mem_go.re & ~mem_busy, mem_req.eq(~mem_req))

        mem_req_s = Signal()
        h_we      = Signal()
        h_hold    = Signal(128)
        h_rdata   = Signal(128)
        self.specials += MultiReg(mem_req, mem_req_s, "ee")
        # The memory is registered, so the value it was asked for is valid the
        # cycle after the request. Acknowledging on the same edge the data is
        # captured is what makes one toggle mean one completed access.
        mem_pend = Signal()
        self.sync.ee += [
            h_we.eq(0),
            If((mem_req_s != mem_ack) & ~mem_pend,
               h_we.eq(self.mem_we.storage[0]),
               mem_pend.eq(1),
            ).Elif(mem_pend,
               h_hold.eq(h_rdata),
               mem_pend.eq(0),
               mem_ack.eq(mem_req_s),
            ),
        ]
        self.comb += [self.mem_r[i].status.eq(h_hold[32*i:32*(i+1)]) for i in range(4)]
        self.comb += self.status.fields.mem_busy.eq(mem_busy)

        # ---- free-running status, snapshotted --------------------------------
        retires_e = Signal(32)
        last_pc_e = Signal(64)
        dbg_gpr_e = Signal(128)
        traps_e   = Signal(16)
        stall_e   = Signal(3)

        snap_cnt = Signal(6)
        snap     = Signal(32 + 64 + 128 + 16 + 3)
        snap_tog = Signal()
        self.sync.ee += [
            snap_cnt.eq(snap_cnt + 1),
            If(snap_cnt == 0,
               snap.eq(Cat(retires_e, last_pc_e, dbg_gpr_e, traps_e, stall_e))),
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
        ]

        dbg_sel_e = Signal(5)
        self.specials += MultiReg(self.dbg_sel.storage, dbg_sel_e, "ee")

        # HI and LO are brought out and left unread for now. Passing a bare
        # Signal() as an output port inside the Instance call makes migen
        # synthesise a name it also treats as combinational, which it then
        # reports as a cycle -- naming them here is the difference between a
        # warning and a clean elaboration, and an unread named signal is
        # trimmed by synthesis anyway.
        dbg_hi_e = Signal(64)
        dbg_lo_e = Signal(64)

        self.specials += Instance("ee_bringup",
            p_WORDS_LOG2 = MEM_WORDS_LOG2,
            i_clk        = ClockSignal("ee"),
            i_reset      = ee_rst,
            i_pc_reset   = self.pc_reset.storage,
            i_h_we       = h_we,
            i_h_addr     = self.mem_addr.storage,
            i_h_wdata    = Cat(*[w.storage for w in self.mem_w]),
            o_h_rdata    = h_rdata,
            o_retires    = retires_e,
            o_last_pc    = last_pc_e,
            i_dbg_sel    = dbg_sel_e,
            o_dbg_gpr    = dbg_gpr_e,
            o_dbg_hi     = dbg_hi_e,
            o_dbg_lo     = dbg_lo_e,
            o_dbg_traps  = traps_e,
            o_dbg_stall  = stall_e,
        )
        add_ee_sources(platform)


class EESoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=SYS_CLK_FREQ,
                 ee_divide=None):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 EE bring-up x{nlanes} {speed}")

        self.crg = _EECRG(platform, sys_clk_freq, ee_divide=ee_divide)

        # BE45 must be driven or the satellite controller powers the card off.
        # HBM is not instantiated: 64 KB of UltraRAM is the whole memory here,
        # and the GS target measured what the alternative costs -- 17.6 W of
        # 22.1 W, for one pin. HBM comes back with ee_ram and the EE's 32 MB,
        # and so does the real over-temperature output.
        self.comb += platform.request("hbm_cattrip").eq(0)

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

        self.ee = EEBringup(platform, clk_locked=self.crg.ps2.locked)

        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_ee.clk)


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_ee",
          place="AltSpreadLogic_low", phys="AggressiveExplore",
          route="Explore", ee_divide=None):
    # -2L, because this target runs at 0.85 V and the speed file has to match
    # the rail. The first EE bitstream was built at -2LV, signed off at
    # -0.719 ns, and produced nondeterministic results on the card -- different
    # registers and different retire counts on three identical runs, which is
    # what a timing violation looks like and what a logic bug never does.
    #
    # Building at -2LV while the card sits at 0.85 V is merely conservative, so
    # it was safe; it was also 40-odd MHz of margin left on the table for no
    # reason. Set the rail before loading this image.
    platform = xilinx_c1100.Platform(toolchain="vivado", speed_grade="2L")
    soc      = EESoC(platform, speed=speed, nlanes=nlanes,
                     ee_divide=ee_divide)

    # These are the directives that won the sweep. Out of context at 0.85 V the
    # core measured 284.2 to 297.7 MHz across seven combinations -- a 13.5 MHz
    # spread on one netlist -- and AltSpreadLogic_low took the top of it. At
    # 0.72 V the same directive was worth 27.3 MHz over Default, so it is not a
    # coincidence of one operating point.
    #
    # They are arguments to build(), not attributes of the toolchain object:
    # setting them on the object looks like it works, errors nothing, and is
    # silently overwritten when build() runs.
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
    ap.add_argument("--place", default="AltSpreadLogic_low")
    ap.add_argument("--phys",  default="AggressiveExplore")
    ap.add_argument("--route", default="Explore")
    ap.add_argument("--out",   default="build/c1100_ee")
    ap.add_argument("--ee-div", type=int, default=None,
                    help="EE output divider; 4 is the console's 294.912 MHz, "
                         "8 halves it for diagnosis")
    a = ap.parse_args()
    build(do_build=a.build, build_dir=a.out,
          place=a.place, phys=a.phys, route=a.route, ee_divide=a.ee_div)
