#!/usr/bin/env python3
"""Mutate gs_texsample.vhd one edit at a time; every mutation must be caught.

    sim/gs/mutate_texsample.py

The bilinear entries are the reason this exists as a script. Building the filter
produced a real bug of exactly the shape these are aimed at -- `resize` on a
VHDL *signed* keeps the sign bit and the low bits beneath it, so `resize(uu, 4)`
returned uu(17) & uu(2 downto 0) rather than the four fractional bits. It was
zero at precisely the half-texel positions where a filter looks correct, so 327
of 759 bilinear cases passed with it in place. The mutation `the weight is three
bits and the sign` below reproduces it.

Run from the repository root.

SPDX-License-Identifier: BSD-2-Clause
"""
import subprocess, shutil, sys, os
SRC = 'rtl/gs/gs_texsample.vhd'
BAK = SRC + '.orig'

MUT = [
 # ---- the filter ---------------------------------------------------------
 ("the half-texel shift is missing",
  "                        uu := resize(u_fixed, 18) - 8;\n                        vv := resize(v_fixed, 18) - 8;",
  "                        uu := resize(u_fixed, 18);\n                        vv := resize(v_fixed, 18);"),

 ("the half texel is added instead of subtracted",
  "                        uu := resize(u_fixed, 18) - 8;\n                        vv := resize(v_fixed, 18) - 8;",
  "                        uu := resize(u_fixed, 18) + 8;\n                        vv := resize(v_fixed, 18) + 8;"),

 ("nearest gets the half-texel shift too",
  "                        r_u0 <= resize(shift_right(u_fixed, 4), 14);\n                        r_v0 <= resize(shift_right(v_fixed, 4), 14);",
  "                        r_u0 <= resize(shift_right(resize(u_fixed, 18) - 8, 4), 14);\n                        r_v0 <= resize(shift_right(resize(v_fixed, 18) - 8, 4), 14);"),

 ("the weight is three bits and the sign, the bug this block actually had",
  "                        r_fu <= unsigned(std_logic_vector(uu(3 downto 0)));\n                        r_fv <= unsigned(std_logic_vector(vv(3 downto 0)));",
  "                        r_fu <= unsigned(std_logic_vector(resize(uu, 4)));\n                        r_fv <= unsigned(std_logic_vector(resize(vv, 4)));"),

 ("the two weights are swapped",
  "   filtered <= bilerp(t00, t10, t01, t11, r_fu, r_fv) when r_linear = '1'",
  "   filtered <= bilerp(t00, t10, t01, t11, r_fv, r_fu) when r_linear = '1'"),

 ("the vertical pair is lerped before the horizontal one",
  "      top := lerp_rgba(c00, c10, fu);\n      bot := lerp_rgba(c01, c11, fu);\n      return lerp_rgba(top, bot, fv);",
  "      top := lerp_rgba(c00, c01, fv);\n      bot := lerp_rgba(c10, c11, fv);\n      return lerp_rgba(top, bot, fu);"),

 ("two corners are transposed",
  "         when \"01\"   => b <= v;\n         when \"10\"   => c <= v;",
  "         when \"01\"   => c <= v;\n         when \"10\"   => b <= v;"),

 ("the lerp shifts by four but divides toward zero",
  "      r := resize(signed('0' & a), 10) + resize(shift_right(p, 4), 10);",
  "      r := resize(signed('0' & a), 10) + resize(p / 16, 10);"),

 ("the lerp weight is out of sixteen but shifted by five",
  "      r := resize(signed('0' & a), 10) + resize(shift_right(p, 4), 10);",
  "      r := resize(signed('0' & a), 10) + resize(shift_right(p, 5), 10);"),

 ("the lerp interpolates the wrong way round",
  "      d := signed('0' & b) - signed('0' & a);",
  "      d := signed('0' & a) - signed('0' & b);"),

 ("the corner offsets are applied to v only",
  "   a_u_in <= resize(r_u0 + (\"0000000000000\" & corner(0)), 13);",
  "   a_u_in <= resize(r_u0, 13);"),

 ("the four corners are wrapped once, at the base coordinate",
  "   a_u_in <= resize(r_u0 + (\"0000000000000\" & corner(0)), 13);\n   a_v_in <= resize(r_v0 + (\"0000000000000\" & corner(1)), 13);",
  "   a_u_in <= resize(r_u0, 13);\n   a_v_in <= resize(r_v0, 13);"),

 ("the texel is expanded after the filter rather than before it",
  "   filtered <= bilerp(t00, t10, t01, t11, r_fu, r_fv) when r_linear = '1'\n               else t00;",
  "   filtered <= expand_texel(bilerp(t00, t10, t01, t11, r_fu, r_fv), unsigned(r_psm))\n               when r_linear = '1' else t00;"),

 ("only three corners are fetched",
  "                        if r_linear = '1' and corner /= \"11\" then\n                           corner <= corner + 1;\n                           state  <= FETCH;\n                        else\n                           state <= EMIT;\n                        end if;",
  "                        if r_linear = '1' and corner /= \"10\" then\n                           corner <= corner + 1;\n                           state  <= FETCH;\n                        else\n                           state <= EMIT;\n                        end if;"),

 # ---- things the nearest path already relied on ---------------------------
 ("MODULATE shifts by eight instead of seven",
  "      mr := shift_right(fr * tr, 7);",
  "      mr := shift_right(fr * tr, 8);"),

 ("DECAL keeps the fragment colour",
  "            return std_logic_vector(ta) & std_logic_vector(tb)\n                 & std_logic_vector(tg) & std_logic_vector(tr);",
  "            return std_logic_vector(ta) & std_logic_vector(fb)\n                 & std_logic_vector(fg) & std_logic_vector(fr);"),
]

shutil.copy(SRC, BAK)
orig = open(BAK).read()
caught = missed = 0
try:
    for name, old, new in MUT:
        if old not in orig:
            print(f"  SKIP  {name}: the pattern no longer matches"); missed += 1; continue
        open(SRC,'w').write(orig.replace(old, new, 1))
        r = subprocess.run(['sim/gs/run_texsample_diff.sh','--seed','1'],
                           capture_output=True, text=True, timeout=3000)
        if r.returncode == 0:
            print(f"  MISSED  {name}"); missed += 1
        else:
            out = r.stdout + r.stderr
            n = [l for l in out.splitlines() if 'samples differ' in l]
            print(f"  caught  {name}" + (f"  ({n[0].strip()})" if n else ""))
            caught += 1
finally:
    shutil.copy(BAK, SRC); os.remove(BAK)
print(f"\n{caught} caught, {missed} missed, of {len(MUT)}")
sys.exit(1 if missed else 0)
