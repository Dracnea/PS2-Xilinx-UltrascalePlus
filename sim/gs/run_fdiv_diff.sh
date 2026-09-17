#!/usr/bin/env bash
# The perspective divide's float divider, against ps2_float.div.
#   sim/gs/run_fdiv_diff.sh [--seed N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/fdiv$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_fdiv.py" --seed "$SEED" --out "$W" 2> gen.log || { cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/ee/ee_fpu_pkg.vhd" "$ROOT/rtl/gs/gs_stq.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_fdiv.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_fdiv -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

if grep -qE "STALLED|still busy" xsim.log; then
    echo "FAIL  seed $SEED: $(grep -oE 'FAIL.*' xsim.log | head -1)"; echo "  (kept in $W)"; exit 1
fi
grep -E '^[0-9]+ [0-9a-f]{8}$' xsim.log > rtl.txt
if diff -q ref.txt rtl.txt > /dev/null; then
    echo "PASS  $(wc -l < rtl.txt) quotients identical (seed $SEED, $(cat gen.log))"
    rm -rf "$W"
else
    echo "FAIL  seed $SEED"
    paste -d' ' <(cat ref.txt) <(cut -d' ' -f2 rtl.txt) | \
      awk '$2!=$3 {n++; if (n<=8) printf "  case %s: model %s  rtl %s\n", $1, $2, $3} \
           END {printf "  %d of %d differ\n", n, NR}'
    echo "  (kept in $W)"
    exit 1
fi
