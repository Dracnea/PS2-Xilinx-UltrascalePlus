#!/usr/bin/env python3
"""A textured scene, built so that the ways texturing goes wrong are visible.

    tools/gs/gen_texscene.py > texscene.hex

`gen_scene.py` is the untextured version of this and says why a picture is
worth having alongside the checksums: it shows the faults that announce
themselves as "the gradient runs the wrong way" or "that triangle has a seam",
which no diff will tell you.

The frame is **64 x 64** because PCRTC's grab buffer holds 4096 pixels, and the
point of this scene is to come back through the card's own display path rather
than only over PCIe.

## What each quadrant is for

A 16 x 16 texture is drawn four times, as four quadrants of 32 x 32:

    +-------------------+-------------------+
    | nearest, 1:1      | bilinear, 1:1     |   tiled 2x2 -- REPEAT, and the
    |                   | +0.5 texel        |   seam between tiles
    +-------------------+-------------------+
    | nearest, 2x       | bilinear, 2x      |   magnified -- the filter is the
    |                   | +0.5 texel        |   whole difference between these
    +-------------------+-------------------+

**The top two quadrants must be identical**, and that is the check this scene
exists for rather than a coincidence of the picture. The bottom two must look
different -- blocks against a gradient -- and a texture unit whose filter select
is stuck one way fails one pair or the other, while either pair alone would
still look plausible.

## The half texel, which is why the bilinear quadrants are offset

The GS filters at (u - 0.5, v - 0.5). So a quad whose UV runs 0 to 32 across 32
pixels puts pixel x at u = x exactly, bilinear samples at x - 0.5, and **every
pixel is an even blend of two texels** -- a uniform half-texel blur, on what
looks like a one-to-one blit. That is not a bug and the first version of this
file asserted the opposite: it is what the hardware does, and it is why content
that wants a sharp 1:1 blit either uses nearest or offsets its UV by half a
texel. The offset is what the right-hand quadrants apply, and applying it is
what makes them match the left-hand ones exactly.

Which is worth having as a picture as well as an assertion: if the half-texel
shift were missing from the filter, the offset quadrants would be the blurred
ones and the unoffset ones sharp -- the same two images, swapped, and a
checksum against a model that shared the mistake would not notice.

## The texture

Four saturated quadrants with a one-texel white border and a black cross
through the middle. The border makes the tiling seam visible in the top row;
the hard colour edges are what a half-texel error smears; and the black cross
is there because a uniform texture hides an addressing fault that swaps u and v.

SPDX-License-Identifier: BSD-2-Clause
"""
import sys

TW_LOG2, TH_LOG2 = 4, 4                  # 16 x 16
TBP  = 96                                # in 256-byte blocks: page 3, clear of the frame
FBP  = 0                                 # the frame buffer, in 8 KB pages
FBW  = 1                                 # 64 pixels
W = H = 64


def tag(nloop, eop, regs, nreg, flg=0):
    return (nloop | (eop << 15) | (flg << 58) | ((nreg & 15) << 60) | (regs << 64))


def ad(items, eop):
    """One A+D group: a tag and then address/data pairs."""
    out = []
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out.append(tag(1, eop, regs, len(items)))
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    return out


def texel(u, v):
    """The 16 x 16 pattern. See the header for why it is this and not a ramp."""
    if u == 0 or v == 0 or u == 15 or v == 15:
        return 0x80FFFFFF                        # white border
    if u in (7, 8) or v in (7, 8):
        return 0x80000000                        # black cross
    quad = (1 if u >= 8 else 0) | (2 if v >= 8 else 0)
    return [0x800000FF, 0x8000FF00, 0x80FF0000, 0x8000FFFF][quad]


def tex0(psm=0, tcc=1, tfx=1):
    # TFX = 1 is DECAL: the texel replaces the fragment, so what is on screen is
    # the texture and not the texture times a colour. That is what makes this
    # picture readable as a texture rather than as a lighting result.
    return (TBP | (FBW << 14) | (psm << 20) | (TW_LOG2 << 26) | (TH_LOG2 << 30)
            | (tcc << 34) | (tfx << 35))


def tex1(linear):
    # MMAG in bit 5, MMIN in 8:6, and LCM set with K = 0 so the LOD is zero and
    # does not depend on Q -- this scene is about the filter, not the level.
    return ((1 if linear else 0) << 5) | ((1 if linear else 0) << 6) | (1 << 19)


def quad(x0, y0, x1, y1, u0, v0, u1, v1):
    """Two triangles covering a rectangle, with UV at the corners, in 12.4.

    UV arrives already in 12.4 rather than in texels, because the half-texel
    offset above is not expressible in whole texels and rounding it here would
    quietly remove the thing the scene is testing.

    A quad and not a sprite: textured sprites are refused by this rasteriser
    until the sprite path has a per-scanline UV seed, so the scene is drawn the
    way the hardware can actually draw it.
    """
    out = []
    corners = [(x0, y0, u0, v0), (x1, y0, u1, v0),
               (x0, y1, u0, v1), (x1, y1, u1, v1)]
    for tri in ((0, 1, 2), (1, 3, 2)):
        vr = 0
        for i in range(6):
            vr |= 0xE << (4 * i)
        out.append(tag(1, 1, vr, 6))
        for k in tri:
            x, y, u, v = corners[k]
            out.append((u | (v << 16)) | (0x03 << 64))
            out.append(((x << 4) | ((y << 4) << 16)) | (0x05 << 64))
    return out


def main():
    out = []

    # ---- the texture, by host-to-local transfer --------------------------
    out += ad([(0x50, (TBP << 32) | (FBW << 48)),     # BITBLTBUF: DBP, DBW
               (0x51, 0),                             # TRXPOS
               (0x52, (1 << TW_LOG2) | ((1 << TH_LOG2) << 32)),
               (0x53, 0)], eop=0)                     # TRXDIR: host -> local
    px = [texel(u, v) for v in range(1 << TH_LOG2) for u in range(1 << TW_LOG2)]
    nqw = len(px) // 4
    out.append(tag(nqw, 1, 0, 1, flg=2))              # IMAGE mode
    for i in range(0, len(px), 4):
        qw = 0
        for j in range(4):
            qw |= px[i + j] << (32 * j)
        out.append(qw)

    # ---- the drawing context, once ---------------------------------------
    out += ad([(0x4C, FBP | (FBW << 16) | (0 << 24)),          # FRAME_1
               (0x18, 0),                                      # XYOFFSET_1
               (0x40, 0 | ((W - 1) << 16) | (0 << 32) | ((H - 1) << 48)),
               (0x42, 0), (0x46, 0),                           # ALPHA_1, COLCLAMP
               (0x4E, 1 << 24), (0x47, 0),                     # ZBUF_1 masked, TEST_1 off
               (0x08, 0),                                      # CLAMP_1: REPEAT both
               (0x01, 0x8080_8080)], eop=1)                    # RGBAQ, unused by DECAL

    # ---- the four quadrants ----------------------------------------------
    # PRIM: TRIANGLE (3), TME (bit 4), FST (bit 8).
    PRIM = 3 | (1 << 4) | (1 << 8)
    for (qx, qy, linear, scale) in ((0,  0,  False, 1),
                                    (32, 0,  True,  1),
                                    (0,  32, False, 2),
                                    (32, 32, True,  2)):
        span = (32 // scale) << 4           # texels across the quadrant, in 12.4
        off = 8 if linear else 0            # half a texel, in 12.4
        out += ad([(0x06, tex0()), (0x14, tex1(linear)), (0x00, PRIM)], eop=1)
        out += quad(qx, qy, qx + 32, qy + 32,
                    off, off, span + off, span + off)

    for q in out:
        print("%032x" % q)
    print("%032x" % 0)


if __name__ == "__main__":
    main()
