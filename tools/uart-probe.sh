#!/usr/bin/env bash
#
# Find which FTDI channel carries the FPGA's UART 0 and check the CSR bus over it.
#
#   tools/uart-probe.sh [csr.csv] [baud]      default: the diagnostic build's csr.csv
#
# For each /dev/ttyUSB1..3 (channel A = ttyUSB0 is JTAG): start litex_server on
# it, ask for the SoC identifier, stop. A channel that answers prints the ident
# string; the others time out. No root: the tty nodes are plugdev 0666.
set -uo pipefail
cd "$(dirname "$0")/.."
VENV=${PS2_VENV:-${VENV:-$([[ -d venv ]] && echo venv || echo "$HOME/MiSTeX-ports/venv")}}
CSR=${1:-build/c1100_ps2_diag/csr.csv}
BAUD=${2:-115200}
for tty in /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
    [[ -e $tty ]] || continue
    echo "== $tty"
    "$VENV/bin/litex_server" --uart --uart-port "$tty" --uart-baudrate "$BAUD" --bind-port 1235 >/tmp/litex_server.$$ 2>&1 &
    srv=$!
    sleep 1.5
    out=$(timeout 8 "$VENV/bin/litex_cli" --port 1235 --csr-csv "$CSR" --ident 2>&1 | tail -3)
    echo "$out"
    kill -TERM $srv 2>/dev/null; wait $srv 2>/dev/null
    if grep -q 'C1100' <<<"$out"; then echo "UART found on $tty"; echo "$tty" > build/uart-tty; break; fi
done
