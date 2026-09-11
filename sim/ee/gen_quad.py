#!/usr/bin/env python3
"""Emit a directed LQ/SQ program.

    sim/ee/gen_quad.py > quad.hex

LQ and SQ are the only instructions that move all 128 bits of a register, and
two things about them need enumerating rather than sampling.

**The upper 64 bits have to differ from what was already there.**  A random
program is nearly blind to this: only MMI's copies ever put a non-zero value in
a register's upper half, and only SQ ever puts one in memory, so both are
usually zero and an LQ that dropped the upper half entirely would write the
same zeroes that were already there.  That is not a hypothesis -- an LQ built
to write only the low 64 bits passes every random seed and fails the third
instruction of this program.  Here every quadword in memory and every
destination register carries a distinct non-zero value in *both* halves.

**The low four bits of the address are ignored, not faulted.**  The manual is
explicit that neither instruction takes an address error exception; they access
the quadword containing the address.  So each of the sixteen offsets within a
quadword is loaded and stored, and all sixteen must give the same result as
offset zero.  A model that faulted, or that let the offset leak into the
address, disagrees with silicon on code that works.
"""

SCRATCH = 0x2000


def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def dsll32(rd, rt, sa): return sp(0, rt, rd, sa, 60)
def or_(rd, rs, rt):  return sp(rs, rt, rd, 0, 37)
def mem(op, rt, rs, off): return (op << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
def pcpyld(rd, rs, rt): return (28 << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (0x0E << 6) | 0x09
def pcpyud(rd, rs, rt): return (28 << 26) | (rs << 21) | (rt << 16) | (rd << 11) | (0x0E << 6) | 0x29

LQ, SQ, SD = 30, 31, 63


def load64(r, hi, lo, tmp=2):
    """r = the 64-bit constant (hi << 32) | lo, via a scratch register."""
    return [lui(r, lo >> 16), ori(r, r, lo & 0xFFFF),
            lui(tmp, hi >> 16), ori(tmp, tmp, hi & 0xFFFF),
            dsll32(tmp, tmp, 0), or_(r, r, tmp)]


def main():
    o = [lui(20, SCRATCH >> 16), ori(20, 20, SCRATCH & 0xFFFF)]

    # Two 64-bit halves, both non-zero and distinguishable from each other, and
    # a 128-bit register built from them.  PCPYLD is the only way to get a
    # value into the upper half in the first place, which is why it is here.
    o += load64(21, 0x1122_3344, 0x5566_7788)
    o += load64(22, 0x99AA_BBCC, 0xDDEE_FF01)
    o += [pcpyld(23, 21, 22)]          # r23 = 1122334455667788_99AABBCCDDEEFF01

    # A *different* 128-bit value, so that a destination register already
    # holding something non-zero in its upper half is overwritten rather than
    # merely confirmed.  This is the case a random program does not reach.
    o += load64(24, 0x0F1E_2D3C, 0x4B5A_6978)
    o += load64(25, 0x8796_A5B4, 0xC3D2_E1F0)
    o += [pcpyld(26, 24, 25)]

    # ---- SQ then LQ at every offset within the quadword -----------------
    # The store is always at offset zero of its own window and the load walks
    # the sixteen offsets: all sixteen must return the whole quadword.  The
    # destination is pre-loaded with the *other* 128-bit value first, so a load
    # that writes nothing, or only half, leaves a value that is visibly wrong
    # rather than accidentally right.
    o += [mem(SQ, 23, 20, 0)]
    for off in range(16):
        o += [or_(3, 26, 0), pcpyud(3, 26, 26)]   # r3 = something non-zero, both halves
        o += [mem(LQ, 3, 20, off)]
        o += [or_(4, 3, 0)]                       # observe the low half too

    # ---- SQ at every offset, read back as two doublewords ---------------
    # A store whose offset leaked into the address would write the next
    # quadword; reading both halves back separately is what shows where the
    # bytes actually went, since the register trace alone cannot.
    win = 0x100
    for off in range(16):
        o += [mem(SD, 0, 20, win), mem(SD, 0, 20, win + 8)]   # clear the window
        o += [mem(SQ, 23, 20, win + off)]
        o += [mem(LQ, 5, 20, win)]
        win += 16

    # ---- an SQ and an LQ back to back, and through a forwarding distance --
    # SQ reads rt, so it is a reader of a register the instruction before it may
    # have written; LQ writes one the instruction after it may read.  Both are
    # the distances the forwarding network has to cover, and neither appears in
    # a directed test that spaces everything out.
    o += [pcpyld(27, 22, 21), mem(SQ, 27, 20, 0x200), mem(LQ, 28, 20, 0x200),
          or_(29, 28, 0)]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
