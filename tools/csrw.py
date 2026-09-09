#!/usr/bin/env python3
"""Read or write a LiteX CSR on the card by name, through the litepcie driver.

    csrw.py --csr <bitstream>.csr.csv read  <name>
    csrw.py --csr <bitstream>.csr.csv write <name> <value>
    csrw.py --csr <bitstream>.csr.csv dump               # every csr_register
Names are the csr_register rows of the csr.csv generated with the loaded
bitstream (e.g. video_enable, hps_control, iop_reset). Same ioctl path as
tools/ps2iop/iop_post.py and host/main_mistex_pcie.
"""
import argparse, fcntl, os, struct, sys

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0

def regs_from_csv(path):
    regs = {}
    with open(path) as f:
        for line in f:
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                regs[p[1]] = (int(p[2], 0), int(p[3]))
    return regs

def readl(fd, addr):
    return struct.unpack("IIB3x", fcntl.ioctl(fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, 0, 0)))[1]

def writel(fd, addr, val):
    fcntl.ioctl(fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, val & 0xFFFFFFFF, 1))

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("read");  p.add_argument("name")
    p = sub.add_parser("write"); p.add_argument("name"); p.add_argument("value", type=lambda x: int(x, 0))
    sub.add_parser("dump")
    a = ap.parse_args()
    regs = regs_from_csv(a.csr)
    fd = os.open(a.dev, os.O_RDWR)
    if a.cmd == "dump":
        for name, (addr, n) in regs.items():
            print(f"{name:32s} 0x{addr:08x} = " + " ".join(f"{readl(fd, addr + 4*i):08x}" for i in range(n)))
        return
    if a.name not in regs:
        sys.exit(f"no register {a.name} in {a.csr}")
    addr, n = regs[a.name]
    if a.cmd == "read":
        print(" ".join(f"{readl(fd, addr + 4*i):08x}" for i in range(n)))
    else:
        # Write every subregister, most significant first, which is the order
        # LiteX assigns them.  Writing only the first word silently sets the
        # high bits of a wide register and leaves the low ones alone -- so
        # `write iop_hbm_disc_base 0x100000` on a 33-bit register put 0 in the
        # one bit that exists above 32 and never touched the address at all.
        # A control that quietly does nothing is worse than no control.
        for i in range(n):
            writel(fd, addr + 4*i, (a.value >> (32 * (n - 1 - i))) & 0xFFFFFFFF)
        print(f"{a.name} <= 0x{a.value:x}" + (f" ({n} words)" if n > 1 else ""))

if __name__ == "__main__":
    main()
