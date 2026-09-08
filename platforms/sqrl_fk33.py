#
# LiteX platform for the SQRL Forest Kitten 33 (FK33).
#
# Pin data transcribed from the vendor board files at
# https://github.com/d953i/SQRL_FK33 --
#   board_files/sqrl_fk33/1.1/sqrl_fk33.xdc   (clock, I2C, LEDs, PCIe, config)
#   projects/fk33_example.xdc                 (full 16-lane PCIe map)
# The 200 MHz reference on BC26/BC27 is independently confirmed by our own
# bitstreams built and run on a physical FK33.
#
# NOTE ON I/O: the FK33 is a headless PCIe accelerator. Its ENTIRE external
# interface is the 200 MHz reference clock, PCIe (refclk / PERST# / 16 lanes),
# one I2C bus, and 7 LEDs. There is no video output, no audio, no USB, and no
# SDRAM -- so a MiSTer core hosted here cannot use the MiSTeX HDMI PHY and must
# render into a framebuffer that is DMA'd to the host over PCIe instead.
#
# SPDX-License-Identifier: BSD-2-Clause

from litex.build.generic_platform import Pins, Subsignal, IOStandard, Misc
from litex.build.xilinx import XilinxUSPPlatform, VivadoProgrammer

# IOs ----------------------------------------------------------------------------------------------

_io = [
    # Clk -- the board's only oscillator: 200 MHz LVDS.
    ("clk200", 0,
        Subsignal("p", Pins("BC26")),
        Subsignal("n", Pins("BC27")),
        IOStandard("LVDS"),
    ),

    # Leds -- 7 of them, the only human-visible output the card has.
    ("user_led", 0, Pins("BD25"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),
    ("user_led", 1, Pins("BE26"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),
    ("user_led", 2, Pins("BD23"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),
    ("user_led", 3, Pins("BF26"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),
    ("user_led", 4, Pins("BC25"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),
    ("user_led", 5, Pins("BB26"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),
    ("user_led", 6, Pins("BB25"), IOStandard("LVCMOS18"), Misc("DRIVE=8")),

    # I2C -- reaches the board's power/monitoring devices.
    ("i2c", 0,
        Subsignal("scl", Pins("BB24"), Misc("DRIVE=8"), Misc("SLEW=SLOW")),
        Subsignal("sda", Pins("BA24"), Misc("DRIVE=8"), Misc("SLEW=SLOW")),
        IOStandard("LVCMOS18"),
    ),

    # PCIe -- lane order below is the board's own lane numbering, not pin order.
    # x4 is called out separately because a card sharing a desktop with a GPU
    # will commonly negotiate down to 4 lanes.
    ("pcie_x1", 0,
        Subsignal("rst_n", Pins("BE24"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AD8")),
        Subsignal("clk_p", Pins("AD9")),
        Subsignal("rx_n",  Pins("AL1")),
        Subsignal("rx_p",  Pins("AL2")),
        Subsignal("tx_n",  Pins("Y4")),
        Subsignal("tx_p",  Pins("Y5")),
    ),
    ("pcie_x4", 0,
        Subsignal("rst_n", Pins("BE24"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AD8")),
        Subsignal("clk_p", Pins("AD9")),
        Subsignal("rx_n",  Pins("AL1 AM3 AK3 AN1")),
        Subsignal("rx_p",  Pins("AL2 AM4 AK4 AN2")),
        Subsignal("tx_n",  Pins("Y4 AA6 AB4 AC6")),
        Subsignal("tx_p",  Pins("Y5 AA7 AB5 AC7")),
    ),
    ("pcie_x8", 0,
        Subsignal("rst_n", Pins("BE24"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AD8")),
        Subsignal("clk_p", Pins("AD9")),
        Subsignal("rx_n",  Pins("AL1 AM3 AK3 AN1 AP3 AR1 AT3 AU1")),
        Subsignal("rx_p",  Pins("AL2 AM4 AK4 AN2 AP4 AR2 AT4 AU2")),
        Subsignal("tx_n",  Pins("Y4 AA6 AB4 AC6 AD4 AF4 AE6 AH4")),
        Subsignal("tx_p",  Pins("Y5 AA7 AB5 AC7 AD5 AF5 AE7 AH5")),
    ),
    ("pcie_x16", 0,
        Subsignal("rst_n", Pins("BE24"), IOStandard("LVCMOS18"), Misc("PULLUP=TRUE")),
        Subsignal("clk_n", Pins("AD8")),
        Subsignal("clk_p", Pins("AD9")),
        Subsignal("rx_n",  Pins(
            "AL1 AM3 AK3 AN1 AP3 AR1 AT3 AU1",
            "AV3 AW1 BA1 BC1 AY3 BB3 BD3 BE5")),
        Subsignal("rx_p",  Pins(
            "AL2 AM4 AK4 AN2 AP4 AR2 AT4 AU2",
            "AV4 AW2 BA2 BC2 AY4 BB4 BD4 BE6")),
        Subsignal("tx_n",  Pins(
            "Y4 AA6 AB4 AC6 AD4 AF4 AE6 AH4",
            "AG6 AJ6 AL6 AM8 AN6 AP8 AR6 AT8")),
        Subsignal("tx_p",  Pins(
            "Y5 AA7 AB5 AC7 AD5 AF5 AE7 AH5",
            "AG7 AJ7 AL7 AM9 AN7 AP9 AR7 AT9")),
    ),
]

# Connectors ---------------------------------------------------------------------------------------

# None. The FK33 exposes no expansion header, PMOD, or FMC -- which is exactly
# why the video path has to be PCIe rather than a display PHY.
_connectors = []

# Platform -----------------------------------------------------------------------------------------

class Platform(XilinxUSPPlatform):
    default_clk_name   = "clk200"
    default_clk_period = 1e9/200e6

    def __init__(self, toolchain="vivado"):
        XilinxUSPPlatform.__init__(self, "xcvu33p-fsvh2104-2-e", _io, _connectors,
                                   toolchain=toolchain)

    def create_programmer(self):
        return VivadoProgrammer()

    def do_finalize(self, fragment):
        XilinxUSPPlatform.do_finalize(self, fragment)

        # The 200 MHz reference, declared the way builds that close timing on
        # this card declare it.
        self.add_period_constraint(self.lookup_request("clk200", loose=True), 1e9/200e6)

        # Passively cooled datacenter card: it expects forced airflow it will not
        # get in a desktop chassis. Let the device shut itself down rather than
        # cook. The XCU1525 platform in litex-boards sets this for the same reason.
        self.add_platform_command("set_property BITSTREAM.CONFIG.OVERTEMPSHUTDOWN ENABLE [current_design]")

        # Board boots its golden image from x4 SPI flash; match the vendor's
        # configuration settings so a bitstream written to flash is loadable.
        self.add_platform_command("set_property CONFIG_MODE SPIx4 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.CONFIGRATE 127.5 [current_design]")
        self.add_platform_command("set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]")

        # Halves programming time on a 28 MB image.
        self.add_platform_command("set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]")
