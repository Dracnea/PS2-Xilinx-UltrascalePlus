#!/usr/bin/env bash
# The FPU package against ps2_float.py, over corner vectors.
#   sim/ee/run_fpu_diff.sh [--random N]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/fpu$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_fpu_vectors.py" "$@" > vectors.hex
python3 "$HERE/fpu_ref.py" vectors.hex > ref.txt

xvhdl -2008 "$ROOT/rtl/ee/ee_fpu_pkg.vhd" "$HERE/fpu_wrap.vhd" > xvhdl.log 2>&1 \
  || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_fpu_pkg.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_fpu_pkg -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "vec=vectors.hex" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
grep '^V ' xsim.log > rtl.txt

if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  $(wc -l < ref.txt) vectors identical"
    exit 0
fi
echo "FAIL"
diff ref.txt rtl.txt | head -6
exit 1
