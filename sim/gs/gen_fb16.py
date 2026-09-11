#!/usr/bin/env python3
"""Emit a directed PSMCT16/PSMCT16S stream.

    sim/gs/gen_fb16.py > fb16.hex

The random streams in gen_gif.py draw to 16-bit buffers, but they are weak at
it in a way that was measured rather than guessed.  Mutating the RTL and
re-running three seeds:

    the S block order used for both formats     caught 3 of 3
    the half taken from x(4) instead of x(3)    caught 2 of 3
    pack16 keeping the wrong five bits          caught 2 of 3
    expand16 replicating instead of zero-filling  caught 0 of 3

The last one is the interesting failure, and it is not bad luck.  Expansion is
only reached when the destination is *read*, and the two candidate expansions of
a five-bit value differ only in the low three bits -- exactly the bits pack16
throws away again on the way back.  A destination that is read, blended by a
selector that copies it, and written back is bit-identical under either rule.
The difference becomes visible only when arithmetic carries it up into bit 3.

So this program arranges that on purpose:

  * **The fill pass** writes a known 16-bit destination with no blending.  Red
    is 0x80, whose five-bit form is 0x10 -- expanded as 0x80 by the zero-filling
    rule the manual states and 0x84 by the replicating one it does not.
  * **The blend pass** draws over it with `Cv = (Cs - Cd) * FIX >> 7`, FIX =
    0x80, so the destination is subtracted at full weight.  The source is 0xC1,
    and 0xC1 - 0x80 = 0x41 packs to 8 while 0xC1 - 0x84 = 0x3D packs to 7.  One
    bit of output, from three bits that would otherwise be discarded.

Everything else here is enumeration rather than cleverness: the rectangles cover
a whole 64 x 64 page so that all four block columns and all eight block rows of
both block orders are touched, and both halves of every word are written.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_gif import tag

# ALPHA: A = Cs, B = Cd, C = FIX, D = Zero.  Cv = (Cs - Cd) * FIX >> 7.
ALPHA_SUB = 0 | (1 << 2) | (2 << 4) | (2 << 6) | (0x80 << 32)
# ALPHA with nothing read from the destination, for the fill passes.
ALPHA_NONE = 0 | (0 << 2) | (2 << 4) | (2 << 6) | (0x00 << 32)
# ALPHA: A = Cs, B = Zero, C = Ad, D = Cd.  Cv = Cs * Ad >> 7 + Cd, which turns
# the destination's one-bit alpha into a coefficient of a half or of nothing --
# and keeps Cd in the result, so the pass does not flatten the pattern it is
# drawn over.  An earlier version used D = Zero and made the whole page depend
# on nothing but the alpha bit, which cost every later pass its position
# dependence.
ALPHA_AD = 0 | (2 << 2) | (1 << 4) | (1 << 6)

# ZTE must be 1 -- the manual calls 0 prohibited -- and ALWAYS with ZMSK set is
# the documented way to draw with no depth at all.
ZTEST = (1 << 16) | (1 << 17)


def sprite(out, fbp, psm, msk, rgba, abe, alpha, x0, y0, x1, y1, zbuf):
    items = [(0x4C, fbp | (1 << 16) | (psm << 24) | (msk << 32)),
             (0x18, 0),
             (0x40, 0 | (63 << 16) | (0 << 32) | (63 << 48)),
             (0x42, alpha), (0x46, 1),
             (0x4E, zbuf), (0x47, ZTEST),
             (0x01, rgba),
             (0x00, 6 | (abe << 6))]
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out.append(tag(1, 0, regs, len(items)))
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    out.append(tag(1, 1, 0xEE, 2))
    out.append(((x0 << 4) | ((y0 << 4) << 16)) | (0x05 << 64))
    out.append(((x1 << 4) | ((y1 << 4) << 16)) | (0x05 << 64))


def main():
    out = []
    # ZBUF with ZMSK set, at a page well clear of the colour buffers, so depth
    # never writes and never decides anything here.
    zbuf = 8 | (0 << 24) | (1 << 32)

    for psm, fbp in ((2, 0), (10, 2)):        # PSMCT16 at page 0, PSMCT16S at 2
        # 1. Fill the page with a pattern that *varies with position*.  A
        #    uniform fill is the trap here: every block holds the same value, so
        #    permuting the blocks changes nothing and the two block orders
        #    become indistinguishable.  This was not hypothetical -- the first
        #    version of this program filled uniformly and scored 0 of 1 against
        #    a mutation that used the S order for both formats, while the random
        #    streams caught it 3 times in 3.
        #
        #    The tile is 8 x 8, half a block wide and a block tall, so a tile
        #    boundary falls inside a block in x and on a block edge in y.
        #
        #    The values must not repeat with the *block* period or the pattern
        #    is uniform where it matters.  A first version alternated alpha on
        #    (tx + ty) & 1, and since a block is two tiles wide every block came
        #    out with the same pair of values -- so permuting the blocks changed
        #    nothing and both block orders scored identically.  Red counts tiles
        #    across, green counts them down, and alpha runs on a period of three
        #    tiles, which shares no factor with the two tiles of a block.
        for ty in range(8):
            for tx in range(8):
                r = 0x08 * tx + 0x80
                g = 0x08 * ty + 0x40
                b = 0x08 * ((tx + 3 * ty) & 7) + 0x20
                a = 0x80 if (tx + 2 * ty) % 3 else 0x00
                sprite(out, fbp, psm, 0x00000000,
                       (a << 24) | (b << 16) | (g << 8) | r, 0, ALPHA_NONE,
                       tx * 8, ty * 8, tx * 8 + 8, ty * 8 + 8, zbuf)

        # 2. Blend over the whole page so that the *expansion* of what is there
        #    reaches bit 3 of the result.  Cv = (Cs - Cd) * FIX >> 7 with FIX at
        #    0x80 subtracts the destination at full weight, and the source's low
        #    three bits decide whether the two candidate expansions land either
        #    side of a multiple of eight.  All three colour channels carry a
        #    different source value so that no channel can hide the difference
        #    for the other two.
        sprite(out, fbp, psm, 0x00000000, 0xFFC3C1C1, 1, ALPHA_SUB,
               0, 0, 64, 64, zbuf)

        # 3. Blend with C = Ad, which is what makes the *alpha* expansion
        #    observable: a 16-bit destination's alpha is 0x80 or 0x00, so this
        #    coefficient is either a half or nothing, and a model that expanded
        #    the one-bit alpha to 0xFF would scale by very nearly one instead.
        #    The pattern above alternates that bit tile by tile.
        sprite(out, fbp, psm, 0x00000000, 0x40707070, 1, ALPHA_AD,
               0, 0, 64, 64, zbuf)

        # 4. A masked write, to check FBMSK converts by the same bit selection
        #    the colour does.  0x00F80000 keeps blue's five surviving bits and
        #    nothing else, so exactly one channel must fail to change.
        #    It covers only the left half of the page, so the right half keeps
        #    the pattern the passes above built rather than being flattened.
        sprite(out, fbp, psm, 0x00F80000, 0x30507090, 0, ALPHA_NONE,
               0, 0, 32, 64, zbuf)

        # 5. A rectangle on odd boundaries, so the first and last word of each
        #    scanline are half-written and the untouched half of a shared word
        #    has to survive.
        sprite(out, fbp, psm, 0x00000000, 0x2040608F, 0, ALPHA_NONE,
               3, 5, 29, 11, zbuf)

    for w in out:
        print("%032x" % (w & ((1 << 128) - 1)))


if __name__ == "__main__":
    main()
