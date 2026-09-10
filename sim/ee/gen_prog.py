#!/usr/bin/env python3
"""Emit a random R5900 integer program, for differential testing.

    sim/ee/gen_prog.py --seed 1 --count 200 > prog.hex

Hand-written tests probe what the author already thought of.  These probe the
encoding space instead, and the reference makes them self-checking.

Two constraints keep a random program meaningful rather than merely legal:
loads and stores are aimed at a scratch area well clear of the code, so a
program cannot rewrite itself and make the two models diverge for reasons that
have nothing to do with the instruction under test; and r0 is never used as a
destination where that would make the instruction a no-op worth nothing.
"""
import argparse, random

SCRATCH = 0x2000          # well past any generated program


def gen(rng, n, branches):
    out = []
    # seed some registers so the first instructions are not all zero-in
    for r in range(1, 8):
        out.append(0x24000000 | (r << 16) | (rng.randrange(0x10000)))       # addiu r,r0,imm
    for r in range(8, 12):
        out.append(0x3C000000 | (r << 16) | rng.randrange(0x10000))         # lui
    while len(out) < n:
        pick = rng.random()
        rs, rt, rd = rng.randrange(32), rng.randrange(32), rng.randrange(1, 32)
        sa = rng.randrange(32)
        if pick < 0.34:                                    # SPECIAL, register ops
            fn = rng.choice([0, 2, 3, 4, 6, 7, 16, 18, 24, 25, 26, 27,
                             32, 33, 34, 35, 36, 37, 38, 39, 42, 43,
                             45, 47, 56, 58, 59, 60, 62, 63])
            out.append((rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn)
        elif pick < 0.60:                                  # immediate ops
            op = rng.choice([8, 9, 10, 11, 12, 13, 14, 15, 25])
            out.append((op << 26) | (rs << 21) | (rd << 16) | rng.randrange(0x10000))
        elif pick < 0.78:                                  # stores into scratch
            op = rng.choice([40, 41, 43, 63])
            off = SCRATCH + rng.randrange(0, 0x400, 8)
            out.append((op << 26) | (0 << 21) | (rt << 16) | (off & 0xFFFF))
        elif pick < 0.92:                                  # loads from scratch
            op = rng.choice([32, 33, 35, 36, 37, 39, 55])
            off = SCRATCH + rng.randrange(0, 0x400, 8)
            out.append((op << 26) | (0 << 21) | (rd << 16) | (off & 0xFFFF))
        elif pick < 0.96:                                  # unaligned accesses
            # These are the only instructions here whose behaviour depends on
            # the low bits of the address, so the offset is deliberately not
            # aligned -- every other memory operation above is on an eight-byte
            # boundary, and an unaligned form at an aligned address exercises
            # exactly one of its four or eight cases.
            op = rng.choice([34, 38, 42, 46, 26, 27, 44, 45])
            off = SCRATCH + rng.randrange(0, 0x400)
            out.append((op << 26) | (0 << 21) | (rd << 16) | (off & 0xFFFF))
        elif branches:
            # only ever forward, only ever a couple of instructions, so the
            # program cannot leave itself
            op = rng.choice([4, 5, 6, 7])
            out.append((op << 26) | (rs << 21) | (rt << 16) | rng.choice([1, 2]))
        else:
            out.append(0x00000020 | (rs << 21) | (rt << 16) | (rd << 11))    # ADD
    return out[:n]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--branches", action="store_true")
    ap.add_argument("--pad", type=int, default=4096)
    a = ap.parse_args()
    prog = gen(random.Random(a.seed), a.count, a.branches)
    for w in prog:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(a.pad - len(prog)):
        print("00000000")


if __name__ == "__main__":
    main()
