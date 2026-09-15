#!/usr/bin/env python3
"""Emit a directed overflow program for the four trapping arithmetic forms.

    sim/ee/gen_ovf.py > ovf.hex

SUB, DADD, DSUB and DADDI raise Integer Overflow; SUBU, DADDU, DSUBU and DADDIU
never do.  Both halves of each pair were computing the same expression here --
in the RTL *and* in the reference model -- so they agreed with each other while
both were wrong, which is the one kind of fault a differential test cannot see.
A test that comes from the instruction set rather than from the other
implementation is the only thing that finds it.

Every case is paired: the trapping form with operands that overflow, and the
unsigned form with the *same* operands, which must write the wrapped result
instead of trapping.  A destination register is preloaded with a marker before
each trapping case, because "the exception was taken" and "the destination was
left alone" are two separate claims and only the second one rules out a core
that counts the trap and writes anyway.

The doubleword cases need 64-bit constants, which the R5900 builds the same way
a compiler does: a 32-bit halfword pair, shifted left by 32, then the low half
merged in.  DSLL32 is what makes that cheap.
"""

HANDLER_WORD = 0x180 // 4

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def addiu(rt, rs, i):  return (9 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def daddiu(rt, rs, i): return (25 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def daddi(rt, rs, i):  return (24 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def lui(rt, imm):      return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm):  return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def sub_(rd, rs, rt):  return sp(rs, rt, rd, 0, 34)
def subu(rd, rs, rt):  return sp(rs, rt, rd, 0, 35)
def dadd(rd, rs, rt):  return sp(rs, rt, rd, 0, 44)
def daddu(rd, rs, rt): return sp(rs, rt, rd, 0, 45)
def dsub(rd, rs, rt):  return sp(rs, rt, rd, 0, 46)
def dsubu(rd, rs, rt): return sp(rs, rt, rd, 0, 47)
def dsll32(rd, rt, sa):return sp(0, rt, rd, sa, 60)
def mfc0(rt, rd):      return (16 << 26) | (0 << 21) | (rt << 16) | (rd << 11)
def mtc0(rt, rd):      return (16 << 26) | (4 << 21) | (rt << 16) | (rd << 11)
def beq(rs, rt, off):  return (4 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
NOP = 0


def load64(reg, value, tmp):
    """reg <- a full 64-bit constant, via the halfword pairs."""
    hi, lo = (value >> 32) & 0xFFFFFFFF, value & 0xFFFFFFFF
    o = [lui(reg, hi >> 16), ori(reg, reg, hi & 0xFFFF), dsll32(reg, reg, 0)]
    o += [lui(tmp, lo >> 16), ori(tmp, tmp, lo & 0xFFFF)]
    # ORI's immediate is zero-extended and LUI sign-extends, so the low half is
    # masked to 32 bits before it is merged -- otherwise a low half with bit 31
    # set carries ones into the high half that was just placed there.
    o += [dsll32(tmp, tmp, 0), sp(0, tmp, tmp, 0, 62)]      # DSRL32 tmp, tmp, 0
    o += [daddu(reg, reg, tmp)]
    return o


def main():
    o = []

    # ---- 32-bit: SUB overflows, SUBU wraps -------------------------------
    # (-2^31) - 1 is the smallest signed 32-bit value minus one.
    o += [lui(5, 0x8000)]                       # r5 = 0xFFFFFFFF80000000
    o += [addiu(6, 0, 1)]                       # r6 = 1
    o += [addiu(7, 0, 0x77)]                    # marker that must survive
    o += [sub_(7, 5, 6)]                        # traps; r7 must keep 0x77
    o += [subu(8, 5, 6)]                        # same operands, must wrap
    # and a SUB that does *not* overflow, so the trap is not unconditional
    o += [addiu(9, 0, 5), addiu(10, 0, 3), sub_(11, 9, 10)]      # r11 = 2

    # ---- 64-bit: DADD overflows, DADDU wraps -----------------------------
    o += load64(12, 0x7FFFFFFFFFFFFFFF, 2)
    o += [daddiu(13, 0, 1)]
    o += [addiu(14, 0, 0x14)]                   # marker
    o += [dadd(14, 12, 13)]                     # traps; r14 must keep 0x14
    o += [daddu(15, 12, 13)]                    # wraps to 0x8000000000000000
    # a DADD that does not overflow
    o += [daddiu(16, 0, 100), daddiu(17, 0, 23), dadd(18, 16, 17)]   # r18 = 123

    # ---- 64-bit: DSUB overflows, DSUBU wraps -----------------------------
    o += load64(19, 0x8000000000000000, 2)
    o += [daddiu(20, 0, 1)]
    o += [addiu(21, 0, 0x21)]                   # marker
    o += [dsub(21, 19, 20)]                     # traps; r21 must keep 0x21
    o += [dsubu(22, 19, 20)]                    # wraps to 0x7FFFFFFFFFFFFFFF

    # ---- DADDI overflows, DADDIU wraps -----------------------------------
    o += [addiu(23, 0, 0x23)]                   # marker
    o += [daddi(23, 12, 1)]                     # 2^63-1 + 1 traps
    o += [daddiu(24, 12, 1)]                    # same operands, must wrap
    # DADDI with a negative immediate that does not overflow
    o += [daddi(25, 16, -4 & 0xFFFF)]           # 100 - 4 = 96

    # park
    o += [beq(0, 0, -1 & 0xFFFF), NOP]

    body = len(o)
    assert body < HANDLER_WORD, "program ran into the exception vector"
    while len(o) < HANDLER_WORD:
        o.append(NOP)
    o += [mfc0(26, 14),          # EPC
          mfc0(27, 13),          # Cause -- the code is what says it was overflow
          addiu(28, 26, 4),      # step past the faulting instruction
          mtc0(28, 14),
          (16 << 26) | (16 << 21) | 24,        # ERET
          NOP]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return body


if __name__ == "__main__":
    main()
