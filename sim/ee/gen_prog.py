#!/usr/bin/env python3
"""Emit a random R5900 integer program, for differential testing.

    sim/ee/gen_prog.py --seed 1 --count 200 > prog.hex

Hand-written tests probe what the author already thought of.  These probe the
encoding space instead, and the reference makes them self-checking.

Two constraints keep a random program meaningful rather than merely legal:
loads and stores are aimed at a scratch area well clear of the code, so a
program cannot rewrite itself and make the two models diverge for reasons that
have nothing to do with the instruction under test; and r0 is never used as a
destination where that would make the instruction a no-op worth nothing.

**The mix is a table, not a chain of thresholds.**  It used to be a chain of
`elif pick < k` arms with the constants written by hand, and two of them were
unreachable: the COP0 arm was added below a `pick < 0.92` arm with a threshold
of 0.90, and the MMI SIMD arm was later added at 0.92 under the same one.  Both
were dead from the moment they were written, so **no random program ever
contained a COP0 move or an MMI SIMD instruction** -- and nothing said so,
because a generator that omits a class of instruction produces a program that
runs perfectly and proves less than it claims.  A weight table cannot shadow an
arm, and `--census` prints what was actually emitted so the claim can be
checked rather than assumed.
"""
import argparse, random

SCRATCH = 0x2000          # well past any generated program

# The defined sub-opcodes of MMI0 and MMI1, which live in the sa field.  These
# mirror sim/ee/r5900_ref.py's tables; the encodings are cross-checked against
# PCSX2's tbl_MMI0 and tbl_MMI1.
MMI0_SA = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
           0x10, 0x11, 0x14, 0x15, 0x18, 0x19]
MMI1_SA = [0x01, 0x02, 0x03, 0x05, 0x06, 0x07, 0x0A,
           0x10, 0x11, 0x14, 0x15, 0x18, 0x19]

# kind -> relative weight.  Weights, not cumulative thresholds: adding a kind
# cannot silently starve the ones after it.
MIX = {
    "special":  34,
    "imm":      24,
    "store":    12,
    "load":     10,
    "cop0":      3,
    "mmi_simd":  4,
    "mmi_par":   6,
    "mmi_p1":    3,
    "unaligned": 4,
    "quad":      4,
    "tail":      2,       # a branch if --branches, otherwise an ADD
}


def emit(rng, kind, branches):
    """One instruction of the named kind."""
    rs, rt, rd = rng.randrange(32), rng.randrange(32), rng.randrange(1, 32)
    sa = rng.randrange(32)

    if kind == "special":
        fn = rng.choice([0, 2, 3, 4, 6, 7, 16, 18, 24, 25, 26, 27,
                         32, 33, 34, 35, 36, 37, 38, 39, 42, 43,
                         45, 47, 56, 58, 59, 60, 62, 63])
        return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn

    if kind == "imm":
        op = rng.choice([8, 9, 10, 11, 12, 13, 14, 15, 25])
        return (op << 26) | (rs << 21) | (rd << 16) | rng.randrange(0x10000)

    if kind == "store":
        op = rng.choice([40, 41, 43, 63])
        off = SCRATCH + rng.randrange(0, 0x400, 8)
        return (op << 26) | (0 << 21) | (rt << 16) | (off & 0xFFFF)

    if kind == "load":
        op = rng.choice([32, 33, 35, 36, 37, 39, 55])
        off = SCRATCH + rng.randrange(0, 0x400, 8)
        return (op << 26) | (0 << 21) | (rd << 16) | (off & 0xFFFF)

    if kind == "cop0":
        # MTC0 then MFC0 on the same register are what make COP0 state
        # observable at all, so both are generated and the distance between
        # them is left to chance -- which is the point, since the forwarding
        # distance is what a COP0 file without forwarding gets wrong.
        cr = rng.randrange(32)
        if rng.randrange(2):
            return (16 << 26) | (4 << 21) | (rt << 16) | (cr << 11)
        return (16 << 26) | (0 << 21) | (rd << 16) | (cr << 11)

    if kind == "mmi_simd":
        # PAND, PXOR, PCPYLD (MMI2) and POR, PNOR, PCPYUD (MMI3).  The copies
        # matter most -- they are what moves data into the upper half in the
        # first place, so without them every other MMI operation would only
        # ever see zeroes up there.
        fn = 0x09 if rng.randrange(2) else 0x29
        return ((28 << 26) | (rs << 21) | (rt << 16) | (rd << 11)
                | (rng.choice([0x12, 0x13, 0x0E]) << 6) | fn)

    if kind == "mmi_par":
        # MMI0 and MMI1: the parallel ALU, over 4 x 32, 8 x 16 or 16 x 8 lanes.
        # Every defined sub-opcode is emitted with equal weight, because the
        # interesting differences between them are the saturation bounds, and a
        # bound that is wrong only for bytes is worth as much generator time as
        # one that is wrong everywhere.
        if rng.randrange(2):
            return ((28 << 26) | (rs << 21) | (rt << 16) | (rd << 11)
                    | (rng.choice(MMI0_SA) << 6) | 0x08)
        return ((28 << 26) | (rs << 21) | (rt << 16) | (rd << 11)
                | (rng.choice(MMI1_SA) << 6) | 0x28)

    if kind == "mmi_p1":
        # MULT1, MULTU1, DIV1, DIVU1, MFHI1, MFLO1, MTHI1, MTLO1: the same
        # operations as their SPECIAL counterparts, on the second HI/LO pair.
        # Emitting them interleaved with the ordinary forms is the point -- the
        # two pairs have to stay independent, and a program that used only one
        # of them would never show it if they did not.
        fn = rng.choice([16, 17, 18, 19, 24, 25, 26, 27])
        return (28 << 26) | (rs << 21) | (rt << 16) | (rd << 11) | fn

    if kind == "unaligned":
        # These are the only instructions here whose behaviour depends on the
        # low bits of the address, so the offset is deliberately not aligned --
        # every other memory operation above is on an eight-byte boundary, and
        # an unaligned form at an aligned address exercises exactly one of its
        # four or eight cases.
        op = rng.choice([34, 38, 42, 46, 26, 27, 44, 45])
        off = SCRATCH + rng.randrange(0, 0x400)
        return (op << 26) | (0 << 21) | (rd << 16) | (off & 0xFFFF)

    if kind == "quad":
        # LQ and SQ, the only instructions that move a whole 128-bit register.
        # The offset is deliberately *not* quadword-aligned: the manual says
        # the low four bits of the address are ignored rather than faulted, and
        # an always-aligned offset would never test that they are.
        op = 30 if rng.randrange(2) else 31
        off = SCRATCH + rng.randrange(0, 0x400)
        return (op << 26) | (0 << 21) | ((rd if op == 30 else rt) << 16) | (off & 0xFFFF)

    if kind == "tail":
        if branches:
            # only ever forward, only ever a couple of instructions, so the
            # program cannot leave itself
            op = rng.choice([4, 5, 6, 7])
            return (op << 26) | (rs << 21) | (rt << 16) | rng.choice([1, 2])
        return 0x00000020 | (rs << 21) | (rt << 16) | (rd << 11)     # ADD

    raise AssertionError("no such kind: %s" % kind)


def gen(rng, n, branches, census=None):
    out = []
    # seed some registers so the first instructions are not all zero-in
    for r in range(1, 8):
        out.append(0x24000000 | (r << 16) | (rng.randrange(0x10000)))       # addiu r,r0,imm
    for r in range(8, 12):
        out.append(0x3C000000 | (r << 16) | rng.randrange(0x10000))         # lui
    kinds, weights = list(MIX), list(MIX.values())
    while len(out) < n:
        kind = rng.choices(kinds, weights)[0]
        if census is not None:
            census[kind] = census.get(kind, 0) + 1
        out.append(emit(rng, kind, branches))
    return out[:n]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--branches", action="store_true")
    ap.add_argument("--pad", type=int, default=4096)
    ap.add_argument("--census", action="store_true",
                    help="report the mix actually emitted, on stderr")
    a = ap.parse_args()
    census = {} if a.census else None
    prog = gen(random.Random(a.seed), a.count, a.branches, census)
    for w in prog:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(a.pad - len(prog)):
        print("00000000")
    if census is not None:
        import sys
        missing = [k for k in MIX if not census.get(k)]
        for k in MIX:
            print("%-10s %d" % (k, census.get(k, 0)), file=sys.stderr)
        if missing:
            print("NOT EMITTED: %s" % ", ".join(missing), file=sys.stderr)


if __name__ == "__main__":
    main()
