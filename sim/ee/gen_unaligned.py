#!/usr/bin/env python3
"""Emit a directed LWL/LWR/SWL/SWR/LDL/LDR/SDL/SDR program.

    sim/ee/gen_unaligned.py > unal.hex

A compiler emits these in pairs to move a word that is not aligned, so the
alignment of the address is the whole point: every one of the four (word) or
eight (doubleword) offsets selects a different number of bytes and a different
shift, and an implementation can be right at one offset and wrong at the rest.
A random generator picks addresses that are aligned nearly all the time, so
each offset is enumerated here instead.

"Left" and "right" swap meaning between endiannesses, which is the classic way
to get these subtly wrong, so both halves of each pair are tested at every
offset against a memory image with a distinct value in every byte.
"""

SCRATCH = 0x2000

def sp(rs, rt, rd, sa, fn): return (rs << 21) | (rt << 16) | (rd << 11) | (sa << 6) | fn
def lui(rt, imm):     return (15 << 26) | (rt << 16) | (imm & 0xFFFF)
def ori(rt, rs, imm): return (13 << 26) | (rs << 21) | (rt << 16) | (imm & 0xFFFF)
def addiu(rt, rs, i): return (9 << 26) | (rs << 21) | (rt << 16) | (i & 0xFFFF)
def dsll32(rd, rt, sa): return sp(0, rt, rd, sa, 60)
def or_(rd, rs, rt):  return sp(rs, rt, rd, 0, 37)
def mem(op, rt, rs, off): return (op << 26) | (rs << 21) | (rt << 16) | (off & 0xFFFF)

SD, LD, SW = 63, 55, 43
LWL, LWR, SWL, SWR = 34, 38, 42, 46
LDL, LDR, SDL, SDR = 26, 27, 44, 45


def main():
    o = [lui(20, SCRATCH >> 16), ori(20, 20, SCRATCH & 0xFFFF)]

    # A memory image with a distinct byte everywhere: r21 = 0x0706050403020100,
    # r22 = 0x0f0e0d0c0b0a0908, written at scratch+0 and +8.
    o += [lui(21, 0x0302), ori(21, 21, 0x0100), lui(2, 0x0706), ori(2, 2, 0x0504),
          dsll32(2, 2, 0), or_(21, 21, 2)]
    o += [lui(22, 0x0b0a), ori(22, 22, 0x0908), lui(2, 0x0f0e), ori(2, 2, 0x0d0c),
          dsll32(2, 2, 0), or_(22, 22, 2)]
    o += [mem(SD, 21, 20, 0), mem(SD, 22, 20, 8)]

    # r23 = a recognisable value for the merge base, distinct from the memory
    o += [lui(23, 0xAAAA), ori(23, 23, 0xAAAA), lui(2, 0xBBBB), ori(2, 2, 0xBBBB),
          dsll32(2, 2, 0), or_(23, 23, 2)]

    # ---- the load forms at every offset --------------------------------
    # Each starts from the same merge base so the result depends only on the
    # offset and the direction.
    r = 3
    for off in range(4):
        for op in (LWL, LWR):
            o += [or_(r, 23, 0), mem(op, r, 20, off)]
            r = 4 if r == 3 else 3          # alternate so both are observable
            o += [or_(9 if op == LWL else 10, r if r == 3 else 4, 0)]
    for off in range(8):
        for op in (LDL, LDR):
            o += [or_(5, 23, 0), mem(op, 5, 20, off), or_(11, 5, 0)]

    # ---- the store forms at every offset -------------------------------
    # Each writes into a fresh 16-byte window so the results do not overlap and
    # a wrong byte count shows up as a wrong neighbour rather than a lost write.
    win = 0x40
    for off in range(4):
        for op in (SWL, SWR):
            o += [mem(SD, 21, 20, win), mem(SD, 22, 20, win + 8)]
            o += [mem(op, 23, 20, win + off)]
            o += [mem(LD, 12, 20, win)]
            win += 16
    for off in range(8):
        for op in (SDL, SDR):
            o += [mem(SD, 21, 20, win), mem(SD, 22, 20, win + 8)]
            o += [mem(op, 23, 20, win + off)]
            o += [mem(LD, 13, 20, win)]
            win += 16

    for w in o:
        print("%08x" % (w & 0xFFFFFFFF))
    for _ in range(4096 - len(o)):
        print("00000000")
    return len(o)


if __name__ == "__main__":
    main()
