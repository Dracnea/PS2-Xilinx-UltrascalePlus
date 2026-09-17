#!/usr/bin/env python3
"""Print what ps2_float.py says for each vector, in the testbench's format.

    sim/ee/fpu_ref.py vectors.hex

The format is the RTL's, deliberately: two implementations printing the same
shape means the comparison is a plain diff and neither side gets to decide what
counts as a match.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ps2_float as F


def f_eq(a, b):
    ca, cb = F.cond(a), F.cond(b)
    if (ca >> 23) & 0xFF == 0 and (cb >> 23) & 0xFF == 0:
        return True
    return ca == cb


def f_lt(a, b):
    ca, cb = F.cond(a), F.cond(b)
    za = (ca >> 23) & 0xFF == 0
    zb = (cb >> 23) & 0xFF == 0
    if za and zb:
        return False
    sa, sb = ca >> 31, cb >> 31
    ma, mb = ca & 0x7FFFFFFF, cb & 0x7FFFFFFF
    if sa != sb:
        return sa == 1
    if sa == 1:
        return ma > mb
    return ma < mb


def main():
    for line in open(sys.argv[1]):
        t = line.split()
        if len(t) != 2:
            continue
        a, b = int(t[0], 16), int(t[1], 16)
        ca, cb = F.cond(a), F.cond(b)
        eq, lt = f_eq(a, b), f_lt(a, b)
        le = lt or eq
        mx = cb if lt else ca
        mn = cb if f_lt(b, a) else ca
        ab = a & 0x7FFFFFFF
        ng = a ^ 0x80000000
        mul, cause = F.mul(a, b)
        print("V %08x %08x COND %08x %08x CMP %d %d %d MAXMIN %08x %08x "
              "ABSNEG %08x %08x MUL %08x %d %d"
              % (a, b, ca, cb, int(eq), int(lt), int(le), mx, mn, ab, ng,
                 mul, int(bool(cause & F.CAUSE_O)), int(bool(cause & F.CAUSE_U))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
