#!/usr/bin/env python3
"""Division cases for gs_fdiv, from ps2_float.

    sim/gs/gen_fdiv.py --seed 1 --out DIR

Writes cases.txt (a b, one pair per line) and ref.txt (the quotient).

## What the cases are chosen to catch

The PS2's float is not IEEE and every difference is a case here.

* **A zero divisor**, which is not an error: the result is the largest finite
  value with the signs exclusive-ored, because the format has no infinity. Zero
  divided by zero is the same answer, and both signs of both are included.
* **Denormal operands**, which read as a signed zero -- so a denormal dividend
  gives zero and a denormal divisor gives Fmax, and the two must not be
  confused.
* **A full exponent field**, which IEEE would call infinity or NaN and this
  format reads as the largest finite value. It can be handed one from memory
  even though the unit cannot produce one.
* **Overflow and underflow**, which saturate and flush rather than producing an
  infinity or a denormal: divisors near Fmin against dividends near Fmax, and
  the reverse.
* **Pairs whose quotient needs the very last mantissa bit.** The result is
  floored, not rounded, so a quotient just below a representable value and one
  just above it are different answers -- and a divider that computed a wider
  quotient and then rounded it would agree on almost everything else.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ee"))
import ps2_float as F                                             # noqa: E402

POS_MAX = 0x7F7FFFFF


def f(sign, exp, man):
    return (sign << 31) | (exp << 23) | man


def cases(rng):
    out = []
    specials = []
    for s in (0, 1):
        specials += [f(s, 0, 0),              # zero
                     f(s, 0, 1), f(s, 0, 0x7FFFFF),   # denormals -> signed zero
                     f(s, 255, 0), f(s, 255, 0x123456),  # inf/NaN -> Fmax
                     f(s, 254, 0x7FFFFF),     # Fmax
                     f(s, 1, 0),              # Fmin normal
                     f(s, 127, 0),            # 1.0
                     f(s, 128, 0),            # 2.0
                     f(s, 126, 0)]            # 0.5
    for a in specials:
        for b in specials:
            out.append((a, b))

    # Exponents at the ends, where saturation and flushing happen.
    for _ in range(400):
        ea = rng.choice([1, 2, 126, 127, 128, 253, 254])
        eb = rng.choice([1, 2, 126, 127, 128, 253, 254])
        out.append((f(rng.randint(0, 1), ea, rng.getrandbits(23)),
                    f(rng.randint(0, 1), eb, rng.getrandbits(23))))

    # Mantissas chosen so the exact quotient lands very close to a representable
    # value from both sides -- which is where flooring and rounding differ.
    for _ in range(400):
        mb = rng.getrandbits(23)
        B = 0x800000 | mb
        k = rng.randrange(0x800000, 0x1000000)
        for d in (-1, 0, 1):
            A = (k * B) // 0x800000 + d
            if 0x800000 <= A < 0x1000000:
                out.append((f(0, 127, A & 0x7FFFFF), f(0, 127, mb)))

    for _ in range(800):
        out.append((rng.getrandbits(32), rng.getrandbits(32)))
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
        for n, (x, y) in enumerate(cs):
            fc.write("%08x %08x\n" % (x, y))
            fr.write("%d %08x\n" % (n, F.div(x, y)[0]))
    print("%d cases" % len(cs), file=sys.stderr)


if __name__ == "__main__":
    main()
