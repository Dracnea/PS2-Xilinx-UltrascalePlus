#!/usr/bin/env bash
# ee_bringup against the reference model, over a self-parking program.
#   sim/ee/run_bringup_diff.sh --seed 1 --count 200
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/bu$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"

python3 "$HERE/gen_card.py" "$@" > prog.hex
python3 - "$HERE" prog.hex > ref.txt <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
import r5900_ref
words = [int(l.strip(), 16) for l in open(sys.argv[2])]

# Log the model's data accesses in the same shape the testbench prints, so the
# two can be diffed rather than eyeballed.
_ld, _st = r5900_ref.Mem.load, r5900_ref.Mem.store
_log = []
def load(self, a, n):
    v = _ld(self, a, n)
    if a >= 0x1000:
        _log.append(("R", a, n, v))
    return v
def store(self, a, n, v):
    if a >= 0x1000:
        _log.append(("W", a, n, v))
    return _st(self, a, n, v)
r5900_ref.Mem.load, r5900_ref.Mem.store = load, store

mem = r5900_ref.Mem()
for k, w in enumerate(words):
    mem.store(k * 4, 4, w)
cpu = r5900_ref.R5900(mem, 0)
last, still, seen = None, 0, 0
for _ in range(40000):
    here = cpu.pc
    cpu.step()
    if seen < 400:
        print("P %d %08x" % (seen, here & 0xFFFFFFFF))
        seen += 1
    if cpu.pc == last:
        still += 1
        if still > 4: break
    else: still = 0
    last = cpu.pc
# r128, not r: r() returns the low 64 bits and MMI writes the upper half.
# Comparing with r() truncates away the very thing PPACH, PEXTL and the
# rest exist to produce, so a register whose upper half is set and whose
# lower half is zero reads as zero and the RTL looks wrong.
for i in range(32):
    print("R%d %032x" % (i, cpu.r128(i)))
for line in range(1024):
    v = 0
    for b in range(16):
        v |= mem.load(line * 16 + b, 1) << (8 * b)
    if v:
        print("M %04x %032x" % (line, v))
PY

xvhdl -2008 "$ROOT/rtl/ee/ee_core.vhd" "$ROOT/rtl/ee/ee_bringup.vhd" > xvhdl.log 2>&1 \
  || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_ee_bringup.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_ee_bringup -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }
xsim tb -R -testplusarg "prog=prog.hex" > xsim.log 2>&1 || { tail -30 xsim.log; exit 1; }
grep -E '^(R[0-9]|M |P )' xsim.log > rtl.txt

if diff -q ref.txt rtl.txt >/dev/null; then
    echo "PASS  all 32 registers agree  ($(grep -o 'RETIRES [0-9]*' xsim.log))"
    exit 0
fi
echo "FAIL  $(grep -o 'RETIRES [0-9]*' xsim.log)"
diff ref.txt rtl.txt | head -8
exit 1
