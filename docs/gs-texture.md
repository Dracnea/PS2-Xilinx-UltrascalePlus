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

## The RTL starts: addressing, 2026-09-17

**Steps 1 to 5 were the reference model. This is the first of the unit to become
hardware**, and it is the addressing rather than the sampler, for the reason
this page gave when it was written: the sampler lives inside a pixel pipeline
that is still being widened, and one written a pixel wide today would be
rewritten. Addressing does not care. A texel is at the same address whether it
is fetched one at a time or four at a time.

`rtl/gs/gs_texaddr.vhd` takes a texel coordinate and the TEX0 and CLAMP state and
says where that texel's bits are. It does not fetch, look up a CLUT, filter, or
combine with a fragment colour — those are the sampler's, and they are what
waits for the pipeline.

### One interface decision

Nine formats store texels at four granularities — a nibble, a byte, a half word
and a word — and three hide an index in the spare bits of somebody else's word.
Reported in their own units, every caller would carry the same four-way case. So
all nine are normalised to the same three numbers: **which 256-bit local-memory
word, which bit in it, and how wide the texel is.** That is the form a fetch
from `gs_lmem` actually needs, and it makes the H formats stop being special:
`PSMT8H` is a `PSMCT32` address with 24 added to the bit offset and a width of
8. The awkward part of those formats becomes an adder that was there anyway.

The colour formats call `gs_addr_pkg` unchanged rather than reimplementing it.
A texture unit reading back a frame buffer has to agree with the rasteriser that
wrote it, and calling the same function is the only way to guarantee that rather
than hope for it.

### What the test is, and what makes it a test

`sim/gs/run_texaddr_diff.sh` drives the RTL with cases from `gs_ref.py` and
compares. **29,140 cases, identical on five seeds.** The cases are structured
before they are random:

* every format at the origin and at fixed places in the first page — if a format
  is wrong at all it is usually wrong here, and a failure at (0,0) says
  something different from one at (17,9);
* **one page of `PSMT8` and of `PSMT4`, exhaustively.** These are the maps this
  unit adds; everything else it inherits. A page is small enough to sweep
  completely, and a wire permutation that is right on 400 random texels and
  wrong on one is exactly the fault a sweep catches and sampling does not;
* multi-page cases crossing a boundary in both axes, because that is where
  TBW's units bite;
* all sixteen combinations of the two wrap modes, with negative coordinates.

The conversion from the model's units into the RTL's three numbers is written in
`gen_texaddr.py` from what each model function documents itself as returning,
deliberately **not** from the RTL. Derived from the RTL it would agree by
construction and the diff would prove nothing.

Passing first time is a reason for suspicion rather than satisfaction, so
**eleven mutations were injected and all eleven were caught**, including the
five that look most like something a careful person would write:

| mutation | cases it broke |
|---|---|
| TBW halving dropped for the indexed formats | 276 |
| `block4`'s x and y not exchanged | 14,688 |
| `column4`'s xor term dropped | 8,403 |
| `PSMT4HH` reading the low nibble | 475 |
| `REGION_REPEAT` written as a clamp | 1,765 |
| the 16-bit half ignored | 455 |
| CLAMP ignoring a negative coordinate | 957 |
| `column8` with x0 and x3 transposed | 4,325 |
| `PSMCT16S` treated as `PSMCT16` | 316 |
| `PSMT8` block row off by one bit | 6,389 |
| `PSMT4` page stride using y>>6 | 8,415 |

The TBW one is worth its own line: it breaks only 276 of 29,140 cases, because
it is *correct* for every texture one page wide or narrower. A test that did not
deliberately cross a page boundary would have missed it, and the picture it
produces is a shear that looks like a rasteriser fault rather than an addressing
one.

### The cost, measured

Out-of-context synthesis for `xcu55n`: **349 LUTs, no flip-flops, no DSP, no
block RAM.** The column maps really are wire permutations and one XOR3 gate
each, as the derivation claimed — most of the 349 is the page arithmetic's
multiply and the wrap's comparators, not the swizzle.

Measured rather than asserted, and that phrasing is deliberate: `gs_pxcap`
carried a comment claiming four block RAMs while costing 30,725 LUTs and 98,428
flip-flops, and nothing caught it until the whole design lost its timing. Forty
seconds of out-of-context synthesis is the cheapest check in this repository.

### Unregistered, on purpose

`gs_texaddr` is combinational. Where the pipeline registers go is the sampler's
decision and putting them here would be guessing at a shape this page says is
still open. A register stage added around a correct function is a much smaller
change than one removed from inside it.

**Next is the fetch and the CLUT** — the first piece that needs the read port,
and therefore the first that has to face the question this page opened with: the
real GS gives texture its own 512-bit path so a texel fetch does not contend
with the frame buffer, and `gs_lmem` has one read port with two customers on it
already.

## The CLUT in hardware — 2026-09-17

`rtl/gs/gs_clut.vhd` is the second piece of the texture unit to become RTL,
chosen for the same reason the addressing was first: it is almost entirely
structure, it is exhaustively checkable against `gs_ref.py`, and it does not
depend on the shape of the pixel pipeline the sampler is still waiting for.

It is two things that are easy to think of as one and must not be: **a buffer**
of 256 entries the sampler reads, and **a cache with explicit invalidation**
whose CLD rules decide when that buffer is refilled. Getting the first wrong
gives wrong colours, which anyone notices. Getting the second wrong gives *the
previous primitive's* colours several primitives later, which is the failure
this block exists to model rather than avoid.

`CSM1` is written as a concatenation rather than a sum, because the four terms
of `clut_csm1_32` — `128*hi`, `64*k0`, `16*(k >> 1)`, and the column — occupy
disjoint bits. A sum of disjoint terms is a wire permutation, the same as every
other swizzle here. `CSM2` calls `pix_addr_page`: it is a one-pixel-high strip
out of an ordinary PSMCT32 buffer with no swizzle to undo, so it is addressed
exactly as any other PSMCT32 read, and sharing the function is what guarantees
that rather than hoping for it.

**16-bit CLUTs are refused, not guessed.** `CPSM` can name PSMCT16 or PSMCT16S
and that layout is still not derived, so the block raises `unsupported` and
leaves the buffer holding what it held. A block that says "I do not know" is
worth more than one that is quietly wrong for a whole class of textures.

### The test, and the two holes mutation testing found in it

`sim/gs/run_clut_diff.sh`: **78 cases identical on six seeds**, comparing the
whole 256-entry buffer *and the load counter* after every TEX0 write. The
counter is not decoration — half of CLD's job is deciding not to reload, and a
buffer correctly left alone looks exactly like one reloaded with the same bytes.

The cases are a sequence and not a set, because CLD makes this a cache: what a
write does depends on every write before it.

Fourteen mutations were injected. Twelve were caught immediately; **two were
missed, and both were faults in the test rather than in the RTL** — which is
the whole reason for doing it:

* **"never set" treated as a match against zero.** `CLD_IF_CBP0` compares
  against a remembered pointer, and "no pointer has ever been remembered" is a
  distinct state from "the remembered pointer is 0". They are only
  distinguishable when the incoming CBP is *itself* zero: with any other value
  an implementation that initialises its stored pointer to zero still reloads,
  for the wrong reason, and looks correct. No case used CBP 0 against a virgin
  register. Two now do, and they come first.

* **CBW of 0 not clamped to 1.** No case used a zero width. Adding one did not
  help either, which is the more interesting half: CBW multiplies `COV >> 5`, so
  with the strip on the first page row the term is zero whatever CBW is, and 0
  and 1 address identically for the wrong reason. The cases now carry
  `COV = 63` and `COV = 40`. **A case that exercises a parameter is not the same
  as a case where the parameter can change the answer.**

Both holes were invisible to a passing test and to a reading of the code. The
mutation is what made them visible.

### The cost, measured

Out of context for `xcu55n`: **170 LUTs, 106 flip-flops, and 1 RAMB18** — the
1 KB palette inferred into block RAM, which is the specific thing worth checking
rather than asserting after `gs_pxcap` claimed four block RAMs in a comment
while costing 30,725 LUTs.

### The cost that is not in that table

A load reads **one entry per local-memory access**, so a 256-entry palette is
256 reads on a port the rasteriser and the display already share. That is the
honest first version. Consecutive CSM1 entries do often land in the same 256-bit
line and a later version can coalesce them — but coalescing a swizzle is exactly
the kind of optimisation that is wrong in a way no colour test notices, and CLD
is what keeps the cost from mattering meanwhile.

**Next is the fetch itself**, which is where the read port stops being
shareable by politeness and becomes the architectural question this page opened
with: the real GS gives texture its own 512-bit path precisely so a texel fetch
does not contend with the frame buffer.

## The fetch: step 4 complete — 2026-09-17

`rtl/gs/gs_texsample.vhd` is the piece that makes the other two useful.
`gs_texaddr` says where a texel is and `gs_clut` holds the palette; this asks
local memory for the bits, turns them into a colour, and combines that colour
with the fragment's. **Step 4 of the plan at the top of this page is done**, so
a 2D textured primitive can now be drawn.

Nearest only. Bilinear needs four of these and a weighted sum, and the model has
it — but four fetches is a decision about the read port, and building the filter
before that is settled would be building it twice.

### Three things that would each be invisible for a while

* **Nearest truncates, it does not round.** The fractional bits of the 12.4
  coordinate are discarded. That is half a texel on every hard edge, and it is
  also why nearest and bilinear disagree by half a texel unless bilinear applies
  its own (u − 0.5) shift.
* **The modulate multiply shifts by seven, not eight.** 1.0 is 0x80 throughout
  the GS's fixed point. Shifting by eight is the obvious guess and darkens every
  textured surface by exactly a factor of two, which reads as a lighting bug
  rather than an arithmetic one. The mutation that does it breaks **355 of 498**
  cases here.
* **PSMCT24 gets an alpha of zero, not a plausible 0x80.** The top byte is not
  part of the pixel and TEXA would normally supply a value; that register is not
  modelled, so this returns zero rather than a constant that would look like a
  blending bug several stages later.

### The test

`sim/gs/run_texsample_diff.sh`: **498 samples identical on four seeds**, against
`sample_uv` followed by `texture_function`. `gs_clut` and `gs_texsample` are
instantiated **together** rather than the palette being poked in directly —
the path from a UV coordinate to a colour is what is under test, and a test that
wrote the CLUT's contents would skip the one interface between the two blocks
and pass whether or not it was wired.

Eleven mutations, all caught, including every one above and the three that a
careful person could plausibly write: DECAL keeping the fragment colour, TCC
ignored, and HIGHLIGHT2 taking HIGHLIGHT's alpha rule.

The fragments in the cases are deliberately **not** 0x80808080. That value is
1.0, and with it DECAL and MODULATE produce the same answer — a test that used
it would exercise both and distinguish neither.

### The cost, measured, and where it went

Out of context for `xcu55n`: **1327 LUTs, 202 flip-flops, no DSP and no RAM.**

That is four times `gs_texaddr` and it is worth saying where it goes, because
the number is not in the arithmetic. The texture function's four multiplies are
8 × 8 and the expansions are wiring; **the bulk is the 256-bit variable shift**
that extracts a texel which may begin at any of 64 bit positions in the line. A
per-format extraction — each format can only start at a few offsets — would
replace most of that barrel with a handful of muxes. It is left alone for now
because it is an optimisation of a block whose surrounding shape is still open,
and because the number is now measured rather than guessed.

### What this does not answer

`gs_lmem` has one read port. The rasteriser and the display already share it,
the CLUT's loader is a third customer, and this is a fourth — and unlike the
others it wants a texel **for every pixel drawn**. The real GS does not do this:
it gives texture its own 512-bit path with its own page buffer, which is why a
textured pixel there costs roughly twice an untextured one rather than four
times.

So this block takes a read port as an ordinary port and does not arbitrate.
Whether the answer is a second port, a wider one time-sliced, or a texture cache
is a throughput question that wants measuring, and an arbiter written in here
now would have to be taken out later. What is here is correct at one fetch at a
time, and what it costs is now a number the integrator can measure.

## The texel cache: the read port, answered — 2026-09-17

The previous section ended on an open question: `gs_lmem` has one read port and
four customers, and the fourth wants a texel for every pixel drawn. The answer
taken is a **texel cache**, `rtl/gs/gs_texcache.vhd`, and the reason is what the
project can afford. The real GS gives texture its own 512-bit path *and* its own
page buffer; a second port on 4 MB of UltraRAM is the faithful half and the one
that is out of reach, because UltraRAM is the scarce resource here — 224 of the
C1100's 640 are spent before the GS's local memory exists at all, and 70 % of an
FK33's 320 ([cards.md](cards.md)). The page buffer is the affordable half, and
it goes in LUTs, where there is room.

The block drops in between `gs_texsample` and the memory and presents exactly
`gs_lmem`'s shape on both sides, so nothing above it changed.

### The shape was measured, and the obvious one was wrong

The first version was direct-mapped with the low address bits as the index,
which is what anyone writes first. On a 64 × 48 raster walk of a PSMCT32
texture it hit **75 %** — and it hit exactly 75 % at 16 lines, at 32, at 64 and
at 128.

A number that does not move with capacity is not a capacity problem. The reuse
histogram said what it was: two distances, **1 and 61**.

61 is the tell. The GS's column order for PSMCT32 interleaves two pixel rows
inside one column, so a 256-bit word holds a **4 × 2 patch** — four texels of
row *v* and four of row *v+1*. A raster walk therefore touches every word twice,
once per row, about a row apart, and it is the second visit that has to hit. It
was missing because the words touched in between mapped on top of it: the
address functions put them at multiples of a block, so the *low* bits of their
addresses — the index — are far from uniform even though the addresses
themselves are well spread.

That a fully-associative cache of the same 32 lines reached the floor, while a
direct-mapped one needed **256**, is what named it as a conflict problem rather
than a capacity one.

Two changes fix it, and both were chosen by simulating the real address streams
— all four addressing formats × four TBWs × four texture bases × seven walk
shapes, **336 configurations** — against each stream's own compulsory-miss floor:

| configuration | above the floor, mean | worst | storage |
|---|---|---|---|
| 64 lines, direct-mapped, plain index | 5.36 % of accesses | 15.6 % | 2 KB |
| 64 lines, direct-mapped, folded index | 2.77 % | 12.5 % | 2 KB |
| 64 lines, 2-way, folded | 2.64 % | 12.5 % | 2 KB |
| **128 lines, 2-way, folded** | **0.53 %** | **7.5 %** | **4 KB** |
| 256 lines, 2-way, folded | 0.46 % | 10.0 % | 8 KB |

* **Fold the index**: `index = addr[S-1:0] xor addr[2S-1:S]`. The bits it drops
  are still in the tag, so a (tag, index) pair names a line exactly as before —
  `addr[S-1:0]` is recoverable from the two — and it costs S XOR gates.
* **Two ways.** Doubling again to 256 lines buys 0.07 %, so 128 lines is the
  knee and that is what the default is.

Replacement is **round-robin, not LRU**, and that is a measurement too: across
those 336 configurations the two are not merely close, they produce the
*identical* miss count everywhere. For two ways they differ only in whether a
hit reorders the pair, and these streams never make that matter. A victim
pointer is one bit per set; LRU is the same bit plus an update on every hit, for
nothing.

With that shape, both formats land exactly on their compulsory-miss floor —
384 misses for PSMCT32 and 96 for PSMT8 on the walk, which are precisely the
counts of distinct memory words each touches. **Zero conflict misses.**

| | before | after |
|---|---|---|
| PSMCT32, 64 × 48 walk | 75 % | **87 %** (8 texels per line: the ceiling is 87.5 %) |
| PSMT8, 64 × 48 walk | 87 % | **96 %** (32 texels per line: the ceiling is 96.9 %) |

### The test, and what makes it one

`sim/gs/run_texcache_diff.sh`, three phases, because they answer three different
questions and one phase would let two of them hide.

**A — the cache must be invisible.** The whole `gs_texsample` vector set runs
again with the cache spliced into the sampler's read path, and the colours are
diffed against the *same* `ref.txt` the uncached block is checked against:
**498 samples identical on four seeds**. A separate vector set for the cached
path could drift from the uncached one and hide the disagreement being looked
for. The arbiter's grant is withheld at random here, so the request has to be
*held* until the memory takes it.

**B — the hit rate that matters, and a second opinion on it.** Those 498 vectors
are random UV over the whole coordinate range with a random texture base each
time, which is the worst input a cache can be given; their hit rate is a floor,
not a measurement. Phase B walks a textured quad in raster order instead, and
runs the same walk through a **second `gs_texsample` wired straight to the
memory**, comparing pixel for pixel. The same block, the same inputs, one with
the cache and one without, and the answers have to match.

The miss *count* is asserted against the compulsory floor rather than a rate
being printed. That is what makes an index regression a failure: the plain
low-bit index this block started with still hits more often than it misses, so
any threshold looser than the floor would have let it through.

**C — coherence, directed.** Local memory is one address space. The framebuffer
the rasteriser writes and the texture this reads are the same 4 MB, and
rendering to a texture is an ordinary PS2 idiom — it is how reflections, shadow
maps and most full-screen effects are done. A cache that does not watch the
write port serves the texture as it was before the render, and the failure looks
like a one-frame-late reflection rather than like a cache bug.

Ten directed cases, and two of them exist for the plausible *wrong*
implementations rather than for the right one:

* **a snoop of a different tag in the same set must NOT invalidate.** A cache
  that invalidates on the index alone is perfectly coherent, passes every
  staleness test, and throws away lines it still holds.
* **a write to the line a miss is fetching must leave that line invalid.**
  `gs_lmem` returns the value the array held *before* the write, so the word in
  flight is already stale. It is still handed to the client — the uncached path
  would have returned the same word — but keeping it would let the stale line
  outlive the write that should have killed it.

There is also a case for a write landing in the *same cycle* as the lookup of
that line. The tag comparison and the invalidation happen on one clock edge, so
a hit taken from the old valid bit returns the word the write has just replaced.
The block forces a miss there, which means the cached path can return a **newer**
word than the uncached path would. That asymmetry is deliberate: the rasteriser
and the texture unit have no defined order between them, so no client can depend
on seeing the older word, while every client depends on not seeing a stale one.

### Mutation testing found two holes in the test again

`sim/gs/mutate_texcache.py` — **twelve mutations, twelve caught**, plus one
mutant recorded as *equivalent* with its reason, because "the test did not catch
it" and "there was nothing to catch" look identical in a results table.

Two of the twelve were not caught on the first run, and neither was an RTL
problem:

* **the modelled memory answered every read**, granted or not, so a cache that
  ignored `m_ready` was indistinguishable from one that honoured it. In `gs_top`
  the ungranted read simply never happens, and the testbench has to model that
  or the backpressure is untested.
* **every address in the coherence cases lived in the bottom of local memory**,
  where the top bit of the tag is zero — so a tag comparison that dropped that
  bit aliased two lines and nothing noticed.

That is the third and fourth time in this repository that mutation testing has
found a hole in a test rather than in the design.

### The cost, measured

Out of context for `xcu55n-2LV`, with the GS's own 147.456 MHz constrained:

| | |
|---|---|
| CLB LUTs | **1570** (850 logic, 720 distributed RAM) |
| CLB registers | 600 |
| Block RAM | **0** |
| UltraRAM | **0** |
| WNS at 147.456 MHz | **+4.159 ns**, so about 380 MHz |

The zeroes are the point. The block exists to protect UltraRAM and it spends
none of it; the 4 KB of lines are LUT memory, which this design is nowhere near
running out of.

### What this does not answer

`gs_top` does not instantiate the texture unit yet, so the cache is verified
against a modelled memory and a modelled arbiter rather than against `gs_lmem`
behind `gs_top`'s real one. Wiring it in means wiring the whole texture path in,
which is the rasteriser driving UV — the next step, not this one. Two things
fall out of it when it happens:

* the snoop port wants the rasteriser's write port, which `gs_top` already has
  in one place;
* `flush` wants TEXFLUSH, and until the GIF decodes that register a CLUT reload
  or a TEX0 base change has to pulse it from wherever the change is seen.

**Bilinear is now unblocked.** It is four fetches per pixel, which is what made
it wait on this decision; with the cache the three neighbours of a texel are
overwhelmingly in lines already held, so the cost is four lookups rather than
four memory reads. Step 5's reference model has been complete since 2026-09-14.

## Bilinear in hardware — 2026-09-17

Step 5's other half. The reference model has had bilinear since 2026-09-14; what
it waited on was the read port, because four fetches per pixel is a throughput
decision and building the filter before that was settled would have been
building it twice. `gs_texcache` settled it, so this is the filter.

It is inside `gs_texsample` rather than beside it. The four corners need the
same addressing, the same wrap, the same palette lookup and the same format
expansion that one corner needs, and a separate block would have had a second
copy of each — which is exactly the kind of duplication that drifts. What was
added is a `linear` input, a corner counter, four texel registers and three
lerps; the fetch loop runs four times instead of once.

`linear` is one bit and not TEX1, deliberately. What TEX1 actually says is MMAG
and MMIN, and reducing those to a filter needs the LOD, which needs Q, which
needs the perspective divide that does not exist yet. Taking TEX1 here would be
pretending mipmapping is wired.

### The half texel, and why nearest must not have it

The GS filters at **(u − 0.5, v − 0.5)**. UV counts texel *edges*, so texel *n*
occupies [n, n+1) and its centre is at n + 0.5; subtracting the half texel first
is what makes `u = n + 0.5` return texel *n* unmixed and `u = n` an even blend
of *n−1* and *n*.

The nearest path keeps **no** shift and its truncation. The two are not the same
operation, and making them the same is the plausible wrong answer in both
directions at once — a filter missing the shift displaces every textured surface
by half a texel, and a nearest path that gained one would disagree with every
existing vector. Both directions are mutated below and both are caught.

The test states it as the two properties rather than as a table of expected
colours: at `u = (n<<4) | 8` the weight must be zero and texel *n* must come back
unmixed, and at `u = n<<4` the weight must be eight. A sampler with no shift gets
the first right by accident at a different coordinate and the second wrong
everywhere.

### The bug this actually had, which is a VHDL trap worth writing down

`resize` on a **signed** does not truncate. It keeps the sign bit and the low
bits beneath it, so `resize(uu, 4)` is `uu(17) & uu(2 downto 0)` — three of the
four fractional bits with the sign pasted on top. The four weight bits need a
**slice**, `uu(3 downto 0)`.

What makes it worth recording is how it failed. The wrong expression is zero at
exactly the half-texel positions, which are the coordinates where a filter looks
most obviously correct: **327 of 759 bilinear cases passed with it in place**,
including every "texel returned unmixed" case. A test built only from the
properties that read like the definition of bilinear filtering would have gone
green. It was the every-weight sweep and the random cases that found it.

`sim/gs/mutate_texsample.py` reproduces it as a mutation, so it stays found.

### The arithmetic: sixteenths, and a shift that floors

The weights are the four fractional bits of the 12.4 coordinate, so there are
sixteen positions between texels and no more. That is not an approximation of
something finer — 12.4 *is* the coordinate format, and a filter that lerped with
more precision than sixteenths would be smoother than the console.

The lerp is `a + ((b − a) * f >> 4)` with an **arithmetic** shift, which floors
rather than truncating toward zero. When b < a the difference is negative and
the two round in opposite directions by one bit, on exactly the pixels where a
texture gets darker from left to right; the model uses Python's `>>`, which
floors. The mutation that divides by sixteen instead **differs on 454 of 1257
cases**.

Two orderings also matter, and both are only visible because each lerp
truncates:

* **the horizontal pair first, the vertical between them.** Doing the vertical
  pair first is algebraically identical in exact arithmetic and different here —
  180 of 1257 cases.
* **expand, then filter.** Two PSMCT16 texels averaged as 5551 and then expanded
  is not the same number as two expanded and averaged — 92 cases. Likewise TFX
  runs *after* the filter, because saturating four texels and averaging them is
  not averaging four and saturating once.

No saturation is applied to the lerp and none is needed: with a and b in 0..255
and f in 0..15 the result is in 15..239. A clamp there would be dead logic that
looked like a safety net.

### The test

`sim/gs/run_texsample_diff.sh`: **1257 samples identical on four seeds**, 498
nearest and 759 bilinear, against `sample_uv` / `sample_uv_linear` followed by
`texture_function`.

Both filters come out of **one generator and one testbench**, in one run. A
filter with its own generator drifts from the one it is supposed to be a
refinement of, and the half-texel relationship between them is precisely what a
split would stop testing.

The bilinear cases are aimed at: the two half-texel properties; all 16 × 16
weight positions at one place; every format at a weight coprime with the shift;
all four texture functions after the filter; and corners stepping off the texture
under all four wrap modes in both axes — each corner is wrapped on its own, and a
filter that wrapped the base coordinate and then added one would smear across the
edge (572 of 1257 cases).

`sim/gs/mutate_texsample.py`: **sixteen mutations, sixteen caught.**

### What it costs, in logic and in time

Out of context for `xcu55n-2LV` at the GS's 147.456 MHz, the same block before
and after — the earlier figure re-measured under the same constraint rather than
quoted from a differently-constrained run:

| `gs_texsample` | nearest only | with bilinear |
|---|---|---|
| CLB LUTs | 1327 | **1589** (+262) |
| CLB registers | 202 | **295** (+93) |
| Block RAM / UltraRAM / DSP | 0 | **0** |
| WNS at 147.456 MHz | +3.634 ns | **+2.693 ns** (≈ 245 MHz) |

The 262 LUTs are twelve `lerp8`s — three lerps by four channels — each an 8 × 4
multiply and an add. The filter is cheap; it was never the cost that made this
wait.

The cost that did is the fetches, and with the cache in front it is **not four
times**. Measured on the 64 × 48 raster walk in `tb_texcache.sv`:

| walk | hit rate | misses | cycles/pixel |
|---|---|---|---|
| PSMCT32 nearest | 87 % | 384 | 6.37 |
| PSMT8 nearest | 96 % | 96 | 8.09 |
| **PSMCT32 bilinear** | **96 %** | **400** | **12.39** — 1.95× nearest |
| **PSMT8 bilinear** | **99 %** | **104** | **20.10** — 2.48× nearest |

Every one of those four miss counts is exactly the walk's compulsory floor — the
count of distinct 256-bit memory words it touches, computed from `gs_ref`'s own
address functions rather than read off a run of this design. **Zero conflict
misses on any of them**, and bilinear reaches 96 % and 99 % because three of its
four corners are already held.

A textured pixel costing about twice an untextured one is, as it happens, the
ratio the real GS has — for the same reason, arrived at from the other side: it
buys it with a dedicated port and a page buffer, and this buys it with the page
buffer alone.

The cycle figures are **per-sample latency, not pipelined throughput**: the walk
drives one sample at a time through `req`/`done`, so each includes a handshake
the rasteriser will not pay. They are the right numbers for comparing the two
filters against each other and the wrong ones for predicting a fill rate.

### What is still not here

MMAG/MMIN and therefore the choice between the filters at run time; mipmapping,
which needs Q; and the perspective divide that produces Q. The model has all
three. `gs_top` still does not instantiate the texture unit, so none of this has
been on the card.
