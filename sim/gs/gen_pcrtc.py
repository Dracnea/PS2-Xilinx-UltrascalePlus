#!/usr/bin/env python3
"""Build one PCRTC case: a memory image, a register set, and the frame it makes.

    sim/gs/gen_pcrtc.py --seed N --out DIR

Writes into DIR:
    mem.hex     the local memory, one 256-bit word per line
    cfg.txt     the raster totals and the privileged registers
    ref.txt     the frame the reference model produces, one pixel per line

The memory is filled with a *position-dependent* pattern rather than random
words, and that is the point of it: a colour that encodes the pixel's own x and
y makes a picture that is shifted, mirrored, magnified wrongly or read from the
wrong page identifiable from the pixel values alone.  Random words would make
every such fault look the same -- wrong -- and none of them diagnosable.

The rasters here are small.  A PCRTC case is not interesting because it is big:
every fault this can find shows up within a few source pixels of the display
area's corner, and a 640 x 480 frame is 300,000 lines of simulation output to
say the same thing as 2,000.
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gs_ref import addr32p, addr16p, pack16
from pcrtc_ref import PCRTC

# Eight 8 KB pages.  Addresses from gs_ref are in *32-bit words*, which is what
# the swizzle names; local memory is 256 bits wide, so the image written out has
# eight of these per line.  Keeping the model in 32-bit words and converting
# once, here, is what stops the two units being mixed up in the arithmetic.
PAGES = 8
MEM_WORDS = PAGES * 2048              # 32-bit words
MEM_LINES = MEM_WORDS // 8            # 256-bit words
M32 = 0xFFFFFFFF


def fill(mem, fbp, fbw, psm, w, h, second=False):
    """Draw a position-encoding pattern into one frame buffer.

    Each pixel carries its own coordinates: red is x, green is y, blue is a
    checker so that a buffer read one pixel off is visible even where x and y
    are small, and alpha ramps with x so that the merge's MMOD = 0 path -- which
    blends by circuit 1's alpha -- has something that varies to blend by.

    `second` gives the *other* read circuit's buffer a visibly different
    pattern, and it is here because mutation testing said it had to be.  With
    both buffers carrying the same pattern, two circuits laid over the same area
    blend a colour with itself -- and a blend of a colour with itself is that
    colour for *every* alpha, so the whole merge, including PSMCT24's alpha byte
    reading back as zero, was unfalsifiable in exactly the cases written to test
    it.
    """
    for y in range(h):
        for x in range(w):
            if second:
                rgba = (((255 - x) & 0xFF)
                        | (((y * 5 + 37) & 0xFF) << 8)
                        | (((((x ^ y) & 1) ^ 1) * 0xC0 | 0x20) << 16)
                        | (((200 - x * 3) & 0xFF) << 24))
            else:
                rgba = ((x & 0xFF)
                        | ((y & 0xFF) << 8)
                        | ((((x ^ y) & 1) * 0xC0 | 0x10) << 16)
                        | ((x * 3 & 0xFF) << 24))
            if psm in (0x00, 0x01):
                mem[addr32p(fbp, fbw, x, y)] = rgba
            else:
                a, half = addr16p(fbp, fbw, x, y, sform=(psm == 0x0A))
                v = pack16(rgba)
                old = mem[a]
                if half:
                    mem[a] = (old & 0x0000FFFF) | (v << 16)
                else:
                    mem[a] = (old & 0xFFFF0000) | v


def circuit(rng, fbp, psm, htotal, vtotal):
    """One (DISPFB, DISPLAY) pair, and the source size it implies."""
    magh = rng.choice([0, 0, 1, 3])           # 1x, 1x, 2x, 4x
    magv = rng.choice([0, 0, 1])              # 1x, 1x, 2x
    dx = rng.randrange(0, max(1, htotal // 3))
    dy = rng.randrange(0, max(1, vtotal // 3))
    dw = rng.randrange(8, htotal - dx)        # in output clocks
    dh = rng.randrange(4, vtotal - dy)
    dbx = rng.choice([0, 0, 1, 7, 8, 16])
    dby = rng.choice([0, 0, 1, 3, 8])
    fbw = 1                                   # 64 pixels
    dispfb = (fbp | (fbw << 9) | (psm << 15) | (dbx << 32) | (dby << 43))
    display = (dx | (dy << 12) | (magh << 23) | (magv << 27)
               | ((dw - 1) << 32) | ((dh - 1) << 44))
    # the source rectangle the area actually reads, so the pattern covers it
    sw = dbx + -(-dw // (magh + 1)) + 1
    sh = dby + -(-dh // (magv + 1)) + 1
    return dispfb, display, min(sw, 64), min(sh, 64), fbw


# Fully specified cases, for the corners the random ones do not reach.
#
# Two of them exist because mutation testing said so.  Reading PSMCT16S with
# PSMCT16's block order survives every random case, because the two orders only
# disagree from x = 32 or y = 16 onwards and a randomly placed, randomly
# magnified display area rarely reads that far into its buffer.  And PSMCT24's
# alpha byte -- which the manual says reads back as zero rather than as whatever
# the rasteriser last left there -- is only observable when it is the alpha the
# merge blends by, which needs both circuits on, overlapping, with MMOD = 0.
#
# Each entry gives the raster, then per circuit (psm, dx, dy, dw, dh, magh,
# magv, dbx, dby), then the merge fields.
CASES = {
    # the whole of a 64 x 64 buffer, unmagnified, one format at a time
    "wide32":  (80, 72, [(0x00, 0, 0, 64, 64, 1, 1, 0, 0), None], 0, 0, 0x80),
    "wide24":  (80, 72, [(0x01, 0, 0, 64, 64, 1, 1, 0, 0), None], 0, 0, 0x80),
    "wide16":  (80, 72, [(0x02, 0, 0, 64, 64, 1, 1, 0, 0), None], 0, 0, 0x80),
    "wide16s": (80, 72, [(0x0A, 0, 0, 64, 64, 1, 1, 0, 0), None], 0, 0, 0x80),
    # the same through every magnification, so the counters are swept
    "mag2h":   (80, 72, [(0x00, 4, 3, 64, 40, 2, 1, 2, 1), None], 0, 0, 0x80),
    "mag4h":   (80, 72, [(0x0A, 4, 3, 64, 40, 4, 1, 2, 1), None], 0, 0, 0x80),
    "mag2v":   (80, 72, [(0x02, 4, 3, 64, 64, 1, 2, 2, 1), None], 0, 0, 0x80),
    "mag16h":  (80, 72, [(0x00, 0, 0, 64, 64, 16, 1, 0, 0), None], 0, 0, 0x80),
    # both circuits over the same area, blending by circuit 1's alpha
    "merge32": (64, 48, [(0x00, 0, 0, 64, 48, 1, 1, 0, 0),
                         (0x00, 0, 0, 64, 48, 1, 1, 0, 0)], 0, 0, 0x80),
    "merge24": (64, 48, [(0x01, 0, 0, 64, 48, 1, 1, 0, 0),
                         (0x00, 0, 0, 64, 48, 1, 1, 0, 0)], 0, 0, 0x80),
    "merge16": (64, 48, [(0x02, 0, 0, 64, 48, 1, 1, 0, 0),
                         (0x0A, 0, 0, 64, 48, 1, 1, 0, 0)], 0, 0, 0x80),
    # and by ALP, with and without the background underneath
    "alp":     (64, 48, [(0x00, 0, 0, 64, 48, 1, 1, 0, 0),
                         (0x00, 0, 0, 64, 48, 1, 1, 0, 0)], 1, 0, 0x40),
    "slbg":    (64, 48, [(0x00, 8, 4, 40, 30, 1, 1, 0, 0),
                         (0x00, 0, 0, 64, 48, 1, 1, 0, 0)], 1, 1, 0xC0),
}


def directed(name):
    """(htotal, vtotal, dispfb[2], display[2], en1, en2, pmode, patterns)."""
    htotal, vtotal, cs, mmod, slbg, alp = CASES[name]
    fb = [0, 0]
    dp = [0, 0]
    en = [0, 0]
    pat = []
    for n, c in enumerate(cs):
        if c is None:
            continue
        psm, dx, dy, dw, dh, magh, magv, dbx, dby = c
        en[n] = 1
        fbp = [0, 4][n]
        fbw = 1
        fb[n] = fbp | (fbw << 9) | (psm << 15) | (dbx << 32) | (dby << 43)
        dp[n] = (dx | (dy << 12) | ((magh - 1) << 23) | ((magv - 1) << 27)
                 | ((dw - 1) << 32) | ((dh - 1) << 44))
        sw = min(dbx + -(-dw // magh) + 1, 64)
        sh = min(dby + -(-dh // magv) + 1, 64)
        pat.append((n, fbp, fbw, psm, sw, sh))
    pmode = en[0] | (en[1] << 1) | (1 << 2) | (mmod << 5) | (slbg << 7) | (alp << 8)
    return htotal, vtotal, fb, dp, pmode, pat


def emit(out, htotal, vtotal, mem, pmode, fb, dp, bgcolor):
    """Write the memory image, the register set, and the model's frame."""
    with open(os.path.join(out, "mem.hex"), "w") as f:
        for i in range(MEM_LINES):
            line = 0
            for j in range(8):
                line |= mem[8 * i + j] << (32 * j)
            f.write("%064x\n" % line)

    with open(os.path.join(out, "cfg.txt"), "w") as f:
        f.write("%d %d\n" % (htotal, vtotal))
        for v in (pmode, fb[0], dp[0], fb[1], dp[1], bgcolor):
            f.write("%016x\n" % v)

    p = PCRTC(htotal, vtotal)
    p.write(0x00, pmode)
    p.write(0x70, fb[0]); p.write(0x80, dp[0])
    p.write(0x90, fb[1]); p.write(0xA0, dp[1])
    p.write(0xE0, bgcolor)
    with open(os.path.join(out, "ref.txt"), "w") as f:
        for y in range(vtotal):
            for x in range(htotal):
                f.write("%4d %4d %06x\n" % (x, y, p.pixel(mem, x, y)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    ap.add_argument("--both", action="store_true",
                    help="force both read circuits on, to reach the merge")
    ap.add_argument("--case", choices=sorted(CASES),
                    help="one of the fully specified cases instead of a random one")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)

    if args.case:
        htotal, vtotal, fb, dp, pmode, pat = directed(args.case)
        mem = [0] * MEM_WORDS
        for n, fbp, fbw, psm, sw, sh in pat:
            fill(mem, fbp, fbw, psm, sw, sh, second=(n == 1))
        bgcolor = 0x3399CC
        emit(args.out, htotal, vtotal, mem, pmode, fb, dp, bgcolor)
        print("case %s: %dx%d raster" % (args.case, htotal, vtotal),
              file=sys.stderr)
        return

    htotal = rng.randrange(40, 96)
    vtotal = rng.randrange(20, 40)

    mem = [0] * MEM_WORDS

    en1 = 1 if args.both else rng.choice([1, 1, 1, 0])
    en2 = 1 if args.both else rng.choice([0, 0, 1])
    if not en1 and not en2:
        en1 = 1

    # Two separate pages, so a circuit reading the other's buffer is visible.
    fbps = [0, 4]
    psms = [rng.choice([0x00, 0x00, 0x01, 0x02, 0x0A]) for _ in range(2)]

    fb = [0, 0]
    dp = [0, 0]
    for n in range(2):
        fb[n], dp[n], sw, sh, fbw = circuit(rng, fbps[n], psms[n], htotal, vtotal)
        fill(mem, fbps[n], fbw, psms[n], sw, sh, second=(n == 1))

    mmod = rng.randint(0, 1)
    slbg = rng.randint(0, 1)
    alp = rng.choice([0x00, 0x40, 0x80, 0xFF])
    # CRTMD is always 001 on hardware; it is written so that a decoder that
    # reads EN1 and EN2 from the wrong bits fails here rather than by accident.
    pmode = en1 | (en2 << 1) | (1 << 2) | (mmod << 5) | (slbg << 7) | (alp << 8)
    bgcolor = rng.randrange(0, 1 << 24)

    emit(args.out, htotal, vtotal, mem, pmode, fb, dp, bgcolor)

    print("seed %d: %dx%d raster, EN=%d%d psm=%02x/%02x mmod=%d slbg=%d alp=%02x"
          % (args.seed, htotal, vtotal, en2, en1, psms[0], psms[1],
             mmod, slbg, alp), file=sys.stderr)


if __name__ == "__main__":
    main()
