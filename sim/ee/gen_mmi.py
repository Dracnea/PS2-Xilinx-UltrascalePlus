#!/usr/bin/env python3
"""Emit a directed MMI0/MMI1 program -- the parallel ALU, at its corners.

    sim/ee/gen_mmi.py > mmi.hex

The random programs reach these instructions but not their interesting inputs.
Mutating the RTL and re-running three seeds, a swap of PMAX and PMIN was caught
by one seed of three: a random register holds a value that happens to compare
one way, and saturation needs operands that actually overflow their lane.

So the operands here are built from the corners of each lane width and nothing
else: 0x7F, 0x80, 0xFF, 0x01 as bytes, which read as 0x7F7F / 0x8080 / 0x7FFF /
0x8000-shaped halfwords and as 0x7F80FF01-shaped words, so one pair of registers
puts every width against its own maximum, its own minimum, minus one and one.
Saturation is then not a rare event but the normal case, and the difference
between wrapping, signed-saturating and unsigned-saturating forms shows on
nearly every lane rather than on nearly none.

Every defined sub-opcode of both tables is emitted against every operand pair,
so a width mixed up between two arms -- the saturation bound that is right at 16
bits and wrong at 8 -- has nowhere to hide.
"""

MMI0_SA = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
           0x10, 0x11, 0x14, 0x15, 0x18, 0x19]
MMI1_SA = [0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x0A,
           0x10, 0x11, 0x14, 0x15, 0x18, 0x19]

# (high 64 bits, low 64 bits) for each operand register.  Chosen so that every
# lane width sees a maximum, a minimum, a minus one and a one.
PAIRS = [
    ((0x7F7F7F7F7F7F7F7F, 0x8080808080808080),
     (0x0101010101010101, 0xFFFFFFFFFFFFFFFF)),
    ((0x7FFFFFFF80000000, 0xFFFFFFFF00000001),
     (0x0000000100000001, 0x800000007FFFFFFF)),
    ((0x8000800080008000, 0x7FFF7FFF7FFF7FFF),
     (0xFFFFFFFFFFFFFFFF, 0x0001000100010001)),
    ((0x0123456789ABCDEF, 0xFEDCBA9876543210),
     (0x8000000080000000, 0x7F0180FF017F80FF)),
]


def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def dsll32(rd, rt, sa): return sp(0, rt, rd, sa, 60)
def or_(rd, rs, rt):  return sp(rs, rt, rd, 0, 37)
def pcpyld(rd, rs, rt): return (28 << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (0x0E << 6) | 0x09
def mmi(fn, sa, rd, rs, rt):
    return (28 << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn


def load64(r, v, tmp=2):
    """r = a 64-bit constant, through a scratch register."""
    hi, lo = (v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF
    return [lui(r, lo >> 16), ori(r, r, lo & 0xFFFF),
            lui(tmp, hi >> 16), ori(tmp, tmp, hi & 0xFFFF),
            dsll32(tmp, tmp, 0), or_(r, r, tmp)]


def load128(rd, hi, lo, t1=20, t2=21):
    """rd = (hi << 64) | lo, which needs PCPYLD -- there is no other way to put
    a value in a register's upper half."""
    return load64(t1, hi) + load64(t2, lo) + [pcpyld(rd, t1, t2)]


def main():
    o = []
    for (ahi, alo), (bhi, blo) in PAIRS:
        o += load128(4, ahi, alo)
        o += load128(5, bhi, blo)
        # A destination that already holds something non-zero in both halves, so
        # an instruction that writes only part of it is visibly wrong rather
        # than accidentally right.
        o += load128(6, 0xA5A5A5A5A5A5A5A5, 0x5A5A5A5A5A5A5A5A)
        for fn, tbl in ((0x08, MMI0_SA), (0x28, MMI1_SA)):
            for sa in tbl:
                o += [or_(3, 6, 0)]                  # reseed the destination
                o += [mmi(fn, sa, 3, 4, 5)]
                o += [or_(7, 3, 0)]                  # and observe it
        # the operands reversed, because subtraction and the compares are not
        # symmetric and half the table would otherwise be tested one way only
        for fn, tbl in ((0x08, MMI0_SA), (0x28, MMI1_SA)):
            for sa in tbl:
                o += [or_(3, 6, 0)]
                o += [mmi(fn, sa, 3, 5, 4)]
                o += [or_(8, 3, 0)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(8192 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
