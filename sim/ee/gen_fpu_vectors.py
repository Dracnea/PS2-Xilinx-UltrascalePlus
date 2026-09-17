#!/usr/bin/env python3
"""Operand pairs that straddle every boundary the conditioner has.

    sim/ee/gen_fpu_vectors.py [--random N] > vectors.hex

Random 32-bit patterns are nearly useless here: almost all of them are ordinary
normals with a middling exponent, and the conditioner's whole job is at the two
ends. So the corners are enumerated -- zero of both signs, the smallest and
largest denormal, the smallest normal, the largest finite value, the exponent
255 patterns an IEEE machine would call infinity and NaN -- and random pairs are
added on top rather than relied upon.
"""
import argparse
import random
import sys

CORNERS = [
    0x00000000,  # +0
    0x80000000,  # -0
    0x00000001,  # the smallest denormal, which reads as +0
    0x807FFFFF,  # the largest negative denormal, which reads as -0
    0x00800000,  # the smallest normal
    0x80800000,
    0x3F800000,  # 1.0
    0xBF800000,  # -1.0
    0x3F7FFFFF,  # just below 1.0
    0x40000000,  # 2.0
    0x7F7FFFFF,  # the largest finite value
    0xFF7FFFFF,
    0x7F800000,  # what IEEE calls +inf; reads as the largest finite
    0xFF800000,
    0x7FC00000,  # a quiet NaN; reads as the largest finite too
    0xFFFFFFFF,  # every bit set: exponent 255, so also the largest finite
    0x007FFFFF,  # the largest positive denormal
    0x00000000,
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--random", type=int, default=600)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    out = []
    # Every corner against every corner: 324 pairs, and the comparisons care
    # about the pairing, not just the operands.
    for x in CORNERS:
        for y in CORNERS:
            out.append((x, y))

    # ---- pairs chosen for the multiply -------------------------------------
    #
    # The corners above were chosen for the conditioner, and they say almost
    # nothing about MUL.S: its interesting behaviour is at the *exponent* ends,
    # where the product saturates or flushes, and at the truncation boundary,
    # where the exact 48-bit product has bits below the cut. docs/ee-fpu.md asks
    # for exactly this sweep -- "pairs whose exact product needs bit 24".
    def f(sign, exp, man):
        return (sign << 31) | (exp << 23) | man

    ONE   = f(0, 127, 0)                 # 1.0
    TWO   = f(0, 128, 0)                 # 2.0
    HALF  = f(0, 126, 0)                 # 0.5
    BIG   = f(0, 254, 0x7FFFFF)          # Fmax
    SMALL = f(0, 1, 0)                   # the smallest normal

    # Saturation at both ends: a product that wants an exponent past 127, and
    # one that wants an exponent below -126. Both signs, because the flag is the
    # same but the saturated value is not.
    for sa in (0, 1):
        for sb in (0, 1):
            mul_pairs = [
                (f(sa, 254, 0), f(sb, 254, 0)),        # overflows hard
                (f(sa, 200, 0), f(sb, 200, 0)),        # overflows
                (f(sa, 1, 0),   f(sb, 1, 0)),          # underflows hard
                (f(sa, 60, 0),  f(sb, 60, 0)),         # underflows
                (f(sa, 127, 0), f(sb, 127, 0)),        # 1 x 1, no shift
                (f(sa, 254, 0x7FFFFF), f(sb, 1, 0)),   # Fmax x smallest normal
            ]
            for x, y in mul_pairs:
                out.append((x, y))

    # Exactly on the boundary: exponent sums that land on 127 and on -126, so
    # that one place of normalisation decides between a number and a saturation.
    # A multiplier that normalised before choosing the exponent, or after, gets
    # one of these wrong and every ordinary product right.
    for ma in (0, 0x400000, 0x7FFFFF):
        for mb in (0, 0x400000, 0x7FFFFF):
            out.append((f(0, 191, ma), f(0, 190, mb)))   # around the top
            out.append((f(0, 64, ma),  f(0, 63, mb)))    # around the bottom

    # Truncation: mantissas whose exact product has bits below the cut. A
    # multiplier that rounds to nearest instead of truncating differs from the
    # model by one in the last place on most of these, and on none of the pairs
    # above.
    for ma in (0x000001, 0x000003, 0x7FFFFF, 0x555555, 0x2AAAAB, 0x400001):
        for mb in (0x000001, 0x7FFFFF, 0x333333, 0x400001, 0x000002):
            out.append((f(0, 127, ma), f(0, 127, mb)))
            out.append((f(1, 127, ma), f(0, 130, mb)))

    out += [(ONE, BIG), (BIG, ONE), (TWO, HALF), (HALF, TWO),
            (SMALL, BIG), (BIG, SMALL), (BIG, BIG), (SMALL, SMALL)]

    rng = random.Random(a.seed)
    for _ in range(a.random):
        # Bias the exponent toward the ends, where the interesting behaviour is.
        def one():
            e = rng.choice([0, 0, 1, 127, 128, 254, 255, 255, rng.randrange(256)])
            return (rng.randrange(2) << 31) | (e << 23) | rng.randrange(1 << 23)
        out.append((one(), one()))

    for x, y in out:
        print("%08x %08x" % (x, y))
    return 0


if __name__ == "__main__":
    sys.exit(main())
