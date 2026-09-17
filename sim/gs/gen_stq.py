#!/usr/bin/env python3
"""Perspective-divide cases for gs_stq, from gs_ref.stq_to_uv.

    sim/gs/gen_stq.py --seed 1 --out DIR

Writes cases.txt (s t q tw th) and ref.txt (u v, as signed decimals).

## What the cases are chosen to catch

* **Q at and near zero**, which games emit at the horizon and at the moment a
  vertex crosses the eye plane. The divide saturates rather than producing an
  infinity, and the coordinate then saturates again -- two different
  saturations, one after the other, and the second is the one no console has
  confirmed.
* **Every TW and TH**, because the multiply by 2**TW is an exponent add and an
  off-by-one there is a texture sampled at half or twice its size, which looks
  like a wrong TBW rather than a wrong exponent.
* **Coordinates either side of the 12.4 limit**, where the clip applies -- and
  the negative side saturates one further than the positive, which is easy to
  write symmetrically and wrong.
* **Values whose scaled magnitude lands just under and just over an integer**,
  because the conversion truncates toward zero rather than rounding.
* **Denormals and full exponents** in all three inputs, which the conditioner
  turns into a signed zero and into Fmax respectively.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse, os, random, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gs_ref                                                     # noqa: E402


def fbits(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


def cases(rng):
    out = []
    specials = [0x00000000, 0x80000000,          # zeros
                0x00000001, 0x807FFFFF,          # denormals -> signed zero
                0x7F800000, 0xFF800000,          # inf -> Fmax
                0x7FC00000,                      # NaN -> Fmax
                0x7F7FFFFF, 0xFF7FFFFF,          # Fmax
                0x00800000, 0x80800000,          # Fmin normal
                fbits(1.0), fbits(-1.0), fbits(0.5), fbits(2.0)]
    for q in specials:
        for st in specials:
            out.append((st, st, q, 6, 6))

    # Every TW/TH, on an ordinary coordinate.
    for tw in range(11):
        for th in range(11):
            out.append((fbits(0.37), fbits(0.61), fbits(1.0), tw, th))

    # Either side of the 12.4 limit, both signs. The limit is 2**18-1 in 12.4,
    # so a coordinate of 16384.0 texels is exactly at it.
    for mag in (16383.0, 16383.9, 16384.0, 16384.1, 32768.0, 1e9):
        for sgn in (1.0, -1.0):
            out.append((fbits(sgn * mag), fbits(sgn * mag), fbits(1.0), 0, 0))

    # Just under and just over a sixteenth, where truncation toward zero shows.
    for k in range(1, 40):
        base = k / 16.0
        for d in (-1e-6, 0.0, 1e-6):
            out.append((fbits(base + d), fbits(-(base + d)), fbits(1.0), 0, 0))

    # Small Q, where the divide grows without bound.
    for e in range(-40, 4, 4):
        out.append((fbits(1.0), fbits(1.0), fbits(2.0 ** e), 6, 6))

    for _ in range(900):
        out.append((rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32),
                    rng.randint(0, 10), rng.randint(0, 10)))
    # and a band of ordinary perspective-looking values
    for _ in range(600):
        z = rng.uniform(0.05, 50.0)
        out.append((fbits(rng.uniform(-4, 4)), fbits(rng.uniform(-4, 4)),
                    fbits(1.0 / z), rng.randint(0, 10), rng.randint(0, 10)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    os.makedirs(a.out, exist_ok=True)
    cs = cases(rng)
    with open(os.path.join(a.out, "cases.txt"), "w") as fc, \
         open(os.path.join(a.out, "ref.txt"), "w") as fr:
        for n, (s, t, q, tw, th) in enumerate(cs):
            u, v = gs_ref.stq_to_uv(s, t, q, tw, th)
            fc.write("%08x %08x %08x %d %d\n" % (s, t, q, tw, th))
            fr.write("%d %d %d\n" % (n, u, v))
    print("%d cases" % len(cs), file=sys.stderr)


if __name__ == "__main__":
    main()
