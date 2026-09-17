#!/usr/bin/env bash
# Diff gs_clut against sim/gs/gs_ref.py's Clut, palette and load counter both.
#   sim/gs/run_clut_diff.sh [--seed N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/clut$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_clut.py" --seed "$SEED" --out "$W" 2> gen.log || { cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/gs/gs_addr_pkg.vhd" "$ROOT/rtl/gs/gs_clut.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_clut.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_clut -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

if grep -q STALLED xsim.log; then
    echo "FAIL  seed $SEED: a CLUT load never completed"; echo "  (kept in $W)"; exit 1
fi
grep -E '^[0-9]+ [0-9]+ [0-9]+ ' xsim.log > rtl.txt
if diff -q ref.txt rtl.txt > /dev/null; then
    echo "PASS  $(wc -l < rtl.txt) cases identical (seed $SEED, $(cat gen.log))"
    rm -rf "$W"
else
    echo "FAIL  seed $SEED"
    # Report which case first differs and in what, rather than 256 columns of hex.
    python3 - ref.txt rtl.txt <<'PY'
import sys
ref = [l.split() for l in open(sys.argv[1])]
rtl = [l.split() for l in open(sys.argv[2])]
for i, (a, b) in enumerate(zip(ref, rtl)):
    if a == b:
        continue
    print(f"  first difference at case {a[0]}:")
    if a[1] != b[1]:
        print(f"    load counter: model {a[1]}, rtl {b[1]}"
              f"   <-- a reload happened that should not have, or did not happen")
    if a[2] != b[2]:
        print(f"    unsupported:  model {a[2]}, rtl {b[2]}")
    diffs = [(k, x, y) for k, (x, y) in enumerate(zip(a[3:], b[3:])) if x != y]
    if diffs:
        print(f"    {len(diffs)} of 256 entries differ; first few:")
        for k, x, y in diffs[:6]:
            print(f"      entry {k:3d}: model {x}  rtl {y}")
    break
else:
    print(f"  the files differ in length: model {len(ref)} cases, rtl {len(rtl)}")
PY
    echo "  (kept in $W)"
    exit 1
fi
