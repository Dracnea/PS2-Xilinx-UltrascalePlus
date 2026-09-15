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
