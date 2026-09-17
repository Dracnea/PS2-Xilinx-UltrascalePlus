#!/usr/bin/env bash
# Diff gs_texsample (with gs_clut behind it) against gs_ref.py's sample_uv+TFX.
#   sim/gs/run_texsample_diff.sh [--seed N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/texsample$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_texsample.py" --seed "$SEED" --out "$W" 2> gen.log || { cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/gs/gs_addr_pkg.vhd" "$ROOT/rtl/gs/gs_texaddr.vhd" \
            "$ROOT/rtl/gs/gs_clut.vhd" "$ROOT/rtl/gs/gs_texsample.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_texsample.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_texsample -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

if grep -q STALLED xsim.log; then
    echo "FAIL  seed $SEED: a fetch never completed"; echo "  (kept in $W)"; exit 1
fi
grep -E '^[0-9]+ [0-9a-f]{8}$' xsim.log > rtl.txt
if diff -q ref.txt rtl.txt > /dev/null; then
    echo "PASS  $(wc -l < rtl.txt) samples identical (seed $SEED, $(cat gen.log))"
    rm -rf "$W"
else
    echo "FAIL  seed $SEED"
    paste -d' ' <(cut -d' ' -f2 ref.txt) <(cut -d' ' -f2 rtl.txt) | \
      awk '$1!=$2 {n++; if (n<=8) printf "  case %d: model %s  rtl %s\n", NR-1, $1, $2} \
           END {printf "  %d of %d samples differ\n", n, NR}'
    echo "  (kept in $W)"
    exit 1
fi
