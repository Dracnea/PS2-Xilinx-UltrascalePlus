#!/usr/bin/env python3
#
# The PS2 IOP on the SQRL Forest Kitten 33 (FK33, xcvu33p).
#
# The same design as boards/c1100_ps2_iop.py -- a LitePCIe endpoint plus the IOP
# subsystem on CSRs -- against a different card.  Everything card-specific is in
# this file and platforms/sqrl_fk33.py; the RTL is untouched, which is the point
# of the repository being laid out this way.
#
# Build, from the root of this repository:
#   venv/bin/python boards/fk33_ps2_iop.py --build
#
# > **NOTE (unverified): no FK33 is attached to the machine this was written on.**
# > Everything here is verified only as far as "synthesises, places, routes and
# > closes timing".  Nothing in this file has run on silicon, and the PCIe
# > numbers in particular -- lane count, link speed, whether the BAR lands in a
# > routed window on a given host -- are inherited from the C1100 work and
# > assumed, not measured.
# > *Verify by: loading it on an FK33 and running tools/ps2iop/hw-test.sh.*
#
# What differs from the C1100:
#
#   * The reference clock.  The FK33's only oscillator is a 200 MHz LVDS pair
#     on BC26/BC27; the C1100 has 100 MHz on BK43/BK44.  The IOP MMCM keeps the
#     same 1106.25 MHz VCO by dividing by 4 instead of 2, so the IOP clocks are
#     bit-for-bit the same 36.875 / 73.75 / 110.625 MHz.
#   * No `hbm_cattrip`.  That pin is a C1100 requirement (floating it powers the
#     card off through the satellite controller); the FK33 has no such pin and
#     requesting one would fail.
#   * Fit.  The IOP costs 224 UltraRAMs, which is 35 % of the C1100's 640 and
#     **70 % of the FK33's 320** -- measured, out of context, on 2026-09-08:
#     16,615 LUTs (3.78 %), 12,594 registers, 57.5 BRAM, 34 DSP, WNS +8.339 ns
#     with 0 failing endpoints of 57,865.  It fits, with the 4 MB BIOS ROM
#     being 128 of those 224.  A design that wants much more UltraRAM on this
#     card will have to shrink the ROM (`ROM_ROWS_LOG2` on iop_ram) or move it
#     off-chip.
#   * LEDs.  The FK33 has seven; one carries a heartbeat so a loaded card shows
#     something without a host.
#
# SPDX-License-Identifier: BSD-2-Clause

import sys
from os.path import join, dirname, abspath

sys.path.insert(0, dirname(abspath(__file__)))
sys.path.insert(0, join(dirname(abspath(__file__)), "..", "platforms"))

from migen import *
from litex.gen.fhdl.module import LiteXModule
from litex.soc.cores.clock import USPMMCM
from litex.soc.integration.soc_core import SoCMini
from litex.soc.integration.builder import Builder

from litepcie.phy.usppciephy import USPHBMPCIEPHY
from litepcie.software import generate_litepcie_software

import sqrl_fk33
from c1100_ps2_iop import _IOPClocks, IOPBringup, add_iop_sources


class _CRG(LiteXModule):
    """200 MHz LVDS reference (BC26/BC27) -> 125 MHz sys clock.

    Buffered once here and handed to both MMCMs, as on the C1100; margin=0
    forces integer dividers so the sys clock is exact.
    """
    def __init__(self, platform, sys_clk_freq):
        self.rst    = Signal()
        self.cd_sys = ClockDomain()
        self.clkref = Signal()          # buffered reference for the IOP MMCM

        pads   = platform.request("clk200")
        clk_se = Signal()
        self.specials += Instance("IBUFDS", i_I=pads.p, i_IB=pads.n, o_O=clk_se)
        self.specials += Instance("BUFG",   i_I=clk_se, o_O=self.clkref)

        self.mmcm = mmcm = USPMMCM(speedgrade=-2, name="sys_mmcm")
        self.comb += mmcm.reset.eq(self.rst)
        mmcm.register_clkin(self.clkref, 200e6)
        mmcm.create_clkout(self.cd_sys, sys_clk_freq, margin=0)

        platform.add_period_constraint(pads.p, 1e9/200e6)


class FK33PS2IOPSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=125e6):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"FK33 PS2 IOP bring-up x{nlanes} {speed}")

        self.crg = _CRG(platform, sys_clk_freq)

        pcie_pads = platform.request(f"pcie_x{nlanes}")
        self.pcie_phy = USPHBMPCIEPHY(platform, pcie_pads,
                                      speed      = speed,
                                      data_width = {1:64, 4:128, 8:256, 16:512}[nlanes],
                                      bar0_size  = 0x20000)
        # 64-bit prefetchable for the same reason as the C1100: a 32-bit BAR can
        # land in a window the host firmware never routed, and then every
        # register reads 0xffffffff with no error anywhere
        # (docs/c1100-pcie-transport.md).  Not measured on this card.
        self.pcie_phy.update_config({
            "pf0_bar0_64bit":        "true",
            "pf0_bar0_prefetchable": "true",
        })
        self.add_pcie(phy=self.pcie_phy, ndmas=1,
                      with_dma_buffering = True, dma_buffering_depth=1024,
                      with_dma_loopback  = False)

        # The IOP: same VCO, reached from 200 MHz instead of 100.
        self.iop_clocks = _IOPClocks(platform, self.crg.clkref, self.crg.rst,
                                     clkin_period=5.0, divclk_divide=4,
                                     ref_clk_name="clk200_p")
        self.iop        = IOPBringup(platform, self.iop_clocks.locked)

        # A heartbeat on LED 0, so a loaded card is visibly alive with no host.
        led  = platform.request("user_led", 0)
        beat = Signal(26)
        self.sync += beat.eq(beat + 1)
        self.comb += led.eq(beat[25])


def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/fk33_ps2_iop"):
    platform = sqrl_fk33.Platform(toolchain="vivado")
    soc      = FK33PS2IOPSoC(platform, speed=speed, nlanes=nlanes)
    builder  = Builder(soc, output_dir=build_dir, compile_software=False,
                       csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    build(nlanes = 16 if "--x16" in sys.argv else (8 if "--x8" in sys.argv else 4),
          do_build = "--build" in sys.argv)
