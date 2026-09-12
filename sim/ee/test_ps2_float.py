#!/usr/bin/env python3
"""Check sim/ee/ps2_float.py against the rules, by enumeration and by property.

    sim/ee/test_ps2_float.py

There is no RTL to diff against yet, so this is not a differential test; it is
the other kind, and it is what the FPU study said to build first.  Everything
here is *structure* -- the conditioner, the saturator, the flags, the ordering
-- which is the half of the FPU that can be finished and known right without a
console.  The arithmetic's last bit cannot, and the two tests that touch it say
so where they sit.
"""
import os, random, struct, sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ps2_float as F

ok = bad = 0


def check(name, got, want):
    global ok, bad
    if got == want:
        ok += 1
        print(f"  PASS {name:56s} {got if not isinstance(got, int) else hex(got)}")
    else:
        bad += 1
        g = hex(got) if isinstance(got, int) else got
        w = hex(want) if isinstance(want, int) else want
        print(f"  FAIL {name:56s} got {g}, want {w}")


def f32(x):
    """A host float's bits, for building test values only -- never for checking
    arithmetic, which is the whole point of ps2_float existing."""
    return struct.unpack("<I", struct.pack("<f", x))[0]


print("the conditioner -- every class of input")
check("zero is zero", F.cond(0x00000000), 0x00000000)
check("negative zero keeps its sign", F.cond(0x80000000), 0x80000000)
check("a denormal reads as zero", F.cond(0x00400000), 0x00000000)
check("a negative denormal reads as negative zero", F.cond(0x80000001), 0x80000000)
check("the smallest normal survives", F.cond(0x00800000), 0x00800000)
check("+inf reads as +Fmax", F.cond(0x7F800000), F.POS_MAX)
check("-inf reads as -Fmax", F.cond(0xFF800000), 0x80000000 | F.POS_MAX)
check("a NaN reads as Fmax too", F.cond(0x7FC00000), F.POS_MAX)
check("Fmax is already Fmax", F.cond(F.POS_MAX), F.POS_MAX)

print("\nrounding -- toward zero, which is where a host float would differ")
# 1/3 is the clearest case: truncation ends ...AA, round-to-nearest ...AB.
check("1.0 / 3.0 truncates", F.div(f32(1.0), f32(3.0))[0], 0x3EAAAAAA)
check("  and a host float would have said", f32(1.0 / 3.0), 0x3EAAAAAB)
check("2.0 / 3.0 truncates", F.div(f32(2.0), f32(3.0))[0], 0x3F2AAAAA)
check("1.0 / 10.0 truncates", F.div(f32(1.0), f32(10.0))[0], 0x3DCCCCCC)

print("\nsaturation -- no infinities to escape into")
check("Fmax * Fmax saturates", F.mul(F.POS_MAX, F.POS_MAX)[0], F.POS_MAX)
check("  and flags overflow", F.mul(F.POS_MAX, F.POS_MAX)[1], F.CAUSE_O)
check("Fmax + Fmax saturates", F.add(F.POS_MAX, F.POS_MAX)[0], F.POS_MAX)
check("-Fmax - Fmax saturates negative",
      F.sub(0x80000000 | F.POS_MAX, F.POS_MAX)[0], 0x80000000 | F.POS_MAX)
tiny = 0x00800000                                   # the smallest normal
check("smallest normal squared is zero", F.mul(tiny, tiny)[0], 0)
check("  and flags underflow", F.mul(tiny, tiny)[1], F.CAUSE_U)

print("\ndivision by zero -- not an error on this machine")
check("1.0 / 0.0 is +Fmax", F.div(f32(1.0), 0)[0], F.POS_MAX)
check("  flagged D", F.div(f32(1.0), 0)[1], F.CAUSE_D)
check("-1.0 / 0.0 is -Fmax", F.div(0x80000000 | f32(1.0), 0)[0],
      0x80000000 | F.POS_MAX)
check("1.0 / -0.0 is -Fmax", F.div(f32(1.0), 0x80000000)[0],
      0x80000000 | F.POS_MAX)
check("0.0 / 0.0 is flagged I, not D", F.div(0, 0)[1], F.CAUSE_I)
check("a denormal divisor counts as zero", F.div(f32(1.0), 0x00000001)[1],
      F.CAUSE_D)

print("\nordering -- signed-integer compare, reversed when both are negative")
check("max(2, 3) = 3", F.fmax(f32(2.0), f32(3.0)), f32(3.0))
check("max(-2, -3) = -2", F.fmax(f32(-2.0), f32(-3.0)), f32(-2.0))
check("min(-2, -3) = -3", F.fmin(f32(-2.0), f32(-3.0)), f32(-3.0))
check("max(-1, 1) = 1", F.fmax(f32(-1.0), f32(1.0)), f32(1.0))
check("min(0, -0) keeps the negative", F.fmin(0x00000000, 0x80000000), 0x80000000)

print("\nproperties, over ten thousand random patterns")
rng = random.Random(1)
rt = mono = sat = 0
for _ in range(10000):
    x = rng.getrandbits(32)
    c = F.cond(x)
    # every conditioned value is a fixed point of the conditioner, and packs
    # back to itself: the format round-trips
    if F.cond(c) != c or F.pack(F.value(c), c >> 31)[0] != c:
        rt += 1
    # nothing ever produces an infinity, a NaN or a denormal
    for got, _fl in (F.add(x, x), F.mul(x, x), F.div(x, x)):
        e = (got >> 23) & 0xFF
        if e == 0xFF or (e == 0 and (got & 0x7FFFFF)):
            sat += 1
    # multiplying by one is the identity
    if F.mul(c, f32(1.0))[0] != c and (c & 0x7FFFFFFF) != 0:
        mono += 1
check("every value round-trips through the format", rt, 0)
check("no operation ever produces inf, NaN or a denormal", sat, 0)
check("multiplying by one is the identity", mono, 0)

print(f"\n{ok} of {ok + bad} pass")
sys.exit(1 if bad else 0)
