#!/usr/bin/env python3
"""How often does an instruction depend on the one immediately before it?

    tools/ee/dep_rate.py [--seeds 20] [--count 400]

This sets the bar for splitting EX into two pipeline stages. A two-stage
execute makes the ALU two cycles deep, so a dependent instruction cannot issue
back to back any more -- it takes a bubble. The clock has to rise by at least
enough to pay for those bubbles before the change is worth anything at all,
and by rather more before it is worth the fidelity question it raises.

    break-even Fmax = current Fmax x (1 + dependent rate)

The rate is measured on the same programs the differential suite uses, plus the
directed ones, rather than assumed from a textbook figure -- the generator's mix
is what this core is actually tuned against, and a random-instruction stream is
*less* dependent than compiled code, so the number here is a floor rather than
an estimate of real game code.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "sim", "ee"))


def dests_srcs(i):
    """(destination register, source registers) for one instruction word.

    Only the common forms need be exact: the point is a rate over thousands of
    instructions, and the shapes below cover everything the generator emits.
    Anything unrecognised counts as neither a producer nor a consumer, which
    biases the answer *down* -- the safe direction for a number being used to
    justify not doing something.
    """
    op = i >> 26
    rs, rt, rd = (i >> 21) & 31, (i >> 16) & 31, (i >> 11) & 31
    fn = i & 0x3F
    if op == 0:                                   # SPECIAL
        if fn in (0, 2, 3, 56, 58, 59, 60, 62, 63):       # shift by sa
            return rd, (rt,)
        if fn in (8,):                                    # JR
            return 0, (rs,)
        if fn in (9,):                                    # JALR
            return rd or 31, (rs,)
        if fn in (16, 18):                                # MFHI, MFLO
            return rd, ()
        if fn in (17, 19):                                # MTHI, MTLO
            return 0, (rs,)
        if fn in (24, 25, 26, 27):                        # MULT/DIV
            return 0, (rs, rt)
        if fn in (12, 13, 15):                            # SYSCALL/BREAK/SYNC
            return 0, ()
        return rd, (rs, rt)
    if op == 1:                                   # REGIMM
        return (31 if rt in (16, 17, 18, 19) else 0), (rs,)
    if op in (2, 3):                              # J, JAL
        return (31 if op == 3 else 0), ()
    if op in (4, 5, 20, 21):                      # BEQ/BNE and the likely forms
        return 0, (rs, rt)
    if op in (6, 7, 22, 23):
        return 0, (rs,)
    if op in (8, 9, 10, 11, 12, 13, 14, 24, 25):  # immediate ALU
        return rt, (rs,)
    if op == 15:                                  # LUI
        return rt, ()
    if op in (32, 33, 35, 36, 37, 39, 55, 30):    # loads (and LQ)
        return rt, (rs,)
    if op in (40, 41, 43, 63, 31):                # stores (and SQ)
        return 0, (rs, rt)
    if op == 28:                                  # MMI
        if fn in (16, 18):
            return rd, ()
        if fn in (17, 19):
            return 0, (rs,)
        if fn in (24, 25, 26, 27):
            return 0, (rs, rt)
        return rd, (rs, rt)
    return 0, ()


def rate(words):
    """(dependent pairs, pairs considered) over one instruction stream."""
    dep = tot = 0
    prev_d = None
    for w in words:
        d, srcs = dests_srcs(w)
        if prev_d is not None:
            tot += 1
            if prev_d != 0 and prev_d in srcs:
                dep += 1
        prev_d = d
    return dep, tot


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--count", type=int, default=400)
    ap.add_argument("--fmax", type=float, default=199.1)
    a = ap.parse_args()

    dep = tot = 0
    for s in range(1, a.seeds + 1):
        for extra in ([], ["--branches"]):
            out = subprocess.run(
                [sys.executable, os.path.join(ROOT, "sim/ee/gen_prog.py"),
                 "--seed", str(s), "--count", str(a.count)] + extra,
                capture_output=True, text=True, cwd=ROOT).stdout
            words = [int(l.split("//")[0].strip(), 16) for l in out.splitlines()
                     if l.split("//")[0].strip()][:a.count]
            d, t = rate(words)
            dep += d
            tot += t

    r = dep / tot if tot else 0
    print("dependent on the immediately preceding instruction:")
    print("  %d of %d pairs = %.1f%%" % (dep, tot, 100 * r))
    print()
    print("If a two-stage execute costs one bubble per dependent pair:")
    print("  CPI          1.000  ->  %.3f" % (1 + r))
    print("  break-even   %.1f MHz -> %.1f MHz" % (a.fmax, a.fmax * (1 + r)))
    print("  and the console's own clock is 294.912 MHz")
    print()
    if a.fmax * (1 + r) > 294.912:
        print("  A two-stage execute CANNOT pay for itself even at the console's")
        print("  clock: the bubbles cost more than the clock can return.")
    else:
        print("  A two-stage execute pays for itself only above %.1f MHz."
              % (a.fmax * (1 + r)))
    print()
    print("Random instructions are LESS dependent than compiled code, so this is")
    print("a floor. Real game code will pay more for the bubbles, not less.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
