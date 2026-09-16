#!/usr/bin/env python3
"""Check sim/gs/gs_ref.py's CSM1 CLUT layout against PCSX2's tables.

    tools/gs/xcheck_clut.py [--pcsx2 ~/pcsx2-ref/src]

The arrangement is the one tools/gs/xcheck_swizzle.py uses and the reasoning is
the same: this repository is GPL-2 and PCSX2 is GPL-3, so nothing is copied, but
an oracle is not a source. The CSM1 layout here was **derived** -- a 16-entry
CLUT is one PSMCT32 column read in raster order, and a 256-entry CLUT is that
pattern stepped over four consecutive blocks alternating between two at a time
-- and this reads PCSX2's tables at run time to check the derivation entry by
entry.

That order matters. A formula fitted to a table is worth nothing: it agrees by
construction. A formula derived from the structure and then checked against a
table is a claim that could have failed, and this one covers every entry of
clutTableT32I4 and clutTableT32I8 and then all 256 entries for bijectivity,
which the tables alone do not reach.

Nothing from PCSX2 is retained; the tables are read, compared, and discarded.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "sim", "gs"))
import gs_ref as g


def table(src, name, n):
    m = re.search(r"\b%s\s*\[\s*%d\s*\]\s*=\s*\{(.*?)\};" % (re.escape(name), n),
                  src, re.S)
    if not m:
        raise SystemExit("could not find %s[%d] -- PCSX2 layout changed?" % (name, n))
    body = re.sub(r"//[^\n]*", "", m.group(1))
    vals = [int(t.strip()) for t in body.split(",") if t.strip()]
    if len(vals) != n:
        raise SystemExit("%s: read %d entries, expected %d" % (name, len(vals), n))
    return vals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcsx2", default=os.path.expanduser("~/pcsx2-ref/src"))
    a = ap.parse_args()
    path = os.path.join(a.pcsx2, "pcsx2", "GS", "GSTables.cpp")
    if not os.path.isfile(path):
        raise SystemExit("no GSTables.cpp at " + path)
    src = open(path, encoding="utf-8", errors="replace").read()

    bad = 0

    t4 = table(src, "clutTableT32I4", 16)
    mine4 = [g.clut_csm1_32(c) for c in range(16)]
    if mine4 == t4:
        print("  ok   clutTableT32I4: 16 entries, a PSMCT32 column in raster order")
    else:
        print("  FAIL clutTableT32I4")
        print("       PCSX2  ", t4)
        print("       derived", mine4)
        bad += 1

    t8 = table(src, "clutTableT32I8", 128)
    mine8 = [g.clut_csm1_32(c) for c in range(128)]
    if mine8 == t8:
        print("  ok   clutTableT32I8: all 128 entries reproduced")
    else:
        first = next(i for i in range(128) if mine8[i] != t8[i])
        print("  FAIL clutTableT32I8: first difference at entry %d" % first)
        print("       PCSX2   %s" % t8[max(0, first - 2):first + 4])
        print("       derived %s" % mine8[max(0, first - 2):first + 4])
        bad += 1

    # The tables stop at 128; the formula covers 256, and bijectivity is what
    # checks the half no table reaches.
    full = [g.clut_csm1_32(c) for c in range(256)]
    if sorted(full) == list(range(256)):
        print("  ok   all 256 entries are a bijection onto the four blocks")
    else:
        dup = len(full) - len(set(full))
        print("  FAIL 256 entries are not a bijection: %d collisions" % dup)
        bad += 1

    # The thing that is easy to assume and wrong: that a CLUT is a 16x16 image.
    image = [g.addr32p(0, 1, c % 16, c // 16) for c in range(256)]
    if image == full:
        print("  FAIL the derivation collapsed into the 16x16-image reading, "
              "which is the wrong one")
        bad += 1
    else:
        print("  ok   and it is NOT the 16x16-image layout, which is the "
              "plausible wrong answer")

    print("PASS" if bad == 0 else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
