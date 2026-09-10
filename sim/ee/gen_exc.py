#!/usr/bin/env python3
"""Emit a directed exception program: SYSCALL, BREAK, overflow, and ERET.

    sim/ee/gen_exc.py > exc.hex

The general exception vector is 0x80000180, and the instruction address space in
this harness is aliased to the 64 KB image (see IMEM_MASK in the reference and
the matching mask in the testbench), so the handler sits at word 0x60 -- 0x180
in bytes.  Without that aliasing an exception test would need a megabyte of
mostly-empty image and the handler could never be reached at all.

The handler is a realistic one: it reads EPC, steps it past the faulting
instruction and writes it back before returning.  Without the step, SYSCALL
returns to itself and the program never advances -- which is correct hardware
behaviour and a mistake worth making once.
"""

HANDLER_WORD = 0x180 // 4

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def addiu(rt, rs, i): return (9 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def addi(rt, rs, i):  return (8 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def add_(rd, rs, rt): return sp(rs, rt, rd, 0, 32)
def addu(rd, rs, rt): return sp(rs, rt, rd, 0, 33)
def mfc0(rt, rd):     return (16 << 26) | (0 << 21) | (rt << 16) | (rd << 11)
def mtc0(rt, rd):     return (16 << 26) | (4 << 21) | (rt << 16) | (rd << 11)
def beq(rs, rt, off): return (4 << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)
SYSCALL = sp(0, 0, 0, 0, 12)
BREAK   = sp(0, 0, 0, 0, 13)
ERET    = (16 << 26) | (16 << 21) | 24
NOP     = 0


def main():
    o = []
    # a marker before and after each fault, so a handler that returns to the
    # wrong place shows up as a marker that never runs or runs twice
    o += [addiu(1, 0, 0x101), SYSCALL, addiu(2, 0, 0x102)]
    o += [addiu(3, 0, 0x103), BREAK,   addiu(4, 0, 0x104)]

    # ADD overflow: 0x7fffffff + 1.  The destination must be left alone, which
    # is what separates a real trap from a trap that happens to be counted.
    o += [lui(5, 0x7FFF), addiu(5, 5, -1 & 0xFFFF), addiu(6, 0, 2),
          addiu(7, 0, 0x77),                    # r7 holds a value that must survive
          add_(7, 5, 6),                        # overflows: r7 must keep 0x77
          addiu(8, 0, 0x108)]
    # ADDIU with the same operands does not trap
    o += [addu(9, 5, 6)]
    # ADDI overflow, same shape
    o += [addiu(10, 0, 0x10A), addi(10, 5, 0x7FFF), addiu(11, 0, 0x10B)]

    # an exception in a branch delay slot: EPC must name the branch, and
    # Cause.BD must be set.  The handler steps EPC by four, which lands on the
    # slot itself; the second time round it is no longer in a delay slot, so
    # this terminates rather than looping.
    o += [addiu(12, 0, 1), beq(12, 12, 1), SYSCALL, addiu(13, 0, 0x10D),
          addiu(14, 0, 0x10E)]

    # park, so execution does not wander into the handler as straight-line code
    o += [beq(0, 0, -1 & 0xFFFF), NOP]

    body = len(o)
    while len(o) < HANDLER_WORD:
        o.append(NOP)
    o += [mfc0(20, 14),          # EPC
          mfc0(21, 13),          # Cause
          addiu(22, 20, 4),      # step past the faulting instruction
          mtc0(22, 14),
          ERET,
          NOP]

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return body


if __name__ == "__main__":
    main()
