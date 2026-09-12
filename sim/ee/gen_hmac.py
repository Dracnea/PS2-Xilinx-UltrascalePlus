#!/usr/bin/env python3
"""Emit a directed program for MMI2's halfword multiply-accumulate group.

    sim/ee/gen_hmac.py > hmac.hex

Five instructions -- PMULTH, PMADDH, PHMADH, PMSUBH, PHMSBH -- that form the
same eight products and differ in what they do with them. Three things about
that shape decide what this file has to contain.

**The lane map is the instruction.** Eight products are dealt to HI and LO in
pairs, alternating, and rd takes the first word of each pair. Nothing about
that is arithmetic, so operands whose lanes are interchangeable would test none
of it: every halfword here is distinct, and rs and rt are distinguishable from
each other, so a product taken from the wrong lane -- or landing in the wrong
word of HI instead of LO -- produces a number that appears nowhere else in the
answer.

**The accumulating forms read HI and LO, so the test has to put something
there first, and then care where it came from.** A PMULTH immediately followed
by a PMADDH is how the group is used, and it is also the hazard: the second
instruction needs the first's HI and LO forwarded, not the register file's copy
from an instruction earlier. Every accumulate below is preceded by one of those
pairs, and some by three in a row.

**These wrap; they do not saturate.** That is the opposite of MMI0's arithmetic
and it is what makes the accumulating forms usable as a dot product -- an
intermediate sum may overflow and come back. So the operand set includes
0x8000 and 0x7FFF, whose products are near 2^30, and the programs accumulate
them four deep, which takes the sums past 32 bits several times over. An
implementation that clamped would be right on every small case and wrong here.

PHMSBH's second word is the *complement* of the product rather than the
product. No manual this project has says so; it is PCSX2's behaviour, marked
undocumented in its own source. It is tested here because it is implemented,
and it is tagged in both implementations because testing a guess against itself
proves only that the two agree.
"""

from gen_mmi import (sp, or_, mmi, load128)

# Sub-opcodes, in MMI2's sa field.
PMULTH, PMADDH, PHMADH, PMSUBH, PHMSBH = 0x1C, 0x10, 0x11, 0x14, 0x15
GROUP = [PMULTH, PMADDH, PHMADH, PMSUBH, PHMSBH]

PMFHI, PMFLO = 0x08, 0x09          # MMI2
PMTHI, PMTLO = 0x08, 0x09          # MMI3

# Operand pairs. Every halfword in a register is distinct, and the two
# registers of a pair are distinguishable, so any lane taken from the wrong
# place is visible in the result.
PAIRS = [
    # small and distinct: the lane map, with nothing else going on
    ((0x0008_0007_0006_0005, 0x0004_0003_0002_0001),
     (0x0018_0017_0016_0015, 0x0014_0013_0012_0011)),
    # every halfword corner against every other
    ((0x8000_7FFF_FFFF_0001, 0x0000_8000_7FFF_FFFF),
     (0x7FFF_8000_0001_FFFF, 0x8000_0001_FFFF_7FFF)),
    # the extreme product, 0x8000 * 0x8000 = +2^30, in every lane at once --
    # which is where four-deep accumulation runs past 32 bits
    ((0x8000_8000_8000_8000, 0x8000_8000_8000_8000),
     (0x8000_8000_8000_8000, 0x8000_8000_8000_8000)),
    # mixed signs, so the horizontal forms' subtraction has something to do
    ((0xFFFF_0001_FFFE_0002, 0x7FFF_8001_0003_FFFD),
     (0x0002_FFFE_0001_FFFF, 0x8001_7FFF_FFFD_0003)),
    # one register all ones, so a product that used rs where it meant rt shows
    ((0x0001_0001_0001_0001, 0x0001_0001_0001_0001),
     (0x1234_5678_9ABC_DEF0, 0x0FED_CBA9_8765_4321)),
]

# A starting HI/LO for the accumulating forms, with all four words distinct and
# two of them already large enough that one more product wraps them.
SEED_LO = (0x7FFFFF00_00001234, 0x00005678_FFFFFF00)
SEED_HI = (0x40000000_0000ABCD, 0x0000EF01_C0000000)


def main():
    o = []
    for (ahi, alo), (bhi, blo) in PAIRS:
        o += load128(4, ahi, alo)
        o += load128(5, bhi, blo)
        o += load128(6, *SEED_LO)
        o += load128(7, *SEED_HI)

        for sa in GROUP:
            # A known HI and LO before every instruction, so the accumulating
            # forms start from something and the others are seen to ignore it.
            o += [mmi(0x29, PMTLO, 0, 6, 0)]
            o += [mmi(0x29, PMTHI, 0, 7, 0)]
            o += [mmi(0x09, sa, 3, 4, 5)]
            o += [mmi(0x09, PMFLO, 8, 0, 0)]
            o += [mmi(0x09, PMFHI, 9, 0, 0)]
            o += [or_(10, 3, 0), or_(11, 8, 0), or_(12, 9, 0)]
            # and the same with the operands the other way round: none of these
            # is commutative across lanes once the horizontal forms subtract
            o += [mmi(0x29, PMTLO, 0, 6, 0)]
            o += [mmi(0x29, PMTHI, 0, 7, 0)]
            o += [mmi(0x09, sa, 13, 5, 4)]
            o += [mmi(0x09, PMFLO, 14, 0, 0)]
            o += [mmi(0x09, PMFHI, 15, 0, 0)]

        # ---- the chain the group exists for --------------------------------
        # A multiply, then three accumulates onto it, with nothing in between.
        # Every one of the four needs the previous instruction's HI and LO
        # forwarded; a core that read the register file instead would give the
        # right answer for the first and drift from the second onwards, which
        # is the failure this catches and a single PMADDH does not.
        o += [mmi(0x09, PMULTH, 0, 4, 5)]
        o += [mmi(0x09, PMADDH, 0, 4, 5)]
        o += [mmi(0x09, PMADDH, 0, 4, 5)]
        o += [mmi(0x09, PMADDH, 16, 4, 5)]
        o += [mmi(0x09, PMFLO, 17, 0, 0), mmi(0x09, PMFHI, 18, 0, 0)]

        # The same, subtracting, so a sign dropped somewhere in the accumulate
        # shows as a growing rather than a shrinking number.
        o += [mmi(0x09, PMULTH, 0, 4, 5)]
        o += [mmi(0x09, PMSUBH, 0, 5, 4)]
        o += [mmi(0x09, PMSUBH, 0, 4, 5)]
        o += [mmi(0x09, PMSUBH, 19, 5, 4)]
        o += [mmi(0x09, PMFLO, 20, 0, 0), mmi(0x09, PMFHI, 21, 0, 0)]

        # The horizontal pair interleaved with the vertical ones: PHMSBH's
        # complemented second word must survive a following PMADDH reading it.
        o += [mmi(0x09, PHMADH, 0, 4, 5)]
        o += [mmi(0x09, PHMSBH, 0, 4, 5)]
        o += [mmi(0x09, PMADDH, 22, 4, 5)]
        o += [mmi(0x09, PMFLO, 23, 0, 0), mmi(0x09, PMFHI, 24, 0, 0)]

        # rd = 0 writes no register but must still write HI and LO, which is
        # the encoding real code uses when only the accumulator is wanted.
        o += [mmi(0x29, PMTLO, 0, 6, 0), mmi(0x29, PMTHI, 0, 7, 0)]
        o += [mmi(0x09, PMULTH, 0, 4, 5)]
        o += [mmi(0x09, PMFLO, 25, 0, 0), mmi(0x09, PMFHI, 26, 0, 0)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(8192 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
