#!/usr/bin/env bash
# Run a program on the reference and on ee_top -- the core with its real main
# memory and a behavioural HBM behind it -- and diff the retire traces.
#
#   sim/ee/run_top_diff.sh --prog FILE [--steps N]
#   sim/ee/run_top_diff.sh --seed N [--count N]
#
# Only the architectural trace is compared, not memory: data lives in HBM behind
# a write-through cache here, so a memory image would need reading back through
# the cache and that is a separate question from whether the core still runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; COUNT=200; STEPS=200; PROG=""
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;; --count) COUNT=$2; shift 2;;
  --steps) STEPS=$2; shift 2;;
  --prog) PROG=$(readlink -f "$2"); shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

if [[ -n $PROG ]]; then cp "$PROG" prog.hex
else python3 "$HERE/gen_prog.py" --seed "$SEED" --count "$COUNT" > prog.hex; fi
if [[ -z $PROG && $STEPS -lt $COUNT ]]; then STEPS=$COUNT; fi
python3 "$HERE/r5900_ref.py" prog.hex --steps "$STEPS" > ref.txt 2> ref.traps

xvhdl -2008 "$ROOT/rtl/ee/ee_core.vhd" "$ROOT/rtl/ee/ee_ram.vhd" \
            "$ROOT/rtl/ee/ee_top.vhd"   > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv   "$HERE/tb_ee_top.sv"        > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_ee_top -s tb        > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "program=prog.hex" -testplusarg "steps=$STEPS" \
     > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
if grep -q "STALLED" xsim.log; then
    echo "FAIL  ${PROG:-seed $SEED}: $(grep STALLED xsim.log)"; exit 1
fi
grep -E "^ *[0-9]+ pc=" xsim.log > rtl.txt

if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  $(wc -l < ref.txt) instructions identical (${PROG:-seed $SEED}) $(grep '^# cache' xsim.log)"
    grep '^# cycles' xsim.log
    exit 0
fi
echo "FAIL  ${PROG:-seed $SEED}"
diff ref.txt rtl.txt | head -4 | cut -c1-150
exit 1
