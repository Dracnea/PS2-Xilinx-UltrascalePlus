#!/usr/bin/env python3
"""Check sim/gs/gs_ref.py's local-memory addressing against PCSX2's tables.

    tools/gs/xcheck_swizzle.py [--pcsx2 ~/pcsx2-ref/src]

The GS swizzle in the reference model is written as bit arithmetic, derived
from the layout the GS User's Manual describes rather than transcribed from
anyone's source.  That is the right way round for a GPL-2 repository that must
not take code from a GPL-3 one, but it means the arithmetic is only as good as
the derivation -- and an off-by-one in a bit interleave produces a picture that
is subtly, silently wrong.

So it gets checked against a second implementation, mechanically and
exhaustively.  PCSX2 stores the same layout as literal tables; this reads them
out of a PCSX2 checkout at run time, expands both to every pixel position a
page can hold, and compares.  Nothing is copied into this repository: the tool
needs a checkout to say anything at all, which is the correct dependency for
something that exists to disagree with us.

Exit status is 0 when they agree.
"""
import argparse, os, re, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "sim", "gs"))
import gs_ref


def read_table(src, name, rows, cols):
    """Pull one `static constexpr u8 name[rows][cols] = {...};` out of the source."""
    m = re.search(r"\b%s\s*\[\s*%d\s*\]\s*\[\s*%d\s*\]\s*=\s*\{(.*?)\n\};"
                  % (re.escape(name), rows, cols), src, re.S)
    if not m:
        return None
    nums = [int(t) for t in re.findall(r"\b\d+\b", m.group(1))]
    if len(nums) != rows * cols:
        return None
    return [nums[r * cols:(r + 1) * cols] for r in range(rows)]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pcsx2", default=os.path.expanduser("~/pcsx2-ref/src"))
    a = ap.parse_args()

    path = os.path.join(a.pcsx2, "pcsx2", "GS", "GSTables.cpp")
    if not os.path.exists(path):
        print("no PCSX2 checkout at %s -- nothing to check against" % path)
        print("this tool is a cross-check, not a test: absence is not a pass")
        return 2
    src = open(path, encoding="utf-8", errors="replace").read()

    bad = 0

    blk = read_table(src, "_blockTable32", 4, 8)
    if blk is None:
        print("FAIL could not read _blockTable32 -- PCSX2 layout changed?")
        bad += 1
    else:
        for by in range(4):
            for bx in range(8):
                mine, theirs = gs_ref.block32(by, bx), blk[by][bx]
                if mine != theirs:
                    print("FAIL block32(%d,%d) = %d, PCSX2 says %d" % (by, bx, mine, theirs))
                    bad += 1
        print("block32:  32 entries checked")

    col = read_table(src, "columnTable32", 8, 8)
    if col is None:
        print("FAIL could not read columnTable32 -- PCSX2 layout changed?")
        bad += 1
    else:
        for cy in range(8):
            for cx in range(8):
                mine, theirs = gs_ref.column32(cy, cx), col[cy][cx]
                if mine != theirs:
                    print("FAIL column32(%d,%d) = %d, PCSX2 says %d" % (cy, cx, mine, theirs))
                    bad += 1
        print("column32: 64 entries checked")

    # Both tables agreeing entry by entry is necessary but not sufficient: the
    # addresses they are combined into are what the rasteriser will use, so
    # check every pixel of a page against the composed table form as well, and
    # check that a page's worth of pixels lands on a page's worth of distinct
    # addresses -- a swizzle that collides is worse than one that is merely
    # shifted, and entry-by-entry equality would not notice.
    if blk and col:
        seen = set()
        for y in range(32):
            for x in range(64):
                mine = gs_ref.addr32(0, 1, x, y)
                theirs = (blk[(y >> 3) & 3][(x >> 3) & 7] * 64) + col[y & 7][x & 7]
                if mine != theirs:
                    print("FAIL addr32(%d,%d) = %d, composed table says %d" % (x, y, mine, theirs))
                    bad += 1
                seen.add(mine)
        print("addr32:   %d pixels of one page checked, %d distinct addresses"
              % (32 * 64, len(seen)))
        if len(seen) != 32 * 64:
            print("FAIL the swizzle collides: %d pixels share %d addresses"
                  % (32 * 64, len(seen)))
            bad += 1

    print("PASS  the addressing agrees with PCSX2" if not bad
          else "FAIL  %d disagreements" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
