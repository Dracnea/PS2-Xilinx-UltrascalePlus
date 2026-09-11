#!/usr/bin/env python3
"""The smallest GIF stream worth putting on a card: one flat sprite.

    tools/gs/gen_firstlight.py > firstlight.hex

The first run of a new board target tests the target, not the Graphics
Synthesizer.  So the primitive is chosen to make a wrong answer obvious rather
than to exercise anything: an 8 x 4 opaque rectangle at the origin, in PSMCT32,
with no blending, no depth, no scissor clipping and one colour.  Thirty-two
pixels, one value.

What each possible failure then looks like:

  * nothing drawn, pixel count zero -- the GIF never accepted the packets, so
    the push handshake or the CSR decode is wrong;
  * nothing drawn, pixel count right -- the write reached memory at an address
    the readback does not agree with;
  * the right pixels in the wrong place -- the swizzle, which is the one thing
    here already cross-checked against PCSX2 exhaustively;
  * every word 0xFFFFFFFF -- the BAR is not routed and nothing is reaching the
    card at all, which is a host problem and not a card one.
"""
import sys


def tag(nloop, eop, regs, nreg):
    return nloop | (eop << 15) | ((nreg & 15) << 60) | (regs << 64)


def ad(items):
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out = [tag(1, 0, regs, len(items))]
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    return out


def xyz(x, y, z=0):
    return (x << 4) | ((y << 4) << 16) | (z << 32)


def main():
    W, H = 8, 4
    out = ad([
        (0x4C, 0 | (1 << 16) | (0 << 24)),          # FRAME_1: page 0, 64px wide, PSMCT32
        (0x18, 0),                                   # XYOFFSET_1: none
        (0x40, 0 | (63 << 16) | (0 << 32) | (31 << 48)),   # SCISSOR_1
        (0x42, 0), (0x46, 1),                        # ALPHA_1, COLCLAMP
        (0x4E, 8 | (1 << 32)),                       # ZBUF_1: page 8, ZMSK=1 -- depth untouched
        (0x47, (1 << 16) | (1 << 17)),               # TEST_1: ZTE=1, ZTST=ALWAYS
        (0x01, 0x80 << 24 | 0x40 << 16 | 0x60 << 8 | 0x20),  # RGBAQ
        (0x00, 6),                                   # PRIM: sprite, no blending
    ])
    # The two vertices go through A+D as well, with XYZ2's address (0x05) in
    # the upper half -- writing XYZ2 is what kicks the primitive.  Sending the
    # coordinates as bare quadwords draws nothing at all, which is how the
    # first version of this file failed and why it is worth having a stream the
    # model has agreed to before any of it reaches a card.
    out += [tag(1, 1, 0xEE, 2),
            xyz(0, 0) | (0x05 << 64),
            xyz(W, H) | (0x05 << 64)]
    for q in out:
        print("%032x" % (q & ((1 << 128) - 1)))
    print("// one sprite, %d x %d = %d pixels, PSMCT32 at page 0" % (W, H, W * H),
          file=sys.stderr)


if __name__ == "__main__":
    main()
