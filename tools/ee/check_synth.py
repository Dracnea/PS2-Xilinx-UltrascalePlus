#!/usr/bin/env python3
"""Assert that the EE actually survived synthesis.

    tools/ee/check_synth.py [--part xcu55n-fsvh2892-2LV-e]

This exists because of a specific failure. While the bring-up memory was being
restructured, a region replacement deleted the one concurrent assignment that
drove `i_data`. That is legal VHDL -- an undriven signal with an initialiser is
a constant -- so it compiled, it elaborated, and synthesis then trimmed the
**entire R5900** because nothing fed it instructions. `ee_core` came back as
42 LUTs and zero DSPs, and a full bitstream was built from it.

The tell was timing *improving*: the design met 294.912 MHz with positive slack
for the first time ever, which should have been the first thing to disbelieve
rather than the first thing to celebrate. An empty design always meets timing.

So the resources are asserted rather than read. Each number here is a thing the
design cannot be correct without:

  DSP48    the R5900's multiplier. Zero means the core was trimmed.
  RAMB36   the 64 KB bring-up memory. Zero means it did not infer and is
           somewhere else -- probably tens of thousands of LUTs.
  LUTRAM   must be zero. Anything here is memory built out of lookup tables,
           which is what "Infeasible attribute ram_style" leaves behind.
  LUT      a floor, so that a core trimmed down to a shell is caught even if
           the DSPs somehow survive.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

EXPECT = {
    "DSP":    (16, 16),      # exactly: one multiplier, no more
    "RAMB36": (16, 64),      # 64 KB at 128 bits wide
    "LUTRAM": (0, 0),        # none, ever
    "LUT":    (15000, 60000),
}

TCL = """
read_vhdl -vhdl2008 {root}/rtl/ee/ee_core.vhd
read_vhdl -vhdl2008 {root}/rtl/ee/ee_bringup.vhd
synth_design -top ee_bringup -part {part} -mode out_of_context
puts "CHECK DSP    [llength [get_cells -hier -filter {{REF_NAME =~ DSP48*}}]]"
puts "CHECK RAMB36 [llength [get_cells -hier -filter {{REF_NAME =~ RAMB36*}}]]"
puts "CHECK LUTRAM [llength [get_cells -hier -filter {{REF_NAME =~ RAMD* || REF_NAME =~ RAMS*}}]]"
puts "CHECK LUT    [llength [get_cells -hier -filter {{REF_NAME =~ LUT*}}]]"
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--part", default="xcu55n-fsvh2892-2LV-e")
    ap.add_argument("--vivado", default=os.path.expanduser("~/Xilinx/2026.1/Vivado/bin/vivado"))
    a = ap.parse_args()

    with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False) as f:
        f.write(TCL.format(root=ROOT, part=a.part))
        path = f.name
    try:
        out = subprocess.run([a.vivado, "-mode", "batch", "-nojournal", "-nolog",
                              "-source", path], capture_output=True, text=True,
                             cwd=ROOT).stdout
    finally:
        os.unlink(path)

    got = {}
    for m in re.finditer(r"^CHECK (\S+)\s+(\d+)", out, re.M):
        got[m.group(1)] = int(m.group(2))

    bad = 0
    for name, (lo, hi) in EXPECT.items():
        n = got.get(name)
        if n is None:
            print(f"  FAIL {name}: synthesis produced no count (did it run?)")
            bad += 1
        elif not (lo <= n <= hi):
            print(f"  FAIL {name}: {n}, expected {lo}..{hi}")
            bad += 1
        else:
            print(f"  ok   {name}: {n}")
    if bad:
        print("FAIL  the design is not what it should be; do not trust a "
              "timing result from it")
    else:
        print("PASS  the R5900 and its memory are both present")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
