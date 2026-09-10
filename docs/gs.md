# The Graphics Synthesizer: how it gets built, and how it gets checked

The GS is the best-specified thing left in this project and the only major block
that can be built **before** the Emotion Engine exists. It takes GIF packets and
produces pixels; nothing about that requires a working R5900, so the host can
play the part of the EE by writing packets straight into the GIF, exactly as the
host already plays the part of the EE for SIF RPC on the disc path.

That independence is why it runs in parallel with the EE rather than after it.

## What already exists

`rtl/gs/gs_lmem.vhd` — the 4 MB of local memory, in UltraRAM. That file settles
the physical question (128 URAM, 20% of the C1100's 640) and deliberately knows
nothing about pixel formats: the page/block/column swizzle belongs to whatever
decides *which* address to touch, which is the rasteriser and the texture unit.

Everything else is unwritten.

## The order, and why it is this order

The EE core was built reference-model-first and it worked: a Python model that
models no timing at all, random and directed programs, and a diff of
architectural state per retired instruction. Three real bugs and three broken
instruments came out of that harness, and none of them would have been found by
looking at the RTL. The GS gets the same treatment, and the order is chosen so
that every step produces something that can be diffed:

1. **GIF packet decode and the register file.** A GIFtag names how many
   quadwords follow, in which format, and which register each maps to. Nothing
   is drawn. Verifiable on its own: feed packets, compare the 64 general
   registers afterwards.
2. **Local memory addressing.** The page/block/column swizzle, per pixel format.
   Verifiable on its own and *exhaustively* — there are only 4 M addresses, so
   every one can be checked rather than sampled.
3. **Host-to-local transfers.** `BITBLTBUF`/`TRXPOS`/`TRXREG`/`TRXDIR` and the
   `HWREG` data path. This is the first thing that puts pixels in memory, and it
   needs no rasteriser at all — which makes it the first end-to-end test.
4. **The rasteriser**, primitive by primitive: sprite first (axis-aligned, no
   interpolation), then flat triangle, then Gouraud, then the scissor and the
   Z and alpha tests, then texture.
5. **PCRTC**, out through the video path that already works.

Steps 1 to 3 are a complete, testable slice with no interpolation in them, which
is the same reasoning that made the R5900 integer core the first EE slice.

## Where PCSX2 comes in, and where it does not

PCSX2 is checked out at `~/pcsx2-ref`, **outside this repository and staying
there**. Two separate reasons:

- **Licensing.** PCSX2 is GPL-3.0+; this repository is GPL-2. Those are not
  compatible in the direction that matters, so no PCSX2 code, and nothing
  derived from it, goes into this tree. What is written here is written from the
  GS User's Manual.
- **Authority.** The same rule the EE work uses: PCSX2 is a second
  implementation, not an authority, and where the two disagree the manual
  decides.

What PCSX2 is genuinely good for is being a **test oracle**. Its swizzle tables
encode facts about Sony's hardware, and a formula written independently from the
manual can be checked against them mechanically, exhaustively, and in a way that
produces a pass or a fail rather than a pile of data to eyeball.
`tools/gs/xcheck_swizzle.py` does exactly that: it reads the tables out of the
PCSX2 checkout at run time, compares all 4 M addresses against the formula in
`sim/gs/gs_ref.py`, and reports agreement. The tables are never copied here; the
tool is useless without a PCSX2 checkout, which is the correct dependency.

There is also an embedding index over the PCSX2 GS sources at
`~/pcsx2-ref/index`, built with `nomic-embed-code` on the local GPU, for finding
the code that implements a behaviour when grep does not know the vocabulary. It
is a search aid over someone else's tree, and its output is a file and a line
number to go read.

**What the local model is not used for is generating GS behaviour.** A
hallucinated register field would be indistinguishable from a real one until a
game rendered wrongly, and since every field has to be checked against the
manual anyway, generating them first saves nothing and risks a great deal. The
division is: mechanical and checkable, yes; authoritative, never.

## Steps 1 to 3 run — 2026-09-10

`rtl/gs/gs_gif.vhd` decodes GIFtags, holds the general registers and runs
host-to-local transfers, and agrees with the reference across **40 random
packet streams** plus directed cases. `sim/gs/run_diff.sh` generates a stream,
runs both, and diffs all 128 register addresses, the framebuffer, and the count
of writes to undefined addresses.

The swizzle is the part worth reading. In hardware it is not arithmetic at all:

    word address = page(8:0) & x5 & y4 & x4 & y3 & x3 & y2 & y1 & x2 & x1 & y0 & x0

The low eleven bits are the low bits of x and y interleaved in a fixed order.
The manual presents this as three tables and PCSX2 stores two of them as
literal arrays, but it is a wire permutation and costs nothing. Only the page
number needs an adder.

### Two bugs, and what found them

**REGLIST with a one-entry descriptor list.** The list is walked once per
register, not once per quadword, so with `NREG = 1` the second half of a
quadword is the *next loop iteration* and uses descriptor 0 again. Indexing it
as descriptor 1 reads past the end of the list and writes whatever register is
named there — in the failing case, `PRIM`. It is invisible until a packet uses a
short list, and a short list is the common case, since that is what REGLIST is
for. Directed tests with `NREG = 2` passed; a random stream found it on the 23rd
tag.

**Every transfer was writing to page zero.** The generator was putting the
buffer pointer in `BITBLTBUF`'s *source* field rather than `DBP` at bits 45:32,
so the base-pointer arithmetic in the address was never exercised at all. Once
corrected, 29 of 40 seeds failed — and the cause was not the RTL but the
harness, which filtered the undefined-write counter out of the RTL's output
while still comparing it from the reference's. That counter is how "a write to
an address the manual does not define must leave every register alone" gets
checked, so it belongs in the diff.

Both are the same shape as the EE work: the test was weaker than it looked, and
what it did not reach stayed broken.

## Step 4 begins: the sprite — 2026-09-10

A sprite is the primitive to build first for the same reason the integer core
came before the FPU: it is axis-aligned and flat-coloured, so there is no
interpolation to get wrong before the addressing, the scissor, the register
contexts and the write mask are known to be right. Two vertices, the colour
from the second, the rectangle between them.

`gs_gif.vhd` now carries a vertex queue, decides the primitive from `PRIM`,
picks context 1 or 2 from `PRIM.CTXT`, subtracts `XYOFFSET`, clips to
`SCISSOR`, and writes through `FRAME`'s `FBMSK`. 40 random streams agree with
the reference on the framebuffer and on the number of pixels drawn — between 69
and 367 per stream, which is what makes the agreement mean something.

**A masked write is a read-modify-write**, and that is why the GIF grew a read
port. `FBMSK = 0` is the common case and still writes in one clock; a non-zero
mask reads the word back, merges, and writes, at the cost of the memory's
latency. That path is the beginning of the one Z and alpha will need, so it is
worth having early even though nothing yet uses it for anything but the mask.

The pixel count is compared, not just printed. A primitive that quietly draws
nothing — clipped away, empty rectangle, a pixel format that is not
PSMCT32 — otherwise looks exactly like a framebuffer that was never meant to
change, and a whole test file can pass that way.

### What the sprite does not do yet

No Z test, no alpha blending, no texture, no dither, no anti-aliasing, and
PSMCT32 only. `PRMODECONT` is ignored, so the mode always comes from `PRIM`.
Each of those is a later block, and drawing them wrongly now would be worse
than not drawing them: a wrong pixel that appears is much harder to notice than
one that never arrives.

## The triangle, and the fill rule — 2026-09-10

`gs_ref.py` rasterises flat-shaded triangles, including strips and fans.

### The rule, settled

The first version was written as an explicit assumption — the standard top-left
rule on edge functions sampled at **pixel centres** — and marked as needing
verification before any RTL was built on it. That caution was justified: it was
wrong, and wrong in a way no self-consistency test could ever have caught.

PCSX2's software rasteriser settles it. It takes `ceil` of the scanline bounds
(`y0011.xzxz(y1221).ceil()`) and `ceil` of each scanline's x span
(`GSVector4 lrf = xy.ceil()`), and it evaluates the edges *at* the integer
scanline. A half-open interval on `ceil` is exactly **sampling the point (x, y)
itself** — the pixel origin, not its centre — with left and top edges inclusive
and right and bottom exclusive:

    covered  ⟺  ceil(left) ≤ x < ceil(right)  and  ceil(top) ≤ y < ceil(bottom)

So the reference now walks scanlines with `ceil` bounds, in **exact rational
arithmetic** rather than floating point: the rule is stated in terms of `ceil`,
and doing the arithmetic in floats would put the answer at the mercy of rounding
in precisely the cases the rule exists to settle.

**A rule shifted by half a pixel still tiles perfectly.** The tiling test passed
under the wrong convention and under the right one, and would have passed under
any consistent rule. What distinguishes them is a sub-pixel edge, so there is
now a test with a left edge at x = 0.5: the ceil rule starts the span at pixel 1
and leaves pixel 0 alone, where centre sampling would have painted a column the
hardware does not. That test is the one that fails if the convention drifts.

Frame-by-frame comparison against PCSX2 is still the stronger check and is still
owed — this settles the convention, not every corner of it. Synthesising a `.gs`
dump to get golden frames was investigated and deferred: the format embeds a
versioned GS freeze-state blob, and getting its layout subtly wrong would
produce *wrong* reference frames, which is worse than having none.

The other properties hold as before: two triangles sharing a diagonal tile a
square exactly, a degenerate triangle draws nothing, a strip reuses its last two
vertices, and nothing lands outside the hypotenuse.

## The DDA, proven before it is built — 2026-09-10

The reference computes each scanline's span with exact rational arithmetic,
which is the right shape for a specification and the wrong shape for hardware:
it divides once per scanline per edge, in unbounded precision. Hardware divides
once per *edge* and steps.

Those are the same answer only if the stepping is exact, and "only if" is the
whole problem — a DDA that accumulates with the wrong rounding is right in the
middle of an edge and wrong at its ends, which is precisely where a fill rule
matters. So `sim/gs/test_dda.py` checks the formulation the RTL will use against
the reference on random edges, including deliberately sub-pixel ones, **before**
any of it is committed to RTL: about 300,000 scanlines per seed, agreeing
exactly. Finding a formulation error from a Python diff costs minutes; finding
it from a waveform costs a day.

The derivation, in pixel space with `y` an integer scanline:

    x(y) = [ x0*dy + dx*(16*y - y0) ] / (16*dy)        (all terms integers)

so with `num` stepping by `16*dx` each scanline and `den = 16*dy` constant, the
span edge is `ceil(num/den)`. Dividing once at setup to get the per-scanline
quotient and remainder steps turns that into an add and at most one correction
per scanline, which is what the RTL will do.

One implementation note for when it is written: the quotient step is a *floor*
division, and VHDL's integer division truncates toward zero. For a leftward edge
the two differ, and the remainder must stay in `[0, den)` for the single
correction to be enough.

## The edge DDA in RTL — 2026-09-10

`rtl/gs/gs_edge_dda.vhd` implements one triangle edge: two divisions at setup,
then an add and at most one correction per scanline. It agrees with the
reference exactly across **13,693 scanlines over twelve seeds**, sub-pixel
endpoints included.

It is built and tested **on its own, before the rasteriser that will use it**,
because a wrong span and a wrong pixel loop look identical in a framebuffer and
only one of them is an arithmetic problem. Three bugs came out of that, and none
would have been obvious from a picture:

**Width.** A VHDL multiplication returns the sum of its operands' widths, so
forming the products at 41 bits each and assigning an 82-bit result to a 41-bit
signal does not even elaborate. The products are now formed at their natural
width and resized once.

**A sampling race in the testbench.** `busy` is driven by the same edge the
driving process wakes on, so reading it there gets the value from *before* the
edge: the wait loop fell straight through and every result was read out of a
unit that had not started. This is the identical race the EE testbench had on
`retire_pc`, which is worth noting — the instrument fails the same way twice if
you let it.

**A lost start pulse.** `start` is high for one cycle, and the restart path went
back to `S_IDLE` to wait for a pulse that had already gone. Every edge after the
first kept the previous one's quotient and remainder, so the output was a
plausible *constant* rather than an obvious failure — the kind that survives a
quick look at a waveform. The setup is now a procedure called from both entry
points, so the two cannot drift apart.

The floor-versus-truncate hazard flagged when the formulation was proven turned
out to be real and is handled: VHDL's integer division truncates toward zero, so
for a leftward edge the quotient step is off by one and the remainder goes
negative. Edge 1 of the very first seed was such an edge — `dx = -5433`, where
floor gives `qstep = -29, rstep = 1232` and truncation gives `-28, -1808`.

## The triangle rasteriser runs — 2026-09-10

Triangles, strips and fans, on top of `gs_edge_dda`: three edge units started
together at the first scanline, exactly two spanning any given scanline, the
span between their `ceil(x)` values. **16 random streams agree with the
reference** — registers, framebuffer, pixel count and a checksum over all 4 MB —
alongside sprites, transfers and the directed cases.

Two things had to be fixed in the *harness* before the RTL could be trusted, and
both had been hiding failures rather than causing them.

**The framebuffer comparison only looked through a window.** A dump of the first
few hundred bytes is a test that checks where it was told to, and a primitive of
any size draws mostly outside it. That is how "the framebuffer matches" and "one
side drew twenty times as many pixels as the other" were both true at once. The
comparison is now a checksum over the whole of local memory, which is cheaper
than a wider dump and complete.

**The random generator was kicking primitives from garbage.** `0x4` and `0x5` —
`XYZF2` and `XYZ2` — draw when they are written, and they had been removed from
the A+D address list for exactly that reason while being left in the *packed
descriptor* list, which is the other way a packet names a register. So random
streams were drawing triangles from random coordinates under a random `PRIM`,
with extents of millions of pixels, and the two models disagreed somewhere out
there. `0xC` and `0xD` stay, because `XYZF3` and `XYZ3` queue a vertex without
drawing — the harmless half of the same idea.

Neither of those is a subtlety of the hardware. Both are the same failure the EE
work kept hitting: **the instrument was weaker than it looked, and what it did
not reach stayed broken.**

### The bug the incremental approach found

The first attempt at this was reverted because it broke seven of ten random
sprite streams. Re-applying it one change at a time, with the sprite suite as
the gate after every step, put the cause in the open immediately: vertex
tracking passed, the `S_DRAW` restructure passed, and the integration failed —
because **`tkick` was declared, reset and used but never assigned.** The state
machine, the edge instances, the kick decode and the divert were all present and
correct, and the triangle path was unreachable. A patch anchor had not matched
after an earlier edit, and nothing checked.

A second fix came out of the same pass: `ceil(y/16)` written as `(y+15)/16`
truncates toward zero in VHDL rather than flooring, so it was wrong for any
vertex above or left of `XYOFFSET`. An arithmetic shift is the floor.

## Alpha blending, and the coordinate width — 2026-09-10

**The blender is in**, for sprites and triangles alike:
`Cv = ((A - B) * C >> 7) + D` per component, where A, B and D each select the
source colour, the destination colour or zero, and C selects the source alpha,
the destination alpha or a fixed value. `COLCLAMP` chooses between clamping and
wrapping, and wrapping is implemented rather than rounded off — content uses the
overflow deliberately. Only RGB is blended; the alpha written is the source's.

All **162 selector combinations** — every A, B, C, D by both clamp modes — are
checked directly, and the random suite now generates blending, including the
selectors that read the destination, since those force a framebuffer read on
every pixel and take a different path through the drawing logic than an opaque
write.

**The signed-16 coordinate assumption is gone.** A vertex and `XYOFFSET` are
each 16-bit unsigned, so their difference spans [-65535, 65535] and never fitted
in a signed 16 — the window coordinates and the edge unit's ports are 18 bits
now. Real content stayed well inside the old range, which is exactly why the
overflow would have gone unnoticed.

### Three faults found on the way, all of them mine

**The blender ran when it should not have.** `PRIM.ABE` gates it, and the RTL
applied it unconditionally on the masked-write path — which is also taken for an
ordinary masked write with no blending at all. It was found by forcing `ABE` off
in the generator and watching *every* seed fail, which said at once that the
divergence was not in the blender.

**A width change that only half applied.** The edge unit's setup had been
factored into a procedure, and a patch aimed at the inline version it replaced
matched nothing — leaving two operands at the old width. It does not elaborate,
which is the good case.

**The framebuffer model raced itself.** Write and read were separate `always_ff`
blocks, both non-blocking, so a read could sample memory before a write landed
and a blended pixel would read a stale destination. They are one block now, the
write applied first. That is a modelling artifact rather than hardware, but it
would have made the two disagree in exactly the case blending exists for:
drawing over something already there.

### PSMCT24

Added alongside the blender. It shares PSMCT32's addressing exactly — same page,
block and column — and differs only in that the top byte of the word is not part
of the pixel and has to survive the write. That is what `FBMSK` already means, so
it is expressed as one rather than as a second write path.

`PSMCT16` is derived and ready but not implemented: its tables are bit
interleaves like the 32-bit ones, `blk = by2·bx1·by1·bx0·by0` and
`column16(cy,cx) = (column32(cy, cx&7) << 1) | cx3`, with a page of 64×64 pixels
and a block of 16×8. It needs the 16-bit pixel packing (RGBA5551) to go with it,
and dither needs *it*, since dither is inert on a 32-bit format.

## What the primary source settles, and what it does not — 2026-09-10

Sony's **GS User's Manual version 6.0** was obtained and read (it is an
encrypted PDF; `poppler-utils` reads it). It is the authority this project has
been citing second-hand, and it settles three questions and refuses a fourth.

### Confirmed: the fill rule, from the source

> *"Draws the pixels in the three sides specified by the three vertices. When a
> side passes the center of a pixel, drawing is performed if it is the left
> side, and is not performed if it is the right side. When a side parallel to
> the X axis passes the center of a pixel, drawing is performed if it is the top
> side, and is not performed if it is the bottom side."* — §3.2.9

That is the top-left rule, and the "center of a pixel" wording reconciles with
what was derived from PCSX2's `ceil` behaviour once the coordinate convention is
pinned down: paraLLEl-GS states independently that on the GS **pixel centres sit
at integer coordinates**, so "a side passes the centre of a pixel" is a side
passing through integer (x, y) — which is where this implementation samples.
Three sources now agree, one of them Sony's own. The rule is no longer
provisional.

### Confirmed: two rules already implemented

> *"the Z coordinate and Fog coordinate of the first vertex are ignored, and the
> setting for the second one takes effect"* — for a Sprite.

> *"when doing Flat shading … the vertex color information set immediately
> before each drawing kick becomes effective"* — the last vertex's colour.

Both match what is implemented. It is worth having checked rather than assumed:
either could have been the first vertex, and nothing in the differential harness
would have noticed, because the reference and the RTL would have been wrong
together.

### Not documented: the DDA's interpolation precision

The manual describes the pipeline — setup computes "the gradient … and the
initial value of DDA", rasterising generates 8 or 16 pixels concurrently and
"the RGBA value, Z value, texture value and Fog value for each pixel are
calculated from the gradient" — and states the pixel pipeline's *arithmetic*
precision as "32-bit calculation precision (8 bits each for RGB + 8 bits for
Alpha)". **It never states how many fractional bits the DDA carries between
pixels.** Keyword search, a semantic search over the whole manual using a local
embedding model, ps2tek and psdevwiki all come up empty.

Nor is it known elsewhere. paraLLEl-GS — the most accuracy-focused GS
implementation in existence — says plainly that it "isn't really aiming for
bit-accuracy against hardware", rasterises with barycentrics rather than
emulating the DDA, and uses FP32 for Z while acknowledging uncertainty about
32-bit fixed-point Z. PCSX2 interpolates in floating point. **Nobody has this.**

### The decision that follows — **superseded, see below**

Three options existed and the middle one is now excluded:

1. **Exact interpolation** — evaluate the plane exactly at each pixel centre,
   in rational arithmetic in the reference and as an exact quotient/remainder
   DDA in the RTL, which is the same mechanism `gs_edge_dda` already uses and
   was already proved bit-exact against the reference.
2. **Reverse-engineer the hardware DDA** — needs a PS2 and test ROMs, which
   this project does not have.
3. **Copy an existing emulator** — would encode *its* floating-point
   approximation as though it were hardware, and it is documented as not being
   hardware.

**Option 1.** It is the mathematically exact answer to "what colour is this
pixel", it is deterministic and reproducible on both sides of the harness, and
it is at least as close to hardware as anything that exists. The residual risk
is bounded and should be stated: against real silicon a Gouraud channel may
differ by a least-significant bit where the hardware DDA's rounding differs from
exact. For colour that is invisible. **For Z it is not** — a depth test at an
exact tie could flip — so when Z is implemented that risk is carried
deliberately and noted where a game shows Z-fighting the hardware does not.

If a real PS2 becomes available, the open question is small and precisely
stated: draw a triangle with known vertex colours and read back the framebuffer,
and the LSB pattern along a scanline answers it.

## Someone has measured it — 2026-09-10

The conclusion above ("nobody has this") was **wrong within a day of being
written**, and the correction matters more than the original finding.

`ARMSX2`, a PS2 emulator aimed at ARM handhelds, ships a software renderer whose
Gouraud and depth interpolation were **measured against a real console** — an
SCPH-30001, driven by purpose-written probes (`gs-zgrad`, `gs-interp`,
`gs-walk2`) that force integer landings under a raw depth readback and score a
width curve over tens of thousands of readings. Their source documents what was
measured, what was inferred, and — unusually — what is still an open divergence.
It is GPL-3, so nothing is taken from it; what follows are facts about Sony's
silicon, established by their probes and cited here.

**The GS does not interpolate exactly, and it does not interpolate per pixel.**

1. **The DDA steps a block of eight pixels at a time.** One DDA step spans eight
   pixels horizontally, on every draw, textured or not. It seeds at the span's
   first pixel, adds a truncated per-lane offset within the block, and adds one
   truncated step per block. Eight is measured — the width curve peaks on powers
   of two and globally at eight — not assumed.
2. **The step is truncated to a 2⁻¹⁰ grid.** A gradient of 1/4 is the identity
   under that truncation, which is what made the depth bias visible in isolation.
3. **Interpolated depth runs short of its plane** by half a step of that grid,
   1/2048, and the two axes carry the shortfall differently: along X it is
   present from the span's first pixel and does not follow the gradient's sign;
   along Y it accumulates, is exempt on the primitive's first scanline, and does
   follow the sign. A flat triangle is exact — 896 of 896 readings — so the bias
   belongs to the walk rather than the seed.
4. **Sprites never interpolate depth**: it is carried as an integer. That agrees
   with the manual's statement that a Sprite takes Z from its second vertex.

### What this does to the decision

**Exact interpolation is now the wrong answer.** It would be systematically
wrong rather than wrong in the last bit: hardware truncates its step to 2⁻¹⁰ and
walks in blocks of eight, and a mathematically exact plane does neither. The
choice made yesterday on the evidence available was right on that evidence and
is superseded by better evidence, which is how it should go.

The rule to implement is therefore a **blocked truncating DDA**: eight-pixel
blocks, per-lane offsets and per-block steps both truncated to 2⁻¹⁰, with the
depth bias applied to the scanline seed. That is *more* tractable in hardware
than exact rational interpolation, not less — truncation to a fixed grid is what
a DDA does naturally, and it removes the need for exact division per component.

Two questions their probes leave open are worth recording, because they are the
first things to ask of a real console if one becomes available:

- **Silicon pairs rows two at a time** — rows *k* and *k+2* read identically at
  every *k* — and nothing models the vertical structure that implies.
- **The affine texture coordinate is truncated** and so could carry a block of
  its own, but no capture has swept its width.

Sources: ARMSX2's `GSBlockWalk.h` and `GSDepthWalk.h` (GPL-3; read, not copied),
and paraLLEl-GS for the independent confirmation of the sampling convention.

### What the rasteriser does not do yet

No Gouraud interpolation — flat shading only, the colour of the last vertex. No
Z test or Z buffer, no texture, no dither, and no 16-bit formats.

Gouraud and Z are the same problem twice: both need a value interpolated across
the primitive, and the interpolation rule has to be established the way the fill
rule was — from the hardware, not from a plausible-looking gradient. The edge
unit generalises to carry them, since a colour or a Z steps along an edge
exactly as x does.

Dither is small but needs a 16-bit pixel format to act on, so the formats come
first. Texture is the largest remaining block by a wide margin — `TEX0`, `TEX1`,
the CLUT, coordinate modes, filtering and mipmaps — and is a milestone rather
than an increment.

## Superseded: the first attempt, reverted — 2026-09-10

The rasteriser was built on top of `gs_edge_dda` — three edge units started
together at the triangle's first scanline, two of them spanning any given
scanline, the span between their `ceil(x)` values — and a directed triangle
matched the reference exactly, 36 pixels for a right triangle with legs of
eight. Two real bugs came out of it and are worth keeping even though the code
is not:

- The testbench drained only 64 cycles after the last packet. A triangle's setup
  is two long divisions *per edge* before a single pixel is written, so the
  simulation ended in the middle of the setup and the framebuffer came out
  empty — which looks exactly like a rasteriser that does not work. The drain is
  now sized for the slowest consumer, and that fix is kept.
- Stepping the edges and reading them in the same cycle gives the *previous*
  scanline's span, so the triangle came out one pixel too wide on every line but
  the first. A shape that is still a triangle is the worst kind of wrong.

It was **reverted** because it broke seven of ten random sprite streams that had
been passing, and the cause was not found within the session. Committing a
rasteriser that works on the one case it was aimed at while quietly breaking the
primitive that already worked would be worse than having no rasteriser: the
suite would stay green only because the failing case had been removed from it.
`gs_edge_dda.vhd` stands on its own and is unaffected — it is verified against
the reference independently, which is precisely why it survives the revert.

## What is not started

The rest of step 4 — triangles (flat, then Gouraud, then textured), lines and
points — and step 5, PCRTC. Local-to-host and local-to-local transfers, and
pixel formats other than PSMCT32.
