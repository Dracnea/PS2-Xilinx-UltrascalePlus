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
# The GS runs in the *sys* clock domain, and sys is the console's own clock:
# 147.455867 MHz, 0.90 ppm off 147.456, out of the two cascaded MMCMs in
# boards/ps2_clocks.py.
#
# Two things about that are deliberate.
#
# **It is the specification, not a speed.**  This is a rebuild of the machine.
# A Graphics Synthesizer at 125 MHz is not a slow GS and one at 150 MHz is not a
# fast one; both are a GS with the wrong clock, and the integer relationships
# between the GS, the EE and the IOP are part of what the software depends on.
# 147.456 MHz is the only right answer, and the card can make it: an MMCM
# synthesises from the 100 MHz reference with a fractional multiplier, so there
# is no grid of 25 MHz steps to land on.
#
# **The GS still does not cross a clock boundary.**  Running it in its own
# domain beside a 125 MHz sys would mean a clock-domain crossing on every CSR,
# the push handshake and the read-back path -- new logic, between a block that
# is verified and a host that is trusted, at exactly the moment the clock
# changes.  Making *sys itself* the console clock avoids all of it: nothing in
# this design crosses a boundary that did not already cross one, and the PCIe
# bridge's own crossing is unchanged and already tested.  What it costs is that
# the PCIe and HBM glue must now close at 147.456 rather than 125.
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
from hbm_common import HBM
from litex.soc.cores.clock import USPMMCM
from migen.genlib.resetsync import AsyncResetSynchronizer
from ps2_clocks import PS2Clocks

REPO_ROOT = join(dirname(abspath(__file__)), "..")


def add_gs_sources(platform, root=REPO_ROOT):
    """The Graphics Synthesizer's RTL, in dependency order."""
    rtl = join(root, "rtl", "gs")
    for f in ("gs_addr_pkg.vhd", "gs_edge_dda.vhd", "gs_chan_dda.vhd", "gs_gif.vhd",
              "gs_lmem.vhd", "gs_top.vhd"):
        platform.add_source(join(rtl, f), language="vhdl")


class _GSCRG(LiteXModule):
    """The console's clock as `sys`, and the three clocks the HBM IP wants.

    Two MMCMs, for two different jobs.  The LiteX one makes the HBM reference,
    the APB clock and the 250 MHz AXI clock, none of which has anything to do
    with a PlayStation 2 and all of which are happy on integer ratios from
    100 MHz.  PS2Clocks makes the console's clock family, and its GS output is
    renamed to `sys` here so that the Graphics Synthesizer and every CSR that
    talks to it share one domain.

    The two are unrelated, so every sys <-> axi and sys <-> apb path is declared
    asynchronous; they already were when sys came from the LiteX MMCM, because
    250 and 100 MHz were never related to 125 either.
    """
    def __init__(self, platform):
        self.rst        = Signal()
        self.cd_sys     = ClockDomain()
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
        mmcm.register_clkin(self.clk100, 100e6)
        mmcm.create_clkout(self.cd_hbm_ref, 100e6, margin=0)
        mmcm.create_clkout(self.cd_apb,     100e6, margin=0)
        mmcm.create_clkout(self.cd_axi,     250e6, margin=0)

        # The GS output becomes sys.  PS2Clocks builds only the domain asked
        # for: the EE's 294.912 and the IOP's 36.864 come off the same second
        # MMCM and will be wanted when those blocks join this image, but a
        # clock domain that drives nothing is a period constraint on nothing.
        self.ps2 = PS2Clocks(platform, self.clk100, self.rst,
                             domains={"gs": self.cd_sys})

        platform.add_period_constraint(pads.p, 1e9 / 100e6)

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
        self.clk_locked = CSRStatus(1, description="both PS2 MMCMs are locked")
        self.clk_ticks  = CSRStatus(32, description="free-running sys-domain counter")
        ticks = Signal(32)
        self.sync += ticks.eq(ticks + 1)
        self.comb += self.clk_ticks.status.eq(ticks)
        if clk_locked is not None:
            self.comb += self.clk_locked.status.eq(clk_locked)

        # ---- the GS itself ------------------------------------------------
        gif_valid = Signal()
        gif_ready = Signal()
        gif_data  = Signal(128)
        h_rd_en   = Signal()
        h_rd_data = Signal(256)
        h_rd_valid = Signal()
        dbg_reg   = Signal(64)
        dbg_unk   = Signal(16)
        dbg_pix   = Signal(32)

        self.comb += gif_data.eq(Cat(self.gif_w0.storage, self.gif_w1.storage,
                                     self.gif_w2.storage, self.gif_w3.storage))

        # A push is held until the GIF takes it.  gif_ready falls for as long as
        # a primitive takes to draw, which for a large sprite is thousands of
        # cycles, so the host has to be told rather than left to guess.
        self.sync += [
            If(self.gif_push.re,
               gif_valid.eq(1),
            ).Elif(gif_valid & gif_ready,
               gif_valid.eq(0),
            ),
        ]
        self.comb += [
            self.status.fields.busy.eq(gif_valid),
            self.status.fields.ready.eq(gif_ready),
            self.pixels.status.eq(dbg_pix),
            self.unknown.status.eq(dbg_unk),
            self.dbg_lo.status.eq(dbg_reg[:32]),
            self.dbg_hi.status.eq(dbg_reg[32:]),
        ]

        # A read is one pulse, answered two cycles later.
        rd_done = Signal()
        self.sync += [
            h_rd_en.eq(0),
            If(self.rd_addr.re,
               h_rd_en.eq(1),
               rd_done.eq(0),
            ),
            If(h_rd_valid,
               rd_done.eq(1),
               *[self.rd_data[i].status.eq(h_rd_data[32*i:32*(i+1)]) for i in range(8)]
            ),
        ]
        self.comb += self.status.fields.rd_done.eq(rd_done)

        self.specials += Instance("gs_top",
            p_ADDR_BITS = 17,
            i_clk       = ClockSignal("sys"),
            i_reset     = self.reset.storage[0] | ResetSignal("sys"),
            i_gif_valid = gif_valid,
            i_gif_data  = gif_data,
            o_gif_ready = gif_ready,
            i_h_rd_en   = h_rd_en,
            i_h_rd_addr = self.rd_addr.storage,
            o_h_rd_data = h_rd_data,
            o_h_rd_valid= h_rd_valid,
            i_dbg_sel   = self.dbg_sel.storage,
            o_dbg_reg   = dbg_reg,
            o_dbg_unknown = dbg_unk,
            o_dbg_pixels  = dbg_pix,
        )
        add_gs_sources(platform)


# 147.455867 MHz is what the two MMCMs actually produce; the nominal is what
# the console runs at.  The difference is 0.90 ppm and the constraint is derived
# by Vivado from the MMCM anyway, so this number is only ever used for LiteX's
# own bookkeeping -- but writing the real one keeps it from reading as if the
# card were making 147.456 exactly.
GS_CLK_FREQ = 147.455867e6


class GSSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=GS_CLK_FREQ):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 GS bring-up x{nlanes} {speed}")

        self.crg = _GSCRG(platform)

        # The GS keeps its 4 MB in UltraRAM and wants nothing from HBM, but
        # hbm_cattrip still has to be driven or the satellite controller powers
        # the card off.  Instantiating HBM is how this repository does that, and
        # it costs nothing that matters here.
        self.hbm = HBM(platform, platform.request("hbm_cattrip"))

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

        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_apb.clk)
        platform.add_false_path_constraints(self.crg.cd_apb.clk, self.crg.cd_axi.clk)


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_gs"):
    platform = xilinx_c1100.Platform(toolchain="vivado")
    soc      = GSSoC(platform, speed=speed, nlanes=nlanes)
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
