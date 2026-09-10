#!/usr/bin/env bash
# Diff gs_edge_dda against the reference's exact arithmetic.
#   sim/gs/run_edge_diff.sh [--seed N] [--n N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; N=60
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;; --n) N=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done
command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/edge$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
python3 "$HERE/gen_edges.py" --seed "$SEED" --n "$N" --out edges.txt > ref.txt
xvhdl -2008 "$ROOT/rtl/gs/gs_edge_dda.vhd" > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv   "$HERE/tb_edge_dda.sv"         > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_edge_dda -s tb         > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
grep -q STALLED xsim.log && { echo "FAIL seed $SEED: $(grep STALLED xsim.log)"; exit 1; }
grep -E "^E " xsim.log > rtl.txt
if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  $(wc -l < ref.txt) scanlines identical (seed $SEED)"
    exit 0
fi
echo "FAIL  seed $SEED"
diff ref.txt rtl.txt | head -6
