#!/usr/bin/env python3
#
# The PlayStation 2's clock tree, from a 100 MHz board reference.
#
# Every clock in a PS2 is an integer multiple of 18.432 MHz: the IOP is 2x, the
# GS 8x, the EE 16x.  This is a rebuild of the machine rather than an emulator,
# so those are a specification -- a block running at the wrong rate is wrong,
# not slow, and the *ratios* between them are what the software depends on.
#
# 18.432 MHz *is* reachable exactly from 100 MHz, and the whole clock tree with
# it.  An earlier version of this file argued at length that it was not, and
# settled for 0.90 ppm; the argument was wrong in one number.
#
#     18.432 / 100 = 576 / 3125 = (2^6 * 3^2) / 5^5
#
# The 5^5 has to come out of the dividers, and the claim was that it cannot
# because CLKFBOUT_MULT would have to exceed "a hard limit of 64".  **64 is the
# 7-series limit.**  An UltraScale+ MMCME4 multiplies by up to 128, and inside
# that larger space there is exactly one exact solution:
#
#     DIVCLK 5, MULT 72, CLKOUT0_DIVIDE_F 78.125
#     VCO = 100 / 5 x 72 = 1440 MHz,  1440 / 78.125 = 18.432000 MHz
#
# One solution, found by searching the whole legal space rather than reasoning
# about it -- which is what should have happened the first time.
#
# Two MMCMs are still needed, and that part of the old argument holds.  A single
# one would have to produce 294.912, 147.456 and 36.864 from one VCO, so the VCO
# must be a common multiple of all three: 1474.56 MHz works arithmetically
# (x5, x10, x40) but needs MULT_F / DIVCLK = 14.7456, and 625 does not divide
# any DIVCLK in range.  So:
#
#   * one MMCM makes the 18.432 MHz base exactly, as above;
#   * a second multiplies it by 64 to a VCO of 1179.648 MHz and divides by 4, 8
#     and 32.  Those are integers, so the EE : GS : IOP ratios are 16 : 8 : 2
#     exactly, by construction.
#
# Every PS2 clock therefore comes out **exact**: 294.912, 147.456 and 36.864
# MHz, 0 ppm, from a 100 MHz board reference and no added oscillator.  That is
# better than the console being copied, whose crystal is 30 to 100 ppm.
#
# Both feedback multipliers are now **integers**, which matters for a second
# reason.  The fractional feedback multiplier the old STAGE1 used is the one
# feature of this block that nothing in this project had ever seen work on
# hardware -- boards/c1100_ps2_iop.py flags its own as unverified for exactly
# this reason -- and the first two attempts to run the card on this clock tree
# produced a design whose sys domain never clocked.  Only the *output* divider
# is fractional now, which is the ordinary case that LiteX's own MMCM wrapper
# emits.
#
# SPDX-License-Identifier: BSD-2-Clause

from migen import *
from migen.genlib.resetsync import AsyncResetSynchronizer
from litex.gen.fhdl.module import LiteXModule

# The measured constants, kept here so they are checkable rather than folded
# into the instance below.
STAGE1 = dict(divclk=5, mult=72, clkout0=78.125)       # 100 MHz -> 18.432 exactly
STAGE2 = dict(divclk=1, mult=64,                       # 18.432 -> VCO 1179.648
              ee=4, gs=8, iop=32)                      # integer, so ratios are exact


class PS2Clocks(LiteXModule):
    """cd_ee (294.912), cd_gs (147.456) and cd_iop (36.864), all 0.9 ppm fast.

    `ref` is the buffered 100 MHz board reference; `rst` holds both MMCMs.
    `locked` is high when *both* have locked, because a design that starts on
    one of two clocks is worse than one that does not start at all.

    Two details of the instances below are not optional and were both missing
    from the first version, which did not lock on the card at all:

      * **CLKINSEL must be tied high.**  It selects between CLKIN1 and CLKIN2,
        and it is not optional just because CLKIN2 is unused: left unconnected
        it reads as 0, the MMCM selects the unconnected CLKIN2, and it never
        locks.  boards/c1100_ps2_iop.py's hand-written MMCM sets it and this one
        did not, which is the whole difference between a design that runs and
        one whose sys domain has no clock.
      * **The second MMCM is held in reset until the first has locked.**  A
        cascade whose downstream stage is released while its input is still
        absent may fail to lock or lock to the wrong frequency; UG572 says to
        gate it, and it costs one term.

    Neither is visible in simulation, neither is a parameter a DRC checks, and
    the failure they produce is silent in a specific and nasty way: the PCIe
    hard block has its own clock, so the card still enumerates, trains its link
    and answers config-space reads.  Only the CSR space behind the bridge is
    dead, and a read of it does not error -- it never completes, so the driver
    hangs.

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
            p_REF_JITTER1      = 0.01,
            p_CLKIN1_PERIOD    = 10.0,
            p_DIVCLK_DIVIDE    = STAGE1["divclk"],
            p_CLKFBOUT_MULT_F  = STAGE1["mult"],
            p_CLKOUT0_DIVIDE_F = STAGE1["clkout0"],
            i_CLKIN1   = ref, i_CLKIN2 = 0, i_CLKINSEL = 1,
            i_RST      = rst, i_PWRDWN = 0,
            i_DADDR = 0, i_DCLK = 0, i_DEN = 0, i_DI = 0, i_DWE = 0,
            i_PSCLK = 0, i_PSEN = 0, i_PSINCDEC = 0, i_CDDCREQ = 0,
            i_CLKFBIN  = fb1,
            o_CLKFBOUT = fb1,
            o_CLKOUT0  = base,
            o_LOCKED   = lock1,
        )
        self.specials += Instance("BUFG", i_I=base, o_O=base_b)

        # ---- stage 2: the three console clocks, integer dividers ---------
        self.specials += Instance("MMCME4_ADV", name=f"{name}_mmcm2",
            p_BANDWIDTH       = "OPTIMIZED",
            p_REF_JITTER1     = 0.01,
            p_CLKIN1_PERIOD   = 1e3 / 18.432,
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
            i_CLKIN1   = base_b, i_CLKIN2 = 0, i_CLKINSEL = 1,
            # Held until the first stage is locked, so this one is never asked
            # to acquire against an input that is not there yet.
            i_RST      = rst | ~lock1, i_PWRDWN = 0,
            i_DADDR = 0, i_DCLK = 0, i_DEN = 0, i_DI = 0, i_DWE = 0,
            i_PSCLK = 0, i_PSEN = 0, i_PSINCDEC = 0, i_CDDCREQ = 0,
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
