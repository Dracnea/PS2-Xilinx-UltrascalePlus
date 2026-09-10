#!/usr/bin/env python3
"""Emit a directed DIV/DIVU program covering the corners a random stream misses.

    sim/ee/gen_div.py > div.hex

A random generator produces divides, but almost never the ones that matter:
division by zero, INT_MIN / -1, and the four sign combinations that decide
whether the quotient truncates toward zero and whether the remainder follows
the dividend.  Those are exactly the cases where an iterative divider and a
`/` operator part company, so they are enumerated here rather than hoped for.

Each case materialises both operands with LUI/ORI, runs DIV and DIVU on them,
and reads HI and LO back.  The trace carries HI and LO on every line, so the
MFHI/MFLO pair is there to prove the read path agrees too, not to capture the
result.
"""

CASES = [
    (0x00000000, 0x00000000),   # 0 / 0            -- divide by zero
    (0x00000001, 0x00000000),   # 1 / 0
    (0xFFFFFFFF, 0x00000000),   # -1 / 0           -- negative dividend, zero divisor
    (0x80000000, 0x00000000),   # INT_MIN / 0
    (0x00000007, 0x00000002),   # +7 / +2
    (0xFFFFFFF9, 0x00000002),   # -7 / +2          -- quotient truncates toward zero
    (0x00000007, 0xFFFFFFFE),   # +7 / -2
    (0xFFFFFFF9, 0xFFFFFFFE),   # -7 / -2          -- remainder takes the dividend's sign
    (0x80000000, 0xFFFFFFFF),   # INT_MIN / -1     -- the overflow case
    (0x80000000, 0x00000001),   # INT_MIN / 1
    (0x7FFFFFFF, 0xFFFFFFFF),   # INT_MAX / -1
    (0xFFFFFFFF, 0xFFFFFFFF),   # -1 / -1
    (0x00000001, 0x00000001),   # 1 / 1
    (0xFFFFFFFF, 0x00000003),   # unsigned 4294967295 / 3, signed -1 / 3
    (0x12345678, 0x00001000),   # exact power-of-two divisor
    (0x00000005, 0x00000007),   # quotient 0, remainder is the whole dividend
    (0xFFFFFFFB, 0x00000007),   # -5 / +7
    (0x00000005, 0xFFFFFFF9),   # +5 / -7
    (0xFFFFFFFB, 0xFFFFFFF9),   # -5 / -7
    (0x80000001, 0xFFFFFFFF),   # (INT_MIN+1) / -1
    (0xFFFFFFFF, 0x80000000),   # -1 / INT_MIN
    (0x80000000, 0x80000000),   # INT_MIN / INT_MIN
    (0x0000FFFF, 0x00010000),   # divisor larger than the dividend
    (0xFFFF0001, 0x0000FFFF),   # borrow across the halfword boundary
]


def lui(rt, imm):   return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def div(rs, rt):    return (rs << 21) | (rt << 16) | 26
def divu(rs, rt):   return (rs << 21) | (rt << 16) | 27
def mfhi(rd):       return (rd << 11) | 16
def mflo(rd):       return (rd << 11) | 18


def main():
    out = []
    for i, (n, d) in enumerate(CASES):
        out += [lui(1, n >> 16), ori(1, 1, n & 0xFFFF),
                lui(2, d >> 16), ori(2, 2, d & 0xFFFF),
                div(1, 2), mfhi(3), mflo(4),
                divu(1, 2), mfhi(5), mflo(6)]
    for w in out:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(out)):
        print("00000000")
    return len(out)


if __name__ == "__main__":
    main()
