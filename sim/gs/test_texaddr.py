#!/usr/bin/env python3
"""Check the indexed-texture addressing without needing anyone's source.

    sim/gs/test_texaddr.py

`tools/gs/xcheck_swizzle.py` proves the column and block *tables* against
PCSX2's, exhaustively.  It says nothing about how those pieces are assembled
into an address -- the page shape, the block-grid indices, and the way TBW is
scaled -- and that assembly is where the remaining mistakes live.

The check that needs no second implementation is **bijectivity**.  A page of
local memory holds exactly as many texels as it has storage units, so the map
from (x, y) to address must hit every unit exactly once.  Any transposed shift,
any wrong mask, any page stride that is off by a factor of two collapses two
texels onto one address and leaves another unreached -- and this finds it by
counting, not by comparison.

The second check is the one bijectivity cannot see: a map can be a perfect
permutation of a page and still put the pages themselves in the wrong order.
So the multi-page cases assert that page n begins exactly n pages along.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gs_ref as g


def bijection(name, w, h, units, fn):
    """fn(x, y) must be a bijection from a w x h page onto 0 .. units-1."""
    seen = [0] * units
    bad = []
    for y in range(h):
        for x in range(w):
            a = fn(x, y)
            if not (0 <= a < units):
                bad.append(f"({x},{y}) -> {a}, outside 0..{units - 1}")
                if len(bad) > 4:
                    break
            else:
                seen[a] += 1
    dup = [i for i, n in enumerate(seen) if n > 1]
    miss = [i for i, n in enumerate(seen) if n == 0]
    if bad or dup or miss:
        print(f"  FAIL {name}")
        for b in bad[:5]:
            print("       " + b)
        if dup:
            print(f"       {len(dup)} addresses written twice, first {dup[:4]}")
        if miss:
            print(f"       {len(miss)} addresses never reached, first {miss[:4]}")
        return False
    print(f"  ok   {name}: {w}x{h} is a bijection onto {units} units")
    return True


def page_order(name, w, h, page_units, fn, bw, pages_x):
    """Texel (0,0) of page (px, py) must land exactly that many pages along."""
    ok = True
    for py in range(2):
        for px in range(pages_x):
            want = (py * pages_x + px) * page_units
            got = fn(px * w, py * h)
            if got != want:
                print(f"  FAIL {name}: page ({px},{py}) starts at {got}, "
                      f"expected {want}")
                ok = False
    if ok:
        print(f"  ok   {name}: pages are in order at TBW={bw}")
    return ok


def main():
    good = True
    print("PSMT8 -- a page is 128 x 64 texels, 8192 bytes")
    good &= bijection("PSMT8 page", 128, 64, 8192,
                      lambda x, y: g.addr8p(0, 2, x, y))
    good &= page_order("PSMT8", 128, 64, 8192,
                       lambda x, y: g.addr8p(0, 4, x, y), 4, 2)

    print("PSMT4 -- a page is 128 x 128 texels, 16384 nibbles")
    good &= bijection("PSMT4 page", 128, 128, 16384,
                      lambda x, y: g.addr4p(0, 2, x, y))
    good &= page_order("PSMT4", 128, 128, 16384,
                       lambda x, y: g.addr4p(0, 4, x, y), 4, 2)

    # The colour formats the indexed ones are checked against, so a regression
    # in the shared pieces shows up here too rather than only in a texture test.
    print("PSMCT32 -- a page is 64 x 32 texels, 2048 words")
    good &= bijection("PSMCT32 page", 64, 32, 2048,
                      lambda x, y: g.addr32p(0, 1, x, y))

    print("the H formats -- addressed exactly as PSMCT32, index in the spare byte")
    vm = bytearray(8192 * 4)
    # Write a distinct index at every texel of one page through PSMT8H, then
    # read every one back.  This is the claim that matters for the H formats:
    # that they are PSMCT32 addressing plus an extraction, and nothing else.
    for y in range(32):
        for x in range(64):
            w = g.addr32p(0, 1, x, y) * 4
            idx = (y * 64 + x) & 0xFF
            word = idx << 24 | 0x00ABCDEF
            vm[w:w + 4] = word.to_bytes(4, "little")
    wrong = 0
    for y in range(32):
        for x in range(64):
            if g.texel_index(vm, g.PSMT8H, 0, 1, x, y) != ((y * 64 + x) & 0xFF):
                wrong += 1
    # The same word read as the two 4-bit H formats must give the two nibbles
    # of that byte, low from HL and high from HH.
    for y in range(4):
        for x in range(8):
            b = (y * 64 + x) & 0xFF
            if g.texel_index(vm, g.PSMT4HL, 0, 1, x, y) != (b & 0xF):
                wrong += 1
            if g.texel_index(vm, g.PSMT4HH, 0, 1, x, y) != (b >> 4):
                wrong += 1
    if wrong:
        print(f"  FAIL H formats: {wrong} texels read back wrong")
        good = False
    else:
        print("  ok   PSMT8H, PSMT4HL and PSMT4HH round-trip through a PSMCT32 page")

    print("PASS" if good else "FAIL")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
