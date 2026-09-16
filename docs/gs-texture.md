# The Graphics Synthesizer's texture unit — the study before the build

*Written 2026-09-12, alongside the fill-rate work rather than after it. The two
interact at exactly one point and it is better to know where before either is
built.*

## Why this is written now and not when the unit is

The texture unit lives **inside** the pixel pipeline, which is currently being
widened for throughput. A texture unit written one pixel wide today would be
rewritten when that pipeline changes shape. So the parts that can usefully be
done now are the parts that are *not* RTL: the coordinate rules, the addressing,
the CLUT, and the reference model — which is needed before any texture RTL can
be tested anyway.

And there is one interaction worth stating up front, because it constrains the
throughput design rather than the other way round:

> **The real GS has a separate texture port.** Frame and Z share a 1024-bit read
> and a 1024-bit write; texture has its own 512-bit path, each side with its own
> 8 KB page buffer. That is not an optimisation, it is why a textured pixel
> costs roughly twice an untextured one rather than four times: the texel fetch
> does not contend with the frame buffer. Any fill-rate architecture that
> assumes one memory port will have to be rebuilt when texture arrives.

`rtl/gs/gs_lmem.vhd` currently has one read port and one write port, and
`gs_top` arbitrates the read between the rasteriser and the host. A texture
unit makes that three customers on one port. Deciding whether to add a second
port is a throughput decision that has to be taken with texture in view.

## What the unit has to do

**Coordinates, two ways.** `PRIM.FST` chooses. `UV` gives texel coordinates
directly in 12.4 fixed point and is what 2D work uses. `STQ` gives
perspective-correct coordinates as floats, divided by Q per pixel — which means
a divider in the pixel path, and is what 3D work uses. These are genuinely
different pipelines and the second is much the harder.

**Nine source formats.** `PSMCT32`, `PSMCT24`, `PSMCT16`, `PSMCT16S` are the
formats the frame buffer already uses and their addressing is already written
and verified. The other five are indexed and are new: `PSMT8`, `PSMT4`,
`PSMT8H`, `PSMT4HL`, `PSMT4HH`. The last three are the interesting ones — they
store their indices *inside the unused bits of a 32-bit buffer*, in the high
byte or in either nibble of it, so a texture and a colour buffer can occupy the
same memory.

**A CLUT for those five**, itself living in local memory, in one of two layouts
(`CSM1`, `CSM2`) with a start offset (`CSA`) and its own load-control rules
(`CLD`) that decide when it is re-read. The CLUT is a cache with explicit
invalidation, and getting *when* it reloads wrong will show as the wrong
palette several primitives later.

**Filtering.** Nearest and bilinear, with `MMAG`/`MMIN` choosing per direction,
and the mipmap forms on top: `MXL` levels, `LCM` and `K`/`L` deciding the level
of detail, `MTBA` auto-generating the level pointers. Bilinear needs four texels
and so four fetches, which is the other half of why texture wants its own port.

**Wrapping.** `REPEAT`, `CLAMP`, `REGION_CLAMP`, `REGION_REPEAT` per axis, the
last two using `MINU`/`MAXU`/`MINV`/`MAXV` — and `REGION_REPEAT` uses them as a
mask and an or rather than as bounds, which is a different operation wearing the
same register fields.

**The texture function**, `TEX0.TFX`, combining texel and fragment colour:
`MODULATE`, `DECAL`, `HIGHLIGHT`, `HIGHLIGHT2`, with `TCC` deciding whether the
texel's alpha is used or the fragment's. Modulation is a multiply by the
fragment colour shifted right by seven — the same 0x80-is-one fixed point the
blender uses.

## What is checkable here, and what is not

This unit is in better shape than the FPU: nearly all of it is *structure*.

**Checkable against the existing machinery.** The addressing for all nine
formats, the CLUT layouts, the wrap modes, the texture function arithmetic, and
nearest-neighbour sampling. All of it is a function from register state to a
number, all of it can go in `sim/gs/gs_ref.py` and be diffed against the RTL,
and all of it can be mutation-tested.

**Needs a console.** Two things, and they are the same two that every
interpolator in this project has needed:

* **Where a texel is sampled from.** The coordinate is truncated somewhere, and
  this project has already found that the *colour* interpolator truncates on an
  eight-pixel block boundary — a fact that no manual states and that took a
  purpose-built probe to establish. `docs/gs.md` records the open question
  directly: "the affine texture coordinate is truncated and may carry a block
  width of its own, but no capture has swept it." The same width sweep that
  settled colour would settle this.
* **Bilinear's rounding.** Four texels combined with two fractional weights, in
  fixed point, with a rounding rule nobody has written down.

Neither blocks starting. Both mean that nearest-neighbour texturing can be
finished and *known* right, while bilinear carries a tag until a console runs
the sweep — the same split the FPU study arrived at for the same reason.

## The order to build it in

1. **The addressing for `PSMT8` and `PSMT4`**, in the reference model, with the
   exhaustive cross-check `tools/gs/xcheck_swizzle.py` already does for the
   colour formats. This is the largest piece of unknown structure and it is
   pure table work — and the colour block table turned out to be a wire
   permutation rather than a table, so it is worth asking whether these are too.
2. **The three `H` formats**, which are the same indices read out of a 32-bit
   buffer's spare bits, so they need no new addressing at all once the base is
   right.
3. **The CLUT**, including when it reloads.
4. **`UV` coordinates, nearest sampling, and the texture function** — at which
   point 2D work draws correctly and can be tested against a picture.
5. **`STQ` and the per-pixel divide**, then mipmap and bilinear.

Steps 1 to 3 touch no RTL at all and can be done while the pixel pipeline is
being widened. Step 4 is where the two tracks meet, and by then the pipeline's
shape should be settled.

## Step 2 run: the H formats, and the addressing assembled — 2026-09-14

`PSMT8H`, `PSMT4HL` and `PSMT4HH` needed no addressing of their own, exactly as
the plan expected. They are palette indices stored in the **spare byte of a
PSMCT32 word** — the byte a 24-bit colour does not use — so the word is found by
`addr32` and only the extraction differs: bits 31:24 for `PSMT8H`, 27:24 for
`PSMT4HL`, 31:28 for `PSMT4HH`. A game can therefore keep a 24-bit image and an
8-bit index image in one buffer at no cost in memory, or two 4-bit index images,
which is what having `HL` and `HH` as separate formats is *for*.

The consequence runs the other way and the rasteriser already honours it: a
write to a `PSMCT24` frame buffer must leave the top byte alone, because
something else may be living in it.

### The part that was not free

Step 1 proved the column and block *tables* against PCSX2's, exhaustively. It
said nothing about how those pieces assemble into an address, and that is where
the remaining mistakes were. Two things differ from the colour formats:

- **The page is a different shape.** A `PSMCT32` page is 64 × 32 texels; a
  `PSMT8` page is 128 × 64 and a `PSMT4` page is 128 × 128. Same 8 KB, more
  texels in it.
- **TBW counts 64-texel units whatever the format**, so for the indexed formats
  it does *not* count pages. A `PSMT8` page is 128 texels wide, so the number of
  pages across a row is TBW / 2.

Forget that halving and every texture wider than one page is sheared — while a
texture exactly one page wide, which is what a first test naturally uses, comes
out perfect.

### Checking it without a second implementation

`sim/gs/test_texaddr.py` leans on **bijectivity**. A page holds exactly as many
texels as it has storage units, so the map from (x, y) to address must hit every
unit exactly once. Any transposed shift, any wrong mask, any page stride off by
a factor of two collapses two texels onto one address and leaves another
unreached — and counting finds it without comparing against anything.

Bijectivity cannot see one class of fault: a map can be a perfect permutation of
a page and still put the *pages* in the wrong order. So the multi-page cases
assert separately that page *n* begins exactly *n* pages along.

Seven mutations, all caught — including the TBW halving, the `PSMT4` block
transposition, and `column4` being eight bits wide instead of nine.

Next is step 3, the CLUT, and it is the last one before a texture can be drawn.

## Step 5 complete: bilinear, the divide, and the level of detail — 2026-09-14

### Bilinear, and the half-texel

Four texels and three lerps, with one detail that decides whether the picture
lines up: the GS samples at **(u − 0.5, v − 0.5)**.

UV counts texel *edges*, so texel *n* occupies [n, n+1) and its centre is at
n + 0.5. Subtracting the half texel before splitting into integer and fractional
parts is what makes `u = n + 0.5` return texel *n* unmixed and `u = n` an even
blend of *n−1* and *n*. Leave it out and every filtered texture is displaced
half a texel, which reads as a sampling offset in the rasteriser rather than as
a filter bug — and the nearest path, which has no such shift, then disagrees
with the bilinear path by half a texel as well.

The weights come from the four fractional bits of the 12.4 coordinate, so there
are sixteen positions between texels and no more. That is not an approximation
of something finer: 12.4 is the coordinate format, and a model that lerped with
more precision than sixteenths would be smoother than the console.

### The perspective divide

`PRIM.FST` chooses. STQ is interpolated linearly in screen space *along with Q*
and the texture coordinate is recovered per pixel by dividing — which is why the
GS has a divider in the pixel path at all.

The arithmetic is `sim/ee/ps2_float.py`, imported rather than reimplemented. The
GS's float unit is different silicon from the EE's COP1 but it is the same
number system, and two blocks that must agree should share one definition of
what a number is. **Q = 0 does not produce an infinity**, because the format has
no encoding for one: it saturates. A model built on host doubles would raise or
produce `inf` there and then disagree with hardware about every pixel of a
degenerate polygon — which games do emit, at the horizon and at the moment a
vertex crosses the eye plane.

The result is then saturated to the coordinate's width, because a coordinate has
one. A Q near zero makes S/Q enormous, and multiplying the saturated float by
sixteen in unbounded integers gives a forty-digit number that no register holds.
**What hardware does past that point is unverified** and is marked as such in the
source: saturating matches what the format does one step earlier, wrapping is the
other possibility, and only a console can settle it.

### Mipmap: LOD comes from Q, not from a derivative

A modern GPU picks a level from the screen-space derivative of the texture
coordinate, which needs neighbouring pixels. **The GS does not have them** — it
rasterises one pixel at a time and has only that pixel's Q. So

    LOD = (log2(1 / Q) << L) + K

and `log2(1/Q)` is **the negated exponent of Q and nothing else**. The mantissa
is discarded entirely, so the result is an integer before K and L touch it, and
every Q inside one power-of-two band gives the same level.

That is a real difference and it is visible: the level changes in steps as a
surface recedes rather than continuously, which is what `LCM = 1` and
per-primitive K exist to work around — a game wanting a smooth transition
computes K itself, on the VU, per primitive. The test asserts the step rather
than a smooth curve, because the step is the behaviour.

**MMAG and MMIN are not symmetric.** MMAG is one bit, nearest or linear, because
magnification has nothing above the base level to blend with. MMIN is three,
because minification can also blend *between* levels. The naming follows the
OpenGL convention and reads backwards until you see it: the first word is the
filter *within* a level and the second is the filter *between* levels, so
`NEAREST_MIPMAP_LINEAR` takes one texel from each of two levels and blends them,
while `LINEAR_MIPMAP_NEAREST` takes four texels from one.

Nine mutations of the texture function, the wrap modes and the CLUT were all
caught, including the two constants that are wrong by a factor of two in the
plausible direction: `MODULATE` shifting by 8 instead of 7, and the CLUT base
scaled as pages rather than blocks.

**Steps 1 to 5 are now done in the reference model.** What remains for the
texture unit is RTL, and the pixel pipeline it has to join.
