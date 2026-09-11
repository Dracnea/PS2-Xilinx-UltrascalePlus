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

# The pack, extend and shuffle half.  These need the *opposite* operands from
# the arithmetic half and that is the whole point of separating them: saturation
# wants values at the edge of a lane, and a permutation wants every lane
# distinguishable from every other.  The corner operands above repeat the same
# byte sixteen times, which hides any reordering completely -- the same trap
# that made the Graphics Synthesizer's first directed test prove nothing.
MMI0_SHUF = [0x12, 0x13, 0x16, 0x17, 0x1A, 0x1B, 0x1E, 0x1F]
MMI1_SHUF = [0x04, 0x12, 0x16, 0x1A]          # QFSRV is swept separately

# Every byte distinct, and the two registers distinguishable from each other, so
# that a lane taken from the wrong operand or the wrong position is visible.
SHUF_A = (0x0F0E0D0C0B0A0908, 0x0706050403020100)
SHUF_B = (0x1F1E1D1C1B1A1918, 0x1716151413121110)
# a second pair whose bytes carry set high bits, so PEXT5 and PPAC5 -- which
# care about bits 4:0, 9:5, 14:10 and 15 rather than about whole bytes -- are
# not fed a pattern whose interesting bits are all zero
SHUF_C = (0x8001C003E005F007, 0x1234ABCD5678EF90)
SHUF_D = (0x7FFE3FFC1FF80FF0, 0xFEDC0123BA987654)

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


def addiu(rt, rs, i): return (9 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def mtsab(rs, imm): return (1 << 26) | (rs << 21) | (24 << 16) | (imm & 0xFFFF)
def mtsah(rs, imm): return (1 << 26) | (rs << 21) | (25 << 16) | (imm & 0xFFFF)
def mtsa(rs):       return (rs << 21) | 41
def mfsa(rd):       return (rd << 11) | 40


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

    # ---- the pack, extend and shuffle group ----------------------------
    for (ahi, alo), (bhi, blo) in ((SHUF_A, SHUF_B), (SHUF_C, SHUF_D),
                                   (SHUF_B, SHUF_A)):
        o += load128(4, ahi, alo)
        o += load128(5, bhi, blo)
        o += load128(6, 0xA5A5A5A5A5A5A5A5, 0x5A5A5A5A5A5A5A5A)
        for fn, tbl in ((0x08, MMI0_SHUF), (0x28, MMI1_SHUF)):
            for sa in tbl:
                o += [or_(3, 6, 0)]
                o += [mmi(fn, sa, 3, 4, 5)]
                o += [or_(9, 3, 0)]
                # and with the operands swapped: PEXTL takes its even lanes from
                # rt and its odd from rs, so a model that had them the wrong way
                # round would agree with itself on a symmetric test
                o += [or_(3, 6, 0)]
                o += [mmi(fn, sa, 3, 5, 4)]
                o += [or_(10, 3, 0)]

    # ---- QFSRV, at every shift amount ----------------------------------
    # SA counts bytes, so there are exactly sixteen answers and all of them are
    # enumerated.  MTSAB sets it by exclusive-or with the immediate, so the
    # register it reads is zeroed first and the immediate then names the amount
    # outright.  MFSA reads it back on every pass, which is what makes the
    # register itself observable rather than only its effect.
    o += load128(4, SHUF_A[0], SHUF_A[1])
    o += load128(5, SHUF_B[0], SHUF_B[1])
    # The operand register must not be zero.  MTSAB exclusive-ors it with the
    # immediate, and with a zero operand exclusive-or and addition give the same
    # answer for every immediate -- so a model that added instead would agree
    # with one that exclusive-ored, on every value.  That is not a hypothetical:
    # the first version of this program used r0 and a mutation replacing the
    # exclusive-or with an addition passed it.
    for base in (0x0, 0x6, 0xB, 0xF):
        o += [addiu(11, 0, base)]
        for amt in range(16):
            o += [mtsab(11, amt)]
            o += [mfsa(12)]                    # the register itself, observed
            o += [mmi(0x28, 0x1B, 3, 4, 5)]    # QFSRV r3, r4, r5
            o += [or_(13, 3, 0)]
            o += [mmi(0x28, 0x1B, 14, 5, 4)]   # and the other way round

    # MTSAH shifts its result left by one, so it reaches only even amounts --
    # and a model that forgot the shift would still produce a legal SA, which is
    # why it needs its own sweep rather than being assumed to follow MTSAB.
    for base in (0x0, 0x3, 0x5, 0x7):
        o += [addiu(11, 0, base)]
        for amt in range(8):
            o += [mtsah(11, amt)]
            o += [mfsa(12)]
            o += [mmi(0x28, 0x1B, 3, 4, 5)]
            o += [or_(15, 3, 0)]

    # MTSA takes a whole register rather than an immediate.
    for v in (0, 1, 7, 8, 15):
        o += [addiu(11, 0, v)]
        o += [mtsa(11)]
        o += [mfsa(12)]
        o += [mmi(0x28, 0x1B, 3, 4, 5)]
        o += [or_(16, 3, 0)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(8192 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
