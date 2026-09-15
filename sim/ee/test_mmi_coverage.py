#!/usr/bin/env python3
"""Assert that gen_mmi.py still exercises every parallel-ALU sub-opcode.

    sim/ee/test_mmi_coverage.py

The R5900 core decodes MMI0's and MMI1's parallel-ALU operation **twice**: once
in ID, as `par_decode`, whose two outputs drive the carry chain's operation and
lane width from a flop rather than from a LUT cone; and once in A1, in the case
arms that say whether the ALU runs at all and decode the shuffles.

Two descriptions of one mapping is a drift risk. The only thing standing between
that and a silent wrong answer is that every sub-opcode is executed by the
differential suite -- a disagreement then shows up as a failing test rather than
as one MMI instruction quietly computing a subtraction where it should have
computed a maximum.

That guard is invisible: nothing in gen_mmi.py says "this list must stay
complete", and a future edit that drops a sub-opcode would weaken the guarantee
without failing anything. So it is asserted here, where removing a sub-opcode
breaks a test that names the reason.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

# The parallel-ALU arms of MMI0 (fn 0x08) and MMI1 (fn 0x28). The shuffle arms
# are decoded only in A1 and so carry no drift risk; these are the ones whose
# operation and width are decoded in two places.
MMI0 = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x10, 0x11, 0x14, 0x15, 0x18, 0x19}
MMI1 = {0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x0A,
        0x10, 0x11, 0x14, 0x15, 0x18, 0x19}


def main():
    out = subprocess.run([sys.executable, os.path.join(HERE, "gen_mmi.py")],
                         capture_output=True, text=True, cwd=ROOT).stdout
    words = [int(l.split("//")[0].strip(), 16) for l in out.splitlines()
             if l.split("//")[0].strip()]
    seen0, seen1 = set(), set()
    for i in words:
        if (i >> 26) == 28:
            fn, sa = i & 0x3F, (i >> 6) & 0x1F
            if fn == 0x08:
                seen0.add(sa)
            elif fn == 0x28:
                seen1.add(sa)

    bad = 0
    for name, want, seen in (("MMI0", MMI0, seen0), ("MMI1", MMI1, seen1)):
        missing = sorted(want - seen)
        if missing:
            print("  FAIL %s: %d of %d covered, missing %s"
                  % (name, len(want & seen), len(want),
                     ", ".join("0x%02X" % m for m in missing)))
            print("       par_decode's ID-stage table is no longer guarded for "
                  "these; either restore them to gen_mmi.py or fold the two")
            print("       decodes into one.")
            bad += 1
        else:
            print("  ok   %s: all %d parallel-ALU sub-opcodes exercised"
                  % (name, len(want)))
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
