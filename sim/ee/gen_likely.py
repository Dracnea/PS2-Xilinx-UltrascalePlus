#!/usr/bin/env python3
"""Emit a directed branch-likely program: annulled slots, taken slots, links.

    sim/ee/gen_likely.py > likely.hex

MIPS III added BEQL, BNEL, BLEZL, BGTZL and the four REGIMM forms so a compiler
could fill a delay slot with an instruction that is only correct when the branch
is taken.  When the branch is NOT taken the slot is **annulled** -- it does not
execute.  That is the entire difference from the ordinary forms, and a core that
treats them as ordinary branches runs an instruction the compiler guaranteed
would not run.  Nothing about that shows up as a decode error; it shows up as a
register holding a value from a path that was never taken.

Each case is laid out so the taken and not-taken paths rejoin immediately:

    A+0   the branch, offset 1  ->  target is A+8
    A+4   the delay slot
    A+8   both paths continue here

so "taken" and "not taken" differ only in whether the slot ran, which is the
one thing being measured.  A slot that must not run writes a poison value over
a marker; a slot that must run writes a distinctive one.  Both claims matter --
a core that annuls unconditionally passes the first kind of test and fails the
second.

The link forms are the easy thing to get wrong: BLTZALL and BGEZALL write r31
**whether or not the branch is taken**.  The annul makes it look as though
nothing should happen, and it is only the slot that is cancelled.

The last case puts a store in an annulled slot.  A register trace cannot see
that fault at all -- a store writes no register -- so the memory image is what
catches it.
"""

HANDLER_WORD = 0x180 // 4

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def addiu(rt, rs, i): return (9 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def ri(op, rs, rt, i): return (op << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def regimm(rs, rt, i): return ri(1, rs, rt, i)
def sw(rt, rs, off):  return ri(43, rs, rt, off)
def lw(rt, rs, off):  return ri(35, rs, rt, off)
NOP = 0

BEQL, BNEL, BLEZL, BGTZL = 20, 21, 22, 23
BLTZL, BGEZL, BLTZALL, BGEZALL = 2, 3, 18, 19


def case(branch_word, slot_word):
    """One branch with offset 1, its slot, and the rejoin point."""
    return [branch_word, slot_word]


def main():
    o = []
    # r1 = 1, r2 = 1, r3 = 2, r4 = -1
    o += [addiu(1, 0, 1), addiu(2, 0, 1), addiu(3, 0, 2), addiu(4, 0, -1 & 0xFFFF)]

    # ---- BEQL taken: r1 == r2, so the slot runs --------------------------
    o += [addiu(5, 0, 0x05)]                       # marker
    o += case(ri(BEQL, 1, 2, 1), addiu(5, 0, 0x55))   # slot RUNS -> r5 = 0x55

    # ---- BEQL not taken: r1 != r3, so the slot is annulled ---------------
    o += [addiu(6, 0, 0x06)]                       # marker that must survive
    o += case(ri(BEQL, 1, 3, 1), addiu(6, 0, 0xDEAD & 0xFFFF))   # annulled

    # ---- BNEL taken and not taken ----------------------------------------
    o += [addiu(7, 0, 0x07)]
    o += case(ri(BNEL, 1, 3, 1), addiu(7, 0, 0x77))               # runs
    o += [addiu(8, 0, 0x08)]
    o += case(ri(BNEL, 1, 2, 1), addiu(8, 0, 0xDEAD & 0xFFFF))    # annulled

    # ---- BLEZL / BGTZL, both ways ----------------------------------------
    o += [addiu(9, 0, 0x09)]
    o += case(ri(BLEZL, 4, 0, 1), addiu(9, 0, 0x99))              # -1 <= 0, runs
    o += [addiu(10, 0, 0x0A)]
    o += case(ri(BLEZL, 1, 0, 1), addiu(10, 0, 0xDEAD & 0xFFFF))  # 1 <= 0 false
    o += [addiu(11, 0, 0x0B)]
    o += case(ri(BGTZL, 1, 0, 1), addiu(11, 0, 0xBB))             # 1 > 0, runs
    o += [addiu(12, 0, 0x0C)]
    o += case(ri(BGTZL, 4, 0, 1), addiu(12, 0, 0xDEAD & 0xFFFF))  # -1 > 0 false

    # ---- REGIMM BLTZL / BGEZL --------------------------------------------
    o += [addiu(13, 0, 0x0D)]
    o += case(regimm(4, BLTZL, 1), addiu(13, 0, 0xDD))            # -1 < 0, runs
    o += [addiu(14, 0, 0x0E)]
    o += case(regimm(1, BLTZL, 1), addiu(14, 0, 0xDEAD & 0xFFFF)) # 1 < 0 false
    o += [addiu(15, 0, 0x0F)]
    o += case(regimm(1, BGEZL, 1), addiu(15, 0, 0xEE))            # 1 >= 0, runs
    o += [addiu(16, 0, 0x10)]
    o += case(regimm(4, BGEZL, 1), addiu(16, 0, 0xDEAD & 0xFFFF)) # -1 >= 0 false

    # ---- the link forms: r31 is written on BOTH paths --------------------
    # Taken first.  r31 must hold the address of the branch + 8.
    o += [addiu(17, 0, 0x11)]
    o += case(regimm(4, BLTZALL, 1), addiu(17, 0, 0xAA))          # taken, slot runs
    o += [sp(0, 0, 18, 0, 32 + 1)]                                # ADDU r18, r0, r0
    o += [sp(31, 0, 18, 0, 33)]                                   # r18 = r31 (taken link)
    # Not taken.  r31 is still written, and the slot is still annulled.
    o += [addiu(19, 0, 0x13)]
    o += case(regimm(1, BLTZALL, 1), addiu(19, 0, 0xDEAD & 0xFFFF))
    o += [sp(31, 0, 20, 0, 33)]                                   # r20 = r31 (untaken link)
    # BGEZALL, both ways
    o += [addiu(21, 0, 0x15)]
    o += case(regimm(1, BGEZALL, 1), addiu(21, 0, 0xCC))          # taken
    o += [addiu(22, 0, 0x16)]
    o += case(regimm(4, BGEZALL, 1), addiu(22, 0, 0xDEAD & 0xFFFF))
    o += [sp(31, 0, 23, 0, 33)]                                   # r23 = r31

    # ---- a store in an annulled slot must never reach memory -------------
    # Seed the word first so "unwritten" and "written with zero" are different.
    o += [addiu(24, 0, 0x5A5A), sw(24, 0, 0x200)]
    o += [addiu(25, 0, 0x1234)]
    o += case(ri(BEQL, 1, 3, 1), sw(25, 0, 0x200))   # annulled: 0x200 keeps 0x5A5A
    o += [lw(26, 0, 0x200)]                          # and read it back into a register

    # ---- a taken likely branch that jumps backwards, to prove the target
    #      arithmetic is the ordinary one ---------------------------------
    o += [addiu(27, 0, 3)]
    back = len(o)
    o += [addiu(27, 27, -1 & 0xFFFF)]                # r27 -= 1
    o += [ri(BNEL, 27, 0, (back - (len(o) + 1)) & 0xFFFF)]
    o += [addiu(28, 28, 1)]                          # slot: counts taken passes
    # falls out when r27 reaches 0, having run the slot twice and annulled once

    o += [ri(4, 0, 0, -1 & 0xFFFF), NOP]             # park: beq r0,r0,-1

    body = len(o)
    assert body < HANDLER_WORD, "program ran into the exception vector"
    while len(o) < HANDLER_WORD:
        o.append(NOP)
    o += [(16 << 26) | (0 << 21) | (29 << 16) | (14 << 11),   # MFC0 r29, EPC
          addiu(30, 29, 4),
          (16 << 26) | (4 << 21) | (30 << 16) | (14 << 11),   # MTC0 r30, EPC
          (16 << 26) | (16 << 21) | 24,                       # ERET
          NOP]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return body


if __name__ == "__main__":
    main()
