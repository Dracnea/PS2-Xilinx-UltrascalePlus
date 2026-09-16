#!/usr/bin/env bash
#
# gs_pxcap against a synthetic pixel stream.
#
#   sim/gs/run_pxcap.sh
#
# No reference model: this block stores what it is given and the testbench knows
# what it gave. What it checks is the four edges -- capture starts on the first
# pixel of a frame rather than the second, a short frame ends at the next
# start-of-frame with the right count, a frame longer than the buffer stops
# rather than wraps, and arming with no frame in sight does not hang.
#
# SPDX-License-Identifier: BSD-2-Clause
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/pxcap$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
xvhdl -2008 "$ROOT/rtl/gs/gs_pxcap.vhd" > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv   "$HERE/tb_pxcap.sv"         > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_pxcap -s tb         > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
grep -E '^PASS|^FAIL' xsim.log
grep -q '^PASS' xsim.log
