#!/usr/bin/env python3
"""Cross-check sim/ee/r5900_ref.py against a second, independent R5900 model.

    tools/ee/xcheck_r5900.py [--repo ~/PS2_fpga] [--n 20000] [--seed 1]

The reference this project's RTL is diffed against has been checked two ways so
far: written from the EE Core User's Manual, and hand-computed at the corners.
Neither of those is a second implementation, and a reference that is wrong in
the same way as the RTL it checks produces a green harness and a broken core.

birdybro/PS2_fpga is a second implementation, MIT-licensed, written
independently from the same manual, and in Python -- so the two can be stepped
side by side on the same instruction and compared directly, which is far
sharper than comparing prose.  It is early: its RTL is an R5900 fragment and
every other block is an empty directory, so there is nothing there to reuse as
hardware.  Its reference model is the part worth having, and only for the
instructions both implement: the arithmetic, logic, shift, multiply and divide
set, with no branches and no memory on their side.

Nothing is copied.  The tool imports their model from a checkout at run time,
the way tools/gs/xcheck_swizzle.py reads PCSX2's tables, and reports
disagreements.  Where the two disagree the manual decides, and this project's
model is not assumed right merely because it is ours.

Note: as checked out, their module does not import on Python 3.12 -- a forward
reference in a method annotation without `from __future__ import annotations`.
This inserts that line into a copy in memory rather than editing their tree.
"""
import argparse, importlib.util, os, random, sys, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "sim", "ee"))
import r5900_ref as MINE


def load_theirs(repo):
    path = os.path.join(os.path.expanduser(repo), "reference", "ee", "r5900.py")
    if not os.path.exists(path):
        return None, "no checkout at %s" % path
    src = open(path, encoding="utf-8").read()
    if "from __future__ import annotations" not in src:
        src = "from __future__ import annotations\n" + src
    mod = types.ModuleType("theirs_r5900")
    mod.__dict__["__file__"] = path
    # dataclasses resolves a class's annotations through
    # sys.modules[cls.__module__].__dict__, so the module has to be registered
    # before the class body runs, not after.
    sys.modules["theirs_r5900"] = mod
    try:
        exec(compile(src, path, "exec"), mod.__dict__)
    except Exception as e:                      # pragma: no cover - diagnostic
        return None, "could not load: %r" % (e,)
    return mod, None


def sp(rs, rt, rd, sa, fn):
    return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn


def imm_op(op, rs, rt, i):
    return (op << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)


# Only what both implement.  Theirs has no branches and no memory, and no
# trapping ADD/SUB/DADD/DSUB, so those are this project's problem alone.
SPECIALS = [0, 2, 3, 4, 6, 7, 20, 22, 23, 56, 58, 59, 60, 62, 63,
            33, 35, 36, 37, 38, 39, 42, 43, 45, 47,
            24, 25, 26, 27, 16, 18, 17, 19]
IMMS = [9, 10, 11, 12, 13, 14, 15, 25]
# MMI pipeline-1: the same operations on the R5900's second HI/LO pair, with
# function codes that mirror the SPECIAL ones.  Their model implements MULT1,
# MULTU1, DIV1, DIVU1 and MFHI1; MFLO1, MTHI1 and MTLO1 it does not have yet,
# so those are checked here only against the manual.
MMI_FNS = [24, 25, 26, 27, 16]


# Their model rejects an instruction whose architecturally-unused encoding
# fields are non-zero, where hardware ignores them -- MIPS calls those cases
# UNPREDICTABLE and real silicon simply does not look.  That is a defensible
# choice for a verification model and not a disagreement about behaviour, but it
# means a generator that fills every field at random has three quarters of its
# output refused.  Emitting canonical encodings instead is what makes the
# comparison cover the instruction set rather than the encoding space.
SHIFT_SA  = {0, 2, 3, 56, 58, 59, 60, 62, 63}          # rs unused
SHIFT_VAR = {4, 6, 7, 20, 22, 23}                      # sa unused
THREE_OP  = {33, 35, 36, 37, 38, 39, 42, 43, 45, 47}   # sa unused
MULDIV    = {24, 25, 26, 27}
MOVE_FROM = {16, 18}                                   # rs, rt unused
MOVE_TO   = {17, 19}                                   # rt, rd unused


def gen(rng):
    if rng.random() < 0.15:
        fn = rng.choice(MMI_FNS)
        rs, rt, rd, sa = rng.randrange(32), rng.randrange(32), rng.randrange(1, 32), 0
        if fn == 16:
            rs = rt = 0
        elif fn in (26, 27):
            rd = 0
        return (28 << 26) | sp(rs, rt, rd, sa, fn)
    if rng.random() < 0.7:
        fn = rng.choice(SPECIALS)
        rs, rt, rd, sa = (rng.randrange(32), rng.randrange(32),
                          rng.randrange(1, 32), rng.randrange(32))
        if fn in SHIFT_SA:
            rs = 0
        elif fn in SHIFT_VAR or fn in THREE_OP:
            sa = 0
        elif fn in MULDIV:
            sa = 0
            if fn in (26, 27):
                rd = 0                 # DIV and DIVU write only HI and LO
        elif fn in MOVE_FROM:
            rs = rt = sa = 0
        elif fn in MOVE_TO:
            rt = rd = sa = 0
        return sp(rs, rt, rd, sa, fn)
    op = rng.choice(IMMS)
    rs = 0 if op == 15 else rng.randrange(32)          # LUI has no source
    return imm_op(op, rs, rng.randrange(1, 32), rng.randrange(1 << 16))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default="~/PS2_fpga")
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    theirs, err = load_theirs(a.repo)
    if theirs is None:
        print("skip: %s" % err)
        print("this is a cross-check, not a test: absence is not a pass")
        return 2

    rng = random.Random(a.seed)
    mem = MINE.Mem()
    mine = MINE.R5900(mem, 0)
    them = theirs.R5900State.initial()

    # the same starting registers on both sides
    for r in range(1, 32):
        v = rng.randrange(1 << 64)
        mine.gpr[r] = v
        them = them.write_gpr(r, v)

    checked = unsupported = 0
    bad = []
    for _ in range(a.n):
        ir = gen(rng)
        try:
            nxt = them.step(ir)
        except theirs.UnsupportedInstructionError:
            unsupported += 1
            continue
        except Exception as e:
            bad.append(("their model raised %r" % (e,), ir, None, None))
            continue
        mem.store(mine.pc, 4, ir)
        mine.step()
        checked += 1
        for r in range(1, 32):
            m = mine.r(r) & MINE.M64
            t = nxt.gprs[r] & MINE.M64
            if m != t:
                bad.append(("r%d" % r, ir, m, t))
        for name, m, t in (("hi", mine.hi & MINE.M64, nxt.hi & MINE.M64),
                           ("lo", mine.lo & MINE.M64, nxt.lo & MINE.M64),
                           ("hi1", mine.hi1 & MINE.M64, nxt.hi1 & MINE.M64),
                           ("lo1", mine.lo1 & MINE.M64, nxt.lo1 & MINE.M64)):
            if m != t:
                bad.append((name, ir, m, t))
        if bad:
            break
        them = nxt

    print("%d instructions compared, %d unsupported by their model" % (checked, unsupported))
    if bad:
        what, ir, m, t = bad[0]
        op, fn = ir >> 26, ir & 0x3F
        print("FAIL  %s after instruction %08x (op=%d fn=%d rs=%d rt=%d rd=%d sa=%d)"
              % (what, ir, op, fn, (ir >> 21) & 31, (ir >> 16) & 31,
                 (ir >> 11) & 31, (ir >> 6) & 31))
        if m is not None:
            print("      ours   %016x" % m)
            print("      theirs %016x" % t)
        print("      where the two disagree the manual decides -- neither is an authority")
        return 1
    print("PASS  the two models agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
