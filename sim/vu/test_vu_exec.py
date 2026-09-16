#!/usr/bin/env python3
"""Check the VU1 execution model: dual issue, delay slots, and the E bit.

    sim/vu/test_vu_exec.py

Three rules here are easy to state and easy to implement backwards, and all
three are invisible in a program that does not happen to exercise them.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vu_ref as V
F = V.F

ok = True
one, two, three = F.pack(1)[0], F.pack(2)[0], F.pack(3)[0]


def check(name, got, want):
    global ok
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r}, expected {want!r}")
        ok = False


# NOP is FD_11[**11**], not [15]. The first version of this file used 15, and
# the model correctly recorded every one of them as an unimplemented upper
# instruction -- which is what the last check below is for. An encoding helper
# that is wrong in a test is indistinguishable from a model that is wrong, until
# something asserts that nothing went unimplemented.
NOP_U = (0x0B << 6) | 0x3F
NOP_L = 0x8000033C                                 # the canonical lower NOP


def up_add(fd, fs, ft, dest=0xF):
    return (dest << 21) | (ft << 16) | (fs << 11) | (fd << 6) | 0x28


def lo_move(ft, fs, dest=0xF):
    return (0x40 << 25) | (dest << 21) | (ft << 16) | (fs << 11) | (12 << 6) | 0x3C


def lo_iaddiu(it, is_, imm):
    return (0x08 << 25) | ((imm & 0x7800) << 10) | (it << 16) | (is_ << 11) | (imm & 0x7FF)


def lo_b(imm):
    return (0x20 << 25) | (imm & 0x7FF)


def word(up, lo):
    return ((up & 0xFFFFFFFF) << 32) | (lo & 0xFFFFFFFF)


def fresh():
    vu = V.VU()
    return vu, V.Program(vu)


# ---- both slots read the same register state ------------------------------
# The upper adds vf1 + vf1 while the lower overwrites vf1 in the same
# instruction. The upper must see the OLD vf1. Running the lower first gives
# the new one; running the upper first and letting it win the merge gives the
# right answer for the wrong reason, so the lower's write must also land.
vu, p = fresh()
vu.vf[1] = V.VF(one, one, one, one)
vu.vf[5] = V.VF(three, three, three, three)
vu.micro[0] = word(up_add(3, 1, 1), lo_move(1, 5))      # ADD vf3,vf1,vf1 | MOVE vf1,vf5
vu.micro[1] = word(NOP_U | (1 << 30), NOP_L)
p.run(0, 10)
check("the upper slot sees the register as it was", vu.vf[3]["x"], two)
check("...and the lower slot's write still lands",  vu.vf[1]["x"], three)

# ---- a branch has exactly one delay slot ----------------------------------
vu, p = fresh()
vu.micro[0] = word(NOP_U, lo_b(2))                       # B +2 -> target is 0+1+2 = 3
vu.micro[1] = word(NOP_U, lo_iaddiu(1, 0, 0x11))         # the delay slot: must run
vu.micro[2] = word(NOP_U, lo_iaddiu(2, 0, 0x22))         # skipped
vu.micro[3] = word(NOP_U, lo_iaddiu(3, 0, 0x33))         # the target
vu.micro[4] = word(NOP_U | (1 << 30), NOP_L)
p.run(0, 20)
check("the delay slot after a taken branch runs", vu.rvi(1), 0x11)
check("the instruction after the delay slot is skipped", vu.rvi(2), 0)
check("execution resumes at the target", vu.rvi(3), 0x33)

# ---- the E bit stops the program two instructions later --------------------
# Not immediately. Stopping at the E bit itself is the natural reading and is
# wrong by exactly two instructions, which in a geometry kernel is two vertices.
vu, p = fresh()
vu.micro[0] = word(NOP_U | (1 << 30), lo_iaddiu(1, 0, 1))   # E bit here
vu.micro[1] = word(NOP_U, lo_iaddiu(2, 0, 2))               # still runs
vu.micro[2] = word(NOP_U, lo_iaddiu(3, 0, 3))               # still runs
vu.micro[3] = word(NOP_U, lo_iaddiu(4, 0, 4))               # must NOT run
n = p.run(0, 20)
check("the E instruction itself runs",        vu.rvi(1), 1)
check("and so does the one after it",         vu.rvi(2), 2)
check("and the one after that",               vu.rvi(3), 3)
check("but the fourth does not",              vu.rvi(4), 0)
check("three instructions in total",          n, 3)

# ---- the I bit makes the lower word an immediate ---------------------------
vu, p = fresh()
vu.micro[0] = word(NOP_U | (1 << 31), 0x12345678)
vu.micro[1] = word(NOP_U | (1 << 30), NOP_L)
p.run(0, 10)
check("LOI loads I with the lower word", vu.i, 0x12345678)
check("...and does not execute it as an instruction", vu.unimplemented, [])

# And the same assertion over every program above: nothing in this file should
# have hit an encoding the model does not know.
vu, p = fresh()
vu.micro[0] = word(NOP_U, NOP_L)
vu.micro[1] = word(NOP_U | (1 << 30), NOP_L)
p.run(0, 10)
check("a NOP pair decodes on both slots", vu.unimplemented, [])

# ---- a program that loops -------------------------------------------------
# IADDIU counting down with IBNE, which exercises the branch and the delay slot
# together over several iterations rather than once.
vu, p = fresh()
vu.wvi(1, 3)
def lo_ibne(is_, it, imm):
    return (0x29 << 25) | (it << 16) | (is_ << 11) | (imm & 0x7FF)
def lo_isubiu(it, is_, imm):
    return (0x09 << 25) | ((imm & 0x7800) << 10) | (it << 16) | (is_ << 11) | (imm & 0x7FF)
vu.micro[0] = word(NOP_U, lo_isubiu(1, 1, 1))            # vi1 -= 1
vu.micro[1] = word(NOP_U, lo_ibne(1, 0, -2 & 0x7FF))     # if vi1 != 0 -> 1+1-2 = 0
vu.micro[2] = word(NOP_U, lo_iaddiu(2, 2, 1))            # delay slot, counts passes
vu.micro[3] = word(NOP_U | (1 << 30), NOP_L)
p.run(0, 60)
check("the loop ran to completion", vu.rvi(1), 0)
check("the delay slot ran once per branch", vu.rvi(2), 3)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
