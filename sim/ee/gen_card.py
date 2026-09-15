#!/usr/bin/env python3
"""A random program that stops on its own, for comparing card against model.

    sim/ee/gen_card.py --seed 1 --count 200 > prog.hex

The card cannot be stopped at a chosen instruction. At 294.912 MHz the core
retires thousands of instructions between two CSR reads, so a harness that polls
a retire counter and then asserts reset has no idea where it stopped -- three
identical runs on a *working* core would still land on three different states.

So the program halts itself. It ends in a branch to its own address with a NOP
in the delay slot, which is the PlayStation 2's idiom for "this is the end" and
costs two instructions. After that the register file is stable and can be read
at leisure, and the reference model can be run until its PC stops advancing.
The two then describe the same moment.

Everything before the park is `gen_prog.py`, unchanged -- the same generator the
whole differential suite uses, so a disagreement on the card is a disagreement
about the same instruction mix the simulation tests already cover.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--branches", action="store_true")
    a = ap.parse_args()

    cmd = [sys.executable, os.path.join(HERE, "gen_prog.py"),
           "--seed", str(a.seed), "--count", str(a.count)]
    if a.branches:
        cmd.append("--branches")
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    words = [int(l.split("//")[0].strip(), 16) for l in out.splitlines()
             if l.split("//")[0].strip()]

    # gen_prog pads to 4096 words with zeros, which are NOPs; the program proper
    # is the first `count` of them. Park immediately after it.
    body = words[:a.count]
    park = (4 << 26) | (0xFFFF)          # BEQ r0, r0, -1
    body += [park, 0]

    for w in body:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(body)):
        print("00000000")
    return 0


if __name__ == "__main__":
    sys.exit(main())
