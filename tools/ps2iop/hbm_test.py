#!/usr/bin/env python3
"""Prove the C1100's HBM from the host: write words, read them back.

    tools/ps2iop/hbm_test.py [--csr bitstreams/c1100_hbm_test.csr.csv]

The probe moves one 256-bit beat at a time through CSRs, which is slow and is
meant to be -- this answers "is the memory there and correct", not "how fast is
it".  Bulk staging of a disc image goes over LitePCIe DMA later.

What it checks, in order, because each answer only means something if the one
before it held:

  1. `hbm_init_done` -- the IP's two APB controllers finished bringing the
     stacks up.  Nothing below is meaningful if this is 0.
  2. A beat at address 0 survives a round trip.
  3. Beats at the far end of the first stack (just under 4 GiB) and inside the
     second stack (above 4 GiB).  This is the check that matters most: the HBM
     IP defaults to 32-bit AXI addressing, which reaches one stack only, and a
     design that quietly wrapped would look perfect until a disc image grew
     past 4 GiB.  ip/hbm/gen_hbm.tcl sets 33 bits.
  4. Distinct addresses hold distinct data -- an aliasing check, because a
     wrapped or ignored high address bit shows up as two addresses sharing a
     value rather than as an error.
"""
import argparse, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import iop_post

BEAT   = 32                  # bytes in one 256-bit beat
GIB    = 1 << 30
STACK  = 4 * GIB             # one HBM stack


def write_beat(dev, addr, words):
    assert len(words) == 8 and addr % BEAT == 0
    dev.wr("probe_addr", addr)
    dev.wr("probe_ctrl", 0x4)             # clear the lane pointer
    for w in words:
        dev.wr("probe_wdata", w & 0xFFFFFFFF)
    dev.wr("probe_ctrl", 0x1)             # write
    return wait(dev)


def read_beat(dev, addr):
    assert addr % BEAT == 0
    dev.wr("probe_addr", addr)
    dev.wr("probe_ctrl", 0x2)             # read
    resp = wait(dev)
    out = []
    for lane in range(8):
        dev.wr("probe_rlane", lane)
        out.append(dev.rd("probe_rdata"))
    return out, resp


def wait(dev, tries=10000):
    for _ in range(tries):
        s = dev.rd("probe_stat")
        if (s >> 1) & 1:                      # done
            return (s >> 2) & 3               # AXI response
    raise SystemExit("HBM probe never reported done: the AXI clock or the IP is not running")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csr", default="bitstreams/c1100_hbm_test.csr.csv")
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()

    dev = iop_post.Dev(a.dev, a.csr)
    if "probe_stat" not in dev.regs:
        sys.exit("this bitstream has no HBM probe; build boards/c1100_hbm_test.py")

    init = dev.rd("hbm_init_done") & 1
    print(f"1. hbm_init_done = {init}  {'(both stacks up)' if init else '(NOT INITIALISED)'}")
    if not init:
        sys.exit("FAIL: the HBM IP never finished initialisation; nothing below would mean anything")

    rng = random.Random(a.seed)
    # Addresses chosen to exercise the thing that can silently be wrong: the
    # 33rd address bit. Two are in stack 0, two in stack 1.
    addrs = [
        0x0_0000_0000,
        0x0_8000_0000,              # 2 GiB, stack 0
        STACK - BEAT,               # last beat of stack 0
        STACK,                      # first beat of stack 1 -- needs bit 32
        STACK + 0x1_0000_0000,      # 5 GiB
        8 * GIB - BEAT,             # last beat of the device
    ]
    pattern = {addr: [rng.getrandbits(32) for _ in range(8)] for addr in addrs}

    print("2/3. write then read back, including both stacks:")
    bad = 0
    for addr in addrs:
        r = write_beat(dev, addr, pattern[addr])
        if r:
            print(f"   {addr:#013x}  WRITE resp={r}"); bad += 1
    for addr in addrs:
        got, r = read_beat(dev, addr)
        ok = (got == pattern[addr]) and r == 0
        stack = 0 if addr < STACK else 1
        print(f"   {addr:#013x} (stack {stack})  {'ok' if ok else 'MISMATCH'}"
              f"  resp={r}  first word {got[0]:#010x} expected {pattern[addr][0]:#010x}")
        if not ok:
            bad += 1

    print("4. aliasing: every address must hold its own value")
    vals = {}
    for addr in addrs:
        got, _ = read_beat(dev, addr)
        key = tuple(got)
        if key in vals:
            print(f"   {addr:#013x} reads the same as {vals[key]:#013x} -- an address bit is being dropped")
            bad += 1
        vals[key] = addr
    if not bad:
        print("   distinct, so no address bit is being lost")

    print("\nPASS" if not bad else f"\nFAIL: {bad} problem(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
