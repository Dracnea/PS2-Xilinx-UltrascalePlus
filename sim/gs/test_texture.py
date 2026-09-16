#!/usr/bin/env python3
"""Check UV sampling, the wrap modes, and the texture function.

    sim/gs/test_texture.py

Three of these are checks against a constant that is easy to get wrong by a
factor of two, and one is a wrap mode that is not a wrap.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gs_ref as g

ok = True


def check(name, got, want):
    global ok
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r}, expected {want!r}")
        ok = False


# ---- the texture function ---------------------------------------------------
# 0x80 is 1.0 in the GS's fixed point, throughout -- the blender's constant and
# the texture unit's are the same one. So MODULATE by a fragment of 0x80 must be
# the identity. Shifting by 8 instead of 7 is the obvious guess and halves every
# textured surface, which reads as a lighting bug rather than as an arithmetic
# one.
white = (0x80, 0x80, 0x80, 0x80)
texel = (0x40, 0x80, 0xFF, 0x60)
check("MODULATE by 0x80 is the identity",
      g.texture_function(g.TFX_MODULATE, 0, white, texel)[:3], (0x40, 0x80, 0xFF))
check("MODULATE by 0x40 halves the texel",
      g.texture_function(g.TFX_MODULATE, 0, (0x40, 0x40, 0x40, 0x80), texel)[:3],
      (0x20, 0x40, 0x7F))
check("MODULATE saturates rather than wrapping",
      g.texture_function(g.TFX_MODULATE, 0, (0xFF, 0xFF, 0xFF, 0x80),
                         (0xFF, 0xFF, 0xFF, 0x80))[:3], (255, 255, 255))

# TCC decides whether the texel's alpha is used at all.
check("TCC=0 passes the fragment's alpha through",
      g.texture_function(g.TFX_MODULATE, 0, (0x80, 0x80, 0x80, 0x33), texel)[3], 0x33)
check("TCC=1 modulates the alpha too",
      g.texture_function(g.TFX_MODULATE, 1, (0x80, 0x80, 0x80, 0x80), texel)[3], 0x60)

check("DECAL ignores the fragment colour",
      g.texture_function(g.TFX_DECAL, 0, (0x10, 0x20, 0x30, 0x44), texel)[:3],
      (0x40, 0x80, 0xFF))
check("DECAL with TCC=0 still takes the fragment's alpha",
      g.texture_function(g.TFX_DECAL, 0, (0x10, 0x20, 0x30, 0x44), texel)[3], 0x44)

# HIGHLIGHT adds the fragment alpha to the colour; HIGHLIGHT2 differs only in
# where the output alpha comes from.
h  = g.texture_function(g.TFX_HIGHLIGHT,  1, (0x80, 0x80, 0x80, 0x20), texel)
h2 = g.texture_function(g.TFX_HIGHLIGHT2, 1, (0x80, 0x80, 0x80, 0x20), texel)
check("HIGHLIGHT adds the fragment alpha to the colour", h[:3],
      (0x40 + 0x20, 0x80 + 0x20, 255))
check("HIGHLIGHT and HIGHLIGHT2 agree on colour", h[:3], h2[:3])
check("HIGHLIGHT's alpha is At + Af", h[3], 0x60 + 0x20)
check("HIGHLIGHT2's alpha is At alone", h2[3], 0x60)

# ---- the wrap modes ---------------------------------------------------------
check("REPEAT masks to the texture size",
      [g.wrap(u, g.WM_REPEAT, 0, 0, 8) for u in (0, 7, 8, 9, 17)], [0, 7, 0, 1, 1])
check("CLAMP holds at the edges",
      [g.wrap(u, g.WM_CLAMP, 0, 0, 8) for u in (-5, 0, 7, 99)], [0, 0, 7, 7])
check("REGION_CLAMP holds at MINU and MAXU",
      [g.wrap(u, g.WM_REGION_CLAMP, 3, 5, 256) for u in (0, 3, 4, 5, 99)],
      [3, 3, 4, 5, 5])
# The one that is not a wrap: MINU is a mask and MAXU is an or.
check("REGION_REPEAT is a mask and an or, not a range",
      [g.wrap(u, g.WM_REGION_REPEAT, 0x07, 0x10, 256) for u in (0, 1, 8, 9, 255)],
      [0x10, 0x11, 0x10, 0x11, 0x17])

# ---- nearest sampling truncates ---------------------------------------------
# A 4 x 4 PSMCT32 texture whose texels carry their own coordinates, so a wrong
# address is readable rather than merely different.
vm = bytearray(8192 * 8)
for y in range(4):
    for x in range(4):
        a = g.addr32p(0, 1, x, y) * 4
        vm[a:a + 4] = ((0xFF << 24) | (x << 8) | y).to_bytes(4, "little")
        # r = y, g = x: expand_texel puts the low byte in red.

TW, TH = 2, 2                       # 4 x 4
tex0 = (0 | (1 << 14) | (g.PSMCT32 << 20) | (TW << 26) | (TH << 30))
clamp = g.WM_REPEAT | (g.WM_REPEAT << 2)
clut = g.Clut()

# 1.9 texels along must sample texel 1, not 2: the fractional bits are
# discarded, not rounded.
r, gx, b, a = g.sample_uv(vm, tex0, clamp, clut, (1 << 4) | 15, 0 << 4)
check("nearest truncates rather than rounding", (gx, r), (1, 0))
r, gx, b, a = g.sample_uv(vm, tex0, clamp, clut, 2 << 4, 3 << 4)
check("the texel carries the coordinates it was written with", (gx, r), (2, 3))
# And the wrap applies before the fetch.
r, gx, b, a = g.sample_uv(vm, tex0, clamp, clut, 6 << 4, 0)
check("REPEAT wraps a coordinate past the edge", gx, 2)

# ---- an indexed texture through the CLUT ------------------------------------
# Write a PSMT8 texture whose index is the texel's x, and a CLUT whose entry n
# is a recognisable colour, then check the pair end to end.
vm2 = bytearray(8192 * 8)
for y in range(4):
    for x in range(8):
        vm2[g.addr8p(0, 2, x, y)] = x
CBP = 8                                        # blocks, clear of the texture
for c in range(256):
    off = g.clut_csm1_32(c)
    addr = ((CBP << 6) + off) * 4
    vm2[addr:addr + 4] = ((0xFF << 24) | (c << 8)).to_bytes(4, "little")
tex0_i = (0 | (2 << 14) | (g.PSMT8 << 20) | (3 << 26) | (2 << 30)
          | (CBP << 37) | (g.PSMCT32 << 51) | (0 << 55) | (0 << 56)
          | (g.CLD_LOAD << 61))
clut2 = g.Clut()
loaded = clut2.load(vm2, tex0_i)
check("the CLUT loaded when CLD said to", loaded, True)
got = [g.sample_uv(vm2, tex0_i, clamp, clut2, x << 4, 0)[1] for x in range(8)]
check("every index maps to its palette entry", got, list(range(8)))

# CLD = 0 must not reload, which is the half of the cache rule that a test
# naturally forgets: it is easy to assert that a load happened.
tex0_noload = (tex0_i & ~(7 << 61)) | (g.CLD_NONE << 61)
before = clut2.loads
clut2.load(vm2, tex0_noload)
check("CLD=0 does not reload", clut2.loads, before)

# ---- bilinear, and the half-texel shift -------------------------------------
# A 4 x 4 texture whose RED channel is x * 64. Red, not green: expand_texel puts
# the LOW byte in red, and writing a value into the wrong channel is the single
# most repeated mistake in this file's history.
vmb = bytearray(8192 * 8)
for y in range(4):
    for x in range(4):
        a = g.addr32p(0, 1, x, y) * 4
        vmb[a:a + 4] = ((0xFF << 24) | (x * 0x40)).to_bytes(4, "little")
tex0b = (1 << 14) | (g.PSMCT32 << 20) | (2 << 26) | (2 << 30)
clampc = g.WM_CLAMP | (g.WM_CLAMP << 2)


def lin(u_texels_times_16):
    return g.sample_uv_linear(vmb, tex0b, clampc, clut, u_texels_times_16, 8)[0]


# UV counts texel EDGES, so texel n's centre is at n + 0.5. The half-texel shift
# is what makes that centre return texel n unmixed.
check("bilinear at a texel centre returns that texel unmixed",
      [lin((n << 4) + 8) for n in range(3)], [0, 64, 128])
check("bilinear at a texel edge is an even blend of its neighbours",
      lin(2 << 4), 96)
check("bilinear three-quarters along weights in sixteenths",
      lin((1 << 4) + 12), 80)
check("nearest and bilinear agree at a texel centre",
      g.sample_uv(vmb, tex0b, clampc, clut, (2 << 4) + 8, 8)[0], lin((2 << 4) + 8))

# ---- the perspective divide --------------------------------------------------
F = g._F
check("STQ divides then scales by the texture size",
      g.stq_to_uv(F.pack(2)[0], F.pack(1)[0], F.pack(2)[0], 4, 4), (256, 128))
# Q = 0 has no infinity to produce, because the format has no encoding for one.
# Games do emit degenerate polygons -- at the horizon, and when a vertex crosses
# the eye plane -- so this is a real case, not a corner.
u, v = g.stq_to_uv(F.pack(1)[0], F.pack(1)[0], 0, 0, 0)
check("Q = 0 saturates rather than producing an infinity",
      (u, v), ((1 << 18) - 1, (1 << 18) - 1))
check("a negative S with Q = 0 saturates the other way",
      g.stq_to_uv(F.pack(-1)[0], F.pack(1)[0], 0, 0, 0)[0], -(1 << 18))

# ---- mipmap: LOD from Q, and the filter split -------------------------------
# log2(1/Q) is the negated exponent of Q and nothing else -- the mantissa is
# discarded, so the level changes in visible steps as a surface recedes rather
# than continuously. That is a real difference from a GPU, not an approximation
# of one, so the test asserts the step and not a smooth curve.
check("LOD is zero at Q = 1",       g.lod_from_q(F.pack(1)[0], 0, 0), 0)
check("LOD rises by one per halving of Q",
      [g.lod_from_q(F.pack(F.Fraction(1, 1 << n))[0], 0, 0) for n in range(4)],
      [0, 1, 2, 3])
check("LOD goes negative when Q grows (magnification)",
      g.lod_from_q(F.pack(4)[0], 0, 0), -2)
# The mantissa really is ignored: anything inside a power-of-two band of Q
# gives the same level.
check("every Q in one octave gives the same level",
      [g.lod_from_q(F.pack(F.Fraction(n, 16))[0], 0, 0) for n in (8, 9, 12, 15)],
      [1, 1, 1, 1])
check("L shifts the result and K biases it",
      g.lod_from_q(F.pack(F.Fraction(1, 4))[0], 2, 3), 2 * 4 + 3)

# MMAG is one bit and MMIN is three, because only minification can blend
# between levels -- there is nothing above the base level to blend with.
check("magnification uses MMAG and never blends levels",
      g.filter_for(-1, 1, g.MMIN_L_MIP_L), (True, False))
check("MMAG = 0 is nearest",  g.filter_for(-1, 0, g.MMIN_L_MIP_L), (False, False))
check("LINEAR_MIPMAP_LINEAR is linear within a level and blends between",
      g.filter_for(2, 0, g.MMIN_L_MIP_L), (True, True))
check("NEAREST_MIPMAP_LINEAR is nearest within a level but still blends",
      g.filter_for(2, 0, g.MMIN_N_MIP_L), (False, True))
check("LINEAR_MIPMAP_NEAREST is linear within one level and blends nothing",
      g.filter_for(2, 0, g.MMIN_L_MIP_N), (True, False))
check("plain LINEAR under minification blends nothing",
      g.filter_for(2, 0, g.MMIN_LINEAR), (True, False))

# MXL clamps: a level beyond the last one that exists is the last one.
check("the level is clamped at MXL", g.mip_level(5, 3), (3, 0))
check("a negative LOD is the base level", g.mip_level(-4, 3), (0, 0))

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
