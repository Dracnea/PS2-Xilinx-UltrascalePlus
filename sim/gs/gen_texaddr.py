#!/usr/bin/env python3
"""Vectors for gs_texaddr, taken from the reference model.

    sim/gs/gen_texaddr.py --seed 1 --out DIR

Writes `vec.txt`, one case per line: the inputs, then what sim/gs/gs_ref.py says
the answer is.  tb_texaddr.sv drives the inputs into the RTL and compares.

## What is being compared

The RTL reports every format as the same three numbers -- which 256-bit local
memory word, which bit in it, and how wide the texel is -- because that is what
a fetch from gs_lmem actually needs.  The model does not: it returns a word
address for the colour formats, a byte address for PSMT8, a *nibble* address for
PSMT4, and a word plus a half for the 16-bit ones.  So the conversion to the
common form happens here, in Python, and is written once per format below.

That conversion is part of what is under test.  It is deliberately written from
the units each model function documents itself as returning, rather than from
the RTL -- if it were derived from the RTL it would agree with it by
construction and the diff would prove nothing.

## What is deliberately not swept

**Page overflow.** The model's page arithmetic is unbounded; gs_addr_pkg's
resizes to nine bits and therefore wraps at 4 MB, which is what the hardware
does. They disagree past the end of memory, and that disagreement is inherited
from the frame-buffer addressing this builds on rather than introduced here. So
the cases are chosen to keep every address inside local memory, and the wrap is
left to whatever settles it for the rasteriser -- it is the same question.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gs_ref                                                    # noqa: E402

PSMS = [gs_ref.PSMCT32, gs_ref.PSMCT24, gs_ref.PSMCT16, gs_ref.PSMCT16S,
        gs_ref.PSMT8, gs_ref.PSMT4, gs_ref.PSMT8H,
        gs_ref.PSMT4HL, gs_ref.PSMT4HH]

NAMES = {gs_ref.PSMCT32: "PSMCT32", gs_ref.PSMCT24: "PSMCT24",
         gs_ref.PSMCT16: "PSMCT16", gs_ref.PSMCT16S: "PSMCT16S",
         gs_ref.PSMT8: "PSMT8", gs_ref.PSMT4: "PSMT4",
         gs_ref.PSMT8H: "PSMT8H", gs_ref.PSMT4HL: "PSMT4HL",
         gs_ref.PSMT4HH: "PSMT4HH"}


def expect(psm, tbp, tbw, u, v):
    """(lm_addr, bit_off, width) for a wrapped texel, from the model.

    One branch per storage granularity, each converting from the units that
    model function returns into the 256-bit word the RTL reports.
    """
    if psm == gs_ref.PSMT8:
        a = gs_ref.addr8(tbp, tbw, u, v)                 # bytes, 32 to a line
        return a >> 5, (a & 31) * 8, 8

    if psm == gs_ref.PSMT4:
        a = gs_ref.addr4(tbp, tbw, u, v)                 # nibbles, 64 to a line
        return a >> 6, (a & 63) * 4, 4

    if psm in (gs_ref.PSMCT16, gs_ref.PSMCT16S):
        a, half = gs_ref.addr16p(tbp >> 5, tbw, u, v,
                                 sform=(psm == gs_ref.PSMCT16S))
        return a >> 3, (a & 7) * 32 + half * 16, 16

    # PSMCT32, PSMCT24 and the three H formats are one 32-bit word, eight to a
    # line.  The H formats differ only in where inside that word they start:
    # the spare byte a 24-bit colour does not use, or one nibble of it.
    a = gs_ref.addr32(tbp, tbw, u, v)
    off = (a & 7) * 32
    if psm == gs_ref.PSMCT24:
        return a >> 3, off, 24
    if psm == gs_ref.PSMT8H:
        return a >> 3, off + 24, 8
    if psm == gs_ref.PSMT4HL:
        return a >> 3, off + 24, 4
    if psm == gs_ref.PSMT4HH:
        return a >> 3, off + 28, 4
    return a >> 3, off, 32


def page_shape(psm):
    """How many texels a page holds, as (width, height)."""
    if psm == gs_ref.PSMT8:
        return 128, 64
    if psm == gs_ref.PSMT4:
        return 128, 128
    if psm in (gs_ref.PSMCT16, gs_ref.PSMCT16S):
        return 64, 64
    return 64, 32


def cases(rng, n):
    """The cases, structured first and random after."""
    out = []

    # Every format, at the origin and at a handful of fixed places inside the
    # first page.  If a format is wrong at all it is usually wrong here, and a
    # failure at (0, 0) says something different from one at (17, 9).
    for psm in PSMS:
        for (u, v) in [(0, 0), (1, 0), (0, 1), (7, 7), (8, 8),
                       (15, 15), (16, 16), (17, 9), (31, 31), (63, 31)]:
            out.append(dict(psm=psm, u=u, v=v, tbp=0, tbw=1, tw=10, th=10,
                            wms=0, wmt=0, minu=0, maxu=0, minv=0, maxv=0))

    # Exhaustively over one page of each indexed format.  These are the maps
    # this unit adds -- everything else it inherits from gs_addr_pkg -- and a
    # page is small enough to sweep completely, so there is no reason to sample
    # it.  A wire permutation that is right on 400 random texels and wrong on
    # one is exactly the fault a sweep catches and sampling does not.
    for psm in (gs_ref.PSMT8, gs_ref.PSMT4):
        w, h = page_shape(psm)
        for v in range(h):
            for u in range(w):
                out.append(dict(psm=psm, u=u, v=v, tbp=0, tbw=2, tw=10, th=10,
                                wms=0, wmt=0, minu=0, maxu=0, minv=0, maxv=0))

    # Multi-page, which is where TBW's units bite.  TBW counts 64 texels
    # whatever the format, so an indexed page -- 128 texels across -- is TBW/2
    # of them.  A texture exactly one page wide comes out perfect with the
    # halving forgotten, so these cases cross a page boundary in both axes on
    # purpose.
    for psm in PSMS:
        w, h = page_shape(psm)
        for tbw in (2, 4, 8):
            for (u, v) in [(w - 1, 0), (w, 0), (w + 1, 0), (2 * w, 0),
                           (0, h - 1), (0, h), (0, h + 1), (0, 2 * h),
                           (w, h), (w + 13, h + 5), (3 * w - 1, 2 * h - 1)]:
                out.append(dict(psm=psm, u=u, v=v, tbp=0, tbw=tbw,
                                tw=10, th=10, wms=0, wmt=0,
                                minu=0, maxu=0, minv=0, maxv=0))

    # A base that is not page zero, and one that is not page-aligned either.
    # Both the model and gs_addr_pkg take TBP in 64-word blocks and use only
    # bits 13:5 of it, so a base part-way into a page names the page it is in --
    # they agree because they do the same thing, and this pins that down rather
    # than leaving it as two independent truncations that happen to match.
    for psm in PSMS:
        for tbp in (32, 64, 32 * 17, 32 * 17 + 5, 32 * 200):
            out.append(dict(psm=psm, u=5, v=3, tbp=tbp, tbw=2, tw=10, th=10,
                            wms=0, wmt=0, minu=0, maxu=0, minv=0, maxv=0))

    # The wrap modes, on both axes, including negative coordinates -- which is
    # the whole reason the coordinate is signed.  REGION_REPEAT is given MINU
    # and MAXU as a mask and an or rather than as bounds, because that is what
    # it does with them.
    for wms in range(4):
        for wmt in range(4):
            for (u, v) in [(-1, -1), (-8, 3), (300, -300), (5, 5),
                           (1023, 1023), (1024, 1024), (2047, -2048)]:
                out.append(dict(psm=gs_ref.PSMT8, u=u, v=v, tbp=0, tbw=2,
                                tw=6, th=5, wms=wms, wmt=wmt,
                                minu=0x1F, maxu=0x08, minv=0x0F, maxv=0x03))

    # Small TW/TH, where REPEAT actually folds.
    for tw in range(0, 11):
        for u in (0, 1, 7, 33, 255, 1000, -1, -33):
            out.append(dict(psm=gs_ref.PSMCT32, u=u, v=u, tbp=0, tbw=1,
                            tw=tw, th=tw, wms=0, wmt=0,
                            minu=0, maxu=0, minv=0, maxv=0))

    # Random, to cover what the structure above did not think of.
    for _ in range(n):
        psm = rng.choice(PSMS)
        tbw = rng.choice([1, 2, 4, 8, 16])
        out.append(dict(
            psm=psm,
            u=rng.randint(-2048, 2047), v=rng.randint(-2048, 2047),
            tbp=rng.randrange(0, 32 * 180), tbw=tbw,
            tw=rng.randint(0, 10), th=rng.randint(0, 10),
            wms=rng.randint(0, 3), wmt=rng.randint(0, 3),
            minu=rng.randint(0, 1023), maxu=rng.randint(0, 1023),
            minv=rng.randint(0, 1023), maxv=rng.randint(0, 1023)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--random", type=int, default=4000,
                    help="how many random cases after the structured ones")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    rows, skipped = [], 0
    for c in cases(rng, a.random):
        u = gs_ref.wrap(c["u"], c["wms"], c["minu"], c["maxu"], 1 << c["tw"])
        v = gs_ref.wrap(c["v"], c["wmt"], c["minv"], c["maxv"], 1 << c["th"])
        lm, off, w = expect(c["psm"], c["tbp"], c["tbw"], u, v)
        # See the module docstring: past the end of local memory the model and
        # the hardware's nine-bit page disagree, and that is not this unit's
        # question to settle.
        if lm >= (1 << 17):
            skipped += 1
            continue
        rows.append("%d %d %d %d %d %d %d %d %d %d %d %d %d  %d %d %d %d %d" % (
            c["u"], c["v"], c["tbp"], c["tbw"], c["psm"], c["tw"], c["th"],
            c["wms"], c["wmt"], c["minu"], c["maxu"], c["minv"], c["maxv"],
            lm, off, w, u, v))

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "vec.txt"), "w") as f:
        f.write("\n".join(rows) + "\n")
    print("%d cases (%d past the end of memory, skipped)" % (len(rows), skipped),
          file=sys.stderr)


if __name__ == "__main__":
    main()
