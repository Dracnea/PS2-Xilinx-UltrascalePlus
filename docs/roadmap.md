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

### The IOP — 10 done, 2 partial, 1 stubbed

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
| CDVD | **works** for reading — status commands, disc presence, and the N-command sector read (0x06/0x07/0x08) delivering to DMA channel 3, verified on the C1100 against a real disc. No seek timing, no audio, no writes |
| **IOP DMAC** | **works** — 13 channels, OTC and channel 3 carry data, the rest accept their registers. SyncMode 1/2 and chain mode not yet |
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

**Totals: 10 blocks working, 2 partial, 1 stubbed, 16 not started.**

The shape of that total is the thing to keep in view. The IOP is nearly
finished, and the IOP is the *small* processor — it is a PS1 CPU whose job on a
PS2 is to run the drive, the pads and the sound chip. The sixteen that have not
started are the Emotion Engine and the Graphics Synthesizer: the processor that
runs the game and the one that draws it, including an R5900 with a 128-bit SIMD
unit, two vector units, and a rasteriser. They are also individually much larger
than anything built so far. Being close to done with the IOP is not being close
to done with a PS2.

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

### 2. The disc path — **working on the C1100, 2026-09-09**

- **IOP DMAC, channel 3** — *done in simulation, 2026-09-09*. Sector data
  reaches IOP memory by DMA; `CDVDMAN` programs `0x1F8010B0`/`B4`/`B8` and waits
  for the interrupt. The DMAC was not what blocked the kernel boot, but it *is*
  what blocks the disc.
- **CDVD sector path** — *done in simulation, 2026-09-09*: the N-command read
  (opcodes 0x06/0x07/0x08, taken from `CDVDMAN` itself), sector buffering, the
  completion interrupt on INTC bit 2. Boot-test stage `0E` reads LBA 16 and
  checks the ISO9660 primary volume descriptor signature in IOP RAM.
- **A sector source** — *host-served over PCIe works on the card*. The IOP asks
  for sector 16 of the Star Wars Battlefront II disc, `discserve.py` answers over
  PCIe, and the 2048 bytes land in IOP RAM byte-identical to the disc:
  `CD001 PLAYSTATION ... 2_01`.
- **The disc in HBM** — *works on the card, 2026-09-09*. The whole 4.34 GiB
  image goes into HBM by DMA in 6.3 s, and **the IOP then reads it with no host
  program running at all**: stage `0E` passes five times consecutively with
  `discserve.py` absent. Moving `iop_hbm_disc_base` so LBA 16 lands on the
  SYSTEM.CNF sector makes `0E` fail and puts `BOOT2 = cdrom0:\SLUS_212.40;1`
  in IOP RAM instead — which is the result worth having, because it shows the
  read goes to HBM at the address selected and that the address path works past
  4 GiB. [hbm.md](hbm.md), [disc-path.md](disc-path.md).

Checked on the card with its negative controls, which is the part that makes it
evidence rather than a green light:

| configuration | result |
|---|---|
| disc in the drive, sectors served | PASS, RAM byte-identical to the disc |
| disc in the drive, nothing serving | fails at `0E`, sector port left asking for LBA 16 |
| empty drive | PASS: the read is refused with CDVD error 0x12 |
| pad data changed | fails at `09`, so the pad CSR really does reach SIO2 |

Five consecutive disc runs pass.

Getting stage `0E` to pass cost three RTL fixes in the RAM arbiter and the DMA
handshakes, two of which would pass a test that checked only whether the
transfer completed — see *What the CDVD read path found* in
[iop-subsystem.md](iop-subsystem.md).

The host side of this is **done and checked against a real disc**:
`discsource.py` reads sectors from an image, a block device or an optical
drive through one interface, and `isoread.py` walks the filesystem the way the
BIOS will.

*Test that proves it, and the pass criterion is already written down.*
`tools/ps2iop/isoread.py` walks a disc from the host exactly as the BIOS will
— volume descriptor at sector 16, root directory record, root directory,
`SYSTEM.CNF` — and on the Star Wars Battlefront II disc on this machine it
reports:

```
   label '2_01',  root directory at LBA 261
   SYSTEM.CNF at LBA 2265115:  BOOT2 = cdrom0:\SLUS_212.40;1
   SLUS_212.40 at LBA 2265116, 166708 bytes, valid ELF magic
```

When the hardware reads that same disc through `CDVDMAN`/`IOMAN` and answers
`SLUS_212.40`, the disc path works. No pixel is drawn and no EE is involved.

Note what the real disc teaches about the read path: **the files the BIOS needs
are at the far end.** SYSTEM.CNF is at LBA 2,265,115 of a 2,278,160-sector
volume, so an LBA truncated to 16 or 20 bits would find the volume descriptor
and then fail on the one file that matters. `tools/ps2iop/mkiso.py --sectors`
builds a sparse test image with that same shape — kilobytes on disk, far-end
LBAs — so the failure can be found without a 4.7 GB image in the loop.

### The BIOS opens a file on the disc — **done, 2026-09-10**

The criterion this section set was *"when the hardware reads that same disc
through `CDVDMAN`/`IOMAN` and answers `SLUS_212.40`, the disc path works"*. It
does, on a **stock, unpatched BIOS**:

```
open('cdrom0:\SLUS_212.40;1', O_RDONLY) -> fd 2
```

and CDVDMAN gets there on its own, reading LBA 16 (the volume descriptor), LBA
257 (the path table) and LBA 261 (the root directory) out of HBM. **LBA 261 is
the same root directory this project's own ISO9660 walk finds independently** —
two different implementations, ours in R3000 assembly and Sony's in the BIOS,
arriving at the same place on the same disc.

Getting there needed the whole SIF stack ([sif.md](sif.md)) and one DMA fix:
block mode took BCR's low half as the entire word count, so a sector transfer
stopped after a sixteenth of it with no error on either side.

And it reads it. `read(fd, ptr, 128)` returns 128 and delivers, to the EE address
the call named:

```
464c457f 00010101 00000000 00000000 00080002 00000001 00100008 00000034
'\x7fELF' ... class 32-bit, little-endian, type EXEC, machine MIPS,
entry 0x00100008
```

**Byte-identical to the file on the disc**, and `0x00100008` is where the
Emotion Engine would begin executing it. The console found the game's executable
by name, opened it, and read it — through Sony's own `CDVDMAN` and `IOMAN`, on a
stock BIOS, with the sectors coming out of the card's HBM.

The next thing to do with those bytes is run them, and that needs the EE.

**So: loading a game image is now a real and useful test.**
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

## Card identity and telemetry, for the host UI

Added 2026-09-09. The repository exists to release on **several** UltraScale+
cards, so the host has to be able to ask a card what it is and how it is doing
rather than being told at build time. What the UI wants is roughly: which board
and which die, a serial that distinguishes two of the same board in one
machine, die temperature, and the core voltage — the last two so a user can see
a card throttling or browning out instead of guessing why a game stutters.

**This costs almost nothing in fabric, and that is worth stating plainly
because it is the reason it can be left until the UI exists.** Everything here
is a hard macro plus a register shim:

* **SYSMON** (`SYSMONE4`) gives die temperature and the supply rails, including
  VCCINT, as a hard block. The fabric cost is the CSR wrapper.
* **DNA_PORT** (`DNA_PORTE2`) gives a 96-bit die identifier — a serial that is
  unique per chip and needs no per-board provisioning.
* **Board identity** is a constant the platform file already knows.

Call it 300-800 LUTs and no URAM or block RAM. Against the C1100 that is under
**0.1 %** of the part: today's whole IOP design, HBM controller and PCIe
endpoint together use 36,572 LUTs of 871,680, which is 4.2 %.

So this does not compete for the resource that is actually scarce. The
constraint on this project is **UltraRAM**, not logic: 224 of the C1100's 640
(35 %) are spent before the Graphics Synthesizer's 4 MB of local memory exists,
and the same design is 224 of 320 (70 %) on an FK33 ([cards.md](cards.md)).
Telemetry does not touch URAM at all.

Two notes for when it is built:

* The C1100 has a **second** source: its satellite controller reports card-level
  voltage and temperature over I2C, which is what the vendor firmware uses to
  control VCCINT. On-die SYSMON and the card controller do not necessarily
  agree, and the UI should say which it is showing.
* Keep it behind one interface with a per-platform implementation, the way
  `discsource.py` treats an image, a block device and a drive as one thing. A
  card that cannot report a rail should say so rather than report zero — a
  plausible wrong number is worse than a missing one.

## Where the memory goes

Full analysis in [hbm.md](hbm.md); the short version, because it changes the
plan for the FK33:

- **The BIOS ROM should move to HBM.** IOP instruction fetch from ROM already
  costs ~33 IOP cycles through the memory controller's BIOS delay; an HBM read
  is ~4-6. It frees 128 UltraRAM for nothing, and that alone takes the IOP from
  70 % to 30 % of an FK33 — enough room for the GS's 4 MB alongside it.
- **The GS's local memory should not.** It is a 2048-bit random-access port at
  ~38 GB/s; one HBM channel gives 14.4 and handles random access worse. That is
  what UltraRAM is for.
- **The disc should live in HBM, as a cache rather than a copy.** A maximal
  dual-layer title is 7.95 GiB against 8 GiB of HBM — it fits only by leaving
  room for nothing else, and some images are larger still. Caching 1 MiB chunks
  makes the size of the game stop mattering: a single-layer disc never misses,
  a dual-layer one keeps its working set. One mechanism instead of two.

## The memory problem, alongside the clock one

The IOP alone takes 70 % of an FK33's UltraRAM, and the GS's 4 MB of local
memory is another 128 URAM on top. A whole console will not fit on the smaller
card with everything on-chip, and the answer is almost certainly HBM -- which
both cards have and neither design has touched yet. [cards.md](cards.md) has
the numbers and the options. This does not block anything today; it is the kind
of number that decides an architecture, so it is better known now.

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
