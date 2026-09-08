# PS2 on Xilinx UltraScale+

A PlayStation 2 rebuilt in FPGA fabric, targeting AMD/Xilinx UltraScale+
accelerator cards rather than the Intel parts the MiSTer/MiSTeX world is built
around. The card is a peripheral: an ordinary PC loads it over PCIe, feeds it
a BIOS, and gets the picture back.

**Where this is today: the I/O processor works and boots a real BIOS.** The
Emotion Engine, the Vector Units and the Graphics Synthesizer do not exist
yet. Nothing here plays a game.
[docs/roadmap.md](docs/roadmap.md) counts what exists against what does not
and says which milestone is which — including the one three blocks away where
your own game disc first becomes a useful test.

## What runs

On a Xilinx Alveo U55N / Varium C1100 (`xcu55n`), verified on silicon:

| | |
|---|---|
| IOP subsystem | R3000A CPU, memory mux, 2 MB RAM and 4 MB ROM in UltraRAM, INTC, six timers, SPU2 (two PSX SPU cores), SIO2 with a digital pad, CDVD with no disc |
| Boot test | 12 POST stages, RAM, cache, timers, interrupts, SPU2, SIO2, CDVD — passes on the card in 10 ms |
| **A real 4 MB retail BIOS** | **the IOP kernel boots to completion**: POST `FC 02 03 04 05 08 09` in 1.654 ms, then all 29 modules are processed and the IOP raises `SMFLAG = SIFINIT \| CMDINIT \| BOOTEND`. The Emotion Engine's half of the SIF mailbox is played by the host |
| Cost | 22,639 LUTs (2.6 %), 83 BRAM, 227 URAM (35 %) of the C1100, timing closed with +0.376 ns |

The detail, with measurements: [docs/ps2-bios-boot.md](docs/ps2-bios-boot.md)
(what a BIOS asks of the hardware and how far it gets),
[docs/ps2-iop-bringup.md](docs/ps2-iop-bringup.md) (simulation, fit, bitstream),
[docs/iop-subsystem.md](docs/iop-subsystem.md) (what each RTL file is).

## Layout

```
boards/       LiteX board targets: the PCIe endpoint plus the IOP on CSRs
platforms/    the C1100 platform definition (pins, clocks, HBM)
rtl/iop/      the PS2 IOP: everything new or modified for this design
rtl/psx/      PSX_MiSTer support files modified for UltraScale+ inference
rtl/altera_compat/   stand-ins for Intel megafunctions
third_party/PSX_MiSTer/   submodule: the CPU, SPU, timers and memory controller
sim/          xsim testbench and the R3000 boot test, with its assembler
fit/          out-of-context synthesis, for sizing a die before a full build
tools/        host side: load a ROM, watch POST, read memory back, read a rom0
docs/         measurements and what they establish
bitstreams/   built images, so a card can be brought up without a Vivado seat
```

## Getting started

```sh
git clone --recursive git@github.com:Dracnea/PS2-Xilinx-UltrascalePlus.git
cd PS2-Xilinx-UltrascalePlus
# already cloned? git submodule update --init third_party/PSX_MiSTer
```

The RTL needs nothing but Vivado. The board targets and host tools need a
Python environment with LiteX:

```sh
python3 -m venv venv && . venv/bin/activate
pip install migen
pip install git+https://github.com/enjoy-digital/litex.git
pip install git+https://github.com/enjoy-digital/litepcie.git
pip install git+https://github.com/enjoy-digital/litescope.git
```

Any LiteX virtualenv will do — the tools look at `$PS2_VENV`, then `./venv`.

Simulate, size, build:

```sh
cd sim && ./run_sim.sh                    # boot test in xsim, ~4 min, prints PASS
cd fit && ./run_fit.sh                    # out-of-context synthesis on xcu55n
venv/bin/python boards/c1100_ps2_diag.py --build     # full bitstream, ~20 min
```

Running one on a card, and loading your own BIOS, is
[docs/user-guide.md](docs/user-guide.md).

## Hardware

The C1100 is the bring-up target and the only card verified on silicon here.
A second target, the SQRL Forest Kitten 33 (`xcvu33p`), builds and closes
timing but **has never run** — no FK33 is attached to the machine this was
developed on. What each card costs, and what porting to a third involves, is
[docs/cards.md](docs/cards.md).

The number that shapes the future is UltraRAM: the IOP needs 224 of them, which
is 35 % of the C1100 and **70 % of the FK33**, and 128 of the 224 are the 4 MB
BIOS ROM. The Graphics Synthesizer's local memory is another 128. Both cards
have unused HBM, which is where those two are likely to end up.

## BIOS and disc images

None are in this repository and none ever will be. A PS2 BIOS is Sony's, and
the only legitimate copy is the one you dump from a console you own. The tools
read whatever dump you point them at; `.gitignore` refuses `*.bin` so one
cannot be committed by accident.

## Licence

**GPL-2.0** — the IOP reuses and derives from PSX_MiSTer. The details, and a
correction to how this was previously labelled, are in
[LICENSING.md](LICENSING.md).

## Credit

The CPU, SPU, timers and memory controller are Robert Peip's
[PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer). The board and
transport plumbing follows [LiteX](https://github.com/enjoy-digital/litex) and
[MiSTeX-ports](https://github.com/MiSTeX-devel/MiSTeX-ports). The PS2's
hardware is documented publicly by [ps2tek](https://psi-rockin.github.io/ps2tek/),
PCSX2 and PS2SDK; no leaked source is used here, and none ever will be.
