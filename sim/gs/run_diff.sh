#!/usr/bin/env bash
# Run a GIF packet stream through the reference and the RTL, and diff them.
#   sim/gs/run_diff.sh --prog FILE [--dump-base N] [--dump-len N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROG=""; BASE=0; LEN=256; SEED=""; TAGS=40
while [[ $# -gt 0 ]]; do case $1 in
  --prog) PROG=$(readlink -f "$2"); shift 2;;
  --seed) SEED=$2; shift 2;; --tags) TAGS=$2; shift 2;;
  --dump-base) BASE=$2; shift 2;; --dump-len) LEN=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done
[[ -n $PROG || -n $SEED ]] || { echo "need --prog or --seed" >&2; exit 2; }

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
if [[ -n $PROG ]]; then cp "$PROG" packets.hex
else python3 "$HERE/gen_gif.py" --seed "$SEED" --tags "$TAGS" > packets.hex; fi

python3 "$HERE/gs_ref.py" packets.hex --raw --dump-mem "$BASE" "$LEN" > ref.txt 2> ref.err

xvhdl -2008 "$ROOT/rtl/gs/gs_edge_dda.vhd" "$ROOT/rtl/gs/gs_gif.vhd" > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv   "$HERE/tb_gs.sv"          > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_gs -s tb          > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "packets=packets.hex" \
     -testplusarg "dumpbase=$BASE" -testplusarg "dumplen=$LEN" \
     > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
if grep -q STALLED xsim.log; then
    echo "FAIL  ${PROG:-seed $SEED}: $(grep STALLED xsim.log)"; exit 1
fi
# The count of writes to undefined register addresses is part of the state
# being compared, not commentary: it is how "a write to an address the manual
# does not define must leave every register alone" gets checked at all.  It was
# being filtered out of the RTL side while the reference still printed it, so
# every stream that touched an undefined address failed on a line the RTL had
# never been given the chance to produce.
grep -E "^REG |^VM |^VMSUM |^# unknown|^# pixels" xsim.log > rtl.txt

if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  $(wc -l < ref.txt) lines identical (${PROG:+$(basename "$PROG")}${SEED:+seed $SEED})"
    exit 0
fi
echo "FAIL  ${PROG:+$(basename "$PROG")}${SEED:+seed $SEED}"
diff ref.txt rtl.txt | head -8
