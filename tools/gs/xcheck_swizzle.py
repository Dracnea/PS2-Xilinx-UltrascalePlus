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
    # Strip line comments before counting numbers.  PCSX2 labels the halves of
    # its column tables with `// column 0`, and the 0 in that comment is
    # indistinguishable from data to a bare number scan -- which made this
    # function return None for every commented table and the check above report
    # "PCSX2 layout changed?" for tables that had not changed at all.  A
    # cross-check that quietly declines to check is worse than no cross-check.
    body = re.sub(r"//[^\n]*", "", m.group(1))
    nums = [int(t) for t in re.findall(r"\b\d+\b", body)]
    if len(nums) != rows * cols:
        return None
    return [nums[r * cols:(r + 1) * cols] for r in range(rows)]


def read_swizzle_xor(pcsx2, name):
    """Pull the block xor out of a `static constexpr GSSwizzleInfo name {table, 0xNN};`."""
    path = os.path.join(pcsx2, "pcsx2", "GS", "GSLocalMemory.h")
    if not os.path.exists(path):
        return None
    src = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"GSSwizzleInfo\s+%s\s*\{[^}]*?,\s*(0x[0-9A-Fa-f]+|\d+)\s*\}"
                  % re.escape(name), src)
    return int(m.group(1), 0) if m else None


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

    # ---- the indexed texture formats ------------------------------------
    #
    # gs_ref derives these as bit-linear closed forms rather than storing the
    # tables, which is the claim this check exists to break.
    for name, rows, cols, fn, label in (
            ("_blockTable8",  4,  8, gs_ref.block8,  "block8"),
            ("columnTable8", 16, 16, gs_ref.column8, "column8"),
            ("_blockTable4",  8,  4, gs_ref.block4,  "block4"),
            ("columnTable4", 16, 32, gs_ref.column4, "column4")):
        t = read_table(src, name, rows, cols)
        if t is None:
            print("FAIL could not read %s -- PCSX2 layout changed?" % name)
            bad += 1
            continue
        n = 0
        for r in range(rows):
            for c in range(cols):
                mine, theirs = fn(r, c), t[r][c]
                if mine != theirs:
                    print("FAIL %s(%d,%d) = %d, PCSX2 says %d"
                          % (label, r, c, mine, theirs))
                    bad += 1
                n += 1
        print("%-9s %d entries checked" % (label + ":", n))

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

    # ---- the depth formats -------------------------------------------------
    # PSMZ32 and PSMZ24 use the *same* block table with the block address
    # exclusive-ored by 24.  PCSX2 states that as a constructor argument rather
    # than as a table -- `swizzle32Z {swizzleTables32, 0x18}` against
    # `swizzle32 {swizzleTables32, 0x00}` -- so the xor is read out of the
    # header and compared with ours instead of being assumed.  It is worth
    # checking mechanically because a differential test between our own two
    # implementations cannot see it: they would be wrong together.
    zxor = read_swizzle_xor(a.pcsx2, "swizzle32Z")
    if zxor is None:
        print("FAIL could not read swizzle32Z's xor -- PCSX2 layout changed?")
        bad += 1
    elif zxor != gs_ref.BLK_Z:
        print("FAIL the Z block xor is %d, PCSX2 says %d" % (gs_ref.BLK_Z, zxor))
        bad += 1
    else:
        print("Z xor:    %d, as PCSX2 has it" % zxor)

    if blk and col and zxor is not None:
        for y in range(32):
            for x in range(64):
                mine = gs_ref.addr32p(0, 1, x, y, gs_ref.BLK_Z)
                theirs = ((blk[(y >> 3) & 3][(x >> 3) & 7] ^ zxor) * 64) + col[y & 7][x & 7]
                if mine != theirs:
                    print("FAIL Z addr(%d,%d) = %d, composed table says %d"
                          % (x, y, mine, theirs))
                    bad += 1
        print("addr32Z:  %d pixels of one page checked" % (32 * 64))

        # The property that makes the xor matter at all: a Z buffer and a colour
        # buffer at the same base do not agree about where a pixel lives.  If
        # this ever came out equal, the xor would have been dropped somewhere.
        same = sum(1 for y in range(32) for x in range(64)
                   if gs_ref.addr32p(0, 1, x, y) == gs_ref.addr32p(0, 1, x, y, gs_ref.BLK_Z))
        if same:
            print("FAIL %d pixels address the same word as colour and as depth" % same)
            bad += 1
        else:
            print("addr32Z:  no pixel shares an address with its colour form")

    # ---- the 16-bit formats ------------------------------------------------
    # Two block tables, one column table shared between them, and a column
    # table whose entries are *pixel* indices within a block rather than word
    # indices -- which is the one place these can be misread.  Ours returns a
    # word and a half; p = word * 2 + half is what PCSX2 tabulates.
    for name, fn in (("_blockTable16", gs_ref.block16),
                     ("_blockTable16S", gs_ref.block16s)):
        tbl = read_table(src, name, 8, 4)
        if tbl is None:
            print("FAIL could not read %s -- PCSX2 layout changed?" % name)
            bad += 1
            continue
        for by in range(8):
            for bx in range(4):
                mine, theirs = fn(by, bx), tbl[by][bx]
                if mine != theirs:
                    print("FAIL %s(%d,%d) = %d, PCSX2 says %d"
                          % (name, by, bx, mine, theirs))
                    bad += 1
        print("%-14s 32 entries checked" % (name.lstrip("_") + ":"))

    col16 = read_table(src, "columnTable16", 8, 16)
    if col16 is None:
        print("FAIL could not read columnTable16 -- PCSX2 layout changed?")
        bad += 1
    else:
        for cy in range(8):
            for cx in range(16):
                word = gs_ref.column32(cy, cx & 7)
                mine = word * 2 + ((cx >> 3) & 1)
                if mine != col16[cy][cx]:
                    print("FAIL column16(%d,%d) = %d, PCSX2 says %d"
                          % (cy, cx, mine, col16[cy][cx]))
                    bad += 1
        print("columnTable16: 128 entries checked")

    # And the composed addressing, for every pixel of a page, in all four
    # 16-bit formats.  The Z forms are the colour ones xor 24, as at 32 bits.
    b16  = read_table(src, "_blockTable16", 8, 4)
    b16s = read_table(src, "_blockTable16S", 8, 4)
    z16  = read_swizzle_xor(a.pcsx2, "swizzle16Z")
    z16s = read_swizzle_xor(a.pcsx2, "swizzle16SZ")
    if z16 != gs_ref.BLK_Z or z16s != gs_ref.BLK_Z:
        print("FAIL PCSX2's 16-bit Z xors are %s/%s, not %d"
              % (z16, z16s, gs_ref.BLK_Z))
        bad += 1
    if b16 and b16s and col16 and z16 is not None:
        for sform, tbl in ((False, b16), (True, b16s)):
            for zx in (0, gs_ref.BLK_Z):
                seen = set()
                for y in range(64):
                    for x in range(64):
                        word, half = gs_ref.addr16p(0, 1, x, y, sform, zx)
                        mine = word * 2 + half
                        theirs = ((tbl[(y >> 3) & 7][(x >> 4) & 3] ^ zx) * 128
                                  + col16[y & 7][x & 15])
                        if mine != theirs:
                            print("FAIL addr16(%d,%d) sform=%s zx=%d: %d, table says %d"
                                  % (x, y, sform, zx, mine, theirs))
                            bad += 1
                        seen.add(mine)
                if len(seen) != 64 * 64:
                    print("FAIL the 16-bit swizzle collides (sform=%s zx=%d): "
                          "%d pixels share %d addresses"
                          % (sform, zx, 64 * 64, len(seen)))
                    bad += 1
        print("addr16:   %d pixels checked in each of four formats" % (64 * 64))

    print("PASS  the addressing agrees with PCSX2" if not bad
          else "FAIL  %d disagreements" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
