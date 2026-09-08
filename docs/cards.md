# Cards: what a port needs, and what each one costs

The point of this repository's layout is that the console is card-independent.
`rtl/` is the PS2; `boards/` wires it to one card; `platforms/` describes that
card. A port is a platform file and a board target, not a fork of the RTL.

## What exists

| | Varium C1100 (Alveo U55N) | SQRL Forest Kitten 33 |
|---|---|---|
| device | `xcu55n-fsvh2892-2LV-e` | `xcvu33p-fsvh2104-2-e` |
| LUTs | 871,680 | 439,680 |
| **UltraRAM** | **640** | **320** |
| BRAM tiles | 1,344 | 672 |
| reference clock | 100 MHz LVDS (BK43/BK44) | 200 MHz LVDS (BC26/BC27) |
| external I/O | PCIe, USB JTAG/UART, I2C | PCIe, I2C, 7 LEDs |
| board target | `boards/c1100_ps2_iop.py`, `boards/c1100_ps2_diag.py` | `boards/fk33_ps2_iop.py` |
| **verified** | **on silicon**: a real BIOS boots its IOP kernel to completion | **build only — no FK33 is attached to the machine this was written on** |

Neither card has video or audio output, so the picture will always leave over
PCIe. That is a property of this class of accelerator card, not a temporary
limitation: they are headless datacenter parts.

## The IOP, measured on both

Out-of-context synthesis of `iop_top`, clocks 27.126 / 13.563 / 9.042 ns
(`fit/run_fit.sh <part>`), 2026-09-08:

| | xcu55n | xcvu33p |
|---|---:|---:|
| CLB LUTs | 16,615 (1.9 %) | 16,615 (3.78 %) |
| CLB registers | 12,594 (0.7 %) | 12,594 (1.43 %) |
| BRAM tiles | 57.5 (4.3 %) | 57.5 (8.56 %) |
| **URAM** | **224 (35 %)** | **224 (70 %)** |
| DSP | 34 | 34 |
| WNS | +20.7 ns | **+8.339 ns**, 0 failing of 57,865 |

**It fits on both, and timing is not the constraint on either.** UltraRAM is.

## The UltraRAM ceiling, which shapes everything after this

The IOP's 224 UltraRAMs are:

| | URAM | why |
|---|---:|---|
| BIOS ROM (4 MB) | 128 | the console's real ROM size; a BIOS needs all of it |
| IOP RAM (2 MB) | 64 | the console's real RAM size |
| SPU2 work RAM (2 × 512 KB) | 32 | one per SPU core |

On the C1100 that leaves 416 UltraRAMs spare. **On the FK33 it leaves 96**, and
the Graphics Synthesizer's 4 MB of local memory is another 128 on its own — so
a whole console will not fit on an FK33 with everything on-chip. The ways out,
in the order they are worth trying:

1. Move the BIOS ROM off-chip. It is read-only and mostly cold after boot; HBM
   or a host-served window would free 128 URAM at once. `ROM_ROWS_LOG2` on
   `iop_ram` already makes the depth a generic.
2. Move the GS's local memory to HBM. Both cards have HBM, unused so far.
3. Keep the FK33 as an IOP-and-peripherals card and put the EE and GS on the
   larger part.

None of this is urgent, and none of it should be designed around before the GS
exists. It is written down because 70 % of a device consumed by the smallest
processor in the system is the kind of number that decides an architecture, and
it is better known now than discovered later.

## Porting to a third card

1. A platform file in `platforms/`: pins for the reference clock and PCIe, the
   part number, and whatever the board demands to stay alive — the C1100 needs
   `hbm_cattrip` driven low or the satellite controller powers the card off;
   the FK33 has no such pin.
2. A board target in `boards/`. The pattern is in `fk33_ps2_iop.py`, which is
   deliberately thin: a CRG for that card's reference clock, the PCIe endpoint,
   then the shared `_IOPClocks` and `IOPBringup`.
3. The IOP MMCM. The three IOP clocks must come from **one** MMCM with integer
   output dividers, because the PSX CPU core samples across them directly. Aim
   for a **1106.25 MHz VCO** and divide by 30 / 15 / 10, giving
   36.875 / 73.75 / 110.625 MHz — 0.03 % above the console's 36.864 MHz, which
   integer ratios cannot reach exactly. Both cards use `CLKFBOUT_MULT_F =
   22.125` and differ only in `DIVCLK_DIVIDE` (2 from 100 MHz, 4 from 200 MHz).
   Keep the multiplier on the 0.125 grid *as printed to three decimals*:
   bitgen's DRC AVAL-168 rejected `11.0625` because the generated Verilog wrote
   it as `11.062`.
4. Check the fit before building: `fit/run_fit.sh <part>` sizes the IOP on any
   part in minutes, which is much cheaper than discovering it in bitgen.
5. `tools/jtag-load.sh <image> <device-glob>` takes a device pattern for
   machines with more than one card on the JTAG chain.
