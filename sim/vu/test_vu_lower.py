#!/usr/bin/env python3
"""Check the VU1 lower unit: addressing modes, the integer wrap, and the moves.

    sim/vu/test_vu_lower.py

The claims worth testing here are the asymmetric ones -- where two instructions
that look like a pair are not one. Those are the places a model written from the
instruction names rather than from the encoding goes wrong, and they are silent:
an off-by-one in a pointer walk produces a picture, just not the right one.
"""
import os
import sys

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


def fresh():
    vu = V.VU()
    return vu, V.LowerUnit(vu)


def enc3(which, k, dest=0xF, ft=0, fs=0, it=0, is_=0):
    """One of the third-level encodings: 0x40 top, 0x3C+which, k in bits 10:6.

    `dest` occupies bits 24:21, and for most instructions that is the field
    mask. For MTIR, DIV, SQRT and RSQRT it is **not**: those overload the same
    four bits as fsf (22:21) and ftf (24:23), naming one field of each operand.
    The first version of this file passed the default mask of 0xF to them, which
    set both selectors to `w` -- so MTIR read an empty field and DIV divided by
    zero and saturated. The model was right and the test was wrong, which is the
    failure that wastes the most time, so the two cases have separate helpers
    now rather than one with a trap in it.
    """
    return ((0x40 << 25) | (dest << 21) | (ft << 16) | (fs << 11)
            | (k << 6) | (0x3C + which))


def enc3_sel(which, k, fsf=0, ftf=0, ft=0, fs=0):
    """The same, for the instructions whose 24:21 is fsf/ftf, not a mask."""
    return ((0x40 << 25) | (ftf << 23) | (fsf << 21) | (ft << 16) | (fs << 11)
            | (k << 6) | (0x3C + which))


def enc_top(op, dest=0xF, ft=0, fs=0, imm=0):
    return (op << 25) | (dest << 21) | (ft << 16) | (fs << 11) | (imm & 0x7FF)


# ---- the 16-bit integer registers wrap, they do not saturate ---------------
vu, l = fresh()
vu.wvi(1, 0xFFFF)
vu.wvi(2, 3)
l.run((0x40 << 25) | (2 << 16) | (1 << 11) | (3 << 6) | 0x30)      # IADD vi3, vi1, vi2
check("IADD wraps at 16 bits", vu.rvi(3), 2)
vu.wvi(1, 0)
l.run((0x40 << 25) | (2 << 16) | (1 << 11) | (4 << 6) | 0x31)      # ISUB vi4, vi1, vi2
check("ISUB wraps below zero", vu.rvi(4), 0xFFFD)
check("vi00 always reads zero", vu.rvi(0), 0)
vu.wvi(0, 0x1234)
check("a write to vi00 is discarded", vu.rvi(0), 0)

# ---- LQI post-increments; LQD PRE-decrements ------------------------------
# This is the asymmetry. LQI reads at the pointer and then advances it; LQD
# retreats the pointer first and reads at the new value. A model that made them
# mirror images -- read then decrement -- would be off by one on every
# backwards walk, and would still produce plausible output.
vu, l = fresh()
for i in range(4):
    vu.mem[i] = V.VF(0xA000 + i, 0, 0, 0)
vu.wvi(1, 2)
l.run(enc3(0, 13, dest=0b1000, ft=5, fs=0, is_=0) | (1 << 11))     # LQI vf5, (vi1++)
check("LQI reads at the pointer",       vu.vf[5]["x"], 0xA002)
check("LQI leaves the pointer advanced", vu.rvi(1), 3)

vu, l = fresh()
for i in range(4):
    vu.mem[i] = V.VF(0xA000 + i, 0, 0, 0)
vu.wvi(1, 2)
l.run(enc3(2, 13, dest=0b1000, ft=5) | (1 << 11))                  # LQD vf5, (--vi1)
check("LQD decrements before reading",  vu.vf[5]["x"], 0xA001)
check("LQD leaves the pointer at the value it read", vu.rvi(1), 1)

# ---- the field mask applies to loads and stores too ------------------------
vu, l = fresh()
vu.mem[0] = V.VF(1, 2, 3, 4)
vu.vf[6] = V.VF(0x90, 0x91, 0x92, 0x93)
l.run(enc_top(0x00, dest=0b0101, ft=6, fs=1))                      # LQ.yw vf6, 0(vi1)
check("LQ writes only the masked fields",
      list(vu.vf[6].v), [0x90, 2, 0x92, 4])

# ---- MR32 rotates by one field --------------------------------------------
vu, l = fresh()
vu.vf[1] = V.VF(1, 2, 3, 4)
l.run(enc3(1, 12, dest=0xF, ft=7, fs=1))                           # MR32 vf7, vf1
check("MR32 rotates x<-y y<-z z<-w w<-x", list(vu.vf[7].v), [2, 3, 4, 1])

# ---- MFIR sign-extends from 16 bits ---------------------------------------
# Not zero-extends, and not converts to float: the bits go across as an integer
# and something else is expected to ITOF them.
vu, l = fresh()
vu.wvi(1, 0xFFFF)                                                  # -1 as 16 bits
l.run(enc3(1, 15, dest=0b1000, ft=8) | (1 << 11))                  # MFIR vf8, vi1
check("MFIR sign-extends -1 to 32 bits", vu.vf[8]["x"], 0xFFFFFFFF)
vu.wvi(1, 0x7FFF)
l.run(enc3(1, 15, dest=0b1000, ft=9) | (1 << 11))
check("MFIR leaves a positive value alone", vu.vf[9]["x"], 0x7FFF)

# ---- MTIR takes one field, and only its low half --------------------------
vu, l = fresh()
vu.vf[1] = V.VF(0x11112222, 0x33334444, 0, 0)
l.run(enc3_sel(0, 15, fsf=1, ft=3, fs=1))                          # MTIR vi3, vf1.y
check("MTIR takes the named field's low 16 bits", vu.rvi(3), 0x4444)

# ---- the divide unit writes Q and nothing else ----------------------------
vu, l = fresh()
one, four = F.pack(1)[0], F.pack(4)[0]
vu.vf[1] = V.VF(one, 0, 0, 0)
vu.vf[2] = V.VF(four, 0, 0, 0)
vu.vf[3] = V.VF(0xAA, 0xBB, 0xCC, 0xDD)
l.run(enc3_sel(0, 14, fsf=0, ftf=0, ft=2, fs=1))                   # DIV Q, vf1.x, vf2.x
check("DIV writes Q", vu.q, F.pack(F.Fraction(1, 4))[0])
check("DIV writes no vector register", list(vu.vf[3].v), [0xAA, 0xBB, 0xCC, 0xDD])

vu, l = fresh()
vu.vf[2] = V.VF(F.pack(4)[0], 0, 0, 0)
l.run(enc3_sel(1, 14, ftf=0, ft=2))                                # SQRT Q, vf2.x
check("SQRT of 4 is 2", vu.q, F.pack(2)[0])

vu, l = fresh()
vu.vf[1] = V.VF(F.pack(3)[0], 0, 0, 0)
vu.vf[2] = V.VF(F.pack(4)[0], 0, 0, 0)
l.run(enc3_sel(2, 14, fsf=0, ftf=0, ft=2, fs=1))                   # RSQRT Q, vf1.x, vf2.x
check("RSQRT gives fs / sqrt(ft)", vu.q, F.pack(F.Fraction(3, 2))[0])

# ---- branches are relative to the delay slot ------------------------------
vu, l = fresh()
vu.pc = 10
l.run(enc_top(0x20, imm=5))                                        # B +5
check("B targets pc + 1 + imm", l.branch, (16, None))
vu, l = fresh()
vu.pc = 10
vu.wvi(1, 7)
vu.wvi(2, 7)
l.run(enc_top(0x28, ft=2, fs=1, imm=-3 & 0x7FF))                   # IBEQ vi1, vi2, -3
check("IBEQ taken goes backwards correctly", l.branch, (8, None))
vu, l = fresh()
vu.pc = 10
vu.wvi(1, 7)
vu.wvi(2, 8)
l.run(enc_top(0x28, ft=2, fs=1, imm=-3 & 0x7FF))
check("IBEQ not taken does not branch", l.branch, None)

# ---- VU Mem wraps rather than faulting ------------------------------------
vu, l = fresh()
vu.mem[0] = V.VF(0xBEEF, 0, 0, 0)
vu.wvi(1, len(vu.mem))                                             # one past the end
l.run(enc_top(0x00, dest=0b1000, ft=5, fs=1))                      # LQ vf5, 0(vi1)
check("an address past the end of VU Mem wraps", vu.vf[5]["x"], 0xBEEF)

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
