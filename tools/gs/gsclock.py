#!/usr/bin/env python3
"""Measure the clock the Graphics Synthesizer is actually running at.

    tools/gs/gsclock.py --csr build/c1100_gs/csr.csv [--seconds 4]

Everything else in this project asserts that the GS runs at 147.456 MHz: a
constraint file, an MMCM's parameters, and an arithmetic argument about why two
cascaded MMCMs land 0.90 ppm off. None of that is a measurement, and a PLL that
fails to lock does not announce itself -- it leaves the design on a clock that
never ticks, or one that ticks at the wrong rate, and every test still passes
because every test is a comparison against a model that has no clock at all.

So the card carries a free-running counter in the sys domain. Read it twice a
known wall-clock apart and the difference is the frequency. That is a direct
measurement of the thing being claimed.

Two caveats about what this can and cannot tell you.

**The host's clock is the reference, and it is the worse of the two.** An
ordinary system clock is good to perhaps a few parts per million over a few
seconds, so this can confirm 147.456 against 125 or 150 easily and cannot
confirm 0.90 ppm. The ppm figure rests on the MMCM arithmetic; what this
rules out is the interesting failures -- a wrong divider, a PLL that did not
lock, a fallback to the reference clock.

**A locked bit of 0 makes everything else meaningless**, so it is checked first
and reported loudly.

And before any of that, the link itself is checked. A C1100 whose bitstream was
just loaded over JTAG has a *dead* PCIe link until it is re-enumerated, and a
dead link does not return an error: every register reads 0xFFFFFFFF. That is
silent, it is documented in docs/c1100-pcie-transport.md as having cost a day
once, and it is exactly what this tool would otherwise turn into a confident
number -- the first run of this script read `locked` as 1, because bit 0 of
0xFFFFFFFF is 1. So `ctrl_scratch` is written and read back first: it is a
plain read/write register with no side effects, and a link that can carry a
value there and return it is a link.
"""
import argparse, fcntl, os, struct, sys, time

LITEPCIE_IOCTL_REG = (3 << 30) | (12 << 16) | (ord("S") << 8) | 0

NATIVE = 147.456e6             # what the two MMCMs produce -- exactly
CONSOLE = 147.456e6            # what a PlayStation 2 runs at


def regs_from_csv(path):
    regs = {}
    with open(path) as f:
        for line in f:
            p = line.strip().split(",")
            if p and p[0] == "csr_register":
                regs[p[1]] = (int(p[2], 0), int(p[3]))
    return regs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dev", default="/dev/litepcie0")
    ap.add_argument("--csr", required=True)
    ap.add_argument("--seconds", type=float, default=4.0,
                    help="how long to count for; longer is more accurate")
    args = ap.parse_args()

    regs = regs_from_csv(args.csr)
    fd = os.open(args.dev, os.O_RDWR)

    def rd(name):
        addr, _ = regs[name]
        return struct.unpack("IIB3x", fcntl.ioctl(
            fd, LITEPCIE_IOCTL_REG, struct.pack("IIB3x", addr, 0, 0)))[1]

    def wr(name, val):
        addr, _ = regs[name]
        fcntl.ioctl(fd, LITEPCIE_IOCTL_REG,
                    struct.pack("IIB3x", addr, val & 0xFFFFFFFF, 1))

    # Is anything there at all?  Two patterns, because a stuck-high bus passes
    # a test that only ever writes ones and a stuck-low one passes only zeros.
    for probe in (0xA5A5_5A5A, 0x0F0F_F0F0):
        wr("ctrl_scratch", probe)
        got = rd("ctrl_scratch")
        if got != probe:
            print(f"FAIL  the PCIe link is not answering: wrote 0x{probe:08x}, "
                  f"read 0x{got:08x}")
            if got == 0xFFFFFFFF:
                print("      all ones is the signature of a card that was "
                      "JTAG-programmed and not re-enumerated.")
                print("      run: sudo tools/pcie-bringup.sh c1100_gs")
            return 1
    wr("ctrl_scratch", 0x12345678)          # LiteX's reset value, put back

    locked = rd("gs_clk_locked") & 1
    print(f"PS2 clock tree locked: {locked}")
    if not locked:
        print("FAIL  the MMCMs did not lock.")
        print("      The link is alive and this bit is readable, which is the")
        print("      whole point of keeping sys off the clock being measured:")
        print("      the answer is 'the PS2 clock tree does not lock', not a")
        print("      driver that hangs with nothing to say.")
        return 1

    # Bracket each read with the clock so the timing error is bounded by one
    # ioctl rather than by whatever the interpreter did in between.
    t0a = time.perf_counter(); c0 = rd("gs_clk_ticks"); t0b = time.perf_counter()
    time.sleep(args.seconds)
    t1a = time.perf_counter(); c1 = rd("gs_clk_ticks"); t1b = time.perf_counter()

    ticks = (c1 - c0) & 0xFFFFFFFF
    dt    = ((t1a + t1b) - (t0a + t0b)) / 2
    # The counter is 32 bits and wraps every 29 seconds at this rate; a gap
    # longer than that would alias to a plausible-looking wrong answer, which is
    # exactly the kind of wrong this tool exists to catch rather than produce.
    if dt > 25.0:
        print(f"FAIL  {dt:.1f} s is long enough for the counter to wrap")
        return 1
    f = ticks / dt
    err = (f - CONSOLE) / CONSOLE * 1e6

    # The counter is in cd_gs and crossed into sys as gray code, so what is
    # being measured is the GS clock, not the clock this CSR bank runs on.
    print(f"counted {ticks} GS-domain ticks in {dt:.4f} s")
    print(f"measured {f/1e6:.4f} MHz")
    print(f"  synthesised target {NATIVE/1e6:.6f} MHz")
    print(f"  a PlayStation 2's  {CONSOLE/1e6:.6f} MHz")
    print(f"  difference {err:+.0f} ppm "
          f"(the host's own clock is worth a few ppm at best, so this "
          f"confirms the divider, not the parts per million)")

    # 0.5 % is far tighter than any wrong divider and far looser than the host
    # clock's own error.  125 MHz would read -15 %, 150 MHz +1.7 %.
    ok = abs(f - CONSOLE) / CONSOLE < 0.005
    print("PASS  the card is running at the console's clock" if ok else
          "FAIL  that is not 147.456 MHz")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
