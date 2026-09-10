#!/usr/bin/env python3
"""Emit a directed program for the pipeline's hazard and forwarding paths.

    sim/ee/gen_hazard.py > haz.hex

A random program produces a dependence between adjacent instructions only by
accident -- with 32 registers the odds are about one in sixteen per pair -- and
it essentially never produces the specific shapes that break a pipeline: a load
whose value is used on the very next instruction, a branch whose condition was
computed one instruction earlier, a delay slot that reads the register its own
branch just wrote, or MFHI immediately behind the MULT that set HI.

Every pattern here is emitted at distances 1, 2 and 3 where the distance is
what decides which forwarding path answers.  In this pipeline distance 1 is
served from MEM, distance 2 from WB, and distance 3 by the register-file read
bypass in ID, so a suite that only tested distance 1 would leave two thirds of
the forwarding logic unexercised.

r20 holds the scratch base and is not otherwise written.
"""

SCRATCH = 0x2000

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def addiu(rt, rs, imm): return (9 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def addu(rd, rs, rt): return sp(rs, rt, rd, 0, 33)
def xor_(rd, rs, rt): return sp(rs, rt, rd, 0, 38)
def sltu(rd, rs, rt): return sp(rs, rt, rd, 0, 43)
def lw(rt, rs, off):  return (35 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def ld(rt, rs, off):  return (55 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def lb(rt, rs, off):  return (32 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def sw(rt, rs, off):  return (43 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def sh(rt, rs, off):  return (41 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def sb(rt, rs, off):  return (40 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def sd(rt, rs, off):  return (63 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def mult(rs, rt, rd): return sp(rs, rt, rd, 0, 24)
def div(rs, rt):      return sp(rs, rt, 0, 0, 26)
def mfhi(rd):         return sp(0, 0, rd, 0, 16)
def mflo(rd):         return sp(0, 0, rd, 0, 18)
def mthi(rs):         return sp(rs, 0, 0, 0, 17)
def mtlo(rs):         return sp(rs, 0, 0, 0, 19)
def beq(rs, rt, off): return (4 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def bne(rs, rt, off): return (5 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def jal(target_word): return (3 << 26) | (target_word & 0x3FFFFFF)
def jr(rs):           return sp(rs, 0, 0, 0, 8)
NOP = 0


def main():
    o = []
    # r20 = scratch base, r21..r24 = a few working values
    o += [lui(20, SCRATCH >> 16), ori(20, 20, SCRATCH & 0xFFFF)]
    o += [addiu(21, 0, 0x0123), addiu(22, 0, 0x4567),
          addiu(23, 0, -3 & 0xFFFF), addiu(24, 0, 0x0011)]
    o += [sd(21, 20, 0), sd(22, 20, 8), sd(23, 20, 16), sd(24, 20, 24)]

    # ---- ALU result forwarded at distances 1, 2 and 3 ---------------------
    for gap in range(3):
        o += [addu(1, 21, 22)]
        o += [NOP] * gap
        o += [addu(2, 1, 1), xor_(3, 2, 1), sltu(4, 3, 2)]

    # ---- a write to r0 must not be forwarded ------------------------------
    # ADDU r0,... is a legal no-op; a forwarding network that matches on the
    # register number without excluding r0 turns the next instruction's read
    # of r0 into the discarded result, and nothing else in a random program
    # would ever show it.
    o += [addu(0, 21, 22), addu(5, 0, 0), xor_(6, 0, 21)]

    # ---- load-use at distances 1, 2 and 3 ---------------------------------
    for gap in range(3):
        o += [ld(7, 20, 0)]
        o += [NOP] * gap
        o += [addu(8, 7, 7), xor_(9, 8, 7)]

    # ---- a load feeding the base register of the next load -----------------
    o += [sd(20, 20, 32), ld(10, 20, 32), ld(11, 10, 0), addu(12, 11, 11)]

    # ---- a load feeding the data operand of a store ------------------------
    o += [ld(13, 20, 8), sd(13, 20, 40), ld(14, 20, 40)]

    # ---- narrow loads, where the sign extension is in the forwarded value --
    o += [lb(15, 20, 16), addu(16, 15, 15)]
    o += [lw(17, 20, 16), addu(18, 17, 17)]

    # ---- HI/LO forwarded at distances 1, 2 and 3 ---------------------------
    for gap in range(3):
        o += [mult(21, 22, 0)]
        o += [NOP] * gap
        o += [mfhi(1), mflo(2), addu(3, 1, 2)]
    for gap in range(3):
        o += [div(22, 24)]
        o += [NOP] * gap
        o += [mflo(4), mfhi(5), addu(6, 4, 5)]
    # two multiplies back to back: the second must win, and MFHI must take it
    # from the younger of the two writers in flight
    o += [mult(21, 22, 0), mult(23, 24, 0), mfhi(7), mflo(8)]
    # MTHI/MTLO are ordinary HI/LO writers and forward the same way
    o += [mthi(21), mfhi(9), mtlo(22), mflo(10)]
    # MULT's third operand and its HI/LO write, read at distance 1
    o += [mult(21, 22, 11), addu(12, 11, 11), mfhi(13)]

    # ---- a branch whose condition was computed one instruction earlier -----
    o += [addu(1, 21, 0), beq(1, 21, 2), addu(2, 1, 1), addu(3, 2, 2), addu(4, 3, 3)]
    o += [addu(1, 21, 0), bne(1, 21, 2), addu(5, 1, 1), addu(6, 5, 5), addu(7, 6, 6)]
    # a load feeding a branch condition: load-use through the branch operand
    o += [ld(8, 20, 0), beq(8, 21, 2), addu(9, 8, 8), addu(10, 9, 9), addu(11, 10, 10)]

    # ---- a delay slot that reads what its own branch wrote ------------------
    # JAL writes r31 and the delay slot runs afterwards, so the delay slot must
    # see the new r31 -- forwarded from MEM, since JAL is one instruction ahead.
    here = len(o)
    o += [jal(here + 3), addu(14, 31, 0), NOP]      # target is the next instruction
    o += [addu(15, 31, 0)]

    # ---- multi-cycle and memory instructions in a delay slot ---------------
    o += [addu(1, 21, 0), beq(1, 1, 1), ld(16, 20, 8), addu(17, 16, 16)]
    o += [addu(1, 21, 0), beq(1, 1, 1), mult(21, 24, 18), mfhi(19)]

    # ---- forwarding across a congested MEM stage ---------------------------
    # This is the shape that broke the first pipelined version of this core,
    # and no distance-based test finds it.  When the instructions around a
    # dependence are themselves memory operations, MEM becomes the bottleneck
    # and the consumer sits in EX for several cycles waiting to advance.
    # Forwarding is recomputed every cycle, but only the value present on the
    # cycle EX finally advances gets latched -- so a source that retires while
    # the consumer is still waiting is lost, and the consumer quietly uses the
    # stale register.  What matters here is the stall, not the distance: the
    # same dependence with NOPs in place of the stores passes.
    for gap in range(3):
        o += [lb(28, 20, 0x10), sh(4, 20, 0x30), ld(18, 20, 0)]
        o += [sw(29, 20, 0x38)] * (gap + 1)
        o += [ori(30, 18, 0x80ed), addu(1, 30, 30)]
    # the same, with the dependence carried through HI/LO instead
    for gap in range(2):
        o += [mult(21, 22, 0), lb(2, 20, 0x10)]
        o += [sb(3, 20, 0x39)] * (gap + 1)
        o += [mfhi(4), mflo(5), addu(6, 4, 5)]
    # and a branch whose condition is forwarded across the same congestion
    o += [ld(7, 20, 0), sw(7, 20, 0x40), sh(7, 20, 0x48),
          beq(7, 0, 2), addu(8, 7, 7), addu(9, 8, 8), addu(10, 9, 9)]

    # ---- JR through a register just computed -------------------------------
    here = len(o)
    o += [lui(2, 0), ori(2, 2, (here + 4) * 4), jr(2), addu(20 if False else 25, 21, 22)]
    o += [addu(26, 25, 25)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
