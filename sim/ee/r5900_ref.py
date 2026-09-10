#!/usr/bin/env python3
"""A reference R5900 integer core, to check the RTL against.

    sim/ee/r5900_ref.py program.hex [--steps N] [--trace]

The EE core is written to the EE Core User's Manual, and the manual is not
"MIPS III plus SIMD" -- several integer instructions differ from stock MIPS in
ways that are easy to implement wrongly and hard to notice:

  * **GPRs are 128 bits.** Integer instructions define only the low 64 and the
    manual does not promise anything about the upper half, so this model keeps
    all 128 bits and leaves the upper half alone rather than zeroing it, which
    is what the hardware does and what MMI later depends on.
  * **MULT and MULTU write a GPR as well as HI/LO.** `mult rd, rs, rt` is a
    three-operand instruction on this core; on stock MIPS it has no rd. Reading
    the result out of LO only would pass every test that never uses the rd form.
  * **DIV and DIVU do not trap**, and division by zero has defined results
    rather than undefined ones.
  * **No integer overflow traps are taken by ADDU/DADDU**; ADD and DADD do
    trap, and this model records the trap rather than raising it, because the
    RTL has no exception path yet and a silent difference would be worse.

This is a *reference*, not a model of timing: it executes one instruction per
step with no pipeline, no cache and no memory latency. Its job is to say what
the architectural state should be after instruction N, so a difference in the
RTL is a difference in behaviour and not in scheduling.

State is dumped in the same format the testbench prints, one line per step:

    step pc gpr[n]=value ... hi lo

so a diff between the two files points at an instruction rather than a symptom.
"""
import argparse, sys

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
# The R5900's processor identifier, which the BIOS reads to tell an EE from an
# IOP.  Implementation 0x2E, revision 0x20.
PRID = 0x00002E20

# COP0 register numbers used by the exception path
C0_STATUS, C0_CAUSE, C0_EPC, C0_ERROREPC = 12, 13, 14, 30

# Exception codes, as Cause.ExcCode
EXC_INT, EXC_SYSCALL, EXC_BREAK, EXC_RI, EXC_OV = 0, 8, 9, 10, 12

# The instruction address space is aliased to the size of the test image, so the
# exception vector at 0x80000180 lands inside a program that can be loaded.  The
# testbench does the same.  It is a harness convention and not architecture:
# without it every exception test would need a megabyte of mostly-empty image,
# and the handler could never be reached at all.
IMEM_MASK = 0xFFFF


def s64(x):
    x &= M64
    return x - (1 << 64) if x >> 63 else x


def s32(x):
    x &= M32
    return x - (1 << 32) if x >> 31 else x


def sext32(x):
    """32-bit results are sign-extended into the 64-bit register, always."""
    return s32(x) & M64


class Mem:
    """Byte-addressable memory, little-endian, sparse."""
    def __init__(self, size=1 << 20):
        self.b = bytearray(size)

    def load(self, addr, n, signed=False):
        v = int.from_bytes(self.b[addr:addr + n], "little")
        if signed and v >> (n * 8 - 1):
            v -= 1 << (n * 8)
        return v & M64 if not signed else v & M64

    def store(self, addr, n, val):
        self.b[addr:addr + n] = (val & ((1 << (n * 8)) - 1)).to_bytes(n, "little")


class R5900:
    def __init__(self, mem, pc=0):
        self.gpr = [0] * 32          # 128-bit each; integer ops touch the low 64
        self.pc = pc
        self.hi = self.lo = 0
        # The R5900 has a *second* HI/LO pair, written by the MMI pipeline-1
        # instructions.  It is not an MMI SIMD feature bolted on: MULT1 and its
        # relatives are the ordinary multiply and divide aimed at HI1/LO1, so a
        # compiler can keep two multiply chains in flight without spilling.
        self.hi1 = self.lo1 = 0
        # COP0, the system control coprocessor: 32 registers of 32 bits.  This
        # slice is the register file and MFC0/MTC0 only.  Count is deliberately
        # *not* free-running here, because this model has no notion of time and
        # a counter that advanced would make every trace disagree with the RTL
        # for a reason that has nothing to do with either being wrong.  The
        # timer behaviour belongs with the exception path, which is where a
        # cycle count starts to mean something.
        self.cop0 = [0] * 32
        self.cop0[15] = PRID          # PRId is read-only and identifies the core
        self.exceptions = 0           # taken, for a test that would otherwise
                                      # pass by never reaching the handler
        self.mem = mem
        self.traps = []
        self.delay = None            # (target_pc,) pending after the delay slot

    # -- register access: r0 is hardwired zero, and writes to it vanish -------
    def r(self, n):
        return self.gpr[n] & M64

    def w(self, n, v):
        if n == 0:
            return
        # Leave the upper 64 bits alone: integer instructions do not define
        # them, and MMI later reads them.
        self.gpr[n] = (self.gpr[n] & ~M64) | (v & M64)

    def step(self):
        # The instruction address space is aliased to the test image; see
        # IMEM_MASK.  Data addresses are not, so a store still goes where it says.
        instr = self.mem.load(self.pc & IMEM_MASK, 4) & M32
        taken = self.delay
        self.delay = None
        # Whether *this* instruction is in a delay slot is not something exec can
        # work out for itself: self.delay describes the instruction being
        # executed, not the one before it.  An exception needs to know, because
        # EPC has to name the branch rather than the slot.
        self.in_delay = taken is not None
        self.exc_taken = False
        self.exec(instr)
        # An exception wins over a pending branch: the handler is where control
        # goes, and the branch is what EPC remembers.
        if taken is not None and not self.exc_taken:
            self.pc = taken
        return instr

    def exception(self, code):
        """Enter the general exception handler.

        EPC records where to resume, which is the *branch* rather than the
        instruction that faulted when the fault happened in a delay slot --
        resuming at the delay slot alone would skip the branch and take the
        wrong path.  Cause.BD says which it was.  Status.EXL is what makes the
        handler non-reentrant, and it is also why an exception raised while EXL
        is already set does not overwrite EPC: the first one is the one worth
        keeping.
        """
        st = self.cop0[C0_STATUS]
        in_delay = self.in_delay
        if not (st >> 1) & 1:                       # Status.EXL
            epc = (self.pc - 4) & M64               # the faulting instruction
            if in_delay:
                epc = (epc - 4) & M64               # the branch before it
            self.cop0[C0_EPC] = epc & M32
            self.cop0[C0_CAUSE] = ((self.cop0[C0_CAUSE] & ~0x8000007C)
                                   | (code << 2)
                                   | (0x80000000 if in_delay else 0))
            self.cop0[C0_STATUS] = st | 2           # set EXL
        # BEV picks which of the two vector bases is used; the offset for a
        # general exception is 0x180 either way.
        base = 0xBFC00200 if (st >> 22) & 1 else 0x80000000
        # The PC is 32 bits and sign-extends into the 64-bit architectural view,
        # so a KSEG0 vector reads as 0xFFFFFFFF80000180 rather than 0x80000180.
        # The core does the same, because its PC really is 32 bits wide.
        self.pc = sext32((base + 0x180) & M32)
        self.delay = None                           # a pending branch is lost
        self.exc_taken = True
        self.exceptions += 1

    def eret(self):
        """Return from an exception, and clear the flag that got us here.

        ERL is checked before EXL because an error-level exception is the more
        serious of the two and returns through its own register.  ERET has no
        delay slot: the instruction after it does not execute.
        """
        st = self.cop0[C0_STATUS]
        if (st >> 2) & 1:                           # Status.ERL
            self.pc = sext32(self.cop0[C0_ERROREPC] & M32)
            self.cop0[C0_STATUS] = st & ~4
        else:
            self.pc = sext32(self.cop0[C0_EPC] & M32)
            self.cop0[C0_STATUS] = st & ~2
        self.delay = None
        self.exc_taken = True

    def branch(self, target):
        self.delay = target & M64

    def exec(self, i):
        op = i >> 26
        rs, rt, rd = (i >> 21) & 31, (i >> 16) & 31, (i >> 11) & 31
        sa, fn = (i >> 6) & 31, i & 0x3F
        imm = i & 0xFFFF
        simm = imm - 0x10000 if imm & 0x8000 else imm
        nxt = (self.pc + 4) & M64
        self.pc = nxt

        if op == 0:
            self._special(i, rs, rt, rd, sa, fn)
        elif op == 1:
            self._regimm(rs, rt, simm, nxt)
        elif op == 2:                                   # J
            self.branch((nxt & ~0x0FFFFFFF) | ((i & 0x3FFFFFF) << 2))
        elif op == 3:                                   # JAL
            self.w(31, (nxt + 4) & M64)
            self.branch((nxt & ~0x0FFFFFFF) | ((i & 0x3FFFFFF) << 2))
        elif op == 4:                                   # BEQ
            if self.r(rs) == self.r(rt): self.branch(nxt + (simm << 2))
        elif op == 5:                                   # BNE
            if self.r(rs) != self.r(rt): self.branch(nxt + (simm << 2))
        elif op == 6:                                   # BLEZ
            if s64(self.r(rs)) <= 0: self.branch(nxt + (simm << 2))
        elif op == 7:                                   # BGTZ
            if s64(self.r(rs)) > 0: self.branch(nxt + (simm << 2))
        elif op == 8:                                   # ADDI
            v = s32(self.r(rs)) + simm
            if not (-(1 << 31) <= v < (1 << 31)):
                self.exception(EXC_OV)     # and rt is left alone
            else:
                self.w(rt, sext32(v))
        elif op == 9:                                   # ADDIU
            self.w(rt, sext32(s64(self.r(rs)) + simm))
        elif op == 10:                                  # SLTI
            self.w(rt, 1 if s64(self.r(rs)) < simm else 0)
        elif op == 11:                                  # SLTIU
            self.w(rt, 1 if self.r(rs) < (simm & M64) else 0)
        elif op == 12: self.w(rt, self.r(rs) & imm)     # ANDI
        elif op == 13: self.w(rt, self.r(rs) | imm)     # ORI
        elif op == 14: self.w(rt, self.r(rs) ^ imm)     # XORI
        elif op == 15: self.w(rt, sext32(imm << 16))    # LUI
        elif op == 24:                                  # DADDI (traps)
            self.w(rt, (s64(self.r(rs)) + simm) & M64)
        elif op == 25:                                  # DADDIU
            self.w(rt, (s64(self.r(rs)) + simm) & M64)
        elif op in (32, 33, 35, 36, 37, 39, 55):        # loads
            a = (s64(self.r(rs)) + simm) & M64
            # width in bytes, and whether the value is sign-extended to 64 bits.
            # LWU is the one that is not: MIPS III added it precisely so a
            # 32-bit load can be zero-extended, and getting it wrong is
            # invisible until an address goes over 0x7fffffff.
            width, signed = {32: (1, True), 36: (1, False),
                             33: (2, True), 37: (2, False),
                             35: (4, True), 39: (4, False),
                             55: (8, False)}[op]
            v = self.mem.load(a, width)
            if signed and v >> (width * 8 - 1):
                v -= 1 << (width * 8)
            self.w(rt, v & M64)
        elif op in (40, 41, 43, 63):                    # stores
            a = (s64(self.r(rs)) + simm) & M64
            n = {40: 1, 41: 2, 43: 4, 63: 8}[op]
            self.mem.store(a, n, self.r(rt))
        elif op == 16:                                  # COP0
            if rs == 0:                                 # MFC0
                self.w(rt, sext32(self.cop0[rd] & M32))
            elif rs == 4:                               # MTC0
                if rd != 15:                            # PRId is read-only
                    self.cop0[rd] = self.r(rt) & M32
            elif rs == 16 and (i & 0x3F) == 24:         # ERET
                self.eret()
            else:
                # the remaining CO forms are the TLB instructions
                self.traps.append(("unimplemented COP0 rs %d" % rs, self.pc - 4))
        elif op == 28:                                  # MMI
            if fn in (16, 17, 18, 19, 24, 25, 26, 27):
                # the same operations as SPECIAL, on the second HI/LO pair
                self._hilo(fn, rs, rt, rd, pipe1=True)
            else:
                self.traps.append(("unimplemented MMI fn %d" % fn, self.pc - 4))
        elif op in (34, 38, 42, 46, 26, 27, 44, 45):    # unaligned
            # LWL/LWR and their doubleword and store counterparts.  A compiler
            # emits these in pairs to move a word that is not aligned, and each
            # one touches only part of the aligned unit that contains the
            # address, merging with whatever is already in the register or in
            # memory.  These are little-endian forms: on a big-endian machine
            # "left" and "right" swap, which is the classic way to get them
            # subtly wrong.
            a = (s64(self.r(rs)) + simm) & M64
            if op in (34, 38, 42, 46):                  # word forms
                base, k, mask = a & ~3, a & 3, M32
                word = self.mem.load(base, 4)
                if op == 34:                            # LWL
                    sh = 8 * (3 - k)
                    v = ((word << sh) | (self.r(rt) & ((1 << sh) - 1))) & mask
                    self.w(rt, sext32(v))
                elif op == 38:                          # LWR
                    sh = 8 * k
                    keep = (mask << (32 - sh)) & mask if sh else 0
                    v = ((word >> sh) | (self.r(rt) & keep)) & mask
                    self.w(rt, sext32(v))
                elif op == 42:                          # SWL
                    sh = 8 * (3 - k)
                    cur = word
                    nb = k + 1                          # bytes written, at the low end
                    bm = (1 << (8 * nb)) - 1
                    self.mem.store(base, 4, (cur & ~bm | ((self.r(rt) >> sh) & bm)) & mask)
                else:                                   # SWR
                    sh = 8 * k
                    cur = word
                    bm = (mask << sh) & mask
                    self.mem.store(base, 4, (cur & ~bm | ((self.r(rt) << sh) & bm)) & mask)
            else:                                       # doubleword forms
                base, k, mask = a & ~7, a & 7, M64
                dw = self.mem.load(base, 8)
                if op == 26:                            # LDL
                    sh = 8 * (7 - k)
                    self.w(rt, ((dw << sh) | (self.r(rt) & ((1 << sh) - 1))) & mask)
                elif op == 27:                          # LDR
                    sh = 8 * k
                    keep = (mask << (64 - sh)) & mask if sh else 0
                    self.w(rt, ((dw >> sh) | (self.r(rt) & keep)) & mask)
                elif op == 44:                          # SDL
                    sh = 8 * (7 - k)
                    bm = (1 << (8 * (k + 1))) - 1
                    self.mem.store(base, 8, (dw & ~bm | ((self.r(rt) >> sh) & bm)) & mask)
                else:                                   # SDR
                    sh = 8 * k
                    bm = (mask << sh) & mask
                    self.mem.store(base, 8, (dw & ~bm | ((self.r(rt) << sh) & bm)) & mask)
        else:
            self.traps.append(("unimplemented op %d" % op, self.pc - 4))

    def _hilo(self, fn, rs, rt, rd, pipe1):
        """MFHI/MTHI/MFLO/MTLO/MULT/MULTU/DIV/DIVU, on either HI/LO pair.

        The MMI pipeline-1 forms -- MULT1, MULTU1, DIV1, DIVU1, MFHI1, MFLO1,
        MTHI1, MTLO1 -- are these same operations aimed at the R5900's second
        HI/LO pair, and their function codes mirror the SPECIAL ones exactly.
        Writing it once means the second pair cannot drift from the first, which
        is the only way this could go wrong quietly.
        """
        a, b = self.r(rs), self.r(rt)
        hi = self.hi1 if pipe1 else self.hi
        lo = self.lo1 if pipe1 else self.lo

        if fn == 16:                                                  # MFHI
            self.w(rd, hi); return
        if fn == 18:                                                  # MFLO
            self.w(rd, lo); return
        if fn == 17:                                                  # MTHI
            hi = a
        elif fn == 19:                                                # MTLO
            lo = a
        elif fn in (24, 25):                                          # MULT/MULTU
            p = (s32(a) * s32(b)) if fn == 24 else ((a & M32) * (b & M32))
            lo, hi = sext32(p & M32), sext32((p >> 32) & M32)
            # The R5900 form also writes rd.  rd == 0 is the MIPS-compatible
            # encoding and writes nothing, which is why this is easy to miss.
            self.w(rd, lo)
        else:                                                         # DIV/DIVU
            if fn == 26:
                x, y = s32(a), s32(b)
                if y == 0:
                    lo, hi = sext32(-1 if x >= 0 else 1), sext32(x)
                else:
                    q = abs(x) // abs(y) * (1 if (x < 0) == (y < 0) else -1)
                    lo, hi = sext32(q), sext32(x - q * y)
            else:
                x, y = a & M32, b & M32
                if y == 0: lo, hi = sext32(M32), sext32(x)
                else: lo, hi = sext32(x // y), sext32(x % y)

        if pipe1:
            self.hi1, self.lo1 = hi, lo
        else:
            self.hi, self.lo = hi, lo

    def _regimm(self, rs, rt, simm, nxt):
        v = s64(self.r(rs))
        if rt == 0 and v < 0: self.branch(nxt + (simm << 2))          # BLTZ
        elif rt == 1 and v >= 0: self.branch(nxt + (simm << 2))       # BGEZ
        elif rt == 16:                                                # BLTZAL
            self.w(31, (nxt + 4) & M64)
            if v < 0: self.branch(nxt + (simm << 2))
        elif rt == 17:                                                # BGEZAL
            self.w(31, (nxt + 4) & M64)
            if v >= 0: self.branch(nxt + (simm << 2))

    def _special(self, i, rs, rt, rd, sa, fn):
        a, b = self.r(rs), self.r(rt)
        if   fn == 0:  self.w(rd, sext32(b << sa))                    # SLL
        elif fn == 2:  self.w(rd, sext32((b & M32) >> sa))            # SRL
        elif fn == 3:  self.w(rd, sext32(s32(b) >> sa))               # SRA
        elif fn == 4:  self.w(rd, sext32(b << (a & 31)))              # SLLV
        elif fn == 6:  self.w(rd, sext32((b & M32) >> (a & 31)))      # SRLV
        elif fn == 7:  self.w(rd, sext32(s32(b) >> (a & 31)))         # SRAV
        elif fn == 8:  self.branch(a)                                 # JR
        elif fn == 9:  self.w(rd or 31, (self.pc + 4) & M64); self.branch(a)   # JALR
        elif fn in (16, 17, 18, 19, 24, 25, 26, 27):
            self._hilo(fn, rs, rt, rd, pipe1=False)
        elif fn == 12: self.exception(EXC_SYSCALL)                    # SYSCALL
        elif fn == 13: self.exception(EXC_BREAK)                      # BREAK
        elif fn == 20: self.w(rd, b << (a & 63) & M64)                # DSLLV
        elif fn == 22: self.w(rd, b >> (a & 63))                      # DSRLV
        elif fn == 23: self.w(rd, s64(b) >> (a & 63) & M64)           # DSRAV
        elif fn == 32:                                                # ADD
            v = s32(a) + s32(b)
            if not (-(1 << 31) <= v < (1 << 31)):
                self.exception(EXC_OV)     # and rd is left alone
            else:
                self.w(rd, sext32(v))
        elif fn == 33: self.w(rd, sext32(s32(a) + s32(b)))            # ADDU
        elif fn == 34: self.w(rd, sext32(s32(a) - s32(b)))            # SUB
        elif fn == 35: self.w(rd, sext32(s32(a) - s32(b)))            # SUBU
        elif fn == 36: self.w(rd, a & b)                              # AND
        elif fn == 37: self.w(rd, a | b)                              # OR
        elif fn == 38: self.w(rd, a ^ b)                              # XOR
        elif fn == 39: self.w(rd, ~(a | b) & M64)                     # NOR
        elif fn == 42: self.w(rd, 1 if s64(a) < s64(b) else 0)        # SLT
        elif fn == 43: self.w(rd, 1 if a < b else 0)                  # SLTU
        elif fn == 45: self.w(rd, (s64(a) + s64(b)) & M64)            # DADDU
        elif fn == 47: self.w(rd, (s64(a) - s64(b)) & M64)            # DSUBU
        elif fn == 56: self.w(rd, (b << sa) & M64)                    # DSLL
        elif fn == 58: self.w(rd, b >> sa)                            # DSRL
        elif fn == 59: self.w(rd, s64(b) >> sa & M64)                 # DSRA
        elif fn == 60: self.w(rd, (b << (sa + 32)) & M64)             # DSLL32
        elif fn == 62: self.w(rd, b >> (sa + 32))                     # DSRL32
        elif fn == 63: self.w(rd, s64(b) >> (sa + 32) & M64)          # DSRA32
        else: self.traps.append(("unimplemented special %d" % fn, self.pc - 4))


def dump(cpu, step, pc):
    """One line per retired instruction, matching what the testbench prints.

    `pc` is the address of the instruction that just ran, not the next one: a
    divergence should name the instruction responsible rather than the one after
    it.  Every register is printed, not just the non-zero ones, so a diff cannot
    be confused by a register merely becoming zero.
    """
    regs = " ".join("r%02d=%016x" % (n, cpu.r(n)) for n in range(1, 32))
    return "%4d pc=%016x hi=%016x lo=%016x hi1=%016x lo1=%016x %s" % (
        step, pc, cpu.hi, cpu.lo, cpu.hi1, cpu.lo1, regs)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("program")
    ap.add_argument("--steps", type=int, default=64)
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0)
    ap.add_argument("--dump-mem", nargs=2, type=lambda x: int(x, 0), metavar=("FROM", "LEN"),
                    help="after the run, print this region as 64-bit words")
    a = ap.parse_args()
    mem = Mem()
    words = [int(l.split("//")[0].strip(), 16) for l in open(a.program)
             if l.split("//")[0].strip()]
    for k, wv in enumerate(words):
        mem.store(a.base + k * 4, 4, wv)
    cpu = R5900(mem, a.base)
    prog_end = a.base + 4 * len(words)
    for n in range(a.steps):
        # Stop when the PC leaves the program that was loaded.  This used to
        # test the instruction word for zero instead, which quietly made NOP a
        # halt instruction: 0x00000000 is SLL r0, r0, 0 and is the natural way
        # to space dependent instructions apart in a directed hazard test.  A
        # test written that way stopped at its first gap, and the diff counted
        # the handful of instructions before it as a pass.
        if not (a.base <= (cpu.pc & IMEM_MASK) < prog_end):
            break
        here = cpu.pc
        cpu.step()
        print(dump(cpu, n, here))
    if a.dump_mem:
        # Registers alone cannot show a store that went to the wrong address:
        # the difference stays in memory until something loads it back, and by
        # then the instruction responsible is long gone.
        lo_, ln = a.dump_mem
        for off in range(0, ln, 8):
            print("MEM %08x %016x" % (lo_ + off, mem.load(lo_ + off, 8)))
    for t, pc in cpu.traps:
        print("# trap: %s at %016x" % (t, pc), file=sys.stderr)


if __name__ == "__main__":
    main()
