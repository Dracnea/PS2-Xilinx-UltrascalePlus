#!/usr/bin/env python3
"""Emit a random GIF packet stream, for differential testing.

    sim/gs/gen_gif.py --seed 1 --tags 40 > packets.hex

Two constraints keep a random stream meaningful rather than merely legal.
Transfers are aimed at a small rectangle inside the first few pages, so a
generator cannot scatter single pixels across four megabytes and make the
memory comparison mostly empty; and NLOOP stays small, because the interesting
behaviour is at the seams -- the end of a descriptor list, the end of a loop,
the boundary between a tag and its data -- not in the middle of a long run.
"""
import argparse, random

# Descriptors worth generating: A+D dominates because it is how a real packet
# writes most registers, and it is the only one carrying its own address.
#
# 0x4 and 0x5 -- XYZF2 and XYZ2 -- are absent for the same reason they are
# absent from AD_ADDRS: they *kick a primitive*, and one kicked from random
# coordinates with a random PRIM is a triangle of arbitrary extent, drawn from
# vertices that mean nothing.  Excluding them there and leaving them here was an
# oversight that took a bisect to find.  0xC and 0xD (XYZF3, XYZ3) stay: they
# queue a vertex without drawing, which is exactly the harmless half.
DESCS = [0x0, 0x1, 0x2, 0x3, 0x6, 0x7, 0x8, 0x9, 0xA,
         0xC, 0xD, 0xE, 0xE, 0xE, 0xE, 0xF]

# addresses A+D may name.  0x53 and 0x54 are excluded here and driven only by
# the deliberate transfer sequences below, because a random TRXDIR in the middle
# of a stream would start a transfer whose set-up registers are random too.
# 0x04 and 0x05 are deliberately absent: XYZF2 and XYZ2 kick a primitive, and a
# random one drawn with a random FRAME and a random SCISSOR is a rectangle of up
# to four million pixels.  Both models would agree on it, slowly.  Drawing is
# generated coherently below instead, where the size can be bounded.
AD_ADDRS = [0x00, 0x01, 0x02, 0x03, 0x06, 0x07, 0x08, 0x09, 0x0A,
            0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x22,
            0x34, 0x35, 0x36, 0x37, 0x3B, 0x3D, 0x3F,
            0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52,
            0x60, 0x61, 0x62,
            # a few the manual does not define: writing one must leave every
            # register alone, and only a generator that tries it would show that
            0x0B, 0x20, 0x55, 0x70]


def blend_regs(rng):
    """ALPHA and COLCLAMP, and whether PRIM enables blending at all.

    All four selectors are generated, including the ones that read the
    *destination* -- those are what force a framebuffer read on every pixel and
    so take a different path through the drawing logic than an opaque write.
    Both clamp modes appear, because wrapping is a deliberate effect and not a
    corner to be rounded off.
    """
    abe = rng.randrange(2)
    a, b, c, d = (rng.randrange(3), rng.randrange(3),
                  rng.randrange(3), rng.randrange(3))
    fix = rng.randrange(256)
    alpha = a | (b << 2) | (c << 4) | (d << 6) | (fix << 32)
    return abe, alpha, rng.randrange(2)


def tag(nloop, eop, regs, nreg, flg=0, pre=0, prim=0):
    return (nloop | (eop << 15) | (pre << 46) | (prim << 47) |
            (flg << 58) | ((nreg & 15) << 60) | (regs << 64))


def gen(rng, ntags):
    out = []
    for _ in range(ntags):
        pick = rng.random()
        if pick < 0.20:
            # a sprite: set the context up coherently, then two vertices.  The
            # write mask is included because a masked write is a
            # read-modify-write in hardware and an unmasked one is not, so the
            # two take different paths through the drawing logic.
            x0 = rng.randrange(0, 48)
            y0 = rng.randrange(0, 24)
            w  = rng.randrange(1, 12)
            h  = rng.randrange(1, 8)
            fbp = rng.choice([0, 1, 2])            # in 8 KB pages
            msk = rng.choice([0x00000000, 0x00000000, 0xFF000000, 0x0000FFFF])
            sc  = (rng.randrange(0, 8), rng.randrange(40, 64),
                   rng.randrange(0, 4), rng.randrange(20, 32))
            abe, alpha, clamp = blend_regs(rng)
            items = [(0x4C, fbp | (1 << 16) | (rng.choice([0, 0, 1]) << 24) | (msk << 32)),
                     (0x18, 0),
                     (0x40, sc[0] | (sc[1] << 16) | (sc[2] << 32) | (sc[3] << 48)),
                     (0x40 + 1, sc[0] | (sc[1] << 16) | (sc[2] << 32) | (sc[3] << 48)),
                     (0x42, alpha), (0x46, clamp),
                     (0x01, rng.randrange(1 << 32)),
                     (0x00, 6 | (abe << 6))]
            regs = 0
            for i in range(len(items)):
                regs |= 0xE << (4 * i)
            out.append(tag(1, 0, regs, len(items)))
            for a, d in items:
                out.append((d & ((1 << 64) - 1)) | (a << 64))
            out.append(tag(1, 1, 0xEE, 2))
            out.append(((x0 << 4) | (((y0 << 4)) << 16)) | (0x05 << 64))
            out.append((((x0 + w) << 4) | ((((y0 + h) << 4)) << 16)) | (0x05 << 64))
        elif pick < 0.34:
            # a triangle, strip or fan, generated coherently.  Kept small on
            # purpose: a large one is thousands of pixels at one per clock plus
            # a long divide per edge, and the interesting behaviour is at the
            # edges rather than in the middle.
            prim = rng.choice([3, 4, 5])
            nv   = 3 if prim == 3 else rng.choice([3, 4, 5])
            bx, by = rng.randrange(0, 40), rng.randrange(0, 20)
            msk = rng.choice([0x00000000, 0x00000000, 0xFF000000])
            sc  = (rng.randrange(0, 4), rng.randrange(40, 64),
                   rng.randrange(0, 4), rng.randrange(20, 32))
            abe, alpha, clamp = blend_regs(rng)
            # Gouraud half the time.  It is worth forcing rather than leaving to
            # a random PRIM because the interpolator is blocked in eights: a
            # triangle narrower than eight pixels never leaves lane 0 and never
            # touches the block step at all, so the widths below are chosen to
            # straddle a block boundary more often than not.
            iip = rng.choice([0, 0, 1, 1])
            items = [(0x4C, rng.choice([0, 1]) | (1 << 16) | (rng.choice([0, 0, 1]) << 24) | (msk << 32)),
                     (0x18, 0),
                     (0x40, sc[0] | (sc[1] << 16) | (sc[2] << 32) | (sc[3] << 48)),
                     (0x42, alpha), (0x46, clamp),
                     (0x01, rng.randrange(1 << 32)),
                     (0x00, prim | (iip << 3) | (abe << 6))]
            regs = 0
            for i in range(len(items)):
                regs |= 0xE << (4 * i)
            out.append(tag(1, 0, regs, len(items)))
            for a, d in items:
                out.append((d & ((1 << 64) - 1)) | (a << 64))
            # With Gouraud on, each vertex carries its own colour, so RGBAQ is
            # rewritten ahead of every XYZ2 rather than once for the primitive.
            per = 2 if iip else 1
            vr = 0
            for i in range(nv * per):
                vr |= 0xE << (4 * i)
            out.append(tag(1, 1, vr, nv * per))
            for _ in range(nv):
                vx = (bx + rng.randrange(0, 14)) * 16 + rng.randrange(0, 16)
                vy = (by + rng.randrange(0, 10)) * 16 + rng.randrange(0, 16)
                if iip:
                    out.append(rng.randrange(1 << 32) | (0x01 << 64))
                out.append((vx | (vy << 16)) | (0x05 << 64))
        elif pick < 0.46:
            # a host-to-local transfer of a small rectangle
            w = rng.randrange(1, 9)
            h = rng.randrange(1, 5)
            dx = rng.randrange(0, 32)
            dy = rng.randrange(0, 16)
            bp = rng.choice([0, 32, 64])          # 256-byte blocks
            out.append(tag(1, 0, 0xEEEE, 4))
            # DBP is at bits 45:32 and DBW at 53:48 -- the low bits are the
            # *source* pointer, so putting the base there left every transfer
            # writing to page zero and the base-pointer arithmetic untested.
            out.append((bp << 32) | (1 << 48) | (0x50 << 64))    # BITBLTBUF
            out.append((dx << 32) | (dy << 48) | (0x51 << 64))   # TRXPOS
            out.append((w | (h << 32)) | (0x52 << 64))           # TRXREG
            out.append(0 | (0x53 << 64))                         # TRXDIR
            npix = w * h
            nqw = (npix + 3) // 4
            out.append(tag(nqw, 1, 0, 1, flg=2))
            for i in range(nqw):
                qw = 0
                for j in range(4):
                    qw |= (rng.randrange(1 << 32)) << (32 * j)
                out.append(qw)
        elif pick < 0.30:
            # REGLIST: two registers per quadword
            nreg = rng.randrange(1, 5)
            nloop = rng.randrange(1, 4)
            regs = 0
            for i in range(nreg):
                regs |= rng.choice([0x0, 0x1, 0x2, 0x6, 0xA, 0xF]) << (4 * i)
            out.append(tag(nloop, 1, regs, nreg, flg=1))
            total = nloop * nreg
            for _ in range((total + 1) // 2):
                out.append(rng.getrandbits(128))
        else:
            # PACKED
            nreg = rng.randrange(1, 5)
            nloop = rng.randrange(1, 4)
            regs = 0
            descs = [rng.choice(DESCS) for _ in range(nreg)]
            for i, d in enumerate(descs):
                regs |= d << (4 * i)
            pre = rng.randrange(2)
            out.append(tag(nloop, 1, regs, nreg, pre=pre,
                           prim=rng.randrange(1 << 11)))
            for _ in range(nloop):
                for d in descs:
                    qw = rng.getrandbits(128)
                    if d == 0xE:
                        addr = rng.choice(AD_ADDRS)
                        qw = (qw & ((1 << 64) - 1)) | (addr << 64)
                    out.append(qw)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--tags", type=int, default=40)
    a = ap.parse_args()
    out = gen(random.Random(a.seed), a.tags)
    out = out[:4000]
    for w in out:
        print("%032x" % (w & ((1 << 128) - 1)))
    for _ in range(4096 - len(out)):
        print("%032x" % 0)


if __name__ == "__main__":
    main()
