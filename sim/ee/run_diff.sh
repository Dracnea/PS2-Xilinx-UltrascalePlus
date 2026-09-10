#!/usr/bin/env bash
# Run a program on the reference and on the RTL, and diff them.
#   sim/ee/run_diff.sh [--seed N] [--count N] [--steps N] [--branches]
#   sim/ee/run_diff.sh --prog FILE [--steps N]      # a pre-made program
#   sim/ee/run_diff.sh --seed 1 --ilat 4 --dlat 3   # slower memories
# A difference names the instruction that produced it, not the symptom.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; COUNT=200; STEPS=150; BR=""; PROG=""; ILAT=1; DLAT=1
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;; --count) COUNT=$2; shift 2;;
  --steps) STEPS=$2; shift 2;; --branches) BR="--branches"; shift;;
  --prog) PROG=$(readlink -f "$2"); shift 2;;
  --ilat) ILAT=$2; shift 2;; --dlat) DLAT=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

# The testbench's memories are delay lines read at [lat-1], so a latency of zero
# is not a faster memory but an out-of-range index: the core is handed an
# instruction of X, never decodes it, and reports "STALLED after 0 of N" --
# which is indistinguishable from a fetch unit that cannot start.  Refuse it
# here so that the run says what is wrong instead of blaming the core.
if [[ ${ILAT:-1} -lt 1 || ${DLAT:-1} -lt 1 ]]; then
  echo "ilat and dlat must be at least 1: a memory that answers in the same" >&2
  echo "cycle is not something the fetch unit is built to talk to" >&2
  exit 2
fi

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

if [[ -n $PROG ]]; then cp "$PROG" prog.hex
else python3 "$HERE/gen_prog.py" --seed "$SEED" --count "$COUNT" $BR > prog.hex; fi
# The trace window has to cover the whole program, because the RTL keeps
# instructions in flight past the last one it reports.  A store commits to
# memory in A2, one stage before it retires in WB, so the instruction *after*
# the last traced one can already have written memory when the dump is taken --
# and the reference, which stops cleanly, has not.  The registers still agree;
# only the memory image differs, which reads exactly like a store to a wrong
# address.  Padding beyond the program is all NOPs, so covering it costs
# nothing and removes the whole class of false failure.
if [[ -z $PROG && $STEPS -lt $COUNT ]]; then
    echo "note: raising --steps from $STEPS to $COUNT so the trace covers the program" >&2
    STEPS=$COUNT
fi
python3 "$HERE/r5900_ref.py" prog.hex --steps "$STEPS" --dump-mem 0x2000 0x400 > ref.txt 2> ref.traps

xvhdl -2008 "$ROOT/rtl/ee/ee_core.vhd"      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv   "$HERE/tb_ee_core.sv"           > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_ee_core -s tb           > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "program=prog.hex" -testplusarg "steps=$STEPS" \
     -testplusarg "ilat=$ILAT" -testplusarg "dlat=$DLAT" \
     > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
if grep -q "STALLED" xsim.log; then
    echo "FAIL  ${PROG:-seed $SEED} (ilat=$ILAT dlat=$DLAT): $(grep STALLED xsim.log)"
    exit 1
fi
grep -E "^ *[0-9]+ pc=|^MEM " xsim.log > rtl.txt

if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  $(wc -l < ref.txt) instructions identical (${PROG:-seed $SEED} ilat=$ILAT dlat=$DLAT)"
    exit 0
fi
echo "FAIL  ${PROG:-seed $SEED} (ilat=$ILAT dlat=$DLAT)"
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
