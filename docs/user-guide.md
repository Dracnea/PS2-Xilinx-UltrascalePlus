# Running the PS2 IOP on your own card

For someone who owns a Varium C1100 (Alveo U55N) and wants to run what is here
today, without reading the rest of the docs. It says what the card can do
right now, what it cannot, and gives the exact steps for each thing it can.
Everything below was run on real hardware; the measurements behind each claim
are in the linked pages.

## What you get today, honestly

| you can | you cannot yet |
|---|---|
| Load a bitstream over the card's USB JTAG and talk to it over PCIe from Linux, or over the card's UART with no driver and no root at all | Play a game. There is no Emotion Engine, no Vector Unit, no Graphics Synthesizer |
| Run the PS2 I/O processor — R3000A, RAM and ROM, timers, interrupt controller, SPU2 stand-in, SIO2 with a pad, CDVD with no disc | See a picture. Video comes from the GS, which does not exist |
| **Load your own BIOS dump and watch it boot**: the reset code, then the IOP kernel loading 21 of its 29 modules | Get past that. The last modules want DMA and a SIF with an EE behind it, and both are register stubs |
| Read the IOP's RAM and ROM back for a post-mortem, and see which modules loaded | Use Windows. The PCIe driver is Linux only |
| Build every image yourself from source with Vivado | |

## What you need

- **Card:** a Varium C1100 in a PCIe slot (x4 or wider; it trains at gen3 x4),
  with its USB cable to the host — that is the on-board FT4232H carrying JTAG
  and the UART. Forced airflow over the heatsink: these are passively cooled
  datacenter cards and a desktop chassis gives them none.
- **Host:** x86-64 Linux (Ubuntu 24.04 here). Kernel headers for the running
  kernel, `gcc`, `make`, `python3` 3.10+, `pciutils`, `usbutils`.
- **To load bitstreams:** Vivado, or the free **Vivado Lab Edition**, on PATH.
  Nothing else is needed to use the prebuilt images in `bitstreams/`.
- **To build them:** Vivado 2026.1 and a LiteX virtualenv (README.md).
- **Your own PS2 BIOS**, dumped from your own console. It is not in this
  repository and is not downloaded from anywhere.

Add yourself to `plugdev` (`sudo usermod -aG plugdev $USER`, then log in
again); the udev rules below give that group the JTAG, UART and PCIe nodes.

## One-time host setup

```sh
git clone --recursive git@github.com:Dracnea/PS2-Xilinx-UltrascalePlus.git
cd PS2-Xilinx-UltrascalePlus

# USB JTAG and the FPGA UART, usable without root
sudo tee /etc/udev/rules.d/99-ftdi-fpga.rules >/dev/null <<'RULES'
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6011", MODE="0666", GROUP="plugdev"
RULES
# /dev/litepcie0 usable without root
sudo cp tools/99-litepcie.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

`lsusb` should list `0403:6011 ... FT4232H`, and `lspci -d 10ee:` the card.

### The driver must match the image

The LitePCIe kernel module is generated per bitstream with that image's
register addresses compiled in. **Use the driver from the build that made the
image you loaded.** You do not need Vivado for that part — generating the
software takes seconds:

```sh
venv/bin/python boards/c1100_ps2_diag.py          # no --build: writes build/c1100_ps2_diag/software
make -C build/c1100_ps2_diag/software/kernel
make -C build/c1100_ps2_diag/software/user
```

`bitstreams/c1100_ps2_diag.bit` goes with `build/c1100_ps2_diag`, and
`bitstreams/c1100_ps2_iop.bit` with `build/c1100_ps2_iop`. Point the scripts
somewhere else with `LITEPCIE_SW=/path/to/build/<target>/software`.

## Loading an image and bringing PCIe up

```sh
tools/jtag-load.sh bitstreams/c1100_ps2_diag.bit      # ~45 s over USB JTAG
sudo tools/pcie-bringup.sh c1100_ps2_diag
```

The second step matters on every load. The host enumerated the card at boot
with whatever was in its flash; after a JTAG load it still holds that stale
identity, so the script removes the PCI device, rescans, loads the matching
driver and prints what it found. Expect `10ee:9034`, `LnkSta: Speed 8GT/s,
Width x4`, and `Region 0: Memory at ... (64-bit, prefetchable) [size=128K]`.

**If every register reads `0xffffffff`** with the link up and nothing logged,
that is the host's memory window, not the card — the whole investigation is in
[c1100-pcie-transport.md](c1100-pcie-transport.md). Every image here declares
its BAR 64-bit prefetchable for that reason.

## Driving the card with no driver and no root

Every register is also reachable over the card's own UART through LiteX's
`litex_server`, needing no kernel module, no `insmod` and no `sudo` — only
membership of `plugdev`. Add `--uart` to either tool:

```sh
tools/uart-probe.sh                                  # finds the tty
tools/ps2iop/iop_post.py --uart /dev/ttyUSB2 --csr build/c1100_ps2_diag/csr.csv status
```

It is much slower — about 1150 register writes a second, so a 4 MB BIOS takes
about a quarter of an hour against a couple of seconds over PCIe, and reads
are slower still at about 60 a second — but it works when PCIe does not, and
it is the quickest way to a first result on a machine where you have not built
the driver.

## The boot test

```sh
sudo tools/ps2iop/hw-test.sh
```

Lock and heartbeat, the 4096-word boot ROM loaded and counted, the boot test
with the pad set (POST `01`…`0A` then `AA`), the same with nothing pressed
(which must fail at stage `09`, proving the pad CSR reaches SIO2), five
repeats. A passing run ends:

```
[  0.010s] POST AA  (count 12)
PASS
```

## Loading your BIOS

The IOP ROM is the BIOS's own size, 4 MB, mapped where the console maps it, so
a dump (`.bin`, 4,194,304 bytes) loads as it is:

```sh
sudo tools/ps2iop/bios-hw.sh /path/to/your/bios.bin 30 --dump-ram 0x200000
# or, with no driver and no root, over the UART:
tools/ps2iop/bios_run.py /path/to/your/bios.bin --uart /dev/ttyUSB2 --seconds 30
```

That loads the image, **reads it back through the peek port and compares it
with your file before releasing reset**, runs it, and writes the POST ring,
the bus trace and (with `--dump-ram`) the IOP's RAM into `build/ps2_bios/`.

**What to expect** (measured with `0220A`): POST `FC 02 03 04 05 08 09` in the
ring at 1.654 ms, then IOPBOOT loads 21 of the 29 modules `IOPBTCONF` names,
up to and including `SIFCMD`, and the CPU spins there waiting for an Emotion
Engine. See which modules landed on your own card:

```sh
tools/ps2iop/iop_ram_map.py build/ps2_bios/<run>/ram.bin --rom /path/to/your/bios.bin
```

Two things to know before reading your own log:

- **A retail BIOS prints nothing.** No module in any retail `rom0` writes to
  the IOP's serial port, so an empty console FIFO is correct, not a fault.
  Emulators show IOP console text by intercepting the `Kprintf` call, which is
  not something hardware can do. Read the POST ring instead.
- **Your dump will behave like the ones tested here**, whichever console it
  came from: `IOPBTCONF` is byte-identical in all 53 dumps checked, from the
  launch `0100J` to `0250J`, with `IOPBOOT` at `rom0 + 0x4A000` in every one.

To see what your dump contains and what it will ask the hardware for:

```sh
tools/ps2iop/romdir.py /path/to/your/bios.bin --list        # every file in the ROM
tools/ps2iop/romdir.py /path/to/your/bios.bin --boot        # the 29 modules IOPBOOT loads
tools/ps2iop/romdir.py /path/to/your/bios.bin --hw SIFMAN   # the registers one touches
```

A game ISO has no use here yet. The CDVD block answers the boot-time status
commands and has no sector path; when it gets one, the image will be served
from the host over PCIe and this page will say how. Keep both files out of the
repository — `.gitignore` refuses `*.bin` so one cannot be committed by
accident.

## Building the images yourself

```sh
venv/bin/python boards/c1100_ps2_diag.py --build     # ~20 min
venv/bin/python boards/c1100_ps2_iop.py  --build     # ~15 min
```

Two things to check in every build log before trusting the result, because
both have silently cost builds here: `grep -E 'No clocks matched|12-4739'`
must show only the two `12-4739` lines from Xilinx's own PCIe IP, and the
timing summary must say `All user specified timing constraints are met`. The
reasons are in [c1100-pcie-transport.md](c1100-pcie-transport.md).

## If something does not work

- **`tools/jtag-load.sh` finds no device:** check `lsusb` for the FT4232H and
  that you are in `plugdev`; unplug and replug the card's USB.
- **`lspci` shows the card but every register reads `0xffffffff`:** the PCIe
  window problem above, or `Memory-` in `lspci -vv` meaning memory space is
  disabled — rerun `tools/pcie-bringup.sh`.
- **`insmod` fails:** the driver was built for a different kernel, or for a
  different image. Rebuild it in `build/<target>/software/kernel`.
- **POST stays `00` with `cpu_error 0`:** the ROM did not load. Check
  `iop_rom_count`, and use `iop_post.py verify` to compare what is in the
  card's ROM against your file — a host-side write counter cannot tell you
  that, and not being able to tell cost this project two long debugging runs.
