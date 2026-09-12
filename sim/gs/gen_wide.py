#!/usr/bin/env python3
"""Emit a directed stream for the rasteriser's wide write path.

    sim/gs/gen_wide.py > wide.hex

A 256-bit memory word holds a 4 x 2 block of PSMCT32 pixels, so four
consecutive pixels of a span share one word and can be written together. That
path exists to make full-screen fills four times faster; this program is what
proves it writes the same pixels the one-at-a-time path did.

**It exists because six mutations of that path all passed.** The random streams
in gen_gif.py never reach it: it needs a sprite, a 32-bit buffer, no frame-buffer
mask, no blending, *and* the depth buffer switched off -- which on this machine
is the specific combination of ZTE = 1, ZTST = ALWAYS and ZMSK = 1, because ZTE
= 0 is prohibited. Random streams pick depth settings at random and almost never
land on it. So the fastest and most common thing the Graphics Synthesizer does
was the one thing the tests did not cover.

What the cases below are chosen to catch:

  * **Alignment.** A run stops at the end of its memory word, so a span starting
    at x = 1 writes three pixels and then four. Every span here starts at each
    of x mod 4 = 0, 1, 2, 3.
  * **The right edge.** A run also stops at the end of the span, and a span is
    not a multiple of four. Widths 1 to 9 put the end in every position within a
    word, including spans narrower than one run.
  * **Odd and even rows.** The four pixels of a row occupy words 0, 1, 4, 5 of
    the line on even y and 2, 3, 6, 7 on odd y, so a run that computed one
    lane's index and reused it would be right on one row and wrong on the next.
  * **That it is still the same picture.** Every sprite is drawn in a colour
    that encodes where it is, over a background written by a first pass, so a
    pixel written that should not have been -- or skipped -- changes the dump.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_gif import tag

# ZTE must be 1 -- the manual calls 0 prohibited -- and ALWAYS with ZMSK set is
# the documented way to draw with no depth at all.  This exact pair is what
# takes the rasteriser down the wide path.
ZTEST_ALWAYS = (1 << 16) | (1 << 17)
ZBUF_OFF     = 1 << 32                      # ZMSK = 1


def sprite(out, rgba, x0, y0, x1, y1, fbw=1, abe=0, msk=0):
    items = [(0x4C, 0 | (fbw << 16) | (0 << 24) | (msk << 32)),   # FRAME_1, PSMCT32
             (0x18, 0),                                           # XYOFFSET_1
             (0x40, 0 | (63 << 16) | (0 << 32) | (63 << 48)),     # SCISSOR_1
             (0x42, 0), (0x46, 1),
             (0x4E, ZBUF_OFF), (0x47, ZTEST_ALWAYS),
             (0x01, rgba),
             (0x00, 6 | (abe << 6))]                              # PRIM: sprite
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out.append(tag(1, 0, regs, len(items)))
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    out.append(tag(1, 1, 0xEE, 2))
    out.append(((x0 << 4) | ((y0 << 4) << 16)) | (0x05 << 64))
    out.append(((x1 << 4) | ((y1 << 4) << 16)) | (0x05 << 64))


def gouraud(out, v0, v1, v2):
    """A Gouraud-shaded triangle, in the same register state as the sprites."""
    items = [(0x4C, 0 | (1 << 16) | (0 << 24)),               # FRAME_1, PSMCT32
             (0x18, 0),
             (0x40, 0 | (63 << 16) | (0 << 32) | (63 << 48)),
             (0x42, 0), (0x46, 1),
             (0x4E, ZBUF_OFF), (0x47, ZTEST_ALWAYS),
             (0x00, 3 | (1 << 3))]                            # PRIM: triangle, IIP
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out.append(tag(1, 0, regs, len(items)))
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    # three vertices, each a colour then a position
    out.append(tag(3, 1, 0xEE, 2))
    for x, y, rgb in (v0, v1, v2):
        out.append((rgb & ((1 << 64) - 1)) | (0x01 << 64))    # RGBAQ
        out.append(((x << 4) | ((y << 4) << 16)) | (0x05 << 64))


def main():
    out = []
    # A background, so that a pixel wrongly left alone is as visible as one
    # wrongly written -- and the screen-clear case, which is what a full-page
    # sprite is, done *first* so that it does not erase everything after it.
    #
    # The first version of this file drew a full-page sprite last.  Every
    # alignment case below was overwritten before the dump, so poisoning the
    # wide path entirely -- making it write nothing at all -- still passed.
    # A test whose last act is to paint over its own evidence proves nothing.
    sprite(out, 0x11223344, 0, 0, 64, 64)
    sprite(out, 0x00C0FFEE, 0, 0, 64, 64)

    # Each region below is disjoint from the others, so nothing here can hide a
    # fault in anything else here.

    # y 0..31 -- every start alignment against every width, one row tall, on
    # both an even and an odd row: the two have different lane indices within
    # the memory word.
    y = 0
    for x0 in range(4):
        for w in range(1, 10):
            for row in (0, 1):
                col = 0x40000000 | (x0 << 20) | (w << 12) | (row << 8) | y
                sprite(out, col, x0 + 16 * (w // 5), y + row,
                       x0 + 16 * (w // 5) + w, y + row + 1)
            y += 2
            if y >= 30:
                y = 0

    # y 32..39 -- spans that are tall as well as wide, so the run restarts on
    # every row rather than only once.
    for x0 in range(4):
        for w in (1, 3, 4, 5, 8):
            sprite(out, 0x80000000 | (x0 << 16) | w,
                   x0 + 12 * (w // 4), 32, x0 + 12 * (w // 4) + w, 40)

    # y 44..55 -- blending on, which takes the *other* path, the
    # read-modify-write.  Kept to its own rows so that it cannot paint over the
    # wide path's evidence, which is exactly what the first version did.
    sprite(out, 0x40302010, 0, 44, 64, 48, abe=1)
    for x0 in range(4):
        for w in (1, 4, 7):
            sprite(out, 0x20000000 | (x0 << 8) | w,
                   x0 + 16 * (w // 5), 50, x0 + 16 * (w // 5) + w, 52, abe=1)

    # y 56..63 -- a Gouraud triangle under exactly the conditions that enable
    # the wide path, which is what says the path must *not* take them.
    #
    # A sprite's colour is constant across its span, so writing four pixels at
    # once needs nothing from the interpolators.  A Gouraud triangle's is not:
    # its colour DDA is stepped once per pixel and has no way to advance four.
    # Allowing the wide path here would write one pixel's colour over four and
    # step the DDA once -- and until this triangle existed, a mutation that did
    # exactly that passed, because no random stream happened to draw a Gouraud
    # triangle with a 32-bit buffer, no mask, no blending and the depth buffer
    # switched off all at once.
    gouraud(out, (2, 56, 0x0000FF), (60, 58, 0x00FF00), (20, 63, 0xFF0000))

    for q in out:
        print("%016x%016x" % ((q >> 64) & ((1 << 64) - 1), q & ((1 << 64) - 1)))


if __name__ == "__main__":
    main()
