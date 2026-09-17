#!/usr/bin/env bash
# Diff gs_texaddr against sim/gs/gs_ref.py's texel addressing.
#   sim/gs/run_texaddr_diff.sh [--seed N] [--random N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; RANDOM_N=4000
while [[ $# -gt 0 ]]; do case $1 in
  --seed)   SEED=$2; shift 2;;
  --random) RANDOM_N=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/texaddr$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_texaddr.py" --seed "$SEED" --random "$RANDOM_N" --out "$W" \
    2> gen.log || { cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/gs/gs_addr_pkg.vhd" "$ROOT/rtl/gs/gs_texaddr.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_texaddr.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_texaddr -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

if grep -q '^PASS' xsim.log; then
    echo "$(grep '^PASS' xsim.log) (seed $SEED, $(cat gen.log))"
    rm -rf "$W"
else
    grep -E '^(MISMATCH|    )' xsim.log | head -40
    echo "$(grep '^FAIL' xsim.log) (seed $SEED)"
    echo "  (case kept in $W)"
    exit 1
fi
