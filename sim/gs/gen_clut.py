#!/usr/bin/env python3
"""Cases and expected palettes for gs_clut, from the reference model.

    sim/gs/gen_clut.py --seed 1 --out DIR

Writes three files:

    mem.hex     local memory, one 256-bit word per line, what the CLUT reads
    cases.txt   one TEX0/TEXCLUT write per line, in order
    ref.txt     after each write: the load counter, the unsupported flag, and
                all 256 entries of the buffer

`tb_clut.sv` applies the writes in the same order and prints the same three
things, and `run_clut_diff.sh` diffs the two.

## Why the cases are a sequence and not a set

The CLUT is a cache with explicit invalidation, and half of CLD's job is
deciding *not* to reload. `CLD_IF_CBP0` compares the incoming CBP against a
pointer remembered from some earlier write, so what a given write does depends
on every write before it. A test that shuffled these cases would still pass
while testing something else.

So the sequence is deliberate, and it includes the cases that only a sequence
can express:

  * a comparison form before any pointer has ever been remembered -- which must
    reload, because "not yet set" is a real state and not a match against zero;
  * a comparison form that matches, which must **not** reload -- checked by the
    load counter, because the buffer would look the same either way if the
    palette in memory has not changed;
  * a comparison form that matches while the memory underneath has changed,
    where not reloading is the *correct* answer and the buffer must keep the
    stale palette. This is the case that a colour comparison alone would call a
    bug, and it is the behaviour a real game depends on.

## Bounds on the random cases

CSM2 addresses an ordinary PSMCT32 buffer, so a large COV or CBW walks a long
way into memory and the test image would have to be megabytes. The parameters
are kept small enough that everything lands inside a 256 KB image, which is a
limit on the test and not on the block: the addressing it uses is
`pix_addr_page`, already exercised across the whole 4 MB by the frame buffer's
own tests.

SPDX-License-Identifier: BSD-2-Clause
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gs_ref                                                    # noqa: E402

MEM_BYTES = 256 * 1024
LINE = 32                                    # bytes in a 256-bit word


def tex0(psm, cbp, cpsm=0, csm=0, csa=0, cld=0):
    return ((psm & 0x3F) << 20 | (cbp & 0x3FFF) << 37 | (cpsm & 0xF) << 51
            | (csm & 1) << 55 | (csa & 0x1F) << 56 | (cld & 7) << 61)


def texclut(cbw=1, cou=0, cov=0):
    return (cbw & 0x3F) | (cou & 0x3F) << 6 | (cov & 0x3FF) << 12


def cases(rng):
    out = []
    P8, P4 = gs_ref.PSMT8, gs_ref.PSMT4
    P4HL, P8H = gs_ref.PSMT4HL, gs_ref.PSMT8H

    # A 256-entry CSM1 palette, the ordinary case, at a few bases.
    for cbp in (0, 1, 32, 77):
        out.append((tex0(P8, cbp, cld=1), texclut()))

    # 16-entry CSM1, and CSA choosing which sixteenth of the buffer it lands in.
    # Eight palettes sharing one CLUT is what CSA is for, so each of them is
    # written in turn and the buffer must end up holding all eight.
    for csa in range(8):
        out.append((tex0(P4, 40 + csa, cld=1, csa=csa), texclut()))

    # The other two 4-bit formats take a 16-entry palette as well, which is a
    # property of the *index width* and not of where the index is stored.
    out.append((tex0(P4HL, 12, cld=1, csa=3), texclut()))
    # ...and an H format with an 8-bit index still takes 256.
    out.append((tex0(P8H, 13, cld=1), texclut()))

    # CSM2: linear, out of an ordinary buffer, with TEXCLUT giving width and
    # origin. Kept small for the reason in the module docstring.
    # CBW of 0 is included deliberately: the model takes max(1, CBW), so zero
    # and one must address identically. Every other case here uses a non-zero
    # width, and a mutation that dropped the clamp survived the whole suite
    # until this line existed -- an untested special case is not a special case,
    # it is a guess.
    #
    # **And COV has to reach 32 for the clamp to be observable at all.** The
    # width multiplies (COV >> 5), so with a strip on the first page row the
    # term is zero whatever CBW is, and 0 and 1 address identically for the
    # wrong reason. The first attempt at these cases used COV of 0 and 9 and
    # still missed the mutation. A case that exercises a parameter is not the
    # same as a case where the parameter can change the answer.
    for cbw, cou, cov in ((1, 0, 0), (2, 1, 3), (4, 3, 17), (1, 8, 63),
                          (0, 0, 0), (0, 2, 9), (0, 0, 63), (0, 1, 40),
                          (1, 0, 63), (1, 1, 40)):
        out.append((tex0(P8, 20, csm=1, cld=1), texclut(cbw, cou, cov)))

    # ---- CLD, in an order that makes each answer mean something ------------
    # **A comparison against CBP 0, before any pointer has been remembered.**
    # This has to come first, and it has to use zero. "Never set" and
    # "remembered, and it was zero" are different states that must both reload,
    # and they are only distinguishable when the incoming pointer is itself
    # zero -- with any other CBP an implementation that initialises its stored
    # pointer to zero still reloads, for the wrong reason, and looks correct.
    # A mutation that dropped the never-set flag survived the whole suite until
    # these two cases existed.
    out.append((tex0(P8, 0, cld=4), texclut()))
    out.append((tex0(P8, 0, cld=5), texclut()))
    # A comparison form before anything has been remembered: must reload.
    out.append((tex0(P8, 90, cld=4), texclut()))
    # Remember 90 in CBP0, then compare against it: the second must NOT reload.
    out.append((tex0(P8, 90, cld=2), texclut()))
    out.append((tex0(P8, 90, cld=4), texclut()))
    # A different pointer against the same remembered one: must reload.
    out.append((tex0(P8, 91, cld=4), texclut()))
    # CBP1 is a separate register; setting CBP0 must not satisfy a CBP1 compare.
    out.append((tex0(P8, 92, cld=2), texclut()))
    out.append((tex0(P8, 92, cld=5), texclut()))
    out.append((tex0(P8, 92, cld=3), texclut()))
    out.append((tex0(P8, 92, cld=5), texclut()))
    # CLD 0 never loads, whatever the pointer.
    out.append((tex0(P8, 99, cld=0), texclut()))
    # The reserved encodings do nothing rather than something plausible.
    out.append((tex0(P8, 99, cld=6), texclut()))
    out.append((tex0(P8, 99, cld=7), texclut()))

    # A 16-bit CLUT, which is not derived and must be refused rather than
    # guessed at. The buffer has to still hold the previous palette afterwards.
    out.append((tex0(P8, 100, cpsm=2, cld=1), texclut()))

    # Random, within the bounds the docstring gives.
    for _ in range(40):
        psm = rng.choice([P8, P4, P4HL, P8H, gs_ref.PSMT4HH])
        csm = rng.randint(0, 1)
        out.append((tex0(psm, rng.randrange(0, 200), csm=csm,
                         csa=rng.randint(0, 15), cld=rng.randint(0, 7)),
                    texclut(rng.randint(1, 4), rng.randint(0, 8),
                            rng.randint(0, 63))))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    os.makedirs(a.out, exist_ok=True)

    vm = bytearray(rng.getrandbits(8) for _ in range(MEM_BYTES))
    with open(os.path.join(a.out, "mem.hex"), "w") as f:
        for i in range(0, MEM_BYTES, LINE):
            # One 256-bit word per line, most significant byte first, which is
            # what $readmemh expects of a [255:0] element.
            f.write(vm[i:i + LINE][::-1].hex() + "\n")

    clut = gs_ref.Clut()
    cs = cases(rng)
    with open(os.path.join(a.out, "cases.txt"), "w") as fc, \
         open(os.path.join(a.out, "ref.txt"), "w") as fr:
        for n, (t0, tc) in enumerate(cs):
            fc.write("%016x %016x\n" % (t0, tc))
            unsup = 0
            try:
                clut.load(vm, t0, tc)
            except NotImplementedError:
                # gs_ref raises where the layout is not derived; the RTL reports
                # it on a pin. Both mean "nothing was loaded", and the buffer
                # must be unchanged either way.
                unsup = 1
            fr.write("%d %d %d %s\n" % (n, clut.loads, unsup,
                                        " ".join("%08x" % e for e in clut.entries)))

    print("%d cases, %d KB of memory" % (len(cs), MEM_BYTES // 1024),
          file=sys.stderr)


if __name__ == "__main__":
    main()
