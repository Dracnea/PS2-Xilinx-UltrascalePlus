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
        instr = self.mem.load(self.pc, 4) & M32
        taken = self.delay
        self.delay = None
        self.exec(instr)
        if taken is not None:
            self.pc = taken
        return instr

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
        elif op == 8:                                   # ADDI (traps)
            v = s64(self.r(rs)) + simm
            if not (-(1 << 31) <= s32(v) == v < (1 << 31)):
                self.traps.append(("ADDI overflow", self.pc - 4))
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
        else:
            self.traps.append(("unimplemented op %d" % op, self.pc - 4))

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
        elif fn == 16: self.w(rd, self.hi)                            # MFHI
        elif fn == 17: self.hi = a                                    # MTHI
        elif fn == 18: self.w(rd, self.lo)                            # MFLO
        elif fn == 19: self.lo = a                                    # MTLO
        elif fn == 20: self.w(rd, b << (a & 63) & M64)                # DSLLV
        elif fn == 22: self.w(rd, b >> (a & 63))                      # DSRLV
        elif fn == 23: self.w(rd, s64(b) >> (a & 63) & M64)           # DSRAV
        elif fn in (24, 25):                                          # MULT/MULTU
            p = (s32(a) * s32(b)) if fn == 24 else ((a & M32) * (b & M32))
            self.lo, self.hi = sext32(p & M32), sext32((p >> 32) & M32)
            # The R5900 form also writes rd.  rd == 0 is the MIPS-compatible
            # encoding and writes nothing, which is why this is easy to miss.
            self.w(rd, self.lo)
        elif fn in (26, 27):                                          # DIV/DIVU
            if fn == 24 or fn == 26:
                x, y = s32(a), s32(b)
                if y == 0:
                    self.lo, self.hi = sext32(-1 if x >= 0 else 1), sext32(x)
                else:
                    q = abs(x) // abs(y) * (1 if (x < 0) == (y < 0) else -1)
                    self.lo, self.hi = sext32(q), sext32(x - q * y)
            else:
                x, y = a & M32, b & M32
                if y == 0: self.lo, self.hi = sext32(M32), sext32(x)
                else: self.lo, self.hi = sext32(x // y), sext32(x % y)
        elif fn == 32:                                                # ADD (traps)
            v = s32(a) + s32(b)
            if not (-(1 << 31) <= v < (1 << 31)):
                self.traps.append(("ADD overflow", self.pc - 4))
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
        elif fn == 12: self.traps.append(("SYSCALL", self.pc - 4))
        elif fn == 13: self.traps.append(("BREAK", self.pc - 4))
        else: self.traps.append(("unimplemented special %d" % fn, self.pc - 4))


def dump(cpu, step):
    """One line per step, matching what the testbench prints."""
    regs = " ".join("r%d=%016x" % (n, cpu.r(n)) for n in range(1, 32) if cpu.r(n))
    return "%4d pc=%016x hi=%016x lo=%016x %s" % (step, cpu.pc, cpu.hi, cpu.lo, regs)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("program")
    ap.add_argument("--steps", type=int, default=64)
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0)
    a = ap.parse_args()
    mem = Mem()
    words = [int(l.split("//")[0].strip(), 16) for l in open(a.program)
             if l.split("//")[0].strip()]
    for k, wv in enumerate(words):
        mem.store(a.base + k * 4, 4, wv)
    cpu = R5900(mem, a.base)
    for n in range(a.steps):
        if not mem.load(cpu.pc, 4):
            break
        cpu.step()
        print(dump(cpu, n))
    for t, pc in cpu.traps:
        print("# trap: %s at %016x" % (t, pc), file=sys.stderr)


if __name__ == "__main__":
    main()
