#!/usr/bin/env python3
"""Emit a directed PDIVW / PDIVUW program -- the parallel dividers, at their
corners.

    sim/ee/gen_pdiv.py > pdiv.hex

A divider is almost all corner.  Random operands exercise the iteration and
nothing else: they are never zero, never 0x80000000 over minus one, and never
arranged so that one lane's result could be the other's.  Each of those is a
separate way for two dividers running side by side to be wrong while every
random stream passes.

So the operand list here is built from pairs, and every pair is used both ways
round, which matters because division is not commutative and a swapped dividend
and divisor is the easiest mistake to make and the hardest to see.  The cases:

  * **a zero divisor**, which on this machine does not trap and is not
    undefined.  The iterative divider finds that zero "fits" at every step, so
    the quotient is all ones and the remainder is the dividend untouched.  That
    is architectural and has to be reproduced, not guarded against.
  * **0x80000000 divided by -1**, the signed quotient with no 32-bit
    representation.  The magnitude divider produces 0x80000000 and the sign
    fixup leaves it there.
  * **the same word in both lanes**, so that a lane crossed with its neighbour
    would still pass -- paired with cases where the lanes differ, which is what
    actually catches it.
  * **words 1 and 3 set to values that would be wrong answers**, since those
    two words are not read by these instructions at all and a divider fed from
    the wrong half of the register would produce them.
  * **operands whose high bit is set**, which divide differently signed and
    unsigned and so separate PDIVW from PDIVUW.  Without these the two
    instructions agree and either could be implementing the other.

The results live only in HI and LO -- both halves of both -- so each divide is
followed by PMFHI and PMFLO into ordinary registers, because a HI that is never
read is a HI that is never compared.
"""

from gen_mmi import (sp, or_, mmi, load128, addiu)

M32 = 0xFFFFFFFF

# (word0, word2) for the dividend and then for the divisor.  Words 1 and 3 are
# filled with a decoy in load_pair below.
CASES = [
    # ordinary, and the two lanes deliberately unequal
    ((100, 7), (7, 100)),
    ((0x7FFFFFFF, 0x00000003), (0x00000002, 0x7FFFFFFF)),
    # zero divisors, one lane at a time and then both
    ((12345, 0xFFFFFFFF), (0, 5)),
    ((12345, 0xFFFFFFFF), (5, 0)),
    ((0x80000000, 0x00000000), (0, 0)),
    # the unrepresentable signed quotient, and its neighbour
    ((0x80000000, 0x80000001), (0xFFFFFFFF, 0xFFFFFFFF)),
    ((0x80000000, 0x7FFFFFFF), (0x00000001, 0xFFFFFFFF)),
    # negative over positive, positive over negative, negative over negative --
    # the four sign combinations, which fix the sign of the remainder as well
    # as of the quotient
    ((0xFFFFFF9C, 0x00000064), (0x00000007, 0xFFFFFFF9)),
    ((0xFFFFFF9C, 0xFFFFFF9C), (0xFFFFFFF9, 0x00000007)),
    # the same in both lanes, so a crossed lane survives here and dies above
    ((0x0000002A, 0x0000002A), (0x00000005, 0x00000005)),
    # high bit set in dividend and divisor: signed and unsigned diverge
    ((0xFFFFFFFF, 0x80000000), (0x00000002, 0x00000003)),
    ((0xC0000000, 0xFFFFFFFE), (0xFFFFFFFF, 0x40000000)),
    ((0xFFFFFFFF, 0xFFFFFFFE), (0xFFFFFFFE, 0xFFFFFFFF)),
    # divisor larger than dividend, so the quotient is zero and the whole
    # dividend comes back as the remainder
    ((0x00000005, 0x00000001), (0x00000063, 0x7FFFFFFF)),
    # one, which should leave the dividend alone, and minus one, which should
    # negate it
    ((0x12345678, 0x87654321), (0x00000001, 0xFFFFFFFF)),
]

# Words 1 and 3 of every operand.  These are never read by PDIVW or PDIVUW, so
# they are set to something that would divide cleanly and produce an obviously
# different answer if a lane were fed from the wrong half.
DECOY_A = 0x0000C000
DECOY_B = 0x00000004


def pack(w0, w2, d):
    """A 128-bit value with w0 in word 0, w2 in word 2 and a decoy elsewhere."""
    return ((w2 & M32) | ((d & M32) << 32), (w0 & M32) | ((d & M32) << 32))


def main():
    o = []
    for (a0, a2), (b0, b2) in CASES:
        ahi, alo = pack(a0, a2, DECOY_A)
        bhi, blo = pack(b0, b2, DECOY_B)
        o += load128(4, ahi, alo)
        o += load128(5, bhi, blo)
        for fn in (0x09, 0x29):            # MMI2 => PDIVW, MMI3 => PDIVUW
            for rs, rt in ((4, 5), (5, 4)):
                o += [mmi(fn, 0x0D, 0, rs, rt)]
                o += [mmi(0x09, 0x08, 6, 0, 0)]     # PMFHI r6
                o += [mmi(0x09, 0x09, 7, 0, 0)]     # PMFLO r7
                # copy where the diff will see them changing every time
                o += [or_(8, 6, 0), or_(9, 7, 0)]
                # and the upper halves, which PMFHI/PMFLO brought down whole
                o += [mmi(0x29, 0x0E, 10, 6, 6)]    # PCPYUD r10, r6, r6
                o += [mmi(0x29, 0x0E, 11, 7, 7)]    # PCPYUD r11, r7, r7

    # ---- PDIVBW: four words by one halfword -----------------------------
    # The divisor is rt's low halfword only, and it is *signed*, so the three
    # things to separate are a divisor read from the wrong halfword, a divisor
    # read as unsigned (0xFFFF meaning 65535 instead of minus one), and the two
    # passes of the divider pair disagreeing -- which would show as words 2 and
    # 3 being wrong while words 0 and 1 are right.  Every dividend below has
    # four distinct words for exactly that reason.
    for dvd in (0x0000002A_FFFFFFD6_00000064_FFFFFF9C,
                0x80000000_7FFFFFFF_00000001_FFFFFFFF,
                0x00000000_00000001_FFFFFFFF_0000000B,
                0x7F7F7F7F_01234567_89ABCDEF_FEDCBA98):
        for dsr in (0x0007, 0xFFFF, 0x0001, 0x0000, 0x7FFF, 0x8000, 0x0003):
            # decoys in rt's other three halfwords: read any of them and the
            # quotients are visibly wrong
            rt = (0x1111222233334444 << 64) | (0x5555666677770000 | dsr)
            o += load128(4, dvd >> 64, dvd & 0xFFFFFFFFFFFFFFFF)
            o += load128(5, rt >> 64, rt & 0xFFFFFFFFFFFFFFFF)
            o += [mmi(0x09, 0x1D, 0, 4, 5)]
            o += [mmi(0x09, 0x08, 6, 0, 0)]     # PMFHI r6
            o += [mmi(0x09, 0x09, 7, 0, 0)]     # PMFLO r7
            o += [or_(22, 6, 0), or_(23, 7, 0)]
            o += [mmi(0x29, 0x0E, 24, 6, 6)]    # PCPYUD r24, r6, r6
            o += [mmi(0x29, 0x0E, 25, 7, 7)]    # PCPYUD r25, r7, r7

    # A PDIVBW read back immediately, which is where an interlock sized for
    # thirty-three cycles rather than sixty-six would come apart.
    o += load128(4, 0x0000000300000004, 0x0000000500000064)
    o += load128(5, 0, 7)
    o += [mmi(0x09, 0x1D, 0, 4, 5), mmi(0x09, 0x09, 26, 0, 0)]
    o += [mmi(0x09, 0x1D, 0, 4, 5), mmi(0x09, 0x08, 27, 0, 0)]
    # and a PDIVW immediately after a PDIVBW, so the second cannot inherit the
    # first's half-finished state
    o += [mmi(0x09, 0x1D, 0, 4, 5), mmi(0x09, 0x0D, 0, 4, 5),
          mmi(0x09, 0x09, 28, 0, 0), mmi(0x09, 0x08, 29, 0, 0)]

    # A divide immediately followed by a read of its result: the interlock has
    # to hold PMFLO back for the whole 33 cycles, and a divider that finished
    # early would be caught here and nowhere else in this file, since every
    # other case has instructions between them.
    o += load128(4, 0, 0x0000000700000064)
    o += load128(5, 0, 0x0000000200000003)
    o += [mmi(0x09, 0x0D, 0, 4, 5), mmi(0x09, 0x09, 12, 0, 0)]
    o += [mmi(0x29, 0x0D, 0, 4, 5), mmi(0x09, 0x08, 13, 0, 0)]

    # And a divide whose result is overwritten by a following one before
    # anything reads it, which is what would break if the second kicked off
    # while the first was still stepping.
    o += [mmi(0x09, 0x0D, 0, 4, 5), mmi(0x29, 0x0D, 0, 5, 4),
          mmi(0x09, 0x09, 14, 0, 0), mmi(0x09, 0x08, 15, 0, 0)]

    # Interleaved with the scalar divider, which shares the first unit: a DIV
    # between two PDIVWs must not pick up the parallel operands and the PDIVW
    # must not pick up the scalar's.
    o += [addiu(16, 0, 100), addiu(17, 0, 7)]
    o += [mmi(0x09, 0x0D, 0, 4, 5)]
    o += [sp(16, 17, 0, 0, 26)]                     # DIV r16, r17
    o += [sp(0, 0, 18, 0, 16), sp(0, 0, 19, 0, 18)] # MFHI r18, MFLO r19
    o += [mmi(0x09, 0x0D, 0, 5, 4)]
    o += [mmi(0x09, 0x09, 20, 0, 0), mmi(0x09, 0x08, 21, 0, 0)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(8192 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
