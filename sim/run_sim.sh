#!/usr/bin/env bash
# Assemble boot_test.s, build the IOP subsystem in xsim, run, and grep PASS.
#   ./run_sim.sh [--debug]
# --debug runs tb_iop_dbg.sv instead: every CPU/RAM/bus transaction printed,
# for finding out why a ROM does not boot; see its plusargs (cycles, quiet,
# regs/rfrom/rto, rf, pfrom/pto) and pass them through XSIM_ARGS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TB=tb_iop; W="$HERE/work"
if [[ "${1:-}" == "--debug" ]]; then TB=tb_iop_dbg; W="$HERE/work_dbg"; shift; fi
ROOT="$(cd "$HERE/.." && pwd)"
UP="$ROOT/third_party/PSX_MiSTer/rtl"
RTL="$ROOT/rtl"
[[ -f "$UP/cpu.vhd" ]] || { echo "no PSX_MiSTer sources at $UP" >&2
    echo "run: git submodule update --init third_party/PSX_MiSTer" >&2; exit 1; }
command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"

python3 "$HERE/asm_r3000.py" "$HERE/boot_test.s" "$HERE/boot_test.hex" --size 4096

rm -rf "$W"; mkdir -p "$W"; cd "$W"
cp "$HERE/boot_test.hex" .

# Altera compatibility shims (the PSX RAM wrappers instantiate altsyncram/altdpram)
xvhdl -2008 --work altera_mf "$RTL/altera_compat/altera_mf_components.vhd" > xvhdl_mf.log 2>&1
# altdpram.v grew three ports for the Saturn wrappers (rdaddressstall,
# wraddressstall, sclr; unused in the model body). The PSX register file binds
# the model from VHDL without them, which synthesis accepts and xsim's
# elaboration does not, so simulate a copy without those ports.
mkdir -p work && grep -vE '^\s*input\s+wire\s+(rdaddressstall|wraddressstall|sclr)\b' "$RTL"/altera_compat/altdpram.v > work/altdpram_sim.v
xvlog --work mem "$RTL"/altera_compat/altsyncram.v work/altdpram_sim.v > xvlog_compat.log 2>&1

# Everything else into library mem, so `entity mem.X` and `entity work.X` both resolve
# (Quartus folds all libraries into work; this reproduces that, as tools/core-fit.py does).
xvhdl -2008 --work mem \
  "$UP/RamMLAB.vhd" "$UP/SyncFifoFallThroughMLAB.vhd" "$UP/SyncFifo.vhd" "$UP/SyncFifoFallThrough.vhd" \
  "$UP/SyncRam.vhd" "$RTL/psx/SyncRamDual.vhd" "$RTL/psx/SyncRamDualNotPow2.vhd" \
  "$UP/SyncRamDualByteEnable.vhd" "$UP/dpram.vhd" "$UP/export.vhd" "$UP/divider.vhd" "$UP/datacache.vhd" \
  "$UP/cpu.vhd" "$UP/timer.vhd" "$UP/memctrl.vhd" \
  "$UP/spu_gauss.vhd" "$UP/spu_ram.vhd" "$UP/spu.vhd" \
  "$RTL/iop/iop_regstub.vhd" "$RTL/iop/iop_console.vhd" "$RTL/iop/iop_intc.vhd" "$RTL/iop/iop_timer32.vhd" \
  "$RTL/iop/iop_ram.vhd" "$RTL/iop/iop_spuram.vhd" "$RTL/iop/iop_spu2.vhd" \
  "$RTL/iop/iop_sio2.vhd" "$RTL/iop/iop_cdvd.vhd" \
  "$RTL/iop/iop_memorymux.vhd" "$RTL/iop/iop_top.vhd" \
  > xvhdl.log 2>&1 || { grep -E "ERROR" xvhdl.log | head -20; exit 1; }
xvlog -sv --work mem "$HERE/$TB.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off --relax -L mem -L altera_mf -s iop mem.$TB > xelab.log 2>&1 || { grep -E "ERROR" xelab.log | head -20; exit 1; }
# XSIM_ARGS passes plusargs to the debug bench, e.g.
#   XSIM_ARGS="-testplusarg cycles=40000 -testplusarg quiet=1" ./run_sim.sh --debug
if [[ $TB == tb_iop_dbg ]]; then xsim iop -R ${XSIM_ARGS:-} 2>&1 | grep -v "^#" | tee xsim.log; exit 0; fi
xsim iop -R ${XSIM_ARGS:-} 2>&1 | tee xsim.log | grep -E "POST|PASS|FAIL|peek|reset released|Error|error" || true
grep -q "^PASS" xsim.log
