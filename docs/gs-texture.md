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
