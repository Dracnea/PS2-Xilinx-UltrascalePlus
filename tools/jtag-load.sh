#!/usr/bin/env bash
#
# Load a bitstream into the C1100 over its on-board USB JTAG (the FT4232H).
#
#   tools/jtag-load.sh bitstreams/<image>.bit
#
# Uses Vivado's hardware manager (Vivado or the free Vivado Lab Edition on
# PATH: `vivado` / `vivado_lab`), which drives the Alveo's USB JTAG directly.
# If FJTAG is set to another loader that understands `--load <bit> --no-serve`,
# that is used instead. Prints "loaded" and exits 0 only when Vivado reports
# "End of startup status: HIGH" (DONE went high). About 45 s for a 56 MB image.
#
# Programming while the card is enumerated on PCIe drops the link; afterwards
# run `sudo tools/pcie-bringup.sh` (or the test script you are using, which
# does it) to re-enumerate, or warm-reboot.
set -uo pipefail
BIT=${1:?bitstream}
[[ -f $BIT ]] || { echo "no such file: $BIT" >&2; exit 1; }
BIT=$(readlink -f "$BIT")

if [[ -n ${FJTAG:-} && -x $FJTAG ]]; then
    "$FJTAG" --load "$BIT" --no-serve && echo "loaded $BIT" && exit 0
    exit 1
fi

VIV=$(command -v vivado || command -v vivado_lab || true)
[[ -n $VIV ]] || { echo "need vivado or vivado_lab on PATH (or FJTAG=<loader>)" >&2; exit 1; }
TCL=$(mktemp --suffix=.tcl)
cat > "$TCL" <<TCL
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xcu55n*] 0]
if {\$dev eq ""} { set dev [lindex [get_hw_devices] 0] }
current_hw_device \$dev
puts "device: \$dev"
set_property PROGRAM.FILE {$BIT} \$dev
program_hw_devices \$dev
close_hw_manager
TCL
out=$("$VIV" -mode batch -notrace -nolog -nojournal -source "$TCL" 2>&1); rc=$?
rm -f "$TCL"
echo "$out" | grep -E 'device:|End of startup status|ERROR' | head -6
if [[ $rc -eq 0 ]] && echo "$out" | grep -q 'End of startup status: HIGH'; then
    echo "loaded $BIT"; exit 0
fi
echo "load failed (rc=$rc)" >&2; exit 1
