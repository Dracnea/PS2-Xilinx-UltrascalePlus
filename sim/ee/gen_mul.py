#!/usr/bin/env python3
"""Emit a directed MULT/MULTU program covering the corners a random stream misses.

    sim/ee/gen_mul.py > mul.hex

The multiplier is pipelined and shares one 33-bit signed unit between MULT and
MULTU, so the cases that matter are the ones where the sign treatment of the
operands decides the answer: full-width negatives, INT_MIN squared, and the
values whose unsigned and signed products differ in the high word.  rd = 0 is
included because MULT is three-operand on the R5900 and rd = 0 is the
MIPS-compatible encoding that must write HI and LO but no register.
"""

CASES = [
    (0x00000000, 0x00000000),
    (0x00000002, 0x00000003),
    (0xFFFFFFFF, 0xFFFFFFFF),   # -1 * -1 signed = 1; unsigned = 0xFFFFFFFE00000001
    (0xFFFFFFFF, 0x00000001),   # -1 * 1
    (0x80000000, 0x80000000),   # INT_MIN squared
    (0x80000000, 0xFFFFFFFF),   # INT_MIN * -1
    (0x7FFFFFFF, 0x7FFFFFFF),   # INT_MAX squared
    (0x7FFFFFFF, 0x00000002),   # overflows the low word
    (0xFFFF0000, 0x0000FFFF),   # high word carries
    (0x12345678, 0x9ABCDEF0),   # one negative, one positive as signed
    (0x00010000, 0x00010000),   # exactly 2^32, low word zero
    (0xFFFFFFFE, 0x00000002),   # -2 * 2
    (0x0000FFFF, 0xFFFF0001),
    (0x80000001, 0x00000003),
]


def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def mult(rs, rt, rd): return (rs << 21) | (rt << 16) | (rd << 11) | 24
def multu(rs, rt, rd):return (rs << 21) | (rt << 16) | (rd << 11) | 25
def mfhi(rd):         return (rd << 11) | 16
def mflo(rd):         return (rd << 11) | 18


def main():
    out = []
    for n, d in CASES:
        out += [lui(1, n >> 16), ori(1, 1, n & 0xFFFF),
                lui(2, d >> 16), ori(2, 2, d & 0xFFFF),
                mult(1, 2, 3), mfhi(4), mflo(5),        # three-operand form
                multu(1, 2, 6), mfhi(7), mflo(8),
                mult(1, 2, 0), multu(1, 2, 0)]          # rd = 0: HI/LO only
    for w in out:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(out)):
        print("00000000")


if __name__ == "__main__":
    main()
