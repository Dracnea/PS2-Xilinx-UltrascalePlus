#!/usr/bin/env python3
"""Mutate gs_texcache.vhd one edit at a time; every mutation must be caught.

    sim/gs/mutate_texcache.py

Mutation testing has twice found holes in this repository's *tests* rather than
in its RTL, which is why it is kept as a script here rather than run once by
hand and written up. Two of the entries below did exactly that again:

  * the modelled memory answered every read whether or not the arbiter had
    granted it, so a cache that ignored `m_ready` was indistinguishable from one
    that honoured it -- in `gs_top` the ungranted read simply never happens;
  * every address in the coherence cases lived in the bottom of local memory,
    where the top bit of the tag is zero, so a tag comparison that dropped that
    bit aliased two lines and nothing noticed.

Both are now covered. Run from the repository root.

SPDX-License-Identifier: BSD-2-Clause
"""
import subprocess, shutil, sys, os
SRC = 'rtl/gs/gs_texcache.vhd'
BAK = SRC + '.orig'

MUT = [
 ("snoop never invalidates",
  "            elsif s_hit = '1' then\n               valid(slot_of(s_set, s_way)) <= '0';",
  "            elsif s_hit = '1' and false then\n               valid(slot_of(s_set, s_way)) <= '0';"),

 ("snoop invalidates on the set alone, ignoring the tag",
  "         if valid(slot_of(s_set, to_unsigned(w, WAYS_LOG2))) = '1'\n            and tag_arr(slot_of(s_set, to_unsigned(w, WAYS_LOG2))) = s_tag then",
  "         if valid(slot_of(s_set, to_unsigned(w, WAYS_LOG2))) = '1' then"),

 ("a write colliding with a lookup is not a forced miss",
  "   l_collide <= '1' when snoop_en = '1' and s_set = l_set and s_tag = l_tag\n                else '0';",
  "   l_collide <= '0';"),

 ("the poisoned fill is kept",
  "               if miss_stale = '0'\n                  and not (snoop_en = '1' and snoop_addr = miss_addr)\n                  and not (flush = '1') then",
  "               if true then"),

 ("flush does not clear the valid bits",
  "            if flush = '1' then\n               valid <= (others => '0');",
  "            if flush = '1' and false then\n               valid <= (others => '0');"),

 ("the victim pointer never advances, so the second way is dead",
  "                  victim(to_integer(l_set)) <= victim(to_integer(l_set)) + 1;",
  "                  victim(to_integer(l_set)) <= victim(to_integer(l_set));"),

 ("the index is the plain low bits, not folded",
  "      return lo xor mid;",
  "      return lo;"),

 ("the fill always lands in way 0, so the cache is direct-mapped",
  "                  data_arr(slot_of(v_set, miss_way)) <= m_rd_data;\n                  tag_arr (slot_of(v_set, miss_way)) <= tag_of(miss_addr);",
  "                  data_arr(slot_of(v_set, to_unsigned(0, WAYS_LOG2))) <= m_rd_data;\n                  tag_arr (slot_of(v_set, to_unsigned(0, WAYS_LOG2))) <= tag_of(miss_addr);"),

 ("a miss is answered before the memory has replied",
  "            if miss_busy = '1' and miss_issued = '1' and m_rd_valid = '1' then",
  "            if miss_busy = '1' and miss_issued = '1' then"),

 ("the request is issued without waiting for the arbiter's grant",
  "            if miss_busy = '1' and miss_issued = '0' and m_ready = '1' then",
  "            if miss_busy = '1' and miss_issued = '0' then"),

 ("the tag comparison ignores its top bit",
  "            and tag_arr(slot_of(l_set, to_unsigned(w, WAYS_LOG2))) = l_tag then",
  "            and tag_arr(slot_of(l_set, to_unsigned(w, WAYS_LOG2)))(TAG_W-2 downto 0) = l_tag(TAG_W-2 downto 0) then"),

 ("a hit under a miss wins over counting the request as dropped",
  "               if miss_busy = '1' then\n                  -- gs_texsample cannot do this. Counted rather than assumed.\n                  dbg_dropped <= dbg_dropped + 1;\n               elsif l_hit = '1' then",
  "               if l_hit = '1' or (miss_busy = '1' and false) then\n                  dbg_dropped <= dbg_dropped + 0;\n               elsif miss_busy = '1' then\n                  dbg_dropped <= dbg_dropped + 1;\n               elsif l_hit = '1' then"),
]

# Mutations that are expected to SURVIVE, with the reason. An equivalent mutant
# is not a hole in the test and must not be counted as one -- but it must be
# stated, because "the test did not catch it" and "there was nothing to catch"
# look identical in a results table. If one of these ever starts failing, the
# code has changed shape and the reason below needs re-reading.
EQUIVALENT = [
 ("the not-miss_busy term is dropped from l_hit",
  "      l_hit <= hit and c_rd_en and (not miss_busy) and (not l_collide);",
  "      l_hit <= hit and c_rd_en and (not l_collide);",
  "l_hit is read in exactly one place, inside the elsif of a branch already "
  "guarded by miss_busy = '1', so the term is redundant with the branch "
  "priority. The behaviour it guards is mutated separately, and caught."),
]

shutil.copy(SRC, BAK)
orig = open(BAK).read()
caught = missed = 0
try:
    for name, old, new in MUT:
        if old not in orig:
            print(f"  SKIP  {name}: the pattern no longer matches"); missed += 1; continue
        open(SRC,'w').write(orig.replace(old, new, 1))
        r = subprocess.run(['sim/gs/run_texcache_diff.sh','--seed','1'],
                           capture_output=True, text=True, timeout=3000)
        ok = r.returncode == 0
        if ok:
            print(f"  MISSED  {name}"); missed += 1
        else:
            why = [l for l in (r.stdout+r.stderr).splitlines() if 'FAIL' in l or 'differ' in l]
            print(f"  caught  {name}")
            if why: print(f"            by: {why[0].strip()[:110]}")
            caught += 1
finally:
    shutil.copy(BAK, SRC)

surprises = 0
try:
    for name, old, new, why in EQUIVALENT:
        if old not in orig:
            print(f"  SKIP  (equivalent) {name}: the pattern no longer matches")
            surprises += 1
            continue
        open(SRC,'w').write(orig.replace(old, new, 1))
        r = subprocess.run(['sim/gs/run_texcache_diff.sh','--seed','1'],
                           capture_output=True, text=True, timeout=3000)
        if r.returncode == 0:
            print(f"  survived as expected  {name}")
            print(f"            because: {why}")
        else:
            print(f"  UNEXPECTEDLY CAUGHT  {name} -- the reason below no longer holds")
            print(f"            was: {why}")
            surprises += 1
finally:
    shutil.copy(BAK, SRC)
    if os.path.exists(BAK): os.remove(BAK)

print(f"\n{caught} caught, {missed} missed, of {len(MUT)}; "
      f"{len(EQUIVALENT)} equivalent, {surprises} surprising")
sys.exit(1 if (missed or surprises) else 0)
