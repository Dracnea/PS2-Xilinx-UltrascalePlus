#!/usr/bin/env python3
#
# The PlayStation 2's clock tree, from a 100 MHz board reference.
#
# Every clock in a PS2 is an integer multiple of 18.432 MHz: the IOP is 2x, the
# GS 8x, the EE 16x.  This is a rebuild of the machine rather than an emulator,
# so those are a specification -- a block running at the wrong rate is wrong,
# not slow, and the *ratios* between them are what the software depends on.
#
# 18.432 MHz is not reachable exactly from 100 MHz.  The ratio is
#
#     18.432 / 100 = 576 / 3125 = (2^6 * 3^2) / 5^5
#
# and no MMCM can put 5^5 in its divider: a single MMCM would need DIVCLK x
# CLKOUT = 3125 (say 25 x 125, both in range) and then CLKFBOUT_MULT = 576,
# against a hard limit of 64.  A search of the whole legal parameter space finds
# no exact solution for 18.432, 36.864, 147.456 or 294.912.
#
# The best a *single* MMCM can do while keeping the ratios exact is 295.000 /
# 147.500 / 36.875 -- 298 ppm fast, which is what boards/c1100_ps2_iop.py's
# _IOPClocks settled for.
#
# Two do far better, and this is the whole idea here:
#
#   * one MMCM makes the 18.432 MHz base, using the *fractional* output divider
#     that only CLKOUT0 has: DIVCLK 3, MULT 44.375, CLKOUT0 80.25, from a VCO of
#     1479.1667 MHz.  That lands on 18.431983 MHz -- **0.90 ppm** fast;
#   * a second multiplies that base by 64 to a VCO of 1179.647 MHz and divides
#     by 4, 8 and 32.  Those are integers, so the EE : GS : IOP ratios are
#     16 : 8 : 2 *exactly*, by construction, not approximately.
#
# The result is every PS2 clock 0.90 ppm fast with mathematically exact ratios.
# A real console's crystal is typically 30 to 100 ppm, so this is a more
# accurate clock than the hardware being copied -- and it needs no oscillator
# added to the card.
#
# The error being *shared* is the part that matters.  A uniform 0.9 ppm is a
# console running 0.9 ppm fast, which nothing can observe.  Two blocks with
# different offsets would break the integer relationships, and that would be
# observable immediately.
#
# SPDX-License-Identifier: BSD-2-Clause

from migen import *
from migen.genlib.resetsync import AsyncResetSynchronizer
from litex.gen.fhdl.module import LiteXModule

# The measured constants, kept here so they are checkable rather than folded
# into the instance below.
STAGE1 = dict(divclk=3, mult=44.375, clkout0=80.25)   # 100 MHz -> 18.431983
STAGE2 = dict(divclk=1, mult=64.0,                     # 18.431983 -> VCO 1179.647
              ee=4, gs=8, iop=32)                      # integer, so ratios are exact


class PS2Clocks(LiteXModule):
    """cd_ee (294.912), cd_gs (147.456) and cd_iop (36.864), all 0.9 ppm fast.

    `ref` is the buffered 100 MHz board reference; `rst` holds both MMCMs.
    `locked` is high when *both* have locked, because a design that starts on
    one of two clocks is worse than one that does not start at all.

    `domains` maps "ee", "gs" and "iop" to the ClockDomain each should drive,
    and selects which of the three to build.  The second MMCM always drives all
    three outputs -- they cost nothing, and keeping them makes the *ratios* a
    property of this one instance rather than of how it was configured -- but a
    domain nobody uses would still collect a period constraint and a reset
    synchroniser, so only the ones asked for get a BUFG.

    A value of None means "create the ClockDomain here"; passing one in is for
    the caller that has to own it.  That is not a hypothetical: LiteX expects
    the clock-and-reset generator itself to own `sys`, so a board whose sys
    clock *is* the console's GS clock hands its own `cd_sys` in.
    """
    def __init__(self, platform, ref, rst, name="ps2", domains=None):
        if domains is None:
            domains = {"ee": None, "gs": None, "iop": None}
        self.locked = Signal()
        made = {}
        for d, cd in domains.items():
            if d not in ("ee", "gs", "iop"):
                raise ValueError(f"PS2Clocks has no {d} domain")
            if cd is None:
                cd = ClockDomain(d)
                setattr(self, f"cd_{d}", cd)     # created here, so owned here
            made[d] = cd

        base   = Signal()
        base_b = Signal()
        fb1, fb2 = Signal(), Signal()
        lock1, lock2 = Signal(), Signal()
        c2 = [Signal(name=f"{name}_c2_{k}") for k in ("ee", "gs", "iop")]

        # ---- stage 1: the 18.432 MHz base -------------------------------
        self.specials += Instance("MMCME4_ADV", name=f"{name}_mmcm1",
            p_BANDWIDTH        = "OPTIMIZED",
            p_COMPENSATION     = "AUTO",
            p_CLKIN1_PERIOD    = 10.0,
            p_DIVCLK_DIVIDE    = STAGE1["divclk"],
            p_CLKFBOUT_MULT_F  = STAGE1["mult"],
            p_CLKOUT0_DIVIDE_F = STAGE1["clkout0"],
            i_CLKIN1   = ref,
            i_RST      = rst,
            i_CLKFBIN  = fb1,
            o_CLKFBOUT = fb1,
            o_CLKOUT0  = base,
            o_LOCKED   = lock1,
        )
        self.specials += Instance("BUFG", i_I=base, o_O=base_b)

        # ---- stage 2: the three console clocks, integer dividers ---------
        self.specials += Instance("MMCME4_ADV", name=f"{name}_mmcm2",
            p_BANDWIDTH       = "OPTIMIZED",
            p_COMPENSATION    = "AUTO",
            p_CLKIN1_PERIOD   = 1e3 / 18.431983,
            p_DIVCLK_DIVIDE   = STAGE2["divclk"],
            p_CLKFBOUT_MULT_F = STAGE2["mult"],
            # CLKOUT0 is the one output with a fractional divider, so its
            # parameter is CLKOUT0_DIVIDE_F and CLKOUT0_DIVIDE does not exist:
            # synthesis rejects the integer name outright ("parameter
            # 'CLKOUT0_DIVIDE' ... does not exist"), which is how this was
            # found -- the arithmetic in this file had been checked since it
            # was written, and the instance had never been through a
            # synthesiser.  A whole number in the fractional parameter is still
            # an exact integer divide, so the ratios below are unaffected.
            p_CLKOUT0_DIVIDE_F = float(STAGE2["ee"]),
            p_CLKOUT1_DIVIDE   = STAGE2["gs"],
            p_CLKOUT2_DIVIDE   = STAGE2["iop"],
            i_CLKIN1   = base_b,
            i_RST      = rst,
            i_CLKFBIN  = fb2,
            o_CLKFBOUT = fb2,
            o_CLKOUT0  = c2[0],
            o_CLKOUT1  = c2[1],
            o_CLKOUT2  = c2[2],
            o_LOCKED   = lock2,
        )
        for sig, key in zip(c2, ("ee", "gs", "iop")):
            if key in made:
                self.specials += Instance("BUFG", i_I=sig, o_O=made[key].clk)

        self.comb += self.locked.eq(lock1 & lock2)
        for cd in made.values():
            self.specials += AsyncResetSynchronizer(cd, rst | ~self.locked)



if __name__ == "__main__":
    # The arithmetic, checkable without a toolchain.
    from fractions import Fraction as F
    vco1 = F(100) / STAGE1["divclk"] * F(str(STAGE1["mult"]))
    base = vco1 / F(str(STAGE1["clkout0"]))
    vco2 = base / STAGE2["divclk"] * F(str(STAGE2["mult"]))
    print(f"stage 1 VCO {float(vco1):.4f} -> base {float(base):.9f} MHz")
    print(f"stage 2 VCO {float(vco2):.4f}")
    for nm, o, native in (("EE", STAGE2["ee"], F(294912, 1000)),
                          ("GS", STAGE2["gs"], F(147456, 1000)),
                          ("IOP", STAGE2["iop"], F(36864, 1000))):
        f = vco2 / o
        print(f"  {nm:3s} {float(f):11.6f} MHz  err {float(abs(f-native)/native)*1e6:5.2f} ppm")
