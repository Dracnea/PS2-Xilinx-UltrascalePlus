# What exists, what does not, and when a game disc becomes useful

The question this page answers: **how much of a PlayStation 2 is here, and how
many more blocks have to work before loading a game image is a meaningful
test?**

The short version: a disc image becomes a *useful test input* three blocks
from now, and becomes *playable* only after essentially the whole console
exists. Those are very different milestones and it is worth not confusing
them.

## The inventory

A PS2 is three processors and their peripherals. Counting blocks that need
separate design and separate verification:

### The IOP — 8 done, 3 partial, 2 stubbed

| block | state |
|---|---|
| R3000A CPU | **works**, verified on the C1100 through a boot test and a real BIOS |
| IOP RAM (2 MB) and BIOS ROM (4 MB) in UltraRAM | **works** |
| memory mux / IOP address map | **works** |
| INTC, 32 sources | **works** |
| timers 0-2 (16-bit) and 3-5 (32-bit) | **works** |
| SSBUS / memory controller | **works** |
| POST register | **works** |
| SPU2 | *partial* — two PS1 SPU cores with 512 KB of work RAM each, but the PS1 register layout rather than the SPU2's, and no DMA |
| SIO2 | *partial* — command queue and a digital pad on port 0; no memory card, no multitap, no DMA |
| CDVD | *partial* — the register block answers the boot-time status commands; no disc, no sector path |
| **IOP DMAC** | **stub** — reads back what is written, moves nothing |
| **SIF** (the link to the EE) | **works** — `rtl/iop/iop_sif.vhd`, with the host playing the EE; the IOP kernel boots to BOOTEND through it |
| SSBUS2 config | **stub**, and that is probably fine forever |

### The Emotion Engine — 0 of 12

R5900 core (64-bit MIPS III plus the 128-bit MMI SIMD set) · FPU (COP1, with
its non-IEEE rules) · 32 MB main memory · 16 KB scratchpad · EE DMAC (10
channels) · EE INTC and timers · SIF (EE side) · VIF0 · VIF1 · VU0 (macro and
micro mode) · VU1 · GIF · IPU (MPEG-2). **None of these exists.**

### The Graphics Synthesizer — 0 of 4

Rasteriser with 4 MB of local memory · texture unit · alpha/Z/dither back end
· PCRTC video output. **None of these exists.**

### Host-side plumbing

PCIe transport **works**; the video path from card to host **works** (verified
at 60 fps with a test pattern). Still needed: a disc-image server, a real
controller path, and an audio path.

**Totals: 8 blocks working, 3 partial, 2 stubbed, 16 not started.**

## The milestones, in order

### 1. The IOP kernel finishes booting — **done, 2026-09-08**

**Corrected 2026-09-08.** This step was first written as "DMAC and SIF, in
that order". Measuring where the boot actually stops showed the DMAC has
nothing to do with it: the CPU spins on `SIF MSFLAG` waiting for bit 16, which
only the Emotion Engine sets, and no DMA register appears anywhere in the
trace ([ps2-bios-boot.md](ps2-bios-boot.md)).

- **SIF, with the host standing in for the EE.** *Done in RTL and simulation*
  (`rtl/iop/iop_sif.vhd`), pending the hardware run. The mailbox registers are
  semaphores, which is precisely what a read-back stub cannot imitate.
- **IOP DMAC** — still wanted, because SPU2, CDVD and the SIF's bulk transfers
  all move data by DMA on a real console, but it is *not* what is blocking the
  boot. PSX_MiSTer has a PS1 DMA controller and the IOP's is that plus a
  second bank of channels at `0x1F801500`, so it follows the pattern the rest
  of the IOP was built on. Whether the remaining eight modules need it to
  finish loading is now an open question the SIF run will answer.

**Done with one block, not two.** The SIF alone did it: on the card, one host
write of MSFLAG bit 16 takes the IOP from 21 modules to 28, and `SMFLAG`
reaches `SIFINIT | CMDINIT | BOOTEND` — the IOP announcing that its boot is
over ([ps2-bios-boot.md](ps2-bios-boot.md)). The DMAC was never involved.

The lesson is worth keeping: the block that looks like the blocker and the
block that is the blocker are not always the same, and a bus trace settles it
in minutes where reasoning did not.

### 2. The disc path — **the next block, and the one that needs your game disc**

- **CDVD sector path**: the N-command read path, sector buffering and its DMA
  channel.
- **Host disc server**: the image lives on the PC and is served over the PCIe
  link the card already has.

*Test that proves it, and it uses your own game disc:* point the IOP at the
image and have the BIOS's own `CDVDMAN` and `ROMDRV`/`IOMAN` read it — the
ISO9660 volume descriptor, the root directory, then `SYSTEM.CNF`, which names
the game's boot ELF (`BOOT2 = cdrom0:\SLUS_xxx.xx;1`). Reading that line off
your disc, through the real BIOS driver stack, proves the whole disc path
without a single pixel being drawn.

**So: three blocks from now, loading a game image is a real and useful test.**
It is not playing the game. It is the console proving it can find one.

### 3. The Emotion Engine — 12 blocks

This is the multi-year item, and the order that keeps it testable is in
[ps2-hardware-study.md](ps2-hardware-study.md) §7: the R5900 integer core
first, verified instruction-by-instruction against PCSX2's interpreter, then
MMI, then the FPU, then VU1 in micro mode, then VU0 and the COP2 coupling,
then the DMAC/VIF/GIF paths and the IPU.

Main memory is worth calling out: the PS2 has 32 MB of RDRAM, which on the
C1100 means HBM rather than on-chip RAM — a memory controller and its
arbitration are part of this step, not a detail of it.

*Milestone:* with the EE and the SIF real, the BIOS boots past the IOP into
`OSDSYS` — the PS2's own browser screen — which is the first moment the thing
behaves like a console.

### 4. The Graphics Synthesizer — 4 blocks

Best specified of everything left (the GS manual documents the memory layout
and every register) and a fixed-function pipeline, so it is large but not
uncertain. It can be built and verified **standalone before the EE exists**,
by feeding it GIF packets from the host and comparing its framebuffer against
PCSX2's software renderer frame for frame.

*Milestone:* a picture, through the video path that already works.

### 5. Integration, then a game

DMA arbitration, timing between the three processors, and the real boot chain.
Only here does "load a game ISO and play it" become the test.

## The clock problem, stated plainly

The EE runs at 294.912 MHz. This project's own fits put the PSX R3000A at
about 117 MHz on the C1100 with no timing effort, and
[ps2-hardware-study.md](ps2-hardware-study.md) judges 150-200 MHz plausible
for a 64-bit dual-issue core written to close on UltraScale+ — not 295.

So "a game runs" and "a game runs at full speed" are separate problems. The
options are a half-rate EE with the rest of the system scaled to match, or
giving up cycle accuracy for a faster functional model. That choice does not
have to be made until step 3, but it should not be a surprise when it arrives.

## Summary

| you want to | blocks still needed | realistic milestone |
|---|---|---|
| see the IOP kernel finish booting | **0 — done 2026-09-08** | `SMFLAG = BOOTEND`, 28 modules |
| **load your own game disc and have the console read it** | **2** | **the next thing being worked on** |
| see the PS2 browser screen | ~15 | after the EE |
| play a game | ~19 plus integration | the end of the road |
