#!/usr/bin/env python3
"""Push a SIF1 packet at the IOP, the way the Emotion Engine would.

    tools/ps2iop/sif1.py loopback [--addr 0x60000] [--words 16]
    tools/ps2iop/sif1.py send --addr 0x19600 --file packet.bin [--no-kick]
    tools/ps2iop/sif1.py status

SIF1 carries EE -> IOP data, and unlike every other IOP DMA channel the
destination is not in MADR: a four-word tag at the head of the stream names it
(docs/sif.md).  The tag is

    word 0   IOP destination address, low 24 bits
    word 1   word count; the low two bits are dropped by the hardware
    word 2   the EE's own DMA tag, low half
    word 3   the EE's own DMA tag, high half

Words 2 and 3 are the EE's business.  The IOP's channel reads them and does
nothing with them, so `loopback` sends zeros there.

`loopback` is the bring-up test and involves no BIOS: it names a scratch address
in IOP RAM, sends a pattern, starts the channel with the host kick, and reads
the RAM back.  That separates "the data path works" from "the BIOS never arms
the channel", which are the two ways this can be silent.
"""
import argparse, fcntl, os, struct, sys

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0


class Card:
    def __init__(self, csr, dev="/dev/litepcie0"):
        self.regs = {}
        for line in open(csr):
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                self.regs[p[1]] = (int(p[2], 0), int(p[3]))
        self.fd = os.open(dev, os.O_RDWR)

    def rd(self, name):
        a, n = self.regs[name]
        v = 0
        for i in range(n):
            v = (v << 32) | struct.unpack("IIB3x", fcntl.ioctl(
                self.fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", a + 4 * i, 0, 0)))[1]
        return v

    def wr(self, name, val):
        a, n = self.regs[name]
        for i in range(n):
            fcntl.ioctl(self.fd, LITEPCIE_IOCTL_REG, struct.pack(
                "IIB3x", a + 4 * i, (val >> (32 * (n - 1 - i))) & 0xFFFFFFFF, 1))

    def push(self, words):
        for w in words:
            if not (self.rd("iop_sif1_stat") & 1):
                sys.exit("SIF1 stream is full: the IOP is not draining it")
            self.wr("iop_sif1_push", w & 0xFFFFFFFF)

    def status(self):
        st = self.rd("iop_sif1_stat")
        return dict(writable=st & 1, readable=(st >> 1) & 1,
                    taken=self.rd("iop_sif1_taken"), tags=self.rd("iop_sif1_tags"),
                    addr=self.rd("iop_sif1_addr"), length=self.rd("iop_sif1_len"))


def tag(addr, words):
    return [addr & 0xFFFFFF, words & 0xFFFFC, 0, 0]


def show(c, label):
    s = c.status()
    print(f"  {label:22s} writable={s['writable']} readable={s['readable']} "
          f"taken={s['taken']} tags={s['tags']} addr=0x{s['addr']:06x} len={s['length']}")
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csr", default="bitstreams/c1100_ps2_iop.csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("loopback")
    p.add_argument("--addr", type=lambda x: int(x, 0), default=0x60000)
    p.add_argument("--words", type=int, default=16)
    p = sub.add_parser("send")
    p.add_argument("--addr", type=lambda x: int(x, 0), required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--no-kick", action="store_true")
    sub.add_parser("status")
    a = ap.parse_args()
    c = Card(a.csr, a.dev)

    if a.cmd == "status":
        show(c, "SIF1")
        return

    if a.cmd == "loopback":
        n = a.words & ~3                      # the hardware drops the low two bits
        if n != a.words:
            print(f"note: {a.words} words rounded down to {n}")
        data = [0xA5A50000 | i for i in range(n)]
        print(f"loopback: {n} words to IOP 0x{a.addr:06x}")
        show(c, "before")
        c.push(tag(a.addr, n))
        c.push(data)
        show(c, "after the push")
        c.wr("iop_sif1_kick", 1)
        s = show(c, "after the kick")
        if s["taken"] < n + 4:
            print(f"\nFAIL: the channel consumed {s['taken']} words of {n + 4}")
            print("      tag+data are in the stream and the channel did not drain them")
            return 1
        if s["addr"] != a.addr or s["length"] != n:
            print(f"\nFAIL: the tag was read as addr=0x{s['addr']:06x} len={s['length']}")
            return 1
        print(f"\nthe channel consumed the tag and {n} words; "
              f"check IOP RAM with:\n"
              f"  tools/ps2iop/iop_post.py --csr {a.csr} reset hold\n"
              f"  tools/ps2iop/iop_post.py --csr {a.csr} peek 0x{a.addr:x} --words 8")
        return 0

    data = open(a.file, "rb").read()
    if len(data) % 4:
        data += b"\0" * (4 - len(data) % 4)
    words = list(struct.unpack("<%dI" % (len(data) // 4), data))
    n = len(words) & ~3
    print(f"send: {n} words to IOP 0x{a.addr:06x}")
    c.push(tag(a.addr, n))
    c.push(words[:n])
    if not a.no_kick:
        c.wr("iop_sif1_kick", 1)
    show(c, "after")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
