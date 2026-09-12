#!/usr/bin/env bash
# Run one PCRTC case through the reference and the RTL, and diff the frames.
#   sim/gs/run_pcrtc_diff.sh --seed N [--both]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; BOTH=""; CASE=""
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;;
  --case) CASE="--case $2"; shift 2;;
  --both) BOTH="--both"; shift;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/pcrtc$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_pcrtc.py" --seed "$SEED" $BOTH $CASE --out "$W" 2> gen.log || {
    cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/gs/gs_addr_pkg.vhd" "$ROOT/rtl/gs/gs_pcrtc.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_pcrtc.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_pcrtc -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

if grep -q STALLED xsim.log; then
    echo "FAIL  seed $SEED: $(grep STALLED xsim.log)"; exit 1
fi
grep -E '^ *[0-9]+ +[0-9]+ +[0-9a-f]{6}$' xsim.log > rtl.txt
if diff -q ref.txt rtl.txt > /dev/null; then
    echo "PASS  $(wc -l < rtl.txt) pixels identical (seed $SEED $(cat gen.log))"
else
    echo "FAIL  seed $SEED $(cat gen.log)"
    echo "first difference:"
    diff ref.txt rtl.txt | head -8
    echo "  (case kept in $W)"
    exit 1
fi
rm -rf "$W"
