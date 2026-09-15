#!/usr/bin/env python3
"""Emit a directed program for the twelve conditional traps.

    sim/ee/gen_trap.py > trap.hex

TGE, TGEU, TLT, TLTU, TEQ and TNE compare two registers; TGEI, TGEIU, TLTI,
TLTIU, TEQI and TNEI compare a register against a sign-extended immediate.  All
twelve raise Trap (Cause code 13) when the condition holds and do nothing
whatever when it does not.

They write no register.  That is what makes them easy to leave out and hard to
notice missing: the instruction decodes as reserved, or as nothing, and the only
visible difference is an exception that never arrives.  So every case here is
bracketed by markers -- one written before, one written after -- and the
trapping cases are distinguished from the non-trapping ones by *where execution
resumes*, since the handler steps EPC past the faulting instruction.

Two pairs are chosen to separate signed from unsigned, which is the only
interesting thing about having both forms:

  * TLT / TLTU with -1 and 1.  Signed, -1 < 1 and the trap fires.  Unsigned,
    0xFFFFFFFFFFFFFFFF < 1 is false and it does not.
  * TGEIU with a negative immediate.  The immediate is **sign-extended** and
    then compared as unsigned, so it becomes a very large number -- a core that
    zero-extends it instead gets the opposite answer.  This is the classic way
    to get TGEIU wrong and it is worth one directed case.
"""

HANDLER_WORD = 0x180 // 4

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def addiu(rt, rs, i):  return (9 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def daddiu(rt, rs, i): return (25 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def regimm(rs, rt, i): return (1 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def trap(rs, rt, fn):  return sp(rs, rt, 0, 0, fn)
NOP = 0

TGE, TGEU, TLT, TLTU, TEQ, TNE = 48, 49, 50, 51, 52, 54
TGEI, TGEIU, TLTI, TLTIU, TEQI, TNEI = 8, 9, 10, 11, 12, 14


def main():
    o = []
    # r1 = 1, r2 = 1, r3 = 2, r4 = -1
    o += [addiu(1, 0, 1), addiu(2, 0, 1), addiu(3, 0, 2), daddiu(4, 0, -1 & 0xFFFF)]

    n = [0x20]
    def mark(reg):
        n[0] += 1
        return addiu(reg, 0, n[0])

    # ---- register forms, each with a firing and a non-firing case --------
    o += [mark(5),  trap(1, 2, TEQ),  mark(6)]      # 1 == 1  -> traps
    o += [mark(7),  trap(1, 3, TEQ),  mark(8)]      # 1 == 2  -> quiet
    o += [mark(9),  trap(1, 3, TNE),  mark(10)]     # 1 != 2  -> traps
    o += [mark(11), trap(1, 2, TNE),  mark(12)]     # 1 != 1  -> quiet
    o += [mark(13), trap(3, 1, TGE),  mark(14)]     # 2 >= 1  -> traps
    o += [mark(15), trap(1, 3, TGE),  mark(16)]     # 1 >= 2  -> quiet

    # signed vs unsigned, the pair that actually distinguishes them
    o += [mark(17), trap(4, 1, TLT),  mark(18)]     # -1 <  1 signed   -> traps
    o += [mark(19), trap(4, 1, TLTU), mark(20)]     # huge < 1 unsigned-> quiet
    o += [mark(21), trap(4, 1, TGEU), mark(22)]     # huge >= 1        -> traps

    # ---- immediate forms --------------------------------------------------
    o += [mark(23), regimm(1, TEQI, 1),  mark(24)]  # 1 == 1  -> traps
    o += [mark(25), regimm(1, TEQI, 2),  mark(26)]  # 1 == 2  -> quiet
    o += [mark(27), regimm(1, TNEI, 2),  mark(28)]  # 1 != 2  -> traps
    o += [mark(5),  regimm(3, TGEI, 1),  mark(6)]   # 2 >= 1  -> traps
    o += [mark(7),  regimm(1, TLTI, 2),  mark(8)]   # 1 <  2  -> traps
    o += [mark(9),  regimm(1, TLTI, -1 & 0xFFFF), mark(10)]   # 1 < -1 -> quiet

    # The sign-extended-then-unsigned case.  simm = -1 becomes 2^64-1, so
    # r1 (1) >= that is false and TGEIU stays quiet; a core that zero-extended
    # the immediate would compare against 0xFFFF and also stay quiet, so the
    # partner below is what separates them.
    o += [mark(11), regimm(1, TGEIU, -1 & 0xFFFF), mark(12)]  # quiet either way
    # r4 is 0xFFFFFFFFFFFFFFFF, which IS >= 2^64-1, so this one fires only if
    # the immediate was sign-extended.  Zero-extend it and 0xFFFF is smaller,
    # so it fires too -- but TLTIU below tells them apart cleanly.
    o += [mark(13), regimm(4, TGEIU, -1 & 0xFFFF), mark(14)]  # fires: huge >= huge
    # 1 < 2^64-1 unsigned is true and traps; 1 < 0xFFFF is also true.  The
    # discriminating one is r4: huge < 2^64-1 is FALSE (they are equal), but
    # huge < 0xFFFF would also be false.  So use r3 = 2 against a small
    # negative: 2 < 2^64-2 traps, 2 < 0xFFFE traps.  The clean discriminator is
    # a register between 0xFFFF and 2^64: r24 below.
    o += [mark(15), regimm(1, TLTIU, -1 & 0xFFFF), mark(16)]  # 1 < huge -> traps
    o += [addiu(24, 0, 0x7FFF), sp(0, 24, 24, 4, 56)]         # r24 = 0x7FFF << 4
    o += [mark(17), regimm(24, TLTIU, -2 & 0xFFFF), mark(18)]
    #   sign-extended: 0x7FFF0 < 0xFFFFFFFFFFFFFFFE  -> traps
    #   zero-extended: 0x7FFF0 < 0xFFFE              -> quiet.  This is the case
    #   that separates the two readings.

    o += [(4 << 26) | (-1 & 0xFFFF), NOP]           # park: beq r0,r0,-1

    body = len(o)
    assert body < HANDLER_WORD, "program ran into the exception vector"
    while len(o) < HANDLER_WORD:
        o.append(NOP)
    o += [(16 << 26) | (0 << 21) | (29 << 16) | (14 << 11),   # MFC0 r29, EPC
          (16 << 26) | (0 << 21) | (30 << 16) | (13 << 11),   # MFC0 r30, Cause
          addiu(29, 29, 4),
          (16 << 26) | (4 << 21) | (29 << 16) | (14 << 11),   # MTC0 r29, EPC
          (16 << 26) | (16 << 21) | 24,                       # ERET
          NOP]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return body


if __name__ == "__main__":
    main()
