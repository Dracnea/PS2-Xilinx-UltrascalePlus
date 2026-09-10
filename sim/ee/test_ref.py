#!/usr/bin/env python3
"""Self-test for the R5900 reference model.

    sim/ee/test_ref.py

The reference is what the RTL will be judged against, so it has to be judged
first.  These are the cases where the R5900 departs from stock MIPS III, or
where a plausible-looking implementation is wrong in a way no ordinary program
would reveal.  Each one is a hand-computed expectation, not a recording of what
this model happens to produce.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from r5900_ref import R5900, Mem

def run(prog, data=None, steps=None, pre=None):
    m = Mem()
    for k, w in enumerate(prog):
        m.store(k * 4, 4, w)
    for a, n, v in (data or []):          # after the code, so data wins on overlap
        m.store(a, n, v)
    c = R5900(m, 0)
    if pre:
        pre(c)
    for _ in range(steps or len(prog)):
        c.step()
    return c

CASES = []
def case(name):
    def deco(fn):
        CASES.append((name, fn)); return fn
    return deco


@case("a negative 32-bit result sign-extends through all 64 bits")
def _():
    c = run([0x3c01ffff, 0x3421ffff, 0x00011021])
    return c.r(2) == 0xFFFFFFFFFFFFFFFF, "r2=%016x" % c.r(2)


@case("MULT writes rd as well as LO (the R5900 three-operand form)")
def _():
    c = run([0x24010007, 0x24020006, 0x00221818])
    return c.lo == 42 and c.r(3) == 42, "lo=%d rd=%d" % (c.lo, c.r(3))


@case("MULT with rd=0 writes no register (the MIPS-compatible encoding)")
def _():
    c = run([0x24010007, 0x24020006, 0x00220018])
    return c.lo == 42 and c.r(0) == 0, "lo=%d r0=%d" % (c.lo, c.r(0))


@case("DSLL32 shifts by sa+32")
def _():
    c = run([0x24010001, 0x0001103c])
    return c.r(2) == 1 << 32, "r2=%016x" % c.r(2)


@case("LW sign-extends, LWU zero-extends")
def _():
    a = run([0x8c210100], [(0x100, 4, 0xFFFFFABC)])
    b = run([0x9c220100], [(0x100, 4, 0xFFFFFABC)])
    return (a.r(1) == 0xFFFFFFFFFFFFFABC and b.r(2) == 0xFFFFFABC,
            "lw=%016x lwu=%016x" % (a.r(1), b.r(2)))


@case("LB sign-extends, LBU does not")
def _():
    a = run([0x80210100], [(0x100, 1, 0x9C)])
    b = run([0x90220100], [(0x100, 1, 0x9C)])
    return (a.r(1) == 0xFFFFFFFFFFFFFF9C and b.r(2) == 0x9C,
            "lb=%016x lbu=%016x" % (a.r(1), b.r(2)))


@case("DIV by zero is defined and does not trap")
def _():
    c = run([0x2401000a, 0x0020001a])
    return (c.lo == 0xFFFFFFFFFFFFFFFF and c.hi == 10 and not c.traps,
            "lo=%016x hi=%016x traps=%d" % (c.lo, c.hi, len(c.traps)))


@case("an integer write leaves a GPR's upper 64 bits alone")
def _():
    c = run([0x24010005], pre=lambda c: c.gpr.__setitem__(1, 0xDEADBEEFCAFEBABE << 64))
    return ((c.gpr[1] >> 64) == 0xDEADBEEFCAFEBABE and c.r(1) == 5,
            "upper=%016x low=%016x" % (c.gpr[1] >> 64, c.r(1)))


@case("a branch runs its delay slot, then the target")
def _():
    c = run([0x10000002, 0x24010001, 0x24020002, 0x24030003], steps=4)
    return (c.r(1) == 1 and c.r(2) == 0 and c.r(3) == 3,
            "r1=%d r2=%d r3=%d" % (c.r(1), c.r(2), c.r(3)))


@case("writes to r0 are discarded")
def _():
    c = run([0x2400ffff])
    return c.r(0) == 0, "r0=%016x" % c.r(0)


def main():
    bad = 0
    for name, fn in CASES:
        ok, detail = fn()
        print("  %-4s %-58s %s" % ("PASS" if ok else "FAIL", name, detail))
        bad += not ok
    print("\n%d of %d pass" % (len(CASES) - bad, len(CASES)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
