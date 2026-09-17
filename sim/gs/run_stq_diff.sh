#!/usr/bin/env bash
# The perspective divide, against gs_ref.stq_to_uv.
#   sim/gs/run_stq_diff.sh [--seed N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/stq$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_stq.py" --seed "$SEED" --out "$W" 2> gen.log || { cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/ee/ee_fpu_pkg.vhd" "$ROOT/rtl/gs/gs_stq.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_stq.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_stq -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

if grep -qE "STALLED|busy before" xsim.log; then
    echo "FAIL  seed $SEED: $(grep -oE 'FAIL.*' xsim.log | head -1)"; echo "  (kept in $W)"; exit 1
fi
grep -E '^[0-9]+ -?[0-9]+ -?[0-9]+$' xsim.log > rtl.txt
if diff -q ref.txt rtl.txt > /dev/null; then
    echo "PASS  $(wc -l < rtl.txt) coordinates identical (seed $SEED, $(cat gen.log))"
    grep -o 'LATENCY .*' xsim.log | sed 's/^/      /'
    rm -rf "$W"
else
    echo "FAIL  seed $SEED"
    paste -d' ' ref.txt rtl.txt | \
      awk '($2!=$5)||($3!=$6) {n++; if (n<=8) printf "  case %s: model (%s,%s)  rtl (%s,%s)\n", $1,$2,$3,$5,$6} \
           END {printf "  %d of %d differ\n", n, NR}'
    echo "  (kept in $W)"
    exit 1
fi
