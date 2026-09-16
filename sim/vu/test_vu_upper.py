#!/usr/bin/env python3
"""Check the VU1 upper unit: field masks, broadcasts, and the rounding.

    sim/vu/test_vu_upper.py

The claims here are about *behaviour that is easy to get subtly better than the
hardware*, which is the failure mode a reference model must not have. A model
that is more accurate than the machine it models will disagree with correct RTL,
and the RTL will then be "fixed" until it is wrong.
"""
import os
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vu_ref as V
F = V.F

ok = True


def check(name, got, want):
    global ok
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r}, expected {want!r}")
        ok = False


def enc(op, dest=0xF, ft=0, fs=0, fd=0):
    return (dest << 21) | (ft << 16) | (fs << 11) | (fd << 6) | op


def fresh():
    vu = V.VU()
    return vu, V.UpperUnit(vu)


# ---- field masks ------------------------------------------------------------
# A masked-off field is not written. Not written as zero, not written back
# through a mux -- not written.
vu, u = fresh()
one, two = F.pack(1)[0], F.pack(2)[0]
vu.vf[1] = V.VF(one, one, one, one)
vu.vf[2] = V.VF(two, two, two, two)
vu.vf[3] = V.VF(0xDEAD0000, 0xDEAD0001, 0xDEAD0002, 0xDEAD0003)
u.run(enc(0x28, dest=0b1010, ft=2, fs=1, fd=3))          # ADD.xz vf3, vf1, vf2
three = F.pack(3)[0]
check("ADD writes x when the mask selects it",      vu.vf[3]["x"], three)
check("ADD leaves y alone when the mask omits it",  vu.vf[3]["y"], 0xDEAD0001)
check("ADD writes z when the mask selects it",      vu.vf[3]["z"], three)
check("ADD leaves w alone when the mask omits it",  vu.vf[3]["w"], 0xDEAD0003)

# ---- broadcast --------------------------------------------------------------
# ADDx reads ft.x for every field, not ft field by field.
vu, u = fresh()
vu.vf[1] = V.VF(one, one, one, one)
vu.vf[2] = V.VF(two, three, F.pack(4)[0], F.pack(5)[0])
u.run(enc(0x00, dest=0xF, ft=2, fs=1, fd=3))             # ADDx vf3, vf1, vf2
check("ADDx broadcasts ft.x to every field",
      [vu.vf[3][f] for f in "xyzw"], [three] * 4)
u.run(enc(0x03, dest=0xF, ft=2, fs=1, fd=4))             # ADDw vf4, vf1, vf2
check("ADDw broadcasts ft.w", [vu.vf[4][f] for f in "xyzw"], [F.pack(6)[0]] * 4)

# ---- vf00 is hardwired ------------------------------------------------------
vu, u = fresh()
vu.vf[1] = V.VF(one, one, one, one)
before = list(vu.vf[0].v)
u.run(enc(0x28, dest=0xF, ft=1, fs=1, fd=0))             # ADD vf0, vf1, vf1
check("a write to vf00 is discarded", list(vu.vf[0].v), before)
check("vf00.w reads as 1.0", vu.vf[0]["w"], one)

# ---- MADD rounds twice ------------------------------------------------------
# Search for a witness rather than asserting one: if no (a, b, c) distinguishes
# the two, this test proves nothing and should say so rather than pass.
def madd_twice(a, b, c):
    return F.add(c, F.mul(a, b)[0])[0]


def madd_fused(a, b, c):
    return F.pack(F.value(c) + F.value(a) * F.value(b))[0]


witness = None
for i in range(1, 400):
    a = F.pack(Fraction(1) + Fraction(i, 1 << 23))[0]
    b = F.pack(Fraction(1) + Fraction(i + 1, 1 << 23))[0]
    c = F.pack(Fraction(-1))[0]
    if madd_twice(a, b, c) != madd_fused(a, b, c):
        witness = (a, b, c)
        break
if witness is None:
    print("  FAIL no (a,b,c) separates fused from twice-rounded -- test is vacuous")
    ok = False
else:
    a, b, c = witness
    vu, u = fresh()
    vu.vf[1] = V.VF(a, a, a, a)
    vu.vf[2] = V.VF(b, b, b, b)
    vu.acc   = V.VF(c, c, c, c)
    u.run(enc(0x29, dest=0xF, ft=2, fs=1, fd=3))         # MADD vf3, vf1, vf2
    check(f"MADD rounds the product before adding "
          f"(a={a:08x} b={b:08x} c={c:08x})",
          vu.vf[3]["x"], madd_twice(a, b, c))
    check("...and is NOT the fused result", vu.vf[3]["x"] != madd_fused(a, b, c), True)

# ---- the accumulator forms write ACC, not fd --------------------------------
vu, u = fresh()
vu.vf[1] = V.VF(one, one, one, one)
vu.vf[2] = V.VF(two, two, two, two)
vu.vf[5] = V.VF(0x11111111, 0x22222222, 0x33333333, 0x44444444)
# MULA is FD_10 table, fd index 0x0A, opcode 0x3E
u.run((0xF << 21) | (2 << 16) | (1 << 11) | (0x0A << 6) | 0x3E)
check("MULA writes the accumulator", [vu.acc[f] for f in "xyzw"], [two] * 4)
check("MULA leaves the register named by fd alone",
      list(vu.vf[5].v), [0x11111111, 0x22222222, 0x33333333, 0x44444444])

# ---- the outer product ------------------------------------------------------
# OPMULA / OPMSUB together are a cross product. Check it against the definition
# rather than against itself: with unit vectors x cross y must be z.
vu, u = fresh()
zero = 0
vu.vf[1] = V.VF(one, zero, zero, zero)                   # (1,0,0)
vu.vf[2] = V.VF(zero, one, zero, zero)                   # (0,1,0)
u.run((0xF << 21) | (2 << 16) | (1 << 11) | (0x0B << 6) | 0x3E)   # OPMULA
u.run(enc(0x2E, dest=0xF, ft=2, fs=1, fd=3))                       # OPMSUB
# OPMULA then OPMSUB with the same operands gives ACC - prod = 0; the cross
# product itself is in ACC after OPMULA. Re-run just OPMULA to read it.
vu2, u2 = fresh()
vu2.vf[1] = V.VF(one, zero, zero, zero)
vu2.vf[2] = V.VF(zero, one, zero, zero)
u2.run((0xF << 21) | (2 << 16) | (1 << 11) | (0x0B << 6) | 0x3E)
check("OPMULA of x and y gives z", [vu2.acc[f] for f in "xyz"], [zero, zero, one])

# ---- ITOF and FTOI scale, and write ft rather than fd ----------------------
#
# These live in the extension, which spends the fd field as its sub-opcode, so
# their destination is ft.  The first version of this file wrote fd and the
# first version of the test did not notice, because the check that should have
# caught it had been written as an expression that was true whatever happened.
# Both are worth recording: a vacuous assertion is worse than no assertion,
# because it reports a pass.

def conv(op36, subop, src_bits, ft=7, fs=1):
    vu, u = fresh()
    vu.vf[fs] = V.VF(*([src_bits] * 4))
    vu.vf[ft] = V.VF(0xAAAA0000, 0xAAAA0001, 0xAAAA0002, 0xAAAA0003)
    u.run((0xF << 21) | (ft << 16) | (fs << 11) | (subop << 6) | op36)
    return vu

# ITOF0 of the integer 16 is 16.0, written to ft.
vu = conv(0x3C, 0x04, 16)
check("ITOF0 of 16 is 16.0, in ft", vu.vf[7]["x"], F.pack(16)[0])

# ITOF4 divides by 2^4, so 16 becomes 1.0.
vu = conv(0x3D, 0x04, 16)
check("ITOF4 of 16 is 1.0", vu.vf[7]["x"], F.pack(1)[0])

# ITOF12 divides by 2^12.
vu = conv(0x3E, 0x04, 1 << 12)
check("ITOF12 of 4096 is 1.0", vu.vf[7]["x"], F.pack(1)[0])

# FTOI0 truncates toward zero: 3.75 becomes 3, and -3.75 becomes -3.
vu = conv(0x3C, 0x05, F.pack(Fraction(15, 4))[0])
check("FTOI0 of 3.75 is 3", vu.vf[7]["x"], 3)
vu = conv(0x3C, 0x05, F.pack(Fraction(-15, 4))[0])
check("FTOI0 of -3.75 is -3 (toward zero, not down)",
      vu.vf[7]["x"], (-3) & 0xFFFFFFFF)

# FTOI4 scales by 2^4 first: 3.75 * 16 = 60.
vu = conv(0x3D, 0x05, F.pack(Fraction(15, 4))[0])
check("FTOI4 of 3.75 is 60", vu.vf[7]["x"], 60)

# ABS also writes ft, and clears the sign bit rather than negating.
vu = conv(0x3D, 0x07, F.pack(Fraction(-5, 2))[0])
check("ABS of -2.5 is 2.5, in ft", vu.vf[7]["x"], F.pack(Fraction(5, 2))[0])

# And the destination claim itself: fd for these names a sub-opcode, so the
# register with that number must be untouched.
vu = conv(0x3C, 0x04, 16)
check("ITOF0 leaves vf04 -- the register fd happens to name -- alone",
      list(vu.vf[4].v), [0, 0, 0, 0])

# ---- the MAC and status flags ----------------------------------------------
# x is bit 3 of each nibble and w is bit 0 -- the same reversal the DEST mask
# has. Getting it backwards puts every flag on the wrong field and is invisible
# until something branches on one.
vu, u = fresh()
minus_one = F.pack(-1)[0]
vu.vf[1] = V.VF(one, one, one, minus_one)
vu.vf[2] = V.VF(one, minus_one, one, minus_one)
u.run(enc(0x28, dest=0xF, ft=2, fs=1, fd=3))       # ADD: 2, 0, 2, -2
check("ADD produces the expected fields",
      [vu.vf[3][f] for f in "xyzw"],
      [F.pack(2)[0], F.pack(0)[0], F.pack(2)[0], F.pack(-2)[0]])
check("the zero flag lands on y, which is bit 2 of the Z nibble",
      vu.mac & 0x000F, 1 << V.MAC_SHIFT["y"])
check("the sign flag lands on w, which is bit 0 of the S nibble",
      (vu.mac >> 4) & 0x000F, 1 << V.MAC_SHIFT["w"])

# Flags are per instruction, not sticky -- a later clean result clears them.
vu.vf[4] = V.VF(one, one, one, one)
u.run(enc(0x28, dest=0xF, ft=4, fs=4, fd=5))       # ADD: all 2.0, no flags
check("MAC flags are recomputed, not accumulated", vu.mac & 0x00FF, 0)

# The status register's low nibble follows, but its sticky bits do not clear.
check("status keeps a sticky record of the zero that happened",
      (vu.status >> 6) & 1, 1)
check("...while its live bits follow the current instruction",
      vu.status & 0x0F, 0)

# MAX selects rather than computing, so it leaves the flags alone.
vu, u = fresh()
vu.vf[1] = V.VF(minus_one, minus_one, minus_one, minus_one)
vu.vf[2] = V.VF(one, one, one, one)
u.run(enc(0x28, dest=0xF, ft=1, fs=1, fd=3))       # ADD -1 + -1 -> sign flags
before = vu.mac
u.run(enc(0x2B, dest=0xF, ft=2, fs=1, fd=4))       # MAX
check("MAX leaves the MAC flags alone", vu.mac, before)
check("...and still selects the larger operand", vu.vf[4]["x"], one)

# Overflow sets O and clears Z and U; the format saturates rather than
# producing an infinity, so the flag is the only way to know it happened.
vu, u = fresh()
big = 0x7F7FFFFF                                    # the largest finite value
vu.vf[1] = V.VF(big, big, big, big)
u.run(enc(0x2A, dest=0b1000, ft=1, fs=1, fd=3))     # MUL big * big
check("overflow saturates to the largest finite value", vu.vf[3]["x"], big)
check("...and sets the overflow flag on x",
      (vu.mac >> 12) & 0xF, 1 << V.MAC_SHIFT["x"])
check("...and clears the zero flag", (vu.mac >> V.MAC_SHIFT["x"]) & 1, 0)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
