#!/usr/bin/env python3
"""Emit a random GIF packet stream, for differential testing.

    sim/gs/gen_gif.py --seed 1 --tags 40 > packets.hex

Two constraints keep a random stream meaningful rather than merely legal.
Transfers are aimed at a small rectangle inside the first few pages, so a
generator cannot scatter single pixels across four megabytes and make the
memory comparison mostly empty; and NLOOP stays small, because the interesting
behaviour is at the seams -- the end of a descriptor list, the end of a loop,
the boundary between a tag and its data -- not in the middle of a long run.
"""
import argparse, random

# descriptors worth generating: A+D dominates because it is how a real packet
# writes most registers, and it is the only one carrying its own address
DESCS = [0x0, 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8, 0x9, 0xA,
         0xC, 0xD, 0xE, 0xE, 0xE, 0xE, 0xF]

# addresses A+D may name.  0x53 and 0x54 are excluded here and driven only by
# the deliberate transfer sequences below, because a random TRXDIR in the middle
# of a stream would start a transfer whose set-up registers are random too.
AD_ADDRS = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
            0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x22,
            0x34, 0x35, 0x36, 0x37, 0x3B, 0x3D, 0x3F,
            0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52,
            0x60, 0x61, 0x62,
            # a few the manual does not define: writing one must leave every
            # register alone, and only a generator that tries it would show that
            0x0B, 0x20, 0x55, 0x70]


def tag(nloop, eop, regs, nreg, flg=0, pre=0, prim=0):
    return (nloop | (eop << 15) | (pre << 46) | (prim << 47) |
            (flg << 58) | ((nreg & 15) << 60) | (regs << 64))


def gen(rng, ntags):
    out = []
    for _ in range(ntags):
        pick = rng.random()
        if pick < 0.18:
            # a host-to-local transfer of a small rectangle
            w = rng.randrange(1, 9)
            h = rng.randrange(1, 5)
            dx = rng.randrange(0, 32)
            dy = rng.randrange(0, 16)
            bp = rng.choice([0, 32, 64])          # 256-byte blocks
            out.append(tag(1, 0, 0xEEEE, 4))
            # DBP is at bits 45:32 and DBW at 53:48 -- the low bits are the
            # *source* pointer, so putting the base there left every transfer
            # writing to page zero and the base-pointer arithmetic untested.
            out.append((bp << 32) | (1 << 48) | (0x50 << 64))    # BITBLTBUF
            out.append((dx << 32) | (dy << 48) | (0x51 << 64))   # TRXPOS
            out.append((w | (h << 32)) | (0x52 << 64))           # TRXREG
            out.append(0 | (0x53 << 64))                         # TRXDIR
            npix = w * h
            nqw = (npix + 3) // 4
            out.append(tag(nqw, 1, 0, 1, flg=2))
            for i in range(nqw):
                qw = 0
                for j in range(4):
                    qw |= (rng.randrange(1 << 32)) << (32 * j)
                out.append(qw)
        elif pick < 0.30:
            # REGLIST: two registers per quadword
            nreg = rng.randrange(1, 5)
            nloop = rng.randrange(1, 4)
            regs = 0
            for i in range(nreg):
                regs |= rng.choice([0x0, 0x1, 0x2, 0x6, 0xA, 0xF]) << (4 * i)
            out.append(tag(nloop, 1, regs, nreg, flg=1))
            total = nloop * nreg
            for _ in range((total + 1) // 2):
                out.append(rng.getrandbits(128))
        else:
            # PACKED
            nreg = rng.randrange(1, 5)
            nloop = rng.randrange(1, 4)
            regs = 0
            descs = [rng.choice(DESCS) for _ in range(nreg)]
            for i, d in enumerate(descs):
                regs |= d << (4 * i)
            pre = rng.randrange(2)
            out.append(tag(nloop, 1, regs, nreg, pre=pre,
                           prim=rng.randrange(1 << 11)))
            for _ in range(nloop):
                for d in descs:
                    qw = rng.getrandbits(128)
                    if d == 0xE:
                        addr = rng.choice(AD_ADDRS)
                        qw = (qw & ((1 << 64) - 1)) | (addr << 64)
                    out.append(qw)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--tags", type=int, default=40)
    a = ap.parse_args()
    out = gen(random.Random(a.seed), a.tags)
    out = out[:4000]
    for w in out:
        print("%032x" % (w & ((1 << 128) - 1)))
    for _ in range(4096 - len(out)):
        print("%032x" % 0)


if __name__ == "__main__":
    main()
