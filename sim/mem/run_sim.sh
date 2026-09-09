#!/usr/bin/env bash
# GS local memory and EE main memory, in xsim.
#   ./run_sim.sh
#
# Each step's errors are printed and stop the run.  An earlier version piped
# every step through `grep ERROR && exit 1`, which sent the error text to a
# filtered stdout and left the previous run's xsim.log in place -- so a compile
# failure looked exactly like a simulation that had run and produced stale
# results.  Twice.
set -uo pipefail
cd "$(dirname "$0")"
RTL="$(cd ../../rtl && pwd)"
TB="$PWD/tb_mem.sv"
mkdir -p work && cd work
rm -f xsim.log

step() {                       # step <name> <command...>
    local name=$1; shift
    if ! "$@" > "$name.log" 2>&1; then
        echo "### $name FAILED"; grep -E "ERROR|Error" "$name.log" | head -20; exit 1
    fi
    if grep -qE "^ERROR" "$name.log"; then
        echo "### $name reported errors"; grep -E "^ERROR" "$name.log" | head -20; exit 1
    fi
}

step xvhdl xvhdl --2008 -work mem "$RTL/gs/gs_lmem.vhd" "$RTL/ee/ee_ram.vhd"
step xvlog xvlog -sv "$TB"
step xelab xelab -debug typical -L mem tb_mem -s memsim
xsim memsim -R 2>&1 | tee xsim.log | grep -E "^--|^   |PASS|FAIL"
