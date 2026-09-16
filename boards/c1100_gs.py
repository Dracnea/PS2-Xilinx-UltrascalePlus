#!/usr/bin/env python3
#
# C1100 Graphics Synthesizer bring-up.
#
# The first time either of the two large blocks -- the GS or the Emotion Engine
# -- goes on a card.  Everything here has been verified in simulation against
# sim/gs/gs_ref.py; the point of this image is to find out what that is worth on
# silicon, and the first run should be treated as testing this target rather
# than testing the GS.
#
# The shape is deliberately the same as the IOP's: a stream in and a window out.
#
#   * GIF packets arrive a quadword at a time through four CSR words and a push,
#     which is slow -- a few thousand quadwords per stream -- and is the right
#     trade for a bring-up, because it needs no DMA engine to be correct before
#     the thing it is testing can be tested at all.
#   * Local memory reads back through a second CSR window, one 256-bit word at a
#     time, which is what lets the host compute the very checksum sim/gs/gs_ref.py
#     prints.  The comparison on the card is then the comparison in simulation,
#     against the same reference, with the same tooling.
#
# The clock, and why this target does not yet run on the one it wants
# ---------------------------------------------------------------------
#
# The Graphics Synthesizer's clock is 147.456 MHz.  That is a *specification*,
# not a speed: this is a rebuild of the machine, a GS at 125 MHz is not a slow
# GS and one at 150 MHz is not a fast one, and the integer relationships between
# the GS, the EE and the IOP are part of what the software depends on.  The card
# can make it exactly -- boards/ps2_clocks.py synthesises 147.456000 MHz, 0 ppm,
# from the 100 MHz board reference.
#
# Two builds have already run the *whole SoC* on that clock tree, and both came
# back dead in a way worth writing down, because it looks like a working card:
# the PCIe hard block has its own clock, so the link trains at Gen3 x4, the BAR
# enumerates and config space reads perfectly.  Only the CSR space behind the
# bridge is dead -- and reading it does not error, it never completes, so the
# host driver *hangs*.  The clock tree had not locked.
#
# The reason both attempts were undiagnosable is the mistake this file now
# corrects: **the control plane was on the clock under test.**  `locked` lived
# in a CSR bank clocked by the very domain whose clock had failed, so the one
# bit that would have said what was wrong could not be read.
#
# So this build separates them.  `sys` -- the CSRs, the PCIe bridge and, for
# now, the GS -- runs on the LiteX MMCM at 125 MHz, which is the configuration
# that has worked on this card since the first bring-up.  PS2Clocks is
# instantiated beside it and drives nothing but a free-running counter, which is
# crossed into `sys` as gray code.  The card therefore cannot fail to come up,
# and tools/gs/gsclock.py can say whether the PS2 clock tree locks and what
# frequency it is actually producing.
#
# **The tree was then measured on the card: locked, 147.4563 MHz, +2 ppm --
# which is the host clock's own error, not the card's.**  So the GS now runs in
# `cd_gs` at the console's rate, and the CSR interface crosses the boundary
# explicitly; `sys` stays on the LiteX MMCM so that the control plane never
# again depends on the clock it is being used to diagnose.
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

REPO_ROOT = join(dirname(abspath(__file__)), "..")


def add_gs_sources(platform, root=REPO_ROOT):
    """The Graphics Synthesizer's RTL, in dependency order."""
    rtl = join(root, "rtl", "gs")
    for f in ("gs_addr_pkg.vhd", "gs_edge_dda.vhd", "gs_chan_dda.vhd", "gs_gif.vhd",
              "gs_lmem.vhd", "gs_pcrtc.vhd", "gs_pxcap.vhd", "gs_top.vhd"):
        platform.add_source(join(rtl, f), language="vhdl")


class _GSCRG(LiteXModule):
    """`sys` on the proven path, and the PS2 clock tree beside it to be measured.

    Two MMCMs, for two different jobs.  The LiteX one makes `sys` and the three
    clocks the HBM IP wants, all on integer ratios from 100 MHz, and this is the
    configuration that has worked on this card since the first bring-up.
    PS2Clocks makes the console's own clock family; here it drives `cd_gs`, which
    is the Graphics Synthesizer's domain and is measured by a counter beside it.

    That separation is the point.  Two earlier builds put `sys` itself on the
    PS2 clock tree, and when the tree did not lock there was no way to find out:
    the bit that says so lived in a CSR bank clocked by the failed domain.  A
    control plane must not depend on the clock it is being used to diagnose.
    """
    def __init__(self, platform, sys_clk_freq):
        self.rst        = Signal()
        self.cd_sys     = ClockDomain()
        self.cd_gs      = ClockDomain()
        self.cd_hbm_ref = ClockDomain()
        self.cd_apb     = ClockDomain()
        self.cd_axi     = ClockDomain()
        self.clk100     = Signal()

        pads   = platform.request("clk100")
        clk_se = Signal()
        self.specials += Instance("IBUFDS", i_I=pads.p, i_IB=pads.n, o_O=clk_se)
        self.specials += Instance("BUFG",   i_I=clk_se, o_O=self.clk100)

        self.mmcm = mmcm = USPMMCM(speedgrade=-2, name="sys_mmcm")
        self.comb += mmcm.reset.eq(self.rst)
        mmcm.create_clkout(self.cd_sys,     sys_clk_freq, margin=0)
        mmcm.register_clkin(self.clk100, 100e6)
        mmcm.create_clkout(self.cd_hbm_ref, 100e6, margin=0)
        mmcm.create_clkout(self.cd_apb,     100e6, margin=0)
        mmcm.create_clkout(self.cd_axi,     250e6, margin=0)

        # The console's clock tree.  Only the GS domain is asked for: the EE's 294.912 and the IOP's 36.864 come off
        # the same second MMCM and will be wanted when those blocks join this
        # image, but a clock domain that drives nothing is a period constraint
        # on nothing.
        self.ps2 = PS2Clocks(platform, self.clk100, self.rst,
                             domains={"gs": self.cd_gs})

        platform.add_period_constraint(pads.p, 1e9 / 100e6)

        # ---- margin at 147.456, without changing 147.456 -------------------
        #
        # Four consecutive builds landed at -0.36, -0.14, +0.02 and 0.000 ns on
        # changes that mostly did not touch the datapath.  The part is three per
        # cent full, so that is not capacity; the GS is simply placed around the
        # PCIe and HBM hard blocks, which all live in SLR0, and the tool stops
        # optimising the moment it reaches zero.
        #
        # Confining gs_top to SLR1 was tried first and did not help.  The reason
        # is worth keeping: synthesis promotes the rasteriser's generate-loop
        # instances out of the gs_top hierarchy, so `get_cells gs_top` captures
        # some of a carry chain and not the rest, and the placer is then asked
        # to split chains across a region boundary.  Vivado says so in the log
        # -- "The cells involved are ... in Carry-chain.  The area groups
        # involved are pblock_gs" -- and the result was 0.000 ns again.  A
        # floorplan that names a hierarchy the netlist no longer has is worse
        # than none.
        #
        # So the target is raised instead of the design being moved.  Clock
        # uncertainty tells the timing engine to assume it has less of the
        # period than it really does; the MMCM still produces 147.456 MHz and
        # the hardware still runs at exactly that.  This is a synthesis effort
        # knob, not a specification change -- the card is not overclocked and
        # nothing about the console being replicated moves.
        # The uncertainty is applied for *placement* and removed again before
        # routing, so the two things it has to do do not fight each other.
        #
        # Placement needs a hard goal.  Left at the real period the tool stops
        # the moment it reaches zero slack, and four builds in a row proved
        # that: -0.36, -0.14, +0.02 and 0.000 ns on changes that mostly did not
        # touch the datapath.  With 0.400 ns of extra uncertainty it kept
        # working and found 0.173 ns of genuine margin.
        #
        # Sign-off needs the truth.  Slack reported against an inflated target
        # reads as VIOLATED on a design that is fine, which is a trap for
        # whoever reads the log next.  Worse, a smaller inflation is not a
        # compromise but a lottery: at 0.150 the same design came back at
        # -0.204, which is -0.054 against the real clock -- *worse* than the
        # build with no uncertainty at all, because the placer lands somewhere
        # in a +-0.2 ns band each time and an easier goal does not make it land
        # higher.
        #
        # So: 0.400 through placement and post-place optimisation, then zero for
        # routing and the reports.  The clock itself never changes; 147.456 MHz
        # is what the MMCM produces throughout.
        platform.toolchain.pre_placement_commands.append(
            "set_clock_uncertainty -setup 0.400 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT1]]")
        # **The goal is kept through routing, and sign-off is told the truth
        # separately.**
        #
        # This target used to drop the uncertainty to zero here, so that the
        # build's own report was honest. The Emotion Engine measured what that
        # convention costs, on its own netlist and at its own clock: routing
        # against a target of zero gave -0.032 ns of *real* slack where routing
        # against an inflated one gave +0.070. The router stops the moment it
        # reaches its target, so a target it can reach is a design that only
        # just fails.
        #
        # The two concerns separate cleanly. bitstream_commands run after
        # report_timing_summary has written the build's own report, so the goal
        # stays inflated through routing and the constraint is then relaxed and
        # the design reported again into *_timing_signoff.rpt. Read that file
        # for what the design is, and the build's own report for what the router
        # was chasing.
        platform.toolchain.pre_routing_commands.append(
            "set_clock_uncertainty -setup 0.150 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT1]]")
        platform.toolchain.bitstream_commands.append(
            "set_clock_uncertainty -setup 0.000 "
            "[get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT1]]")
        platform.toolchain.bitstream_commands.append(
            "report_timing_summary -datasheet -max_paths 10 "
            "-file {build_name}_timing_signoff.rpt")

        # Named by MMCM pin, not by net: a net name that no longer exists makes
        # Vivado print "No clocks matched" and apply nothing, which is the trap
        # c1100_ps2_iop.py's comment records hitting three times.  After a
        # build, grep the log for "No clocks matched" and for 12-4739.
        platform.toolchain.pre_placement_commands.append(
            "set_clock_groups -asynchronous "
            "-group [get_clocks -of_objects [get_pins ps2_mmcm2/CLKOUT1]] "
            "-group [get_clocks -of_objects [get_pins ps2_mmcm1/CLKOUT0]] "
            "-group [get_clocks -of_objects [get_pins {{sys_mmcm/CLKOUT0 "
            "sys_mmcm/CLKOUT1 sys_mmcm/CLKOUT2}}]] "
            "-group [get_clocks clk100_p]")


class GSBringup(LiteXModule, AutoCSR):
    """gs_top on CSRs.

    reset     1 (the power-up value) holds the GS in reset.
    gif_w0..3 the quadword to push, low word first.
    gif_push  writing it presents that quadword to the GIF.  The GS may stall
              for a long time -- a triangle divides twice per edge before a
              pixel is drawn -- so `status.busy` says when the push has been
              taken and the next may be written.
    rd_addr   a 256-bit word address in local memory; writing it starts a read.
    rd_d0..7  the word that came back, low first, valid when status.rd_done.
    dbg_sel   which of the 64 general registers to show in dbg_lo / dbg_hi.
    pixels    pixels drawn since reset, which is how a primitive that quietly
              drew nothing is told apart from a framebuffer that was never
              meant to change.
    unknown   writes to register addresses the manual does not define.
    """
    def __init__(self, platform, clk_locked=None):
        self.reset    = CSRStorage(1, reset=1, description="1 holds the GS in reset")
        self.gif_w0   = CSRStorage(32, description="quadword bits 31:0")
        self.gif_w1   = CSRStorage(32, description="quadword bits 63:32")
        self.gif_w2   = CSRStorage(32, description="quadword bits 95:64")
        self.gif_w3   = CSRStorage(32, description="quadword bits 127:96")
        self.gif_push = CSRStorage(1,  description="write to present the quadword")
        self.status   = CSRStatus(fields=[
            CSRField("busy",    size=1, offset=0, description="a pushed quadword has not been taken yet"),
            CSRField("ready",   size=1, offset=1, description="the GIF's ready line"),
            CSRField("rd_done", size=1, offset=2, description="rd_d0..7 hold the requested word"),
        ])
        self.pixels   = CSRStatus(32, description="pixels drawn since reset")
        self.unknown  = CSRStatus(16, description="writes to undefined register addresses")
        self.rd_addr  = CSRStorage(17, description="256-bit word address; writing starts a read")
        self.rd_data  = [CSRStatus(32, name=f"rd_d{i}") for i in range(8)]
        for i, c in enumerate(self.rd_data):
            setattr(self, f"rd_d{i}", c)
        self.dbg_sel  = CSRStorage(7,  description="which general register to show")
        self.dbg_lo   = CSRStatus(32, description="that register, bits 31:0")
        self.dbg_hi   = CSRStatus(32, description="that register, bits 63:32")

        # ---- is this actually the console's clock? -------------------------
        #
        # Everything else in this file asserts 147.456 MHz; these two CSRs are
        # the only things that can *show* it.  Without them "the GS runs at the
        # console's clock" is a statement about a constraint file -- the MMCM
        # parameters have never been through a synthesiser until now, let alone
        # locked on this card, and a PLL that fails to lock does not announce
        # itself, it just leaves the design on a clock that never ticks or one
        # that ticks at the wrong rate.
        #
        #   locked   both MMCMs have locked.  0 means the clock tree did not
        #            come up and nothing else on this page means anything.
        #   ticks    a free-running counter in the sys domain.  Read it twice a
        #            known wall-clock apart and the difference is the frequency,
        #            measured rather than assumed.  It wraps every 29 seconds at
        #            this rate, which is far longer than any sensible gap.
        # ---- the display, and a frame of it -------------------------------
        # PCRTC composites two read circuits and blends them; a C1100 has no
        # video connector, so the only way to see whether the card does that
        # correctly is to catch a frame and read it back. gsgrab.py reads the
        # *frame buffer* instead, which skips exactly the part PCRTC does.
        self.pr_addr    = CSRStorage(8,  description="privileged register offset from 0x12000000")
        self.pr_d0      = CSRStorage(32, description="that register, bits 31:0")
        self.pr_d1      = CSRStorage(32, description="that register, bits 63:32")
        self.pr_push    = CSRStorage(1,  description="write to present the privileged register write")
        self.h_total    = CSRStorage(12, reset=64, description="raster width, until there is a sync generator")
        self.v_total    = CSRStorage(12, reset=64, description="raster height")
        self.disp_en    = CSRStorage(1,  description="1 runs PCRTC; it reads local memory when it does")
        self.cap_arm    = CSRStorage(1,  description="1 arms the frame grab; it starts at the next frame")
        self.cap_stat   = CSRStatus(fields=[
            CSRField("busy", size=1, description="capturing now"),
            CSRField("done", size=1, description="a frame is in the buffer"),
        ])
        # Free-running while a capture is in flight, so it means something only
        # once `done` is set -- which is the point at which it stops moving.
        self.cap_count  = CSRStatus(13, description="pixels captured; read it after done")
        self.cap_addr   = CSRStorage(12, description="which captured pixel to show")
        self.cap_data   = CSRStatus(24, description="that pixel, 0xBBGGRR")
        self.crtc_rd    = CSRStatus(32, description="display reads the arbiter granted")
        self.crtc_stall = CSRStatus(32, description="display reads it refused")

        self.clk_locked = CSRStatus(1, description="both PS2 MMCMs are locked")
        self.clk_ticks  = CSRStatus(32, description="free-running cd_gs counter")

        # The counter lives in cd_gs and is read from sys, so it crosses a
        # clock boundary -- and a plain binary counter sampled across one is
        # wrong in a way that looks right: several bits change at once at a
        # carry, and the sampling flop can catch some of the old value and some
        # of the new.  At 0xFF -> 0x100 that reads as anything from 0 to 511.
        #
        # Gray code is the fix and the reason it works is that only *one* bit
        # changes per increment, so a sample caught mid-transition is either the
        # old count or the new one and never a third number.  The decoder turns
        # it back into binary on this side.
        gc = ClockDomainsRenamer("gs")(GrayCounter(32))
        self.submodules += gc
        self.comb += gc.ce.eq(1)
        gray_s = Signal(32)
        self.specials += MultiReg(gc.q, gray_s, "sys")
        dec = GrayDecoder(32)
        self.submodules += dec
        self.comb += dec.i.eq(gray_s), self.clk_ticks.status.eq(dec.o)

        # locked is one bit and changes once, so two flops are enough.
        if clk_locked is not None:
            self.specials += MultiReg(clk_locked, self.clk_locked.status, "sys")

        # ---- the GS itself, in its own clock domain ------------------------
        #
        # Everything above this line is in `sys`; gs_top is in `gs`, at the
        # console's 147.456 MHz.  Every signal between them crosses a boundary
        # between two unrelated clocks, and none of it may be sampled naively.
        #
        # Three patterns cover all of it, and the choice of which to use is
        # decided by what the signal *is*, not by how wide it happens to be:
        #
        #   * **A request that must happen exactly once** -- a GIF push, a
        #     memory read -- crosses as a *toggle*.  A level would be sampled
        #     for as many cycles as the two clocks' ratio allows and the request
        #     would happen two or three times; a pulse could be missed entirely
        #     between sampling edges.  A toggle is edge-free: the far side
        #     compares it against what it last acted on, so one toggle is one
        #     request however the clocks line up.
        #
        #   * **Data that accompanies a request** -- the quadword, the address --
        #     is not synchronised at all.  It sits in a CSR register that the
        #     host wrote before the request and does not touch until the
        #     acknowledgement comes back, so it is stable for the whole crossing.
        #     Synchronising it would cost 400 flip-flops to solve a problem the
        #     handshake has already solved.
        #
        #   * **Free-running status** -- the pixel count, the register window --
        #     is snapshotted in `gs` every 64 cycles and announced with a toggle.
        #     A multi-bit counter sampled directly is the classic mistake: at a
        #     carry, several bits change at once and the sampler can catch some
        #     old and some new, so 0x0FF -> 0x100 reads as anything in between.
        gif_valid  = Signal()
        gif_ready  = Signal()
        gif_data   = Signal(128)
        h_rd_en    = Signal()
        h_rd_addr  = Signal(17)
        h_rd_data  = Signal(256)
        h_rd_valid = Signal()
        dbg_reg    = Signal(64)
        dbg_unk    = Signal(16)
        dbg_pix    = Signal(32)
        gs_rst     = Signal()

        self.comb += gif_data.eq(Cat(self.gif_w0.storage, self.gif_w1.storage,
                                     self.gif_w2.storage, self.gif_w3.storage))

        # ---- reset: a level, so two flops are all it needs -----------------
        rst_gs = Signal()
        self.specials += MultiReg(self.reset.storage[0], rst_gs, "gs")
        self.comb += gs_rst.eq(rst_gs | ResetSignal("gs"))

        # ---- the push handshake --------------------------------------------
        push_req  = Signal()          # toggles in sys, one toggle per push
        push_ack  = Signal()          # follows it in gs, once the GIF has taken it
        push_ack_s = Signal()
        push_busy = Signal()
        self.specials += MultiReg(push_ack, push_ack_s, "sys")
        self.comb += push_busy.eq(push_req != push_ack_s)
        self.sync += If(self.gif_push.re & ~push_busy, push_req.eq(~push_req))

        push_req_s = Signal()
        self.specials += MultiReg(push_req, push_req_s, "gs")
        self.comb += gif_valid.eq(push_req_s != push_ack)
        self.sync.gs += If(gif_valid & gif_ready, push_ack.eq(push_req_s))

        # ---- the read handshake --------------------------------------------
        rd_req   = Signal()
        rd_ack   = Signal()
        rd_ack_s = Signal()
        rd_done  = Signal()
        self.specials += MultiReg(rd_ack, rd_ack_s, "sys")
        self.sync += [
            If(self.rd_addr.re,
               rd_req.eq(~rd_req),
               rd_done.eq(0),
            ).Elif(rd_req == rd_ack_s,
               rd_done.eq(1),
            ),
        ]

        rd_req_s = Signal()
        rd_pend  = Signal()
        rd_hold  = Signal(256)
        self.specials += MultiReg(rd_req, rd_req_s, "gs")
        self.comb += h_rd_addr.eq(self.rd_addr.storage)   # stable across the crossing
        self.sync.gs += [
            h_rd_en.eq(0),
            If((rd_req_s != rd_ack) & ~rd_pend,
               h_rd_en.eq(1),
               rd_pend.eq(1),
            ),
            If(rd_pend & h_rd_valid,
               rd_hold.eq(h_rd_data),
               rd_pend.eq(0),
               rd_ack.eq(rd_req_s),
            ),
        ]
        self.comb += [self.rd_data[i].status.eq(rd_hold[32*i:32*(i+1)])
                      for i in range(8)]

        # ---- free-running status, snapshotted -------------------------------
        snap_cnt = Signal(6)
        snap     = Signal(112)
        snap_tog = Signal()
        self.sync.gs += [
            snap_cnt.eq(snap_cnt + 1),
            If(snap_cnt == 0, snap.eq(Cat(dbg_pix, dbg_unk, dbg_reg))),
            If(snap_cnt == 1, snap_tog.eq(~snap_tog)),
        ]
        tog_s, tog_d = Signal(), Signal()
        hold = Signal(112)
        self.specials += MultiReg(snap_tog, tog_s, "sys")
        self.sync += [
            tog_d.eq(tog_s),
            If(tog_s != tog_d, hold.eq(snap)),
        ]
        ready_s = Signal()
        self.specials += MultiReg(gif_ready, ready_s, "sys")
        self.comb += [
            self.status.fields.busy.eq(push_busy),
            self.status.fields.ready.eq(ready_s),
            self.status.fields.rd_done.eq(rd_done),
            self.pixels.status.eq(hold[0:32]),
            self.unknown.status.eq(hold[32:48]),
            self.dbg_lo.status.eq(hold[48:80]),
            self.dbg_hi.status.eq(hold[80:112]),
        ]

        # ---- the display's crossings ---------------------------------------
        # Same three patterns as everything above: a level crosses in two flops,
        # a request that must happen exactly once crosses as a toggle, and the
        # data beside it is stable across the crossing because the host wrote it
        # before the request and does not touch it until the answer comes back.
        pr_we   = Signal()
        pr_addr = Signal(8)
        pr_data = Signal(64)
        disp_en_gs = Signal()
        px_valid, px_sof = Signal(), Signal()
        px_rgb  = Signal(24)
        px_x, px_y = Signal(12), Signal(12)
        crtc_rd_gs, crtc_st_gs = Signal(32), Signal(32)
        cap_arm_gs, cap_busy_gs, cap_done_gs = Signal(), Signal(), Signal()
        cap_count_gs = Signal(13)
        cap_data_gs  = Signal(24)

        self.comb += pr_addr.eq(self.pr_addr.storage)
        self.comb += pr_data.eq(Cat(self.pr_d0.storage, self.pr_d1.storage))
        self.specials += MultiReg(self.disp_en.storage[0], disp_en_gs, "gs")
        self.specials += MultiReg(self.cap_arm.storage[0], cap_arm_gs, "gs")
        self.specials += MultiReg(cap_busy_gs, self.cap_stat.fields.busy, "sys")
        self.specials += MultiReg(cap_done_gs, self.cap_stat.fields.done, "sys")
        self.specials += MultiReg(cap_count_gs, self.cap_count.status, "sys")
        self.specials += MultiReg(cap_data_gs,  self.cap_data.status,  "sys")
        self.specials += MultiReg(crtc_rd_gs,   self.crtc_rd.status,   "sys")
        self.specials += MultiReg(crtc_st_gs,   self.crtc_stall.status,"sys")

        pr_req, pr_ack, pr_ack_s, pr_busy = Signal(), Signal(), Signal(), Signal()
        self.specials += MultiReg(pr_ack, pr_ack_s, "sys")
        self.comb += pr_busy.eq(pr_req != pr_ack_s)
        self.sync += If(self.pr_push.re & ~pr_busy, pr_req.eq(~pr_req))
        pr_req_s = Signal()
        self.specials += MultiReg(pr_req, pr_req_s, "gs")
        self.sync.gs += [
            pr_we.eq(0),
            If(pr_req_s != pr_ack, pr_we.eq(1), pr_ack.eq(pr_req_s)),
        ]

        self.specials += Instance("gs_pxcap",
            p_ADDR_BITS = 12,
            i_clk     = ClockSignal("gs"),
            i_reset   = gs_rst,
            i_px_valid= px_valid,
            i_px_rgb  = px_rgb,
            i_px_sof  = px_sof,
            i_arm     = cap_arm_gs,
            o_busy    = cap_busy_gs,
            o_done    = cap_done_gs,
            o_count   = cap_count_gs,
            i_rd_addr = self.cap_addr.storage,
            o_rd_data = cap_data_gs,
        )

        self.specials += Instance("gs_top",
            p_ADDR_BITS = 17,
            i_clk       = ClockSignal("gs"),
            i_reset     = gs_rst,
            i_gif_valid = gif_valid,
            i_gif_data  = gif_data,
            o_gif_ready = gif_ready,
            i_h_rd_en   = h_rd_en,
            i_h_rd_addr = h_rd_addr,
            o_h_rd_data = h_rd_data,
            o_h_rd_valid= h_rd_valid,
            i_dbg_sel   = self.dbg_sel.storage,
            o_dbg_reg   = dbg_reg,
            o_dbg_unknown = dbg_unk,
            o_dbg_pixels  = dbg_pix,
            i_pr_we       = pr_we,
            i_pr_addr     = pr_addr,
            i_pr_data     = pr_data,
            i_h_total     = self.h_total.storage,
            i_v_total     = self.v_total.storage,
            i_disp_enable = disp_en_gs,
            o_px_valid    = px_valid,
            o_px_rgb      = px_rgb,
            o_px_x        = px_x,
            o_px_y        = px_y,
            o_px_sof      = px_sof,
            o_dbg_crtc_rd    = crtc_rd_gs,
            o_dbg_crtc_stall = crtc_st_gs,
        )
        add_gs_sources(platform)


# 147.455867 MHz is what the two MMCMs actually produce; the nominal is what
# the console runs at.  The difference is 0.90 ppm and the constraint is derived
# by Vivado from the MMCM anyway, so this number is only ever used for LiteX's
# own bookkeeping -- but writing the real one keeps it from reading as if the
# card were making 147.456 exactly.
GS_CLK_FREQ = 147.456e6

# What `sys` runs at in this build.  Not the console's clock: see the header --
# sys is deliberately on the proven LiteX MMCM while the PS2 clock tree is
# measured beside it.
SYS_CLK_FREQ = 125e6


class GSSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=SYS_CLK_FREQ):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 GS bring-up x{nlanes} {speed}")

        self.crg = _GSCRG(platform, sys_clk_freq)

        # ---- hbm_cattrip, driven low, and why HBM is not instantiated ------
        #
        # BE45 must be driven or the satellite controller powers the card off.
        # This target used to satisfy that by instantiating the whole HBM
        # controller, on the grounds that it carries the *real* over-temperature
        # output and tying the pin low would make an overheating card look
        # healthy.  That reasoning is sound for a design that uses HBM.  This
        # one does not: the Graphics Synthesizer keeps its 4 MB in UltraRAM and
        # never touches the stacks.
        #
        # And the power report says what it was costing.  Of 22.058 W on chip,
        # **HBM was 17.627 W** -- eighty per cent of the design's power, for one
        # pin.  Everything that is actually the GS -- clocks, signals, block RAM,
        # UltraRAM, DSPs, the MMCMs -- comes to about 0.6 W.
        #
        # That matters because of what this project is for.  A PlayStation 2
        # draws somewhere between 35 and 79 W depending on the model, and a
        # replication that needs more power than the machine it replicates is
        # not a replication anybody would use.  Seventeen watts spent keeping
        # idle memory refreshed so that it can report its own temperature is the
        # opposite of that trade.
        #
        # The over-temperature argument also inverts once HBM is not running:
        # the heat CATTRIP exists to warn about is the heat of the stacks being
        # driven, and they are not being driven.  When the Emotion Engine's main
        # memory arrives HBM comes back, and so does the real output.
        self.comb += platform.request("hbm_cattrip").eq(0)

        pcie_pads = platform.request(f"pcie_x{nlanes}")
        self.pcie_phy = USPHBMPCIEPHY(platform, pcie_pads,
                                      speed      = speed,
                                      data_width = {1:64, 4:128, 8:256, 16:512}[nlanes],
                                      bar0_size  = 0x20000)
        # BAR0 must be 64-bit prefetchable on this card; a 32-bit BAR lands in a
        # window the firmware never routed and every access reads 0xFFFFFFFF
        # with no error at either end (docs/c1100-pcie-transport.md).
        self.pcie_phy.update_config({
            "pf0_bar0_64bit":        "true",
            "pf0_bar0_prefetchable": "true",
        })
        self.add_pcie(phy=self.pcie_phy, ndmas=1,
                      with_dma_buffering = True, dma_buffering_depth=1024,
                      with_dma_loopback  = False)

        self.gs = GSBringup(platform, clk_locked=self.crg.ps2.locked)

        # Everything crossing sys <-> gs is either two-flop synchronised, gray
        # coded, or data held stable by a handshake for the whole crossing, so
        # the two clocks are declared asynchronous and no path between them is
        # timed.  That is a claim about the logic, not a way of silencing the
        # tool: see the crossing patterns documented in GSBringup.
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_gs.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_apb.clk)
        platform.add_false_path_constraints(self.crg.cd_apb.clk, self.crg.cd_axi.clk)


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_gs"):
    platform = xilinx_c1100.Platform(toolchain="vivado")
    soc      = GSSoC(platform, speed=speed, nlanes=nlanes)

    # The Graphics Synthesizer closes at about 152 MHz out of context and is
    # marginal at 147.456 in it -- not because the part is full (this design
    # uses three per cent of it) but because the GS ends up placed around the
    # PCIe and HBM hard blocks, and the routes stretch.  Two builds have now
    # come back on opposite sides of zero from changes that touched no datapath.
    #
    # So the implementation is told to try harder rather than left on defaults.
    # Explore placement and physical optimisation together cost perhaps twenty
    # minutes of build time, which is cheap against a bitstream that cannot be
    # trusted to behave.
    #
    # These are arguments to the toolchain's build(), not attributes of it --
    # setting them on the toolchain object looks like it works, produces no
    # error, and is silently overwritten by the defaults when build() runs.
    # The first attempt did exactly that and came back with a WNS identical to
    # the digit, which is what gave it away.
    effort = dict(
        vivado_place_directive               = "Explore",
        vivado_post_place_phys_opt_directive = "Explore",
        vivado_route_directive               = "Explore",
        vivado_post_route_phys_opt_directive = "Explore",
    )
    builder  = Builder(soc, output_dir=build_dir, compile_software=False,
                       csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build, **effort)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    # **--out exists because eliding it is destructive.** Running this file
    # without --build still writes csr.csv, so elaborating to check a change
    # overwrites the CSR map of whatever bitstream is already in the default
    # directory -- leaving a .bit and a csr.csv that disagree, which is the one
    # failure tools/pcie-bringup.sh exists to catch and the user guide warns
    # about. c1100_ee.py has taken --out from the start; this file had not.
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--x16",   action="store_true")
    ap.add_argument("--out",   default="build/c1100_gs")
    a = ap.parse_args()
    build(nlanes = 16 if a.x16 else 4, do_build = a.build, build_dir = a.out)
