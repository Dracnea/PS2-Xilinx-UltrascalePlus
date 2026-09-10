#!/usr/bin/env bash
# Run a program on the reference and on the RTL, and diff them.
#   sim/ee/run_diff.sh [--seed N] [--count N] [--steps N] [--branches]
# A difference names the instruction that produced it, not the symptom.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; COUNT=200; STEPS=150; BR=""
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;; --count) COUNT=$2; shift 2;;
  --steps) STEPS=$2; shift 2;; --branches) BR="--branches"; shift;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_prog.py" --seed "$SEED" --count "$COUNT" $BR > prog.hex
python3 "$HERE/r5900_ref.py" prog.hex --steps "$STEPS" --dump-mem 0x2000 0x400 > ref.txt 2> ref.traps

xvhdl -2008 "$ROOT/rtl/ee/ee_core.vhd"      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv   "$HERE/tb_ee_core.sv"           > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_ee_core -s tb           > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "program=prog.hex" -testplusarg "steps=$STEPS" \
     > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
grep -E "^ *[0-9]+ pc=|^MEM " xsim.log > rtl.txt

if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  $(wc -l < ref.txt) instructions identical (seed $SEED)"
    exit 0
fi
echo "FAIL  seed $SEED"
echo "first difference:"
diff ref.txt rtl.txt | head -6
n=$(diff --unchanged-group-format='' --old-group-format='%dF
' --new-group-format='' --changed-group-format='%dF
' ref.txt rtl.txt | head -1)
echo
echo "reference line $n and the RTL disagree; the instruction is at the pc on that line"
sed -n "${n}p" ref.txt | cut -c1-90
sed -n "${n}p" rtl.txt | cut -c1-90
exit 1
