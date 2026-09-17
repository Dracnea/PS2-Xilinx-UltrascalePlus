#!/usr/bin/env python3
"""Mutate gs_stq.vhd one edit at a time; every mutation must be caught.

    sim/gs/mutate_stq.py

This block is pure arithmetic against an exact model, which is the situation
where a wrong constant survives longest: it is right on most inputs and wrong
on a band, and a test built from round numbers never enters the band. Two of
the entries below are mistakes this file actually had.

**Every mutation is run against both tests**, and caught if either fails. That
is not tidiness. Three of these are invisible at gs_stq's output and obvious at
gs_fdiv's, because the last step throws away exactly the information they
corrupt: the sign of a zero and an exponent one past the format both disappear
when the coordinate is converted to 12.4, where any zero is 0 and anything past
the limit saturates the same way. Running only the block-level test scores them
as holes in the test suite when they are holes in one member of it.

Run from the repository root.

SPDX-License-Identifier: BSD-2-Clause
"""
import subprocess, shutil, sys, os
SRC = 'rtl/gs/gs_stq.vhd'
BAK = SRC + '.orig'

MUT = [
 # ---- the divider ---------------------------------------------------------
 ("a zero divisor raises instead of saturating",
  "                     q     <= sgn & POS_MAX(30 downto 0);",
  "                     q     <= sgn & (30 downto 0 => '0');"),

 ("a zero divisor forgets the sign",
  "                     q     <= sgn & POS_MAX(30 downto 0);",
  "                     q     <= '0' & POS_MAX(30 downto 0);"),

 ("a zero dividend returns a signed zero, which it had",
  "                     q     <= (31 downto 0 => '0');",
  "                     q     <= sgn & (30 downto 0 => '0');"),

 ("the quotient normalises the wrong way round",
  "                     if ma_v >= mb_v then\n                        n_v := resize(ma_v - mb_v, 25);",
  "                     if ma_v <= mb_v then\n                        n_v := resize(ma_v - mb_v, 25);"),

 ("the exponent is not decremented when the ratio is below one",
  "                        n_v := resize(ma_v, 25) + resize(ma_v, 25) - resize(mb_v, 25);\n                        e := e - 1;",
  "                        n_v := resize(ma_v, 25) + resize(ma_v, 25) - resize(mb_v, 25);"),

 ("the bias is 126 rather than 127",
  "                          + to_signed(127, 11);",
  "                          + to_signed(126, 11);"),

 ("the divider runs 22 steps instead of 23",
  "                  if cnt = 22 then",
  "                  if cnt = 21 then"),

 ("the remainder is not restored after a successful subtraction",
  "                  if rem_v >= resize(den, 25) then\n                     rem_v := rem_v - resize(den, 25);",
  "                  if rem_v >= resize(den, 25) then\n                     rem_v := rem_v;"),

 ("overflow wraps instead of saturating",
  "                  if ex >= 255 then\n                     q <= sgn & POS_MAX(30 downto 0);       -- saturate, no infinity",
  "                  if ex >= 256 then\n                     q <= sgn & POS_MAX(30 downto 0);       -- saturate, no infinity"),

 ("underflow drops the sign",
  "                     q <= sgn & (30 downto 0 => '0');       -- no denormals: zero",
  "                     q <= (31 downto 0 => '0');             -- no denormals: zero"),

 # ---- the scale by 2**TW --------------------------------------------------
 ("the scale subtracts the exponent instead of adding it",
  "      e := signed(resize(fexp(x), 11)) + signed(resize(k, 11));",
  "      e := signed(resize(fexp(x), 11)) - signed(resize(k, 11));"),

 ("the scale treats TW as a size rather than a logarithm",
  "      e := signed(resize(fexp(x), 11)) + signed(resize(k, 11));",
  "      e := signed(resize(fexp(x), 11)) + signed(resize(shift_left(resize(k, 11), 1), 11));"),

 ("the scale saturates a zero operand instead of passing it through",
  "      if fexp(x) = 0 then\n         return (31 downto 0 => '0');\n      end if;",
  "      if fexp(x) = 0 then\n         return x(31) & POS_MAX(30 downto 0);\n      end if;"),

 # ---- the conversion to 12.4 ---------------------------------------------
 ("the fixed-point shift is off by one, so every coordinate is doubled",
  "      sh := to_integer(fexp(x)) - 123;",
  "      sh := to_integer(fexp(x)) - 122;"),

 ("the saturation is symmetric, which the model's is not",
  "            return to_signed(-LIM - 1, 19);",
  "            return to_signed(-LIM, 19);"),

 ("the magnitude rounds instead of truncating toward zero",
  "      mag := resize(shift_right(m, 23 - sh), 19);",
  "      mag := resize(shift_right(m + shift_left(to_unsigned(1, 24), 22 - sh), 23 - sh), 19);"),


 ("the saturating band starts one exponent too late",
  "      elsif sh >= 18 then",
  "      elsif sh >= 19 then"),
]

# Expected to SURVIVE, with the reason. An equivalent mutant is not a hole and
# must not be scored as one -- but it has to be stated, because "not caught" and
# "nothing to catch" look identical in a results table.
EQUIVALENT = [
 ("the guard against a magnitude below one is removed",
  "      if sh < 0 then\n         return to_signed(0, 19);",
  "      if sh < -1 then\n         return to_signed(0, 19);",
  "at sh = -1 the shift below is shift_right(m, 24) on a 24-bit mantissa, which "
  "is zero anyway. The guard states the intent and the shift enforces it, so "
  "removing one leaves the other. At sh = -2 and below the guard is doing real "
  "work and the mutation would be caught."),
]

shutil.copy(SRC, BAK)
orig = open(BAK).read()
caught = missed = 0
try:
    for name, old, new in MUT:
        if old not in orig:
            print(f"  SKIP  {name}: the pattern no longer matches"); missed += 1; continue
        open(SRC, 'w').write(orig.replace(old, new, 1))
        by, detail = None, ""
        for script in ('sim/gs/run_fdiv_diff.sh', 'sim/gs/run_stq_diff.sh'):
            r = subprocess.run([script, '--seed', '1'],
                               capture_output=True, text=True, timeout=3000)
            if r.returncode != 0:
                by = script.split('/')[-1]
                n = [l for l in (r.stdout + r.stderr).splitlines()
                     if 'differ' in l or 'STALLED' in l]
                detail = n[0].strip() if n else ""
                break
        if by is None:
            print(f"  MISSED  {name}"); missed += 1
        else:
            print(f"  caught  {name}")
            print(f"            by {by}" + (f": {detail}" if detail else ""))
            caught += 1
finally:
    shutil.copy(BAK, SRC)

surprises = 0
try:
    for name, old, new, why in EQUIVALENT:
        if old not in orig:
            print(f"  SKIP  (equivalent) {name}"); surprises += 1; continue
        open(SRC, 'w').write(orig.replace(old, new, 1))
        ok = True
        for script in ('sim/gs/run_fdiv_diff.sh', 'sim/gs/run_stq_diff.sh'):
            if subprocess.run([script, '--seed', '1'], capture_output=True,
                              text=True, timeout=3000).returncode != 0:
                ok = False
                break
        if ok:
            print(f"  survived as expected  {name}")
            print(f"            because: {why}")
        else:
            print(f"  UNEXPECTEDLY CAUGHT  {name} -- the reason no longer holds")
            surprises += 1
finally:
    shutil.copy(BAK, SRC)
    if os.path.exists(BAK): os.remove(BAK)

print(f"\n{caught} caught, {missed} missed, of {len(MUT)}; "
      f"{len(EQUIVALENT)} equivalent, {surprises} surprising")
sys.exit(1 if (missed or surprises) else 0)
