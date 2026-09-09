#!/usr/bin/env python3
#
# C1100 HBM bring-up: prove the 8 GB of HBM2 before anything depends on it.
#
#   venv/bin/python boards/c1100_hbm_test.py --build
#
# This is deliberately the smallest design that can answer "does the HBM work,
# and can the host reach all 8 GB of it": PCIe for the host, the HBM2 IP, and a
# single-beat AXI master on one pseudo-channel driven from CSRs.  No IOP, no
# CDVD, nothing that could be blamed if it fails.
#
# It exists because the disc sector source is about to move into HBM, and the
# lesson of the CDVD read path (docs/disc-path.md) is that everything between a
# host CSR and another clock domain is only ever tested on the card.  A sector
# source built directly on an unproven memory would give two candidate faults
# for every failure.
#
# Why a CSR-driven single beat rather than DMA: staging a 4 GB disc image at CSR
# speed would take half an hour, so this is not the staging path and is not
# meant to be.  It is the correctness check -- write a word at an address, read
# it back, including addresses in the second stack, which is the part the
# default 32-bit AXI addressing cannot reach.  Bulk staging over LitePCIe DMA
# comes next and can then assume the memory itself is sound.
#
# Address space: 33-bit, so one AXI port covers all 8 GB across both stacks.
# The per-stack switches are enabled in ip/hbm/gen_hbm.tcl.

import sys
from os.path import join, dirname, abspath, normpath, exists

sys.path.insert(0, dirname(abspath(__file__)))
sys.path.insert(0, normpath(join(dirname(abspath(__file__)), "..", "platforms")))

from migen import *
from migen.genlib.cdc import MultiReg, PulseSynchronizer
from migen.genlib.resetsync import AsyncResetSynchronizer

from litex.gen.fhdl.module import LiteXModule
from litex.soc.cores.clock import USPMMCM
from litex.soc.integration.soc_core import SoCMini
from litex.soc.integration.builder import Builder
from litex.soc.interconnect.csr import CSRStorage, CSRStatus, CSRField, AutoCSR

from litepcie.phy.usppciephy import USPHBMPCIEPHY
from litepcie.software import generate_litepcie_software

import xilinx_c1100
from hbm_common import HBM, HBMProbe, HBM_XCI



class _CRG(LiteXModule):
    """125 MHz sys, plus the three clocks the HBM IP wants.

    HBM_REF_CLK is 100 MHz (the IP's PLL multiplies it), APB is 100 MHz, and
    the AXI ports run at 250 MHz -- above the IP's 225 MHz floor and matching
    USER_AXI_CLK_FREQ in ip/hbm/gen_hbm.tcl.  250 MHz on a 256-bit port is
    8 GB/s, which is absurd headroom for disc sectors; the floor is what sets
    it, not the bandwidth.
    """
    def __init__(self, platform, sys_clk_freq):
        self.rst       = Signal()
        self.cd_sys    = ClockDomain()
        self.cd_hbm_ref= ClockDomain()
        self.cd_apb    = ClockDomain()
        self.cd_axi    = ClockDomain()
        self.clk100    = Signal()

        pads   = platform.request("clk100")
        clk_se = Signal()
        self.specials += Instance("IBUFDS", i_I=pads.p, i_IB=pads.n, o_O=clk_se)
        self.specials += Instance("BUFG",   i_I=clk_se, o_O=self.clk100)

        self.mmcm = mmcm = USPMMCM(speedgrade=-2, name="sys_mmcm")
        self.comb += mmcm.reset.eq(self.rst)
        mmcm.register_clkin(self.clk100, 100e6)
        mmcm.create_clkout(self.cd_sys,     sys_clk_freq, margin=0)
        mmcm.create_clkout(self.cd_hbm_ref, 100e6,        margin=0)
        mmcm.create_clkout(self.cd_apb,     100e6,        margin=0)
        mmcm.create_clkout(self.cd_axi,     250e6,        margin=0)

        platform.add_period_constraint(pads.p, 1e9/100e6)


class HBMTestSoC(SoCMini):
    def __init__(self, platform, speed="gen3", nlanes=4, sys_clk_freq=125e6):
        SoCMini.__init__(self, platform, sys_clk_freq,
                         ident=f"C1100 HBM bring-up x{nlanes} {speed}")

        self.crg = _CRG(platform, sys_clk_freq)

        # PCIe, exactly as the IOP target (verified on hardware 2026-09-05/07).
        pcie_pads = platform.request(f"pcie_x{nlanes}")
        self.pcie_phy = USPHBMPCIEPHY(platform, pcie_pads,
                                      speed      = speed,
                                      data_width = {1:64, 4:128, 8:256, 16:512}[nlanes],
                                      bar0_size  = 0x20000)
        self.pcie_phy.update_config({
            "pf0_bar0_64bit":        "true",
            "pf0_bar0_prefetchable": "true",
        })
        self.add_pcie(phy=self.pcie_phy, ndmas=1,
                      with_dma_buffering=True, dma_buffering_depth=1024,
                      with_dma_loopback=False)

        # HBM.  Unlike every other target here, hbm_cattrip is driven by the
        # IP's real over-temperature output rather than tied low.
        if not exists(HBM_XCI):
            raise SystemExit(
                f"no HBM IP at {HBM_XCI}\n"
                f"generate it first:\n"
                f"  vivado -mode batch -source ip/hbm/gen_hbm.tcl "
                f"-tclargs xcu55n-fsvh2892-2LV-e")
        self.hbm = HBM(platform, platform.request("hbm_cattrip"))

        # One pseudo-channel is enough to prove the memory; the switch makes the
        # whole 8 GB reachable through it.
        self.probe = HBMProbe(self.hbm.axi[0])

        # Everything that crosses between these domains does so through a
        # MultiReg or a PulseSynchronizer, so the data paths are false by
        # construction.  They share one MMCM and are not truly asynchronous,
        # which is why each crossing still has to be written as a crossing --
        # the constraint records the intent, it does not create it.
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.cd_apb.clk)
        platform.add_false_path_constraints(self.crg.cd_apb.clk, self.crg.cd_axi.clk)
        platform.add_false_path_constraints(self.crg.cd_sys.clk, self.crg.clk100)
def build(nlanes=4, speed="gen3", do_build=False, build_dir="build/c1100_hbm_test"):
    platform = xilinx_c1100.Platform(toolchain="vivado")
    soc      = HBMTestSoC(platform, speed=speed, nlanes=nlanes)
    builder  = Builder(soc, output_dir=build_dir, compile_software=False,
                       csr_csv=join(build_dir, "csr.csv"))
    builder.build(run=do_build)
    try:
        generate_litepcie_software(soc, join(build_dir, "software"))
    except Exception as e:
        print(f"note: litepcie software generation skipped: {e}")
    return builder


if __name__ == "__main__":
    build(nlanes = 16 if "--x16" in sys.argv else 4,
          do_build = "--build" in sys.argv)
