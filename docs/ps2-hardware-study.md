# PlayStation 2 hardware study: what is documented, what exists in HDL, and what a C1100/FK33 recreation would take

Written 2026-09-06 as the follow-up to the PS2 paragraph in
the retro-cores survey in Dracnea/FPGA-Retro. **Status:** step 1 of §7 has since been
started — the IOP subsystem simulates through a boot test, fits both dies
and has a C1100 bitstream; see [ps2-iop-bringup.md](ps2-iop-bringup.md). That paragraph said "nothing to port, and
clock". This document is the evidence behind it, gathered the way the PSX port
was approached: board, chips, buses, memories, then the RTL that exists and
the RTL that would have to be written. Numbers are from the sources named; the
FPGA sizing is an estimate scaled from this repo's own PSX fit and is marked
as such.

**Do not commit Sony's manuals here.** They are marked SCE CONFIDENTIAL and
this repository is public. They are cited by URL and page; keep local copies
outside the tree.

## 1. Sources, ranked by authority

| source | what it is | covers |
|---|---|---|
| *EE Core User's Manual*, 6th ed., April 2002 (180 pp) — [docs.alexrp.com/mips/ee.pdf](https://docs.alexrp.com/mips/ee.pdf) | Sony's own, from the PS2 Linux Kit | block diagram, six-stage dual-issue pipeline and per-phase description, registers, MMU/TLB, caches and scratchpad, bus interface, FPU, breakpoints, performance counters |
| *EE Core Instruction Set Manual* (ee_insns.pdf, same host) | Sony | every instruction incl. the 128-bit MMI class, latencies |
| *VU User's Manual*, 6th ed. (368 pp) — [docs.alexrp.com/mips/ee_vu.pdf](https://docs.alexrp.com/mips/ee_vu.pdf) | Sony | VPU structure, FMAC/FDIV/EFU/IALU pipelines, micro and macro mode, full LIW instruction reference, XGKICK |
| *GS User's Manual*, 6th ed. (176 pp) — [usermanual.wiki](https://usermanual.wiki/Pdf/GSUsersManual.1012076781/html) | Sony | block configuration, local-memory ports and page/block/column layout, drawing pipeline, all 64 general and the privileged registers, PCRTC |
| *EE User's Manual* (system level) — [usermanual.wiki](https://usermanual.wiki/Pdf/EEUsersManual.1748563585.pdf) | Sony | DMAC, VIF, GIF, IPU, timers, INTC, SIF, RDRAM interface |
| [ps2tek](https://psi-rockin.github.io/ps2tek/) | community, nocash-style | EE/VU/VIF/GIF/GS/DMAC/timers/INTC in depth; SIF/IPU moderately; IOP, SPU2, DEV9, CDVD, SIO2 as register maps only |
| [Copetti, *PlayStation 2 Architecture*](https://www.copetti.org/writings/consoles/playstation-2/) | secondary, well cited | block-level system description with the numbers below |
| [psdevwiki PS2](https://www.psdevwiki.com/ps2/Motherboards) (Motherboards, Emotion_Engine, Graphics_Synthesizer, EE+GS) | community | chip revision per board, process, die size, package; die-shot references. Cloudflare blocks scripted fetches; read it in a browser |
| SCPH-50000 series service manual, 2nd ed., GH-023 board (H-chassis) — [archive.org](https://archive.org/details/PlayStation_2_SCPH-50000_Series_Service_Manual_2nd_Edition); SCPH-39000 GH-017/GH-022 — [gamesx.com](https://gamesx.com/wiki/lib/exe/fetch.php?media=schematics:sony-ps2-scph-39000_series_service_manual_gh-017.pdf) | Sony service | board-level schematics: IC designators, rails, crystals, connectors |
| Wikimedia Commons categories [CXD9542GB](https://commons.wikimedia.org/wiki/Category:Emotion_Engine_(PlayStation_2)), CXD9615GB, CXD9708GB (includes a die shot), CXD9832GB; [Fritzchens Fritz's die-shot albums](https://www.flickr.com/photos/130561288@N04/albums/) | photos | package and die photographs of four EE revisions |
| PCSX2, DobieStation, Play! | software emulators | the only *executable* descriptions of undocumented behaviour (IOP peripherals, SPU2, CDVD/MechaCon, timing corner cases) |

What is **not** publicly documented at Sony's level: the IOP beyond "a PSX
CPU", SPU2 internals, the CDVD/MechaCon protocol, DEV9, and the RDRAM
controller's initialisation. Those live in emulator source and homebrew
findings.

## 2. The board

A fat PS2 main board (GH-001 through GH-023) carries, per the service
manuals, psdevwiki and Copetti:

| block | part (early boards) | notes |
|---|---|---|
| Emotion Engine (EE) | CXD9542GB (250 nm, 13.5 M transistors, ~226-240 mm², 18 W); CXD9615GB (180 nm); CXD9708GB (GH-017/023 era); CXD9832GB | 294.912 MHz = 16 x 18.432 MHz |
| Graphics Synthesizer (GS) | CXD2934GB (180 nm, 19 W); CXD2944GB on GH-001..GH-016 (108 mm², 384-pin BGA) | 147.456 MHz = 8 x 18.432 MHz; 4 MB eDRAM on die |
| main memory | 2 x 16 MB Rambus RDRAM | two 16-bit channels, 400 MHz DDR, 3.2 GB/s |
| I/O processor (IOP) | CXD9611 family (fat); replaced by a PowerPC 440 "PPC-IOP" running the DECKARD MIPS emulator in late slims | R3000A at 36.864 MHz (2 x 18.432), 2 MB EDO; slims 4 MB SDRAM |
| SPU2 | separate chip on fat boards; two cores x 24 voices, 2 MB work RAM | 16.9344 MHz crystal on the board = 384 x 44.1 kHz |
| CDVD + MechaCon | drive DSP, RF amp (CXA2605R or TI SP3727A daughter board), MechaCon microcontroller | protocol undocumented; PCSX2 is the reference |
| video DAC, DEV9 (PCMCIA/expansion bay), USB 1.1 x 2, i.LINK (early), SIO2 (pads, memory cards) | | |
| rails | 8.5 V input on GH-001/003, 12 V on later boards; 1.7-1.8 V and 2.5 V core rails, 3.3 V I/O (SM GH-023) | |

Two facts from the board matter for a recreation: **every clock derives from
one 18.432 MHz reference** (EE x16, GS x8, IOP x2) plus the 16.9344 MHz audio
reference, so the whole system is two clock domains and the ratios are
exact; and Sony later fused **EE+GS into one 90 nm die (53.5 M transistors,
86 mm², 2003)** and then EE+GS+IOP, which says the three are separable blocks
with clean interfaces (GIF, SIF), not one tangled netlist.

## 3. The chips, block by block

### 3.1 EE Core (the R5900)

From the EE Core User's Manual ch. 1:

- 2-way superscalar, in-order issue and completion; six stages, each with two
  phases (1I/2I fetch, 1Q/2Q queue, 1R/2R register, 1A/2A execute, 1D/2D data,
  1W/2W write-back). Loads are non-blocking; load misses, multiply, MAC,
  divide, prefetch and coprocessor instructions retire out of order.
- Six physical pipes: **I0, I1** (each a full 64-bit ALU, shifter and
  multiply-accumulate; I0 holds the SA funnel-shift register, I1 the leading-
  zero counter; the two share one 128-bit multimedia shifter and are ganged
  into a single 128-bit pipe for MMI instructions), **LS** (128-bit
  load/store), **BR**, **C1** (FPU), **C2** (VU0 in macro mode).
- 32 x 128-bit GPRs; 64-bit MIPS III minus some instructions, MIPS IV prefetch
  and conditional moves, three-operand MUL/MADD, 128-bit MMI configuring the
  datapath as 2 x 64 / 4 x 32 / 8 x 16 / 16 x 8; little endian.
- 16 KB 2-way I-cache, 8 KB 2-way write-back D-cache with line locking, 64-byte
  lines; 16 KB scratchpad (DMA-reachable); 48-entry (96-page) fully
  associative TLB with ITLB/DTLB; 64-entry BTAC plus a 2-bit BHT stored in the
  I-cache; 8-entry write-back buffer; 8-qword uncached-accelerated buffer;
  128-bit CPU bus.
- FPU: COP1, 32 x 32-bit, single precision, *not* IEEE 754 (no NaN/inf, no
  denormals; the manual devotes a chapter to the differences). Fifteen-stage
  FP pipeline per Wikipedia.

### 3.2 VPU0 / VPU1 (VU User's Manual ch. 1)

- A VPU is VU + VU Mem + VIF (the decompression front end). VU0: 4 KB micro
  memory + 4 KB data memory, coupled to the core as COP2 (macro mode) or free-
  running (micro mode). VU1: 16 KB + 16 KB, micro mode only, has the EFU and
  XGKICK (direct path to the GIF, PATH1).
- 64-bit LIW: upper 32 bits a floating-point FMAC op, lower 32 bits FDIV /
  integer / load-store / branch. Upper unit: **four FMACs** (x, y, z, w),
  latency unified at 4 cycles. Lower unit: FDIV (self-timed divide/sqrt into
  the Q register, non-pipelined), EFU (exp/log/trig into P, VU1 only), 16-bit
  IALU, 128-bit LSU with field masking, BRU (11-bit PC-relative), RANDU
  (x^23 + x^5 + 1).
- 32 x 128-bit VF registers, 16 x 16-bit VI registers, ACC, I, Q, R, P;
  MAC/status/clipping flags.
- Same non-IEEE float rules as the FPU.

### 3.3 The rest of the EE die (EE User's Manual, ps2tek)

- **DMAC**: 10 channels (VIF0, VIF1, GIF, IPU_FROM, IPU_TO, SIF0, SIF1, SIF2,
  SPR_FROM, SPR_TO); normal, chain (tag-driven) and interleave modes; 8-qword
  slices; MFIFO.
- **VIF0/VIF1**: decompress packed vertex formats (UNPACK) into VU Mem, load
  microcode, VIF1 also drives GIF PATH2 and can mask PATH3.
- **GIF**: 64-bit bus to the GS at 150 MHz (1.2 GB/s theoretical); three
  arbitrated paths (PATH1 VU1/XGKICK, PATH2 VIF1 DIRECT, PATH3 DMA); 16-qword
  FIFO; GIFtag packet format.
- **IPU**: MPEG-2 macroblock decode and colour-space conversion (the MDEC's
  successor, but a different standard).
- **Timers** x4 (16-bit, bus clock / prescale / H-blank / V-blank), **INTC**,
  **SIF** (EE-IOP mailbox and DMA bridge at 0x1D000000), **RDRAM interface**
  (two 16-bit channels at 400 MHz DDR).
- Memory map: RAM 0x00000000 (32 MB), EE I/O 0x10000000, VU0 code/data
  0x11000000/0x11004000, VU1 0x11008000/0x1100C000, GS privileged
  0x12000000, IOP RAM window 0x1C000000, BIOS 0x1FC00000, scratchpad virtual
  0x70000000.

### 3.4 Graphics Synthesizer (GS User's Manual ch. 1 and 8)

- Blocks: host interface, setup/rasterizing (DDA, 8 or 16 pixels per cycle),
  **16 pixel pipelines** (texture, fog, alpha blend, tests), memory interface,
  4 MB local memory, PCRTC (two output circuits, NTSC/PAL/VESA, interlace or
  not, feedback write).
- Local memory: unified frame/Z/texture/CLUT; **1024-bit read port + 1024-bit
  write port** for frame and Z, **512-bit port** for textures, each side with
  an 8 KB page buffer; DRAM to page buffer 8192 bits per cycle. Bandwidth at
  150 MHz: 38.4 GB/s frame (1024 x 2) + 9.6 GB/s texture. Organisation: 512
  pages of 8 KB = 16,384 blocks of 256 B = 65,536 columns of 64 B; a column
  (512 bits) is one cycle, frame + Z together 2048 bits per cycle. Page/
  block/column map to pixel rectangles that depend on the pixel format
  (PSMCT32 page = 64 x 32 px, block 8 x 8, column 8 x 2; PSMT4 page = 128 x
  128).
- Rates: 2.4 Gpixel/s untextured, 1.2 Gpixel/s textured (32-bit, Z and alpha
  on); triangle setup 2-9 cycles depending on texture/Gouraud/fog/AA;
  primitives point, line, line strip, triangle, strip, fan, sprite; 16/24/32-
  bit textures and 4/8-bit CLUT; bilinear, trilinear, mipmap; Z 16/24/32;
  two register contexts.
- Programming interface: 64 general registers written through GIF packets
  (PRIM, RGBAQ, ST, UV, XYZ2, TEX0-2, CLAMP, FRAME, ZBUF, TEST, ALPHA, PABE,
  FBA, BITBLTBUF/TRXPOS/TRXREG/TRXDIR for transfers), and the privileged
  registers at 0x12000000 (PMODE, SMODE1/2, DISPFB1/2, DISPLAY1/2, EXTBUF,
  BGCOLOR, CSR, IMR, BUSDIR, SIGLBLID).

### 3.5 IOP side

- CPU: the PS1's R3000A at 36.864 MHz with 2 MB RAM, its own 13-channel DMAC
  (SIF0/SIF1, SPU2 cores, CDVD, SIO2, DEV9, USB, ...), timers, INTC.
- SPU2: two cores of 24 ADPCM voices each with reverb and effects, 2 MB work
  RAM, 48 kHz; documented only through emulator source and ps2tek's register
  map.
- CDVD/MechaCon, SIO2 (controllers and memory cards), DEV9 (HDD/network
  adapter), USB 1.1 OHCI, i.LINK.
- That Sony later replaced this whole chip with a PowerPC 440 running a MIPS
  emulator, and games still worked, is the strongest evidence that the IOP is
  a *behavioural* target: it does not need cycle accuracy the way the EE/GS
  pair does.

## 4. RTL that exists

| need | exists | state |
|---|---|---|
| R3000A CPU, PS1 DMA, SIO, timers, IRQ, MDEC, CD | **yes**: [PSX_MiSTer](https://github.com/MiSTer-devel/PSX_MiSTer) (Robert Peip), already fitted on both cards here | cpu.vhd 4,514 LUT; dma.vhd 2,276; joypad 1,508; cd_top 3,958; irq/timer < 300 |
| PS1 SPU | **yes**: PSX_MiSTer spu.vhd + spu_ram.vhd | 7,123 LUT, 32 BRAM; SPU2 is "two of these, bigger RAM, more effects", not identical |
| PS1 GPU (as an analogue for one GS pixel pipeline) | yes | gpu_pixelpipeline.vhd 2,746 LUT / 16 DSP for *one* pipe; whole GPU 11,936 |
| R5900 EE core | **no**. Nearest open cores: [NonTrivial-MIPS](https://github.com/trivialmips/nontrivial-mips) (MIPS32, superscalar, boots Linux) and [0dMIPS](https://github.com/Nambers/0dMIPS) (MIPS64r6, in-order, WIP). Neither has MIPS III's 64-bit semantics as the EE implements them, the 128-bit GPRs, MMI, the EE's cache/scratchpad model or its non-IEEE FPU | would be written from the manual |
| VU0/VU1, VIF, GIF, DMAC, IPU, SIF, RDRAM controller | **no** open HDL anywhere | from the manuals |
| GS | **no** open HDL. Software references: PCSX2's software renderer, DobieStation | from the manual; the memory layout chapter (ch. 8) is complete enough to build against |
| SPU2, CDVD/MechaCon, SIO2, DEV9 | no HDL; PCSX2 source is the behavioural reference | |

A fresh search (2026-09-05 and 2026-09-06) finds no PS2 FPGA core, complete or
in progress, on any platform; the MiSTer forum's assessment is that none is
coming. The one "PS2 on FPGA" project is a portable built around real EE/GS
silicon with an FPGA video-out board.

## 5. Sizing on the C1100 and FK33 — an estimate, not a fit

Scaled from this repo's PSX fit on xcu55n
(`build/fit_PSX_xcu55n/utilization_hier.rpt`, whole core 43,955 LUT / 27,219
FF / 68 BRAM / 93 DSP):

| PS2 block | basis | LUT estimate | memory |
|---|---|---|---|
| IOP (CPU + DMAC + timers + INTC + SIO2) | PSX cpu + dma + joypad + timer + irq ≈ 8.5k, plus 13-channel DMA and SIF | 10-14k | 2 MB IOP RAM: 8 URAM (288 Kb each) or HBM |
| SPU2 | 2 x PSX SPU (7.1k) plus effects | 14-18k | 2 MB: 8 URAM |
| CDVD + MechaCon + DEV9 + USB | PSX cd_top 4k plus DVD sector path and host-side streaming | 6-10k | host |
| EE core (2-issue 64-bit, 128-bit MMI, caches, TLB, FPU) | no analogue; 4-6x an R3000A plus 128-bit datapaths and a 15-stage FPU | 40-70k | 24 KB cache + 16 KB SPRAM: BRAM |
| VU0 + VU1 (4 FMAC + FDIV + EFU + IALU each, VIF each) | one FP32 FMA in fabric ~350 LUT + 2 DSP; the rest is control, register file (32 x 128 with 3 read ports) and UNPACK | 2 x 15-25k | 40 KB total: BRAM |
| DMAC + GIF + SIF + IPU + timers + INTC | PSX dma x 5 for channels and chain tags; IPU is a MPEG-2 macroblock decoder (~10k) | 25-35k | |
| GS: 16 pixel pipelines, setup, texture (bilinear/trilinear/CLUT), Z, alpha, fog, PCRTC | one PSX pixel pipe is 2.7k; a GS pipe does more (perspective-correct, mipmap, 32-bit Z) — 6-8k each x 16 plus setup/DDA and two CRTCs | 120-180k | **4 MB local memory with 2048-bit/cycle frame + 512-bit texture ports at 150 MHz**: 16 URAM columns wide (each URAM is 72 bits x 4096) — 128 URAM of the U55N's 640 / VU33P's 320; feasible on chip, which no MiSTer board can do |
| RDRAM 32 MB, 3.2 GB/s | | | HBM2 (both cards) or 111 URAM; latency to HBM is the design problem, not bandwidth |
| **total** | | **~250-400k LUT** | |

Against the fabric: C1100/xcu55n 871,680 LUT, 640 URAM, 1,344 BRAM tiles;
FK33/xcvu33p 439,680 LUT, 320 URAM, 720 BRAM. **Area fits on the C1100 with
room and is marginal on the FK33.** The 4 MB GS memory with its 2.5 kbit-wide
ports is the part these cards uniquely make possible.

## 6. Clock

| block | native | what this fabric does with MiSTer-style RTL |
|---|---|---|
| EE core + VUs | 294.912 MHz | the PSX R3000A closes ~117 MHz fmax here (156 on the VU33P) at a 33.9 MHz target with no timing effort. A dual-issue 64-bit core with a 128-bit datapath written to *close* on UltraScale+ could plausibly reach 150-200 MHz; 295 MHz for a whole in-order superscalar core with a shared 128-bit shifter and 3-read-port 128-bit register file is not a realistic target for a first design |
| GS | 147.456 MHz | reachable: it is a fixed-function pipeline, and URAM at 2048 bits per cycle at 150 MHz is inside the URAM FMAX |
| IOP | 36.864 MHz | trivial |
| RDRAM | 400 MHz DDR x 2 x 16 | replaced by HBM; bandwidth is not the issue |

### Where each block actually stands — 2026-09-11

Measured, not estimated, and stated against the native clock because **that is
the specification**. This project is rebuilding the machine, not emulating it:
a block that does not run at its native rate is not slow, it is *wrong*, and the
timing relationships between the three processors are part of what the software
depends on.

| block | native | measured | short by |
|---|---|---|---|
| EE core | 294.912 MHz | 192.7 (mean, three directives) | **35 %** |
| GS | 147.456 MHz | 129.1 | **12 %** |
| IOP | 36.864 MHz | runs on the card | met |

The GS number is the one to fix first and the study above already said it was
reachable. The EE is the known blocker and nothing here has changed that.

### The other half of the problem: the C1100 cannot make these clocks exactly

Every PS2 clock is an integer multiple of **18.432 MHz** — the EE is 16x, the GS
8x, the IOP 2x — and 18.432 MHz is not reachable from this card's 100 MHz
reference. The ratio is 576/3125, and the 5^5 in the denominator is not
something an MMCM's multiplier grid can produce.

`_IOPClocks` already lives with this: it runs the IOP at **36.875 MHz against a
native 36.864**, 0.03 % fast, from a VCO of 1106.25 MHz. The same approach gives
the GS 147.5 MHz from a VCO of 1475 (100 x 14.75, output divide 10), also 0.03 %
fast.

**What matters is not the absolute error but that every block shares it.** A
0.03 % offset applied uniformly is a console running 0.03 % fast — far inside a
real crystal's tolerance, and invisible. Two blocks with *different* offsets
would break the integer ratios the hardware depends on, and that would not be
invisible at all. So the PS2's clock tree should come from **one VCO** with
integer output dividers, the way `_IOPClocks` already derives the IOP's 1x, 2x
and 3x — not from a per-block MMCM chosen for each block's convenience.

Exactness, if it is ever wanted, is a board change rather than a logic one: an
18.432 MHz (or 147.456 MHz) oscillator feeding the fabric makes every ratio
exact. Worth knowing; not worth doing before the blocks close at their rates.

So a **cycle-accurate EE at native rate is the blocker**, exactly as the
retro-cores note said. The options are (a) a half-rate EE (games run at half
speed — useless as a product, useful as a bring-up target), (b) a
multi-cycle-per-instruction EE that trades accuracy for closure, or (c) an
EE that is not cycle-accurate but is *faster* where it can be (deeper
pipeline, higher fmax) and throttled to match — which is what the IOP's
PowerPC replacement did in software, and what PCSX2 does.

## 7. If it were pursued: the order that produces something testable at every step

1. **IOP subsystem first.** PSX_MiSTer's CPU, DMA, SIO, timers and IRQ, plus
   an SPU2 built as two instances of its SPU with 2 MB of URAM, plus SIO2 and
   a host-fed CDVD. This is the PS2's PS1-compatibility mode and can be
   validated against PS1 games and the PS2 BIOS's IOP boot. Everything is
   existing RTL with existing fits on both cards.
2. **GS as a standalone unit.** Feed GIF packets from the host over PCIe
   (the c1100-pcie-transport work) and compare the framebuffer against
   PCSX2's software renderer frame-for-frame. The GS manual's chapter 8 is a
   complete memory-layout spec, and the pipeline is fixed function; this is
   the largest block but the best specified.
3. **EE core** written to the EE Core User's Manual: MIPS III subset first,
   then MMI, then the FPU with its non-IEEE rules, verified against
   PCSX2's interpreter with instruction traces. VU1 next (micro mode only),
   then VU0 with macro mode and the COP2 coupling.
4. DMAC, VIF, GIF paths, SIF, IPU; then integration and the BIOS boot.

Each step is months of work for someone who knows the fabric; the whole is
the "full-time job for a team" the MiSTer developers describe. This document
does not change the retro-cores verdict — PCSX2 on the host GPU remains the
answer — it records what the verdict rests on and what step 1 would cost if
the question is asked again.
