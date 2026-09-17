#!/usr/bin/env bash
# The texel cache: invisible on the texsample vectors, then coherent on purpose.
#   sim/gs/run_texcache_diff.sh [--seed N]
#
# The vectors are gen_texsample.py's, unchanged and deliberately so. The whole
# claim a cache makes is that it changes nothing, so the right test is the
# uncached block's own test with the cache spliced into its read path, diffed
# against the same ref.txt. A separate vector set for the cached path could
# drift from the uncached one and hide exactly the disagreement being looked for.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1
SETS=6
WAYS=1
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;;
  --sets) SETS=$2; shift 2;;
  --ways) WAYS=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/texcache$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_texsample.py" --seed "$SEED" --out "$W" 2> gen.log || { cat gen.log; exit 1; }

xvhdl -2008 "$ROOT/rtl/gs/gs_addr_pkg.vhd" "$ROOT/rtl/gs/gs_texaddr.vhd" \
            "$ROOT/rtl/gs/gs_clut.vhd" "$ROOT/rtl/gs/gs_texsample.vhd" \
            "$ROOT/rtl/gs/gs_texcache.vhd" \
      > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_texcache.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off -generic_top "SETS_LOG2=$SETS" -generic_top "WAYS_LOG2=$WAYS" tb_texcache -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "dir=$W" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }

fail=0
if grep -q STALLED xsim.log; then
    echo "FAIL  seed $SEED: a fetch never completed"; fail=1
fi
grep -E '^[0-9]+ [0-9a-f]{8}$' xsim.log > rtl.txt
if ! diff -q ref.txt rtl.txt > /dev/null; then
    echo "FAIL  seed $SEED: the cache changed an answer"
    paste -d' ' <(cut -d' ' -f2 ref.txt) <(cut -d' ' -f2 rtl.txt) | \
      awk '$1!=$2 {n++; if (n<=8) printf "  case %d: uncached %s  cached %s\n", NR-1, $1, $2} \
           END {printf "  %d of %d samples differ\n", n, NR}'
    fail=1
fi
if grep -q '^FAIL' xsim.log; then
    grep '^FAIL' xsim.log | head -20 | sed 's/^/  /'
    fail=1
fi
if ! grep -q '^COHERENT' xsim.log; then
    echo "FAIL  seed $SEED: the coherence phase did not finish clean"
    fail=1
fi
if [[ $(grep -c '^WALK ' xsim.log) -ne 2 ]]; then
    echo "FAIL  seed $SEED: the raster walk did not run both formats"
    fail=1
fi

stats=$(grep '^CACHE ' xsim.log | head -1)
if [[ $fail -eq 0 ]]; then
    echo "PASS  $(wc -l < rtl.txt) samples identical, coherent (seed $SEED, 2^$SETS sets x 2^$WAYS ways, ${stats#CACHE })"
    grep '^WALK ' xsim.log | sed 's/^WALK /      raster walk: /'
    rm -rf "$W"
else
    echo "  ${stats}"
    echo "  (kept in $W)"
    exit 1
fi
