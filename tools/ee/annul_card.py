#!/usr/bin/env python3
"""Check on the card that a not-taken branch-likely annuls its delay slot.

    tools/ee/annul_card.py --csr build/c1100_ee/csr.csv
    tools/ee/annul_card.py --csr build/c1100_ee/csr.csv --runs 50

`BGTZL` reads `r0`, so it is never taken and its delay slot must be nullified.
The slot is then one of three things -- a divide, a multiply, or an ordinary
ADDIU -- and `MFLO`/`MFHI` bring HI and LO back into general registers, which is
the only way the debug port can see them.

This exists because the other card harnesses cannot see this bug. They generate
straight-line and branching code that never puts a multiply or divide in a delay
slot, so they show the absence of a regression rather than the presence of the
fix. The bug it guards against: a multiply or divide in the slot asserts
`ex_busy`, which holds A1, so the slot does not move into EX2 on the edge the
branch acts -- annulment cancelled the bubble that moved instead, and the slot
stayed in A1 and finished. A DIVU slot wrote LO=0xe and HI=2 where the reference
model wrote neither.

Every case is diffed against sim/ee/r5900_ref.py rather than against a constant,
so the expected values come from the same model every other test is checked
against.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "sim", "ee"))

import eerun                      # noqa: E402
import r5900_ref                  # noqa: E402

# ADDIU r1,r0,100 / ADDIU r2,r0,7 / BGTZL r0,+2 / <slot> / MFLO r3 / MFHI r4 /
# ADDIU r6,r0,0x42 / park / delay slot
PREFIX = [0x24010064, 0x24020007, 0x5C000002]
SUFFIX = [0x00001812, 0x00002010, 0x24060042, 0x1000FFFF, 0x00000000]

CASES = [
    ("DIVU  in the slot", 0x0022001B),
    ("MULT  in the slot", 0x00220018),
    ("ADDIU in the slot", 0x24050055),   # the control: it always annulled
]

MEM_WORDS = 4096


def program(slot):
    p = PREFIX + [slot] + SUFFIX
    return p + [0] * (MEM_WORDS - len(p))


def model(words):
    mem = r5900_ref.Mem()
    for k, v in enumerate(words):
        mem.store(k * 4, 4, v)
    cpu = r5900_ref.R5900(mem, 0)
    for _ in range(400):
        cpu.step()
    return [cpu.r128(i) for i in range(32)]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    ap.add_argument("--runs", type=int, default=25)
    a = ap.parse_args()

    card = eerun.Card(a.dev, a.csr)
    card.check_link()

    ok = True
    for name, slot in CASES:
        words = program(slot)
        want = model(words)
        bad = 0
        for _ in range(a.runs):
            card.wr("ee_reset", 1)
            card.wr("ee_pc_reset", 0)
            card.load(words)
            card.wr("ee_reset", 0)
            time.sleep(0.02)
            got = [card.gpr(i) for i in range(32)]
            card.wr("ee_reset", 1)
            if got != want:
                bad += 1
                if bad == 1:
                    print(f"  {name}: MISMATCH  LO={got[3]:#x} HI={got[4]:#x}"
                          f"   model LO={want[3]:#x} HI={want[4]:#x}")
        ok &= bad == 0
        print(f"  {name}: {a.runs - bad} of {a.runs} agree with the model")

    # The model must agree the slot is annulled, or the test proves nothing:
    # a model that ran the slot would make a card that ran it look correct.
    ran = [n for n, s in CASES if model(program(s))[3] != 0]
    if ran:
        print(f"FAIL  the reference model executed the slot for: {', '.join(ran)}")
        return 1

    print()
    print("PASS  a not-taken branch-likely annuls its slot on the card" if ok
          else "FAIL  the slot is not being annulled on the card")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
