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

## Gouraud, built to the measured rule — 2026-09-10

`PRIM.IIP` now interpolates all four channels across a triangle, in the
reference (`sim/gs/gs_ref.py`) and in the RTL (`rtl/gs/gs_chan_dda.vhd`)
together, because a reference-only change has nothing to be diffed against.

It implements the **blocked truncating DDA** the section above arrived at rather
than the exact plane, and the arithmetic falls out more cleanly than expected.
Working in window space with X and Y in 12.4, the plane through the three
vertices has

```
det = dx10*dy20 - dx20*dy10
nx  = (c1-c0)*dy20 - (c2-c0)*dy10
ny  = (c2-c0)*dx10 - (c1-c0)*dx20
```

and, scaled so that every quantity is an integer count of 2⁻¹⁰,

```
gradient  = floor(16 * 1024 * nx / det)
seed(x,y) = floor(1024 * (c0*det + nx*(16x - X0) + ny*(16y - Y0)) / det)
```

The sixteens are the 12.4 fraction cancelling — `det` carries it twice and `nx`
once — and deriving them rather than fitting them is the only reason the model
and the RTL agreed at the first attempt on everything except one timing bug.

The eight lane offsets are **not** eight divisions. With
`16384*nx = q*det + r` and `0 ≤ r < det`,

```
floor(j * 16384 * nx / det) = j*q + floor(j*r / det)
```

and because `r < det` that correction is at most `j-1`, so all eight lanes and
the block step fall out of eight accumulate-and-subtract cycles behind the one
division that is actually needed. Per triangle that is one division per channel;
per scanline it is one more per channel for the seed, and the four channels have
their own dividers so a scanline costs one division's worth of latency rather
than four. **No per-pixel division at all** — which is the practical payoff of
hardware's grid being coarse.

### The seed is snapped too, and that is a choice

Everything above lives on the 2⁻¹⁰ grid, the seed included. That is a modelling
decision and not a measurement: the probes that established the grid used flat
triangles to isolate the seed, and a flat triangle's seed is an integer, so
nothing in the evidence distinguishes a snapped seed from an exact one. It is
chosen because it puts the whole DDA on one grid — which is what the register
holding it would be in silicon — and because it lets the RTL agree with the
model bit for bit in integer arithmetic instead of chasing an exact rational
through a divider. If a console ever contradicts it, this is the line to change.

### The bug worth keeping

The interpolators first stepped on a **registered** pulse, raised on the cycle a
pixel was written. That lands the step on the edge that produces the *next*
pixel's address, so the next pixel is written with the previous lane's value:
every span repeated its first pixel and ran one behind for the rest of the
scanline. What makes it worth recording is how it presented — a picture that is
still a smooth gradient, still the right shape, still the right colours at the
vertices, and shifted by one pixel. That reads as a half-pixel sampling
convention, which is a thing this rasteriser has genuinely had wrong before, and
the temptation was to go back and re-examine the fill rule. It was a pipeline
mistake. The advance is now combinational, on the same edge as the address.

It was found in two minutes rather than an afternoon only because the directed
test compared a whole scanline against a hand-computed plane, so the first
correct pixel followed by a repeat was visible directly.

### What it is checked against

- A directed Gouraud triangle with primary-coloured vertices, whole framebuffer
  compared, 643 lines identical.
- The random GIF streams, which now emit `IIP` on about half of their triangles
  and rewrite `RGBAQ` ahead of every vertex when they do.
- The model's own arithmetic against exactness: a gradient of ¼ is the identity
  under 2⁻¹⁰ truncation and reproduces the exact plane, and every other gradient
  diverges from it at pixel 9 — the second block. That signature is what the
  console's probes measured, so seeing the model produce it is a check that the
  rule was implemented and not merely described.

## Depth — 2026-09-10

The Z buffer, the depth test and interpolated depth, again in the reference and
the RTL together.

Two thirds of this is not in doubt. The manual specifies the test exactly —
`ZTE`/`ZTST` with NEVER, ALWAYS, GEQUAL and GREATER, `ZMSK` masking the write,
and the Z buffer having no width of its own because it is the frame buffer's —
and it is worth honouring its corner cases rather than smoothing them:

- **`ZTE = 0` is not a mode.** The manual calls it *prohibited, since it may
  cause a malfunction*. There is no documented behaviour for two models to agree
  on, so neither implements one and the generator does not emit it.
- **The documented way to draw without a depth test** is `ZTE=1`, `ZTST=ALWAYS`,
  `ZMSK=1`, which leaves the buffer "neither accessed nor updated". That
  combination is detected and the buffer is not even addressed — not read and
  discarded.
- **A sprite's depth is an integer** from its second vertex and is never
  interpolated, which is both what the manual says about Sprite and what the
  console probes found.

The test runs **before** the colour, and a pixel it rejects is never read, never
blended and never written. Doing it afterwards would give the right picture
almost always and the wrong one wherever `FBMSK` or the blender touches a pixel
that should not have survived. For the same reason the Z write is a consequence
of the *test* and not of the colour write: a pixel that passes updates Z even
when the frame buffer write is entirely masked out, and the two masks are
independent.

### Depth rides the colour interpolator

`gs_chan_dda` became generic. Depth differs from a colour channel in exactly
three ways — 32 bits instead of 8, no clamp to a byte, and the bias — so it is
the same unit with `CWIDTH => 32, ZMODE => true` rather than a second file to
keep in step. The only structural change is the accumulator's grid: depth is
carried on 2⁻¹¹, one bit finer than the 2⁻¹⁰ the *step* is truncated to, because
its bias is half a step and snapping a half-step onto the grid it is half of
would round it straight back out of existence. The step and lane offsets are
still computed on 2⁻¹⁰ and scaled up, so the DDA does exactly what it did.

### The bias is the one thing here that is not verified

The rule implemented is the recorded one: depth lands half a grid step below its
plane; along X the shortfall is present from the span's first pixel and ignores
the gradient's sign; along Y it accumulates, follows the sign, and is exempt on
the primitive's first scanline; a flat triangle is exact. That is a restatement
of somebody else's measurements on an SCPH-30001, and **this project has never
seen a console either confirm or contradict it.**

It is therefore confined to one function in each implementation — `_zbias()` in
`sim/gs/gs_ref.py`, two lines under `ZMODE` in `rtl/gs/gs_chan_dda.vhd` — so
that a console disagreeing costs one edit rather than an investigation.

`hw/ps2probe` now asks the question directly. `gsprobe.c` draws two flat
triangles whose depth varies along one axis only, reads the Z buffer back
through the Local→Host path, and prints it; `compare.py` builds the same
primitives as a GIF stream, runs them through the reference, and diffs. The
model's own answer for the y-gradient probe already shows the signature the
probe is looking for — the first pixel of the first scanline reads `000fffff`
where the plane says `00100000`, one below, which is the X half of the bias with
nothing else on top of it. Whether silicon prints the same number is the point
of the exercise.

The probe also prints the count of rows equal to their `k+2` neighbour, because
"silicon pairs rows two at a time" is an open question nobody has published an
answer to, and a triangle with a pure Y gradient answers it without any analysis
at all.

### What it is checked against

- A directed stream of three overlapping sprites at different depths plus a
  Gouraud triangle interpolating depth through the same buffer: identical, and
  the depth test rejects 522 of 2040 pixels — so the two models agree about
  which pixels *lost*, not merely about drawing everything.
- The same stream with the test disabled the documented way, also identical,
  which is what proves the rejection above came from the test rather than from
  both models failing to draw.
- Twenty random GIF streams, whose sprites and triangles now carry vertex depth
  and random `ZBUF`/`TEST` — including a Z buffer deliberately overlapping the
  frame buffer about half the time, since that is the case that catches the two
  writes being done in the wrong order.

### What the rasteriser does not do yet

No texture, no dither, and no 16-bit formats. PSMZ16 and PSMZ16S are not
supported either — the depth path takes PSMZ32 and PSMZ24, which share the
32-bit-per-pixel layout, and the 16-bit Z formats come with the 16-bit colour
formats since they need the same addressing work.

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

## The depth buffer was addressed as if it were colour — 2026-09-11

The Z buffer work committed the day before used the same address function as
the frame buffer. It should not have: **the depth formats use the same block
table with the block address exclusive-ored by 24.**

Two independent sources say so and agree exactly.

* The GS User's Manual draws the block configuration for every format (8.3.1,
  8.3.2). The PSMZ32 figure is the PSMCT32 figure with every entry xor 24 —
  `0 1 4 5 16 17 20 21` becomes `24 25 28 29 8 9 12 13` — and PSMZ16 and
  PSMZ16S stand in the same relation to PSMCT16 and PSMCT16S.
* PCSX2 states it as a constructor argument rather than as a table:
  `swizzle32Z {swizzleTables32, 0x18}` against `swizzle32 {swizzleTables32,
  0x00}`, and likewise `swizzle16Z` and `swizzle16SZ`.

PCSX2 applies the xor to the final block number where this model applies it to
the index within the page. The two agree because `ZBUF.ZBP` counts pages, so
the base is always a multiple of 32 blocks and the xor cannot carry into it.

**Why the differential suite could not see it.** The reference and the RTL were
wrong in exactly the same way, so nineteen passing runs — including the ones
that deliberately overlapped the Z buffer with the frame buffer — agreed with
each other about the wrong address. This is the limit of differential testing
against one's own second implementation, and it is worth naming: a shared
misreading of the source is invisible to it by construction. What found it was
reading the manual's block figures while adding the 16-bit formats.

**What it would have cost.** `hw/ps2probe/gsprobe.c` reads the Z buffer back
through the Local→Host path, which addresses memory as PSMCT32. On a console
the depth was written with the xor and is read back without it, so the readback
is permuted in blocks of 8x8 pixels; this model would have returned it
unpermuted. The first console run would have produced a scrambled Z image, and
the obvious suspect would have been the one thing already flagged as unverified
— the depth bias — which is in a different part of the pipeline entirely.

The fix is one xor in each implementation, and it is now checked mechanically
rather than by assertion: `tools/gs/xcheck_swizzle.py` reads the xor out of
PCSX2's header, compares it with `gs_ref.BLK_Z`, checks every pixel of a page
against the composed table, and checks the property that makes it matter —
that no pixel addresses the same word as colour and as depth.

## The 16-bit formats: addressing — 2026-09-11

Step 2 of the order above, for PSMCT16, PSMCT16S, PSMZ16 and PSMZ16S. Only the
addressing; the pixel path is not written yet.

A 16-bit page is 64 x 64 pixels, a block 16 x 8, a column 16 x 2, and two
pixels share a 32-bit word. Three things change and one does not, and the one
that does not is the part worth stating: **the word within a block is the same
interleave as PSMCT32's**, `column32(y & 7, x & 7)`. A column holds sixteen
words either way, and the extra eight pixels of width go into the *upper half*
of those same words rather than into more of them. So the only genuinely new
arithmetic is which block — two tables, since PSMCT16 and PSMCT16S differ in
block order — and which half, which is address bit 3 of x.

`addr16p()` returns the word and the half separately rather than a half-word
address, because every caller needs both and folding them would push the split
onto each call site.

*Checked exhaustively.* `tools/gs/xcheck_swizzle.py` now compares both block
tables and the column table against PCSX2 entry by entry, then walks all 4096
pixels of a page in all four 16-bit formats against the composed tables, and
confirms no two pixels collide. PCSX2's `columnTable16` tabulates *pixel*
indices within a block rather than word indices, which is the one place these
can be misread; the tool compares `word * 2 + half` against it.

## The 16-bit pixel path — 2026-09-11

PSMCT16 and PSMCT16S can now be drawn to, in the reference and the RTL
together. Three conversions carry the whole of it, and all three are the
opposite of the obvious guess, which is why each is taken from the manual
rather than assumed:

* **Writing truncates.** The masking diagram in 3.9.5 lines the frame buffer's
  five bits up against bits 7:3 of the 8-bit channel, so the low three are
  dropped. Dither is what is meant to make that acceptable, and dither is a
  later block.
* **Reading shifts back up with zeros**, not by replicating the top bits: the
  manual draws the expansion as `E D C B A 0 0 0`. White in a 16-bit buffer
  therefore reads back as `0xF8F8F8`, not `0xFFFFFF`. The replicating form is
  what a graphics programmer reaches for and is a different function.
* **Alpha read from a 16-bit buffer is 0x80 or 0x00**, never 0xFF.

FBMSK needs no conversion function of its own. Its bit positions are those of
the pixel *before* format conversion, and the bits that survive the conversion
are exactly the ones `pack16` keeps — so the mask converts with the same
function the colour does.

The no-read fast path survives at 16 bits: when FBMSK is zero and blending is
off, the byte enables protect the other pixel sharing the word, so a 16-bit
pixel does not force a read-modify-write.

### What the random streams could not see

`gen_gif.py` now picks a 16-bit frame buffer for about four draws in ten, and
that was **not** enough. Mutating the RTL and re-running three random seeds:

| mutation | caught |
|---|---|
| the S block order used for both formats | 3 of 3 |
| the half taken from x(4) instead of x(3) | 2 of 3 |
| `pack16` keeping the wrong five bits | 2 of 3 |
| `expand16` replicating instead of zero-filling | **0 of 3** |

The last one is not bad luck. Expansion is reached only when the destination is
*read*, and the two candidate expansions of a five-bit value differ only in the
low three bits — exactly the bits `pack16` discards again on the way back. A
destination that is read, blended by a selector that copies it, and written back
is bit-identical under either rule. The difference becomes visible only when
arithmetic carries it up into bit 3.

`sim/gs/gen_fb16.py` arranges that deliberately: a fill pass writes a known
destination, then a blend pass draws over it with `Cv = (Cs - Cd) * FIX >> 7`
at FIX = 0x80, subtracting the destination at full weight so that the source's
low three bits decide which side of a multiple of eight the result lands on. A
second blend pass uses `C = Ad`, which is what makes the *alpha* rule
observable, since a coefficient of 0x80 and one of 0xFF are nothing alike.

**Two things about writing that program are worth keeping**, because both made
it pass while proving nothing:

* Its first version filled each page with a **uniform** colour. A block order is
  a permutation of blocks within a page, and permuting blocks that all hold the
  same value changes nothing — so the directed program scored 0 of 1 against a
  block-order mutation that the random streams had caught 3 times in 3. A
  directed test can be *weaker* than a random one, and this is how.
* Its second version varied the pattern with a period of two tiles, and a block
  is exactly two tiles wide, so every block again held identical content. The
  period has to share no factor with the block, which is why the alpha pattern
  runs on three.

With those fixed, all nine mutations tried are caught by `gen_fb16.py` alone:
both block orders, the half selection, the column order, the page stride, both
directions of the colour conversion, the alpha rule, and the mask conversion.

## 16-bit depth, and a depth that does not fit — 2026-09-11

PSMZ16 and PSMZ16S join the depth path, on the 16-bit addressing already built
and cross-checked. Two things came with them.

### A depth too wide for its buffer clamps; it does not wrap

The committed depth code masked the incoming depth with the format's width.
That is the same thing as clamping for every value that fits and the **opposite**
for every value that does not: a Z of `0x01000000` against PSMZ24 compares as 0
after a mask and as `0xFFFFFF` after a clamp, so a `GREATER` test flips from
failing everything to passing everything.

It could not be seen before. The generator's deepest vertex was 24 bits and the
only narrow format was PSMZ24, so masking and clamping agreed on every value
ever generated — and the reference and the RTL masked together, so the
differential agreed with itself. PSMZ16 makes it central rather than latent:
nearly every depth a vertex carries exceeds 16 bits.

> **NOTE (unverified):** clamping is taken from PCSX2, which does it twice over
> — `min_u32(z_max)` on the vertex and a scanline clamp gated on whether the
> primitive's maximum depth exceeds the format — which is the shape of something
> modelled from hardware rather than a convenience. The GS User's Manual gives
> the three Z formats (2.3.2) and never says what happens to a value too wide
> for one.
> *Verify by:* `hw/ps2probe` asks the console directly. `ZCPROBE` writes
> `0x01234567` into a PSMZ24 buffer through a **sprite** — a sprite because its
> depth is an integer from the second vertex and never interpolates, so the
> depth bias cannot contaminate the answer — and reads it back. Clamping gives
> `0xFFFFFF`, truncating gives `0x234567`; the two are far enough apart to need
> no analysis. `compare.py` prints the verdict and names the one line in each
> implementation to change if it says TRUNCATE.

### Frame and Z formats may not be paired freely

The manual (2.5.4) puts both into two groups and allows a combination only
within one: **PSMCT16 goes with PSMZ16**, and PSMCT32, PSMCT24, PSMCT16S,
PSMZ32, PSMZ24 and PSMZ16S go together. The generator paired them at random
until now, so some fraction of every run was asking two models to agree about a
configuration the hardware does not define. It now picks the Z format from the
frame format's group.

### The testbench was silently dropping packets

`tb_gs.sv` held 4096 quadwords and `$readmemh` fills only as far as the array
goes, reporting nothing about the rest. A directed program of 4576 quadwords was
therefore truncated: the reference read all of it, the RTL saw a prefix, and the
diff blamed the two models for disagreeing about a register. The array is 16384
now, and — because any size can be exceeded — a run that fills it says so and
stops, since a truncated run must not be able to look like a failing one.

That is the fourth instrument on this project to fail by staying quiet, after
the drain that ended mid-setup, the filtered unknown-register count, and the
`ilat`/`dlat` of zero.

### What the directed stream had to be taught, twice more

`gen_fb16.py` now lays a depth pattern and tests against it. Getting it to prove
anything needed the same lesson the colour half taught, applied twice more:

* A **flat** Z buffer is invariant under any permutation of its blocks, so a
  block-order mutation is invisible against one. The first version ended with a
  full-page pass whose depth beat the whole buffer, which writes the same value
  everywhere — and with that in place the reference gave a bit-identical result
  with the depth block xor switched off entirely.
* The fix is not a different pattern but a different **structure**: the pattern
  is laid down once, disturbed once in a way that keeps it varied, and after
  that every pass leaves `ZMSK` set and only *reads* it. The colour buffer
  records which pixels passed, which is what the comparison needs anyway.

With that, all five depth mutations tried are caught — the clamp reverted to a
mask, the depth block xor switched off, PSMZ16S given the plain block order, the
half taken from the wrong address bit, and the half ignored on read.

## The GS wired to its own memory — 2026-09-11

`gs_gif` and `gs_lmem` had never been connected. Their ports were shaped for
each other from the start — `gs_gif`'s own comment says "shaped for `gs_lmem`" —
and each was verified against a testbench that modelled the other: `tb_gs.sv`
models a memory with two clocks of latency because that is what the UltraRAM
output registers give, and `sim/mem/tb_mem.sv` exercises the memory with no
rasteriser in sight. Two halves proven separately and never joined.

`rtl/gs/gs_top.vhd` joins them. The only thing in it that is not wiring is a
read arbiter: `gs_lmem` has one read port and two customers — the rasteriser,
which reads for the read-modify-write that FBMSK, blending and the depth test
all need, and the host, which reads a finished buffer back. The rasteriser wins
whenever it asks, because it is inside a half-drawn pixel and the host is not.
Returning the data to the right customer is the part that needs care: a read
takes two clocks and `rd_valid` does not say whose read it was, so ownership
travels beside the request in a two-stage shift register. Handing the rasteriser
the host's data mid-blend would look like a blender bug, not an arbiter bug.

### One difference between the model and the memory, and it does not bite

`tb_gs.sv` forwards a write to a read at the same address in the same cycle, and
says so — it calls it a modelling artifact. **`gs_lmem` does not forward.** Its
write is a VHDL signal assignment, so it lands at the end of the process and a
read in that cycle sees the old contents. Eight 32-bit pixels share a 256-bit
word, so consecutive pixels of a scanline *are* the same address, and whether
the rasteriser ever reads a word in the cycle it writes one is not obvious from
either side.

Running the identical streams through both answers it: **11 of 11 pass against
the real memory**, including the directed 16-bit program, which is the
blending-heaviest thing in the suite and therefore the most likely to care. So
the rasteriser never does read a word in the cycle it writes it — which is now a
measured fact rather than an assumption, and the reason the model's forwarding
was harmless.

`sim/gs/run_top_diff.sh` runs any stream the ordinary differential takes, against
`gs_top` instead of against the model, and reads the whole of local memory back
through the host port to produce the same checksum. That read path is also the
only thing exercising the arbiter.

### What it costs, and what it closes at — 2026-09-11

The first fit of the whole Graphics Synthesizer, out of context on
`xcu55n-fsvh2892-2LV-e`:

| | |
|---|---|
| UltraRAM | **128 of 640 — 20.00 %** |
| CLB LUTs | 19149 (2.20 %) |
| CLB registers | 14870 (0.85 %) |
| DSPs | 96 (1.61 %) |
| Block RAM | 0 |
| **Fmax** | **110.8 MHz** |

The UltraRAM figure is the one that was predicted: `gs_lmem.vhd` was written to
settle the physical question and said 128 URAM, 20 % of the C1100, before
anything else existed. It is exactly that, which is a small piece of evidence
that the memory is being inferred as UltraRAM and not quietly built out of
something else.

**The clock is the problem.** The real GS runs at 147.456 MHz and this closes at
110.8, so the design is a quarter short before the texture unit — the largest
remaining block — has been written at all.

The critical path says where to look: `chans[0].u/lane_reg` to
`gif/wr_data_reg`, **37 logic levels with fifteen carry chains**, 44 % logic and
56 % routing. That is the whole per-pixel colour path standing as one
combinational chain — the Gouraud interpolator's lane value, into the blender,
into the format pack, into the word being written. Nothing between the
interpolator and memory is registered.

So the GS has the same shape of problem the EE core had, and the pixel path
wants a pipeline stage between the interpolator and the blender.

### The cut is free, and worth less than it looks — 2026-09-11

It is free because the interpolator is already standing still there. `px_step`
is not asserted on the edge that moves `S_DRAW` to `S_DRAWRD`, so `c_adv` is low
and the DDA holds its value across both cycles: the blender was reading a value
that had not changed since the cycle before, and now reads it from a register.
The same applies to the depth the comparison uses. Twenty-one of twenty-one
runs pass unchanged, and eleven of eleven against the real memory.

**110.8 → 117.3 MHz.** That is 6.5 MHz, not the sixty the path arithmetic
suggested, and the reason is visible in where the path went rather than in what
it became. The old path is gone entirely; the new one is
`gif/t_x_reg → gif/chans[3].u/dv_n_reg`, twenty-two levels with eight carry
chains **and six DSP stages** — the triangle setup, where the interpolation
gradients are divided out before a single pixel is drawn.

The lesson is one about method rather than about the GS. Cutting the longest
path is only worth what the *second* longest path allows, and nothing in the
first measurement said how close behind it was. Two long paths in different
parts of the design, one per-pixel and one per-triangle, and fixing the first
buys the difference between them and no more.

### The setup divider, and what the pattern turned out to be — 2026-09-11

The seed numerator — `1024 * (c0*det + nx*(16x - X0) + ny*(16y - Y0))` — was one
expression in one state: a subtraction, a multiply, a second multiply whose
adder synthesis cascaded into the first through the DSP's `PCIN`, then carry
chains into the divider's numerator register.

Splitting the three products from the sum puts them side by side instead of in a
chain, because once they land in registers there is nothing downstream for the
tool to cascade into. It costs **one cycle per seed** — one per scanline per
channel, against a division that takes sixty-four — so it is close to free.

**117.3 → 121.5 MHz**, and the path moved again: `gif/t_regs_reg` to
`gif/dr_empty_reg`, thirty levels with ten carry chains, which is the primitive
setup in `gs_gif` — reading the register file and working out whether the
primitive is empty after scissoring.

Three cuts now, and the shape of the problem is clear:

| | Fmax |
|---|---|
| as first fitted | 110.8 |
| pixel path cut | 117.3 |
| seed numerator split | 121.5 |

**This is not a design with one long path; it is a design with a population of
them**, each two to three nanoseconds over budget, in the per-primitive and
per-scanline setup rather than in the pixel loop. Each cut buys four to six MHz
and uncovers the next. That is worth stating plainly because it changes what the
remaining work looks like: reaching the console's 147.456 MHz is not one more
fix, it is a sustained pass over the setup path, and the honest estimate is
several more cuts.

### The sprite setup, and the end of the setup work — 2026-09-11

The last of the setup paths, and the largest gain of the three. Everything from
the arriving quadword to `dr_empty` happened on one edge: the register file
read, the vertex minus `XYOFFSET`, the divide by sixteen, the swap that orders
the corners, four clamps against the scissor, and the test for whether anything
survived. Thirty logic levels with ten carry chains.

It is three cycles now — the coordinates, then the clamps, then the test. A
sprite covers hundreds of pixels, so two extra cycles per primitive is not a cost
worth measuring, which is the general reason the *setup* paths are the right ones
to cut and the pixel loop is not.

**121.5 → 129.1 MHz.** One thing had to be fixed alongside it and is worth
naming: `gif_ready` is a function of the state, and the two new states were not
in its list, so the GIF went on accepting quadwords while a sprite was being set
up. Every stream failed immediately, which is the good kind of failure — a
handshake that stays ready during a new state is otherwise the sort of thing
that shows up much later as one dropped primitive.

**The setup work is done**, and the measurement says so rather than a judgement
call: the critical path has left the setup entirely and returned to the write
path — `dr_addr` to `wr_data`, twenty-three levels — which is the per-pixel side
again.

| | Fmax |
|---|---|
| as first fitted | 110.8 |
| pixel path cut | 117.3 |
| seed numerator split | 121.5 |
| **sprite setup split** | **129.1** |

Sixteen per cent over four cuts, and the remaining gap to the console's 147.456
MHz is about fourteen per cent more.

**None of this blocks a board target.** 129.1 MHz is a perfectly good clock to
bring the Graphics Synthesizer up on a card at — the console's clock is what
full-speed emulation needs, not what proving the hardware works needs.

## On a card — 2026-09-11

`boards/c1100_gs.py` is the first board target for either of the two large
blocks. It builds, and it **meets timing**: WNS +0.008 ns, zero failing
endpoints of 91888, at 125 MHz on the C1100.

| | |
|---|---|
| CLB LUTs | 26782 (3.07 %) |
| CLB registers | 28562 (1.64 %) |
| **UltraRAM** | **128 (20.00 %)** |
| Block RAM | 27 tiles (PCIe and the CSR fabric) |
| DSPs | 96 (1.61 %) |

The whole image — the GS, a PCIe endpoint, the HBM controller that exists only
to drive `hbm_cattrip`, and the CSR fabric — is three per cent of the part. The
UltraRAM figure is the GS's 4 MB and nothing else's.

**The GS runs in the sys clock domain at 125 MHz.** It closes at 129.1 MHz out
of context, so it needs no clock of its own, and a design that does not cross a
clock boundary cannot fail at one — which is worth having on a first bring-up.
A real GS runs at 147.456 MHz and this does not; that is a performance question
and nothing here is timed against a video output yet.

The shape is the IOP's: a stream in and a window out. GIF packets arrive a
quadword at a time through four CSR words and a push, which is slow and is the
right trade, because it needs no DMA engine to be correct before the thing being
tested can be tested at all. Local memory reads back through a second window one
256-bit word at a time, which is what lets the host compute the very checksum
`gs_ref.py` prints — so the comparison on the card is the comparison in
simulation, against the same reference, with the same tooling.

`tools/gs/gsrun.py` is that comparison: it feeds a stream, then diffs the
register file, the pixel count and local memory against `sim/gs/gs_ref.py`.

### It runs — 2026-09-11

**The Graphics Synthesizer runs on the C1100 and agrees with the reference
model.** The first time either of the two large blocks has been on hardware.

Fourteen streams, every one of them compared against `sim/gs/gs_ref.py` on the
register file, the pixel count, and **the whole of local memory** — the same
FNV-1a checksum over all 4 MB that the simulation prints:

| | |
|---|---|
| first light, one 8 x 4 sprite | pass |
| `gen_fb16.py`, the directed 16-bit program | pass |
| twelve random `gen_gif.py` streams | pass |

That directed program is the interesting one: PSMCT16 and PSMCT16S, PSMZ16 and
PSMZ16S, both block orders, alpha blending, the depth test and the depth clamp,
all of it settled in simulation over the preceding days and none of it seen by
silicon until now. The whole-memory comparison takes four seconds, so there is
no reason to run the cheaper one.

Feeding is quicker than expected: about 80,000 quadwords a second through the
CSR window, so a 4096-quadword stream is well under a second and the readback
dominates.

**Both faults found on the way were in the host tool, not the card**, and both
are worth recording because simulation cannot show either.

* **Local memory survives `gs_reset`.** A reset clears the logic, not the
  UltraRAM, while `gs_ref.py` starts every run with 4 MB of zeros — so the
  second stream of a session disagreed everywhere the first had drawn, and the
  values gave it away: the previous test's colour, blended under the new one.
  `gsrun.py` now clears memory first, which needs no host write port and no
  rebuild: one sprite at page 0 with FBW = 16 covering 1024 x 1024 pixels of
  PSMCT32 is exactly 512 pages, the whole of local memory, in about ten
  milliseconds.
* **`busy` falls when a quadword is *accepted*, not when its primitive is
  *drawn*.** Waiting on it alone reported a 4 MB clear as finishing in no
  measurable time, then reset the GS in the middle of it and read the pixel
  count before the drawing had happened — which presented as the card drawing
  95 pixels where the model drew 120. Idle is `busy` clear *and* `ready` set.

`tools/gs/gen_firstlight.py` is that stream: an 8 x 4 opaque rectangle at the
origin in PSMCT32, no blending, no depth, no clipping, one colour. Thirty-two
pixels of `0x80406020`, and **both simulation harnesses agree on it** — the
ordinary differential and the one that runs against the real `gs_lmem`, which is
what the card has. So a disagreement on the card is the board target's fault and
not the rasteriser's, which is the only useful property for a first run.

It is also its own small argument for having a first-light stream at all: the
first version drew *nothing*, because the two vertices were sent as bare
quadwords rather than through A+D with XYZ2's address, and writing XYZ2 is what
kicks a primitive. That would have looked on the card exactly like a GIF that
never accepted a packet.

## What is not started

The rest of step 4 — lines and points, and texture — and step 5, PCRTC.
Local-to-host and local-to-local transfers; host-to-local is still PSMCT32 only.
Dither, which needs a 16-bit format to act on and now has one.
