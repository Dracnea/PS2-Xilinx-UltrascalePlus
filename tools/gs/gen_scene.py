#!/usr/bin/env python3
"""A scene built to be looked at rather than diffed.

    tools/gs/gen_scene.py > scene.hex

Every test in this repository so far compares two numbers.  This one is for the
other kind of checking: a picture a person can glance at and say "the gradient
runs the wrong way" or "that triangle has a seam", which no checksum will tell
you and which is how a rasteriser's remaining faults usually announce
themselves.

It uses only what is built: flat and Gouraud triangles, sprites, alpha blending
and the depth test.  No texture, because there is no texture unit.
"""
import sys

W, H = 320, 224          # a quarter of a PS2 frame, and 280 KB of a page-aligned
                         # buffer, so a grab is quick


def tag(nloop, eop, regs, nreg):
    return nloop | (eop << 15) | ((nreg & 15) << 60) | (regs << 64)


def ad(items, eop=0):
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out = [tag(1, eop, regs, len(items))]
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))
    return out


def rgbaq(r, g, b, a=0x80):
    return (a << 24) | (b << 16) | (g << 8) | r


def xyz(x, y, z=0):
    return (int(x) << 4) | ((int(y) << 4) << 16) | (z << 32)


def ctx(prim, alpha=0, abe=0, ztst=1, zmsk=1, fbmsk=0):
    return [
        (0x4C, 0 | ((W // 64) << 16) | (0 << 24) | (fbmsk << 32)),
        (0x18, 0),
        (0x40, 0 | ((W - 1) << 16) | (0 << 32) | ((H - 1) << 48)),
        (0x42, alpha), (0x46, 1),
        (0x4E, 32 | (zmsk << 32)),          # Z buffer well clear of the frame
        (0x47, (1 << 16) | (ztst << 17)),
        (0x00, prim | (abe << 6)),
    ]


def sprite(out, x0, y0, x1, y1, colour, abe=0, alpha=0):
    out += ad(ctx(6, alpha, abe) + [(0x01, colour)])
    out += [tag(1, 1, 0xEE, 2),
            xyz(x0, y0) | (0x05 << 64), xyz(x1, y1) | (0x05 << 64)]


def tri(out, pts, colours, iip=1, z=None, ztst=1, zmsk=1, abe=0, alpha=0):
    """pts are three (x, y); colours three RGBAQ words."""
    out += ad(ctx(3 | (iip << 3), alpha, abe, ztst, zmsk))
    items = []
    for (x, y), c in zip(pts, colours):
        items.append((0x01, c))
        items.append((0x05, xyz(x, y, 0 if z is None else z)))
    regs = 0
    for i in range(len(items)):
        regs |= 0xE << (4 * i)
    out.append(tag(1, 1, regs, len(items)))
    for a, d in items:
        out.append((d & ((1 << 64) - 1)) | (a << 64))


def main():
    out = []

    # a dark background, so anything drawn over it is obvious
    sprite(out, 0, 0, W, H, rgbaq(0x10, 0x10, 0x20))

    # a row of flat sprites: the primary colours, at known positions
    for i, c in enumerate([rgbaq(0xF0, 0, 0), rgbaq(0, 0xF0, 0), rgbaq(0, 0, 0xF0),
                           rgbaq(0xF0, 0xF0, 0), rgbaq(0, 0xF0, 0xF0),
                           rgbaq(0xF0, 0, 0xF0)]):
        sprite(out, 10 + i * 50, 10, 50 + i * 50, 40, c)

    # one large Gouraud triangle: red, green and blue at the corners, which is
    # the shape that shows an interpolation fault as a colour that does not
    # belong anywhere along an edge
    tri(out, [(30, 70), (290, 90), (140, 200)],
        [rgbaq(0xFF, 0, 0), rgbaq(0, 0xFF, 0), rgbaq(0, 0, 0xFF)])

    # two overlapping half-transparent sprites over it: Cs*As + Cd*(1-As) is
    # A=0, B=1, C=0, D=1 with the source alpha, so the overlap is a third shade
    # and a blend that reads the wrong operand shows up as a hard edge
    alpha = 0 | (1 << 2) | (0 << 4) | (1 << 6)
    sprite(out, 40, 120, 160, 210, rgbaq(0xFF, 0xFF, 0xFF, 0x40), abe=1, alpha=alpha)
    sprite(out, 110, 150, 240, 215, rgbaq(0xFF, 0xC0, 0x00, 0x40), abe=1, alpha=alpha)

    # a depth-tested pair: the second is behind the first and must not appear
    # where they overlap
    tri(out, [(200, 60), (300, 60), (250, 140)],
        [rgbaq(0xFF, 0x80, 0x80)] * 3, iip=0, z=0x2000, ztst=2, zmsk=0)
    tri(out, [(230, 90), (310, 90), (270, 170)],
        [rgbaq(0x40, 0xFF, 0x40)] * 3, iip=0, z=0x1000, ztst=2, zmsk=0)

    for q in out:
        print("%032x" % (q & ((1 << 128) - 1)))
    print(f"// {W}x{H}, {len(out)} quadwords", file=sys.stderr)


if __name__ == "__main__":
    main()
