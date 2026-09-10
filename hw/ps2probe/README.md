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

## What the first probe asks

`gsprobe.c` draws one Gouraud triangle whose three vertices are pure red, green
and blue, so every channel carries a gradient of its own and a single readback
answers all of them. It prints one row per line, which the host diffs against
`sim/gs/gs_ref.py`.

The two questions worth asking first are the ones ARMSX2's captures leave open,
because nobody has published an answer:

- **Row pairing.** Their probes found that silicon reads rows *k* and *k+2*
  identically at every *k*, and no emulator models the vertical structure that
  implies. A triangle with a pure Y gradient, read back in full, shows it
  immediately.
- **Texture coordinate block width.** The affine texture coordinate is
  truncated and so may carry a block width of its own, but no capture has swept
  it. The same width curve that established eight pixels for colour would settle
  it.

## Status

**Builds; untested against hardware.** Every line of the readback path is
written from the manual and has never been run on a console. The first run
should be treated as testing the probe, not the GS: a wrong `BUSDIR` sequence or
a wrong DMA direction will look exactly like a GS that returns nothing.
