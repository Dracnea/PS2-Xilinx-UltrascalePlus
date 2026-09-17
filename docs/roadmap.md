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

### The Emotion Engine — 1 of 13, updated 2026-09-16

| block | state |
|---|---|
| **R5900 core** | **works on the card** — 64-bit MIPS III plus the 128-bit MMI SIMD set, 35 differential tests, mutation-checked, and running at **the console's 294.912 MHz** with +0.135 ns of margin. The ~204 MHz that was the open problem is closed: a sixth pipeline stage, the 0.85 V rail and its matching speed file between them bought the difference |
| FPU (COP1) | *partial, and the roadmap had this wrong until 2026-09-17* — the **structural half is RTL and passing**: `rtl/ee/ee_fpu_pkg.vhd` has the conditioner, compares, MAX/MIN and ABS/NEG, plus **MUL.S**, at 1034 vectors identical to `ps2_float.py` with seven mutations caught. ADD/SUB/DIV/SQRT are not built. The last bit of the arithmetic stays unverified against silicon until a console runs the probe |
| 32 MB main memory | **works on the card, 2026-09-17** — the R5900 executes out of HBM at the console's 294.912 MHz, 11 of 12 differential seeds identical to the model with 0 unimplemented instructions. It is mapped at `HBM_BASE`, 6 GiB into HBM, which a host loader has to know |
| 16 KB scratchpad | not started |
| EE DMAC, 10 channels | not started |
| EE INTC and timers | not started |
| SIF, EE side | not started — the IOP side works with the host standing in |
| VIF0 / VIF1 | not started |
| VU0 (macro and micro mode) | not started |
| **VU1** | not started. Every scrap of PlayStation 2 geometry runs here |
| GIF | *the GS-facing half works* — tag parsing, the three modes, A+D writes, inside `rtl/gs/gs_gif.vhd`. The EE-facing half, fed by DMA rather than by the host a quadword at a time, does not exist |
| IPU (MPEG-2) | not started |
| TLB / MMU | not started — currently counted as traps, and the BIOS uses it |

### The Graphics Synthesizer — 1 of 4, updated 2026-09-16

| block | state |
|---|---|
| **rasteriser + 4 MB local memory** | *works on the card* — sprites, Gouraud triangles, the page/block/column swizzle cross-checked exhaustively against a second implementation, PSMCT32/24/16/16S, 14 differential streams byte-identical by full 4 MB checksum, running at **147.456 MHz, the console's own clock**, four pixels per clock on all three paths |
| **texture unit** | *RTL started 2026-09-17* — `gs_texaddr.vhd` does the addressing for all nine formats and the four wrap modes (29,140 cases on five seeds, eleven mutations caught, 349 LUTs) `gs_clut.vhd` the palette and its CLD reload rules (78 cases on six seeds, fourteen mutations, 170 LUTs and one block RAM), and `gs_texsample.vhd` the fetch, palette lookup and texture function (498 samples on four seeds, eleven mutations, 1327 LUTs) — **step 4 of gs-texture.md is complete, so a 2D textured primitive can be drawn**. Nearest only; bilinear waits on the read-port decision, and 16-bit CLUTs are refused rather than guessed. The reference model is **complete**: `gs-texture.md` runs from the PSMT8/PSMT4 address permutations through the H formats and the CLUT to UV sampling, STQ with the perspective divide, mipmap and bilinear. The RTL will have an exhaustively cross-checked oracle to diff against from its first line |
| alpha / Z / dither back end | *partial* — alpha blending and the depth test work and are 4-wide; dither is not started, and alpha test and destination-alpha test are not started |
| PCRTC video output | *partial* — the read circuit works, is wired into `gs_top`, and **has composited a frame on the card** that matches both the host de-swizzle and the reference model on all 4096 pixels (2026-09-16). No sync generator, and nothing is out of a connector: the frame reaches the host through the grab buffer, which holds 64 x 64 |

Also not started in the GS: lines and points, local-to-host and local-to-local
transfers, host-to-local beyond PSMCT32, and the comparing depth tests 4-wide.

### Host-side plumbing

PCIe transport **works**; the video path from card to host **works** (verified
at 60 fps with a test pattern). Still needed: a disc-image server, a real
controller path, and an audio path.

**Totals, 2026-09-16: 12 blocks working, 5 partial, 1 stubbed, 15 not
started.** The count has not moved since 2026-09-14 and the change behind it is
not visible in a count: the R5900 has gone from working in simulation to
working on the card, at the console's own clock. That is the difference between
a design that is believed and one that is known, and it cost two bugs that only
hardware could show — a pipeline stage the reset branch did not clear, which
lost everything after the first instruction on about one release in five, and a
branch-likely that failed to annul a multiply or divide in its delay slot.
Neither reproduced in simulation until a test was written to provoke it.

The count also understates how much is left, because a texture unit and two
vector units are each larger than most of the entries above them.

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

### 3. The Emotion Engine — 12 blocks — **the core runs, 2026-09-16**

This is the multi-year item, and the order that keeps it testable is in
[ps2-hardware-study.md](ps2-hardware-study.md) §7: the R5900 integer core
first, verified instruction-by-instruction against PCSX2's interpreter, then
MMI, then the FPU, then VU1 in micro mode, then VU0 and the COP2 coupling,
then the DMAC/VIF/GIF paths and the IPU.

**The first of those is done and runs on the card** at the console's
294.912 MHz ([ee-core.md](ee-core.md)). The integer core and MMI are one block
of thirteen, so this milestone has barely started — but it has started in the
place that decides whether the rest is worth building, because a core that
cannot reach the console's clock makes every block behind it moot.

**Next is the FPU (COP1).** Its reference model is finished and exact
([ee-fpu.md](ee-fpu.md)), so the RTL has an oracle from the first line — with
the caveat that page records honestly, that part of the FPU's behaviour cannot
be checked against anything and has to be built another way.

Main memory is worth calling out and is the other candidate for next: the PS2
has 32 MB of RDRAM, which on the C1100 means HBM rather than on-chip RAM — a
memory controller and its arbitration are part of this step, not a detail of
it. Nothing above the core needs more than the 64 KB it has now; everything
from the DMAC upwards does.

*Milestone:* with the EE and the SIF real, the BIOS boots past the IOP into
`OSDSYS` — the PS2's own browser screen — which is the first moment the thing
behaves like a console.

### 4. The Graphics Synthesizer — 4 blocks — **started in parallel, 2026-09-10**

Best specified of everything left (the GS manual documents the memory layout
and every register) and a fixed-function pipeline, so it is large but not
uncertain. It can be built and verified **standalone before the EE exists**,
by feeding it GIF packets from the host and comparing its framebuffer against
PCSX2's software renderer frame for frame.

Because that independence is real, this milestone no longer waits for the EE:
it runs alongside it. [gs.md](gs.md) has the plan and the order. The reference
model (`sim/gs/gs_ref.py`) covers GIFtag decode, the general registers and the
local-memory swizzle, and the addressing is cross-checked against PCSX2
exhaustively by `tools/gs/xcheck_swizzle.py` — PCSX2 being a test oracle and a
second implementation, never an authority, and never a source of code, since it
is GPL-3 and this repository is GPL-2.

*Milestone:* a picture, through the video path that already works.
**Taken, 2026-09-16.**

The card composited a frame through PCRTC and the host wrote it to a PNG:
`tools/gs/gen_scene.py --size 64 64` for the scene, `tools/gs/gsrun.py` to draw
it, `tools/gs/pcrtcgrab.py` to grab it. 4096 pixels, 297,159 display reads, and
**zero refused by the arbiter** — the display and the rasteriser share one read
port and the display never lost it.

What makes it evidence rather than a screenshot is that the same frame was read
back three ways and all three agree on **every one of the 4096 pixels**:

| path | what it exercises |
|---|---|
| `pcrtcgrab.py` | the card's own read circuits, merge, blend and magnification |
| `gsgrab.py` | the frame buffer over PCIe, de-swizzled on the host |
| `gsgrab.py --model-only` | `sim/gs/gs_ref.py`, no card involved |

The first two are different silicon paths to the same memory; the third is a
different implementation entirely. The picture shows six flat sprites, a Gouraud
triangle interpolating red-green-blue across its corners, two half-transparent
sprites whose overlap is a third shade, and a depth-tested pair where the
further triangle is correctly cut away by the nearer one.

**What it does not show, and the honest limit on it:** there is still no sync
generator, so this is a raster PCRTC walks on command rather than a video
signal a display could lock to, and nothing is out of a connector. And the
frame grab holds 4096 pixels, so a whole frame through this path is 64 x 64 and
no larger — a bring-up window, not the picture path a game would use. Both are
the next things on this track.

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

## Two parallel tracks opened — 2026-09-14

Texture and VU1 both started, chosen because they are the two largest unbuilt
blocks and neither contends with the EE's timing work for files or for a
toolchain slot.

**Texture** is at step 2 of 5: the H formats are done and the indexed addressing
is assembled and bijectivity-checked (`docs/gs-texture.md`). Step 3, the CLUT,
is the last one before a textured triangle can be drawn at all.

**VU1** has a reference model rather than RTL, for the same reason the R5900 and
the GS did: the model is what the hardware gets checked against, and a model
written afterwards tends to agree with the hardware rather than with the
machine. `sim/vu/vu_ref.py` has the register file, the memories, and the whole
upper (FMAC) unit — field masks, broadcasts, the accumulator forms, the outer
product, ITOF/FTOI, ABS and CLIP. Its arithmetic is `sim/ee/ps2_float.py`,
imported rather than reimplemented: the VU and COP1 share a number system, and
two blocks that must agree bit for bit should share one implementation of what a
number is.

The lower unit — loads, stores, the integer ALU, branches and the divide unit —
is next, and after that the pipeline timing, which is deliberately a layer on
top of a functional model that is already right.

### VU1: the lower unit, and the CLUT — 2026-09-14

`sim/vu/vu_ref.py` now has both slots. The lower unit is the harder decode —
three dispatch levels, `code >> 25` then `code & 0x3F` then `(code >> 6) & 0x1F`
— and all 69 defined entries cross-check against the oracle, with the check also
asserting that nothing PCSX2 leaves undefined decodes here either. Inventing an
instruction is as wrong as missing one.

The tests target the asymmetries, because those are where a model written from
instruction *names* goes wrong silently:

- **`LQI` post-increments but `LQD` pre-decrements.** They are not mirror
  images. A model that made them symmetric is off by one on every backwards walk
  and still produces a picture.
- **`MFIR` sign-extends** from 16 bits rather than zero-extending, and does not
  convert — the bits cross as an integer and something else is expected to
  `ITOF` them.
- **The integer registers wrap at 16 bits**, they do not saturate. A pointer
  walked past the end of VU Mem reads something else rather than faulting.
- **Bits 24:21 are not always a field mask.** `MTIR`, `DIV`, `SQRT` and `RSQRT`
  overload them as `fsf` and `ftf`, naming one field of each operand. The first
  version of the test passed the default mask of `0xF` to them, which selected
  `w` for both — so `MTIR` read an empty field and `DIV` divided by zero and
  saturated. **The model was right and the test was wrong**, which is the
  failure that wastes the most time, so the two encodings now have separate
  helpers rather than one with a trap in it.

On the texture side, the CLUT's CSM1 layout was **derived rather than
tabulated**: a 16-entry CLUT is one PSMCT32 column read in raster order, and a
256-entry CLUT is that pattern stepped over four consecutive blocks alternating
between two at a time. One expression reproduces PCSX2's whole 128-entry table
and is a bijection over all 256. The plausible wrong answer — that a CLUT is a
16 × 16 image — is also a bijection, so `tools/gs/xcheck_clut.py` asserts
explicitly that the derivation is *not* that one.

The 16-bit CSM1 layout is deliberately **not implemented**: its first eight
entries match a half-word raster and then it diverges by offsets of 4, 1 and 5.
The structure is "one row pattern, four offsets" and only the offsets are open.
That is written down in `gs_ref.py` rather than guessed at, because a wrong
palette layout looks like a wrong palette, not like a wrong address.
