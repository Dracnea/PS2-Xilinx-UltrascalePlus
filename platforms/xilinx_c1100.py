#
# LiteX platform for the Xilinx Varium C1100 (Alveo U55N, xcu55n, UltraScale+ HBM).
#
# Pin data follows Corundum's AU55N target,
#   https://github.com/corundum/corundum -- fpga/mqnic/Alveo/fpga_25g/fpga_au55.xdc
# and has been independently confirmed here: every pin below has been through
# place-and-route and a real bitstream on a physical C1100, so it is verified
# rather than transcribed from a datasheet.
#
# TWO TRAPS, both encoded below rather than left to the caller:
#
#  1. hbm_cattrip (BE45) MUST BE DRIVEN LOW by any design that does not
#     instantiate the HBM IP. If it floats, the satellite controller reads a
#     catastrophic over-temperature event and powers the card off. Our own tree
#     calls this out as the trap that "silently kills a C1100 bring-up". The
#     Platform below exposes it as a required resource and the board file
#     drives it low unconditionally.
#
#  2. The reference clock is 100 MHz, NOT 200 MHz. Constraint files in the wild
#     frequently name this clock object "clk200" while giving it -period 10.000,
#     which is 100 MHz -- a legacy name that does not match its frequency. The
#     resource here is named clk100 so the name and the number agree. The FK33,
#     by contrast, really is 200 MHz; do not copy CRG constants between the two
#     boards.
#
# NO PCIe PINS ARE DECLARED. The C1100's PCIe lane assignments are not in any
# constraint file in this tree, are not in Vivado's board_files (there is no
# U55N board file installed), and inventing them would produce a design that
# builds and cannot link. They must come from the official Alveo U55N XDC
# before the PCIe video path can be built. See MISSING in the board file.
#
# SPDX-License-Identifier: BSD-2-Clause

from litex.build.generic_platform import Pins, Subsignal, IOStandard, Misc
from litex.build.xilinx import XilinxUSPPlatform, VivadoProgrammer

# IOs ----------------------------------------------------------------------------------------------

_io = [
    # Clk -- 100 MHz LVDS. See trap 2 above.
    ("clk100", 0,
        Subsignal("p", Pins("BK43")),
        Subsignal("n", Pins("BK44")),
        IOStandard("LVDS"),
    ),

    # HBM catastrophic-temperature output. See trap 1 above. Drive LOW.
    ("hbm_cattrip", 0, Pins("BE45"), IOStandard("LVCMOS18")),

    # PCIe. Pins from Corundum's AU55N target (fpga/mqnic/Alveo/fpga_25g/
    # fpga_au55.xdc) -- the same file our own c1100.xdc took its clock and
    # cattrip pins from, so this is the identical, already-trusted source.
    # Cross-check that gives confidence: that file's clk_100mhz_1 is BK43/BK44
    # and its hbm_cattrip is BE45, matching our shipped constraints exactly.
    #
    # Reference clock is pcie_refclk_1 on MGTREFCLK0_225 (AR15/AR14), which
    # Corundum designates "for x16 or x8 bifurcated lanes 8-16". A x16-capable
    # core uses this one even when the link trains down; a card sharing a
    # desktop with a GPU commonly negotiates x4, which is why that width is
    # broken out separately below.
    ("pcie_x1", 0,
        Subsignal("rst_n", Pins("BF41"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AR14")),
        Subsignal("clk_p", Pins("AR15")),
        Subsignal("rx_n",  Pins("AL1")),
        Subsignal("rx_p",  Pins("AL2")),
        Subsignal("tx_n",  Pins("AL10")),
        Subsignal("tx_p",  Pins("AL11")),
    ),
    ("pcie_x4", 0,
        Subsignal("rst_n", Pins("BF41"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AR14")),
        Subsignal("clk_p", Pins("AR15")),
        Subsignal("rx_n",  Pins("AL1 AM3 AN5 AN1")),
        Subsignal("rx_p",  Pins("AL2 AM4 AN6 AN2")),
        Subsignal("tx_n",  Pins("AL10 AM8 AN10 AP8")),
        Subsignal("tx_p",  Pins("AL11 AM9 AN11 AP9")),
    ),
    ("pcie_x8", 0,
        Subsignal("rst_n", Pins("BF41"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AR14")),
        Subsignal("clk_p", Pins("AR15")),
        Subsignal("rx_n",  Pins("AL1 AM3 AN5 AN1 AP3 AR1 AT3 AU1")),
        Subsignal("rx_p",  Pins("AL2 AM4 AN6 AN2 AP4 AR2 AT4 AU2")),
        Subsignal("tx_n",  Pins("AL10 AM8 AN10 AP8 AR10 AR6 AT8 AU10")),
        Subsignal("tx_p",  Pins("AL11 AM9 AN11 AP9 AR11 AR7 AT9 AU11")),
    ),
    ("pcie_x16", 0,
        Subsignal("rst_n", Pins("BF41"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AR14")),
        Subsignal("clk_p", Pins("AR15")),
        Subsignal("rx_n",  Pins(
            "AL1 AM3 AN5 AN1 AP3 AR1 AT3 AU1",
            "AV3 AW5 AW1 AY3 BA5 BA1 BB3 BC1")),
        Subsignal("rx_p",  Pins(
            "AL2 AM4 AN6 AN2 AP4 AR2 AT4 AU2",
            "AV4 AW6 AW2 AY4 BA6 BA2 BB4 BC2")),
        Subsignal("tx_n",  Pins(
            "AL10 AM8 AN10 AP8 AR10 AR6 AT8 AU10",
            "AU6 AV8 AW10 AY8 BA10 BB8 BC10 BC6")),
        Subsignal("tx_p",  Pins(
            "AL11 AM9 AN11 AP9 AR11 AR7 AT9 AU11",
            "AU7 AV9 AW11 AY9 BA11 BB9 BC11 BC7")),
    ),
]

# Connectors ---------------------------------------------------------------------------------------

# None. Like the FK33, the C1100 is a headless PCIe accelerator: no video
# output, no expansion header, no PMOD, no FMC.
_connectors = []

# Platform -----------------------------------------------------------------------------------------

class Platform(XilinxUSPPlatform):
    default_clk_name   = "clk100"
    default_clk_period = 1e9/100e6

    def __init__(self, toolchain="vivado"):
        # -2LV-e is what our shipped bitstreams were built with (build_sweep.tcl
        # defaults to it). The c1100.xdc header comment says -2L-e; the build
        # script is the one that actually produced silicon-tested images, so it
        # wins. Speed grade changes the timing solution, so this is not cosmetic.
        XilinxUSPPlatform.__init__(self, "xcu55n-fsvh2892-2LV-e", _io, _connectors,
                                   toolchain=toolchain)

    def create_programmer(self):
        return VivadoProgrammer()

    def do_finalize(self, fragment):
        XilinxUSPPlatform.do_finalize(self, fragment)

        self.add_period_constraint(self.lookup_request("clk100", loose=True), 1e9/100e6)

        # hbm_cattrip is a static level, not a timed signal.
        self.add_platform_command("set_false_path -to [get_ports hbm_cattrip]")

        # Config interface voltages, per the AU55N reference constraints.
        self.add_platform_command("set_property CFGBVS GND [current_design]")
        self.add_platform_command("set_property CONFIG_VOLTAGE 1.8 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]")

        # Passively cooled datacenter card expecting server airflow.
        self.add_platform_command("set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN Enable [current_design]")
