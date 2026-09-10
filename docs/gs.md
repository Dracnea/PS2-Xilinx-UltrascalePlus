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

## The triangle rasteriser: attempted, reverted — 2026-09-10

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
