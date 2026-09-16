#!/usr/bin/env python3
"""Check sim/vu/vu_ref.py's upper-instruction decode against PCSX2's tables.

    tools/vu/xcheck_ops.py [--pcsx2 ~/pcsx2-ref/src]

Same arrangement as tools/gs/xcheck_swizzle.py, and for the same reason. This
repository is GPL-2 and PCSX2 is GPL-3, so nothing may be copied from it; but
an *oracle* is not a source. The decode in `vu_ref.py` was written from the
instruction set, and this reads PCSX2's dispatch tables at run time and checks
that every one of the 64 + 4 x 32 entries names the same instruction.

That matters more here than it looks. The upper opcode space has two shapes in
it -- a flat 64-entry table, and a four-way extension where opcodes 0x3C..0x3F
use the *fd* field as a sub-opcode -- and the extension is where a
reconstruction from memory goes wrong: ADDAx and ADDAy live in different
tables, three entries apart from their neighbours, and the arrangement is not
the one the broadcast forms use. Checking all 192 entries is what turns "this
looks right" into a claim that can fail.

Nothing from PCSX2 is retained: the tables are read, compared, and discarded.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "sim", "vu"))
import vu_ref as V


def table(src, name, n):
    """Pull one `static const ... name[n] = { ... };` out of the source."""
    m = re.search(r"\b%s\s*\[\s*%d\s*\]\s*=\s*\{(.*?)\};" % (re.escape(name), n),
                  src, re.S)
    if not m:
        raise SystemExit("could not find %s[%d] -- PCSX2 layout changed?" % (name, n))
    body = re.sub(r"//[^\n]*", "", m.group(1))
    names = [t.strip() for t in body.split(",") if t.strip()]
    if len(names) != n:
        raise SystemExit("%s: read %d entries, expected %d" % (name, len(names), n))
    return names


# PCSX2's name -> what vu_ref's decode should say. The broadcast suffix and the
# accumulator "A" are folded back out, because vu_ref keeps them as fields of
# the decode rather than as distinct instruction names.
BC = {"x": 0, "y": 1, "z": 2, "w": 3}


def expected(sym):
    """(name, src, acc, bc) that vu_ref should return for PCSX2's `sym`."""
    if sym in ("mVUunknown",):
        return None
    n = sym[len("mVU_"):] if sym.startswith("mVU_") else sym
    if n == "NOP":
        return ("NOP", None, False, None)
    if n == "ABS":
        return ("ABS", None, False, None)
    if n == "CLIP":
        return ("CLIP", None, False, None)
    if n.startswith("ITOF") or n.startswith("FTOI"):
        return (n, None, False, None)
    if n in ("OPMULA",):
        return ("OPMULA", "v", True, None)
    if n in ("OPMSUB",):
        return ("OPMSUB", "v", False, None)

    acc = False
    m = re.match(r"^(ADD|SUB|MADD|MSUB|MAX|MINI|MUL)(A?)([xyzwqi]?)$", n)
    if not m:
        raise SystemExit("unhandled PCSX2 name: " + sym)
    base, a, suf = m.group(1), m.group(2), m.group(3)
    acc = (a == "A")
    if suf in BC:
        return (base, "bc", acc, BC[suf])
    if suf in ("q", "i"):
        return (base, suf, acc, None)
    return (base, "v", acc, None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pcsx2", default=os.path.expanduser("~/pcsx2-ref/src"))
    a = ap.parse_args()
    path = os.path.join(a.pcsx2, "pcsx2", "x86", "microVU_Tables.inl")
    if not os.path.isfile(path):
        raise SystemExit("no microVU_Tables.inl at " + path)
    src = open(path, encoding="utf-8", errors="replace").read()

    checked = wrong = skipped = 0

    def compare(what, sym, code):
        nonlocal checked, wrong, skipped
        want = expected(sym)
        if want is None:
            skipped += 1
            return
        got = V.decode_upper(code)
        gname, gsrc, gacc, gbc = got
        wname, wsrc, wacc, wbc = want
        ok = (gname == wname and gsrc == wsrc and gacc == wacc
              and (wbc is None or gbc == wbc))
        checked += 1
        if not ok:
            wrong += 1
            if wrong <= 12:
                print("  MISMATCH %-22s code=%08x" % (what, code))
                print("      PCSX2   %-12s -> %s" % (sym, want))
                print("      vu_ref                 -> %s" % (got,))

    # The flat table. fd and the bc bits both matter, so build a real encoding.
    flat = table(src, "mVU_UPPER_OPCODE", 64)
    for op, sym in enumerate(flat):
        if op >= 0x3C:
            continue                       # the extension, checked below
        code = (0xF << 21) | (2 << 16) | (1 << 11) | (3 << 6) | op
        compare("opcode 0x%02x" % op, sym, code)

    # The four extension tables. Their index is the fd field.
    for w, nm in enumerate(("00", "01", "10", "11")):
        ext = table(src, "mVU_UPPER_FD_%s_TABLE" % nm, 32)
        for fd, sym in enumerate(ext):
            code = (0xF << 21) | (2 << 16) | (1 << 11) | (fd << 6) | (0x3C + w)
            compare("FD_%s[%d]" % (nm, fd), sym, code)

    # ---- the lower slot ---------------------------------------------------
    # Three dispatch levels, 128 + 64 + 4 x 32 entries. The names map straight
    # across here because vu_ref keeps the lower instructions as names rather
    # than folding suffixes into fields the way the upper ones do.
    lo_checked = lo_wrong = 0

    def lo(what, sym, code):
        nonlocal lo_checked, lo_wrong
        if sym == "mVUunknown":
            # An encoding PCSX2 does not define must not decode here either:
            # inventing an instruction is as wrong as missing one.
            if V.decode_lower(code) is not None:
                print("  EXTRA %-22s decodes as %s, undefined in PCSX2"
                      % (what, V.decode_lower(code)))
                lo_wrong += 1
            return
        want = sym[len("mVU_"):] if sym.startswith("mVU_") else sym
        if want.startswith("owerOP"):
            return                       # a dispatch entry, not an instruction
        got = V.decode_lower(code)
        lo_checked += 1
        if got != want:
            lo_wrong += 1
            if lo_wrong <= 12:
                print("  MISMATCH %-22s PCSX2 %-8s vu_ref %s" % (what, want, got))

    top = table(src, "mVULOWER_OPCODE", 128)
    for op, sym in enumerate(top):
        if op == 0x40:
            continue
        lo("lower 0x%02x" % op, sym, (op << 25) | 0x0000)

    second = table(src, "mVULowerOP_OPCODE", 64)
    for sub, sym in enumerate(second):
        if 0x3C <= sub <= 0x3F:
            continue
        lo("lower2 0x%02x" % sub, sym, (0x40 << 25) | sub)

    for w, nm in enumerate(("00", "01", "10", "11")):
        t3 = table(src, "mVULowerOP_T3_%s_OPCODE" % nm, 32)
        for k, sym in enumerate(t3):
            lo("T3_%s[%d]" % (nm, k), sym, (0x40 << 25) | (0x3C + w) | (k << 6))

    print("lower: %d entries checked, %d wrong" % (lo_checked, lo_wrong))
    wrong += lo_wrong

    print("%d entries checked, %d unknown in PCSX2 and skipped, %d wrong"
          % (checked, skipped, wrong))
    print("PASS" if wrong == 0 else "FAIL")
    return 0 if wrong == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
