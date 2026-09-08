#!/usr/bin/env bash
# ./run_fit.sh [part]   -> build/fit_iop_<part>/{fit.log,utilization.rpt,timing.rpt}
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PART="${1:-xcu55n-fsvh2892-2L-e}"
B="$HERE/../build/fit_iop_${PART%%-*}"; mkdir -p "$B"; cd "$B"
command -v vivado >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
vivado -mode batch -nojournal -log fit.log -source "$HERE/fit_iop.tcl" -tclargs "$PART" > /dev/null
grep -E "^\| (CLB LUTs|CLB Registers|Block RAM Tile|URAM|DSPs)" utilization.rpt | head -5
grep -A3 "WNS(ns)" timing.rpt | tail -2
