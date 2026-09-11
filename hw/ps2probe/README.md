# Asking the console directly

The differential harness in this project compares an RTL implementation against
a reference model. Both can be wrong together, and on two occasions they nearly
were: the fill rule was implemented from a plausible reading and turned out to
be half a pixel off, and the interpolation rule was about to be implemented as
"exact" when the hardware in fact steps a block of eight pixels with the step
truncated to a 2⁻¹⁰ grid. Neither error is visible to a test that checks the
model against itself.

A real PlayStation 2 is the reference with no approximation in it. These probes
run on one.

## What it needs

- **A PS2 that boots homebrew.** FreeMcBoot on a memory card, a modchip, or a
  disc exploit. Without this the console will not run the ELF and nothing else
  here matters.
- **Ethernet, not USB.** A slim (SCPH-70000 and later) has it built in; a fat
  needs the expansion-bay Network Adaptor. USB 1.1 has no standard homebrew
  transport and is an order of magnitude slower.
- **A host interface on the same segment.** On this machine `eno1np0` is the
  main network and `eno2np1` is free — that is the one to use. (There is no
  `eno1np1`.)

## Setting it up

```sh
# host side: give the spare port an address the PS2 can reach
sudo ip addr add 192.168.99.1/24 dev eno2np1
sudo ip link set eno2np1 up

# the PS2 runs ps2link (FreeMcBoot ships it) configured with, say,
#   192.168.99.2 / 255.255.255.0 / gateway 192.168.99.1

~/ps2dev/ps2client/bin/ps2client -h 192.168.99.2 execee host:gsprobe.elf
```

`ps2client` uploads the ELF over TCP and streams the program's `stdout` back, so
a probe simply prints what it found.

## Building

The toolchain is the prebuilt ps2dev release, unpacked at
`~/ps2dev/toolchain/ps2dev`:

```sh
export PS2DEV=~/ps2dev/toolchain/ps2dev PS2SDK=$PS2DEV/ps2sdk
export PATH="$PS2DEV/bin:$PS2DEV/ee/bin:$PS2DEV/iop/bin:$PATH"
make -f Makefile.probe
```

## How the readback works

This is the part that is easy to get wrong, and it is done as the GS User's
Manual describes rather than by pattern-matching someone's example:

1. `BITBLTBUF`, `TRXPOS`, `TRXREG` describe the source rectangle in local memory.
2. `TRXDIR = 01` selects Local → Host and starts the transfer.
3. The **privileged** `BUSDIR` register is set to 1, which turns the interface
   around.
4. The quadwords come out through VIF1 run in reverse, into EE memory.
5. `BUSDIR` goes back to 0. Skipping this leaves the machine unable to accept a
   normal GIF packet, which presents as a hang rather than as an error.

## What the probes ask

Three passes, and the host compares all of them in one command:

```sh
~/ps2dev/ps2client/bin/ps2client -h 192.168.99.2 execee host:gsprobe.elf | tee run.txt
hw/ps2probe/compare.py run.txt
```

`compare.py` builds the same primitives as a GIF packet stream, runs them
through `sim/gs/gs_ref.py`, and prints the pixels that differ with the delta.
Keep it and `gsprobe.c` in step: they describe the same pictures twice, in C and
in Python, and nothing forces them to agree — if the probe changes and the
script does not, the diff is of two different pictures and will look like a
discovery.

**`PROBE gouraud`** — one triangle with pure red, green and blue vertices, so
every channel carries its own gradient and one readback answers all four. This
checks the blocked truncating DDA: eight-pixel blocks with the step snapped to
2⁻¹⁰.

**`ZPROBE ygrad` and `ZPROBE xgrad`** — flat triangles whose depth varies along
one axis only, with `ZTST = ALWAYS` and `ZMSK = 0` so every pixel writes its
interpolated depth and nothing is filtered out by the test itself. These are
the important ones, because **the depth bias is the only rule in this project
implemented from someone else's measurements and never checked against a
console.** The model's answer for `ygrad` already shows what to look for: the
first pixel of the first scanline reads `000fffff` where the plane says
`00100000` — one below, the X half of the bias with nothing on top of it.

`ygrad` also settles an open question. ARMSX2's captures found that silicon
reads rows *k* and *k+2* identically at every *k*, nobody has published why, and
no emulator models the vertical structure it would imply. A pure Y gradient
shows it without any analysis, and `compare.py` prints the count.

**`ZCPROBE`** — one sprite, one number, two possible answers. It writes
`0x01234567` into a **PSMZ24** buffer with `ZTST = ALWAYS` and `ZMSK = 0`, then
reads it back, to settle what the GS does with a depth too wide for its Z
format. Clamping gives `0xFFFFFF`; truncating gives `0x234567`. This project
models clamping, taken from PCSX2, and the manual gives the three Z formats
without ever saying what happens to a value that will not fit.

Two choices here are deliberate. It uses a **sprite**, whose depth is an integer
from the second vertex and never interpolates, so the depth bias — the other
unverified rule on this page — cannot contaminate the answer. And it uses
PSMZ24 with a PSMCT32 frame buffer, because the manual only allows a frame and Z
format from the same group, PSMZ24 is in PSMCT32's group, and PSMZ24 is
addressed exactly as PSMZ32 is — so the existing readback reaches it unchanged.
`compare.py` prints the verdict and names the one line in each implementation to
change if the console says TRUNCATE.

The remaining open question needs a probe that does not exist yet: **the affine
texture coordinate is truncated and may carry a block width of its own**, but no
capture has swept it. The same width curve that established eight pixels for
colour would settle it, and there is no texture unit to drive it with.

## Status

**Builds; untested against hardware.** Every line of the readback path is
written from the manual and has never been run on a console. The first run
should be treated as testing the probe, not the GS: a wrong `BUSDIR` sequence or
a wrong DMA direction will look exactly like a GS that returns nothing.
