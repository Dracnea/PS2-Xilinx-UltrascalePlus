#!/usr/bin/env bash
#
# Put a PS2 image back on the card and bring PCIe up again, in the one order
# that works.
#
#   sudo tools/reload.sh c1100_gs
#
# This exists because the three steps have a mandatory order and getting it
# wrong fails in ways that look like something else:
#
#   1. take the card off the PCIe bus.  Programming over JTAG drops the link
#      under a bound driver, and the host does not recover it by itself.
#   2. program over JTAG -- as the invoking user, not root: the Vivado install
#      and its licence live in that user's home.
#   3. rescan, insert the driver built with *this* image, and check the
#      identifier.
#
# Skipping (2) is the specific trap this script was written for.  Anything that
# reconfigures the fabric behind our back -- a satellite-controller voltage
# session, another project's bitstream -- leaves build/.last-loaded naming an
# image that is no longer on the card.  pcie-bringup.sh then loads a driver
# whose CSR map belongs to a design that is not there.  It catches that with the
# identifier check, which is what the failure looks like:
#
#     FAIL: the card does not report the identifier of build/c1100_gs
#
# The answer to that message is to run this, not to run bring-up again.
#
# It also prints the rails on the way through.  A voltage setpoint is global and
# survives reconfiguration, so the number the card comes up at is not
# necessarily the one the last PS2 session used, and it is worth seeing rather
# than assuming.
#
# SPDX-License-Identifier: BSD-2-Clause
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo $0 $*" >&2; exit 1; }
IMAGE=${1:?name the image, e.g. sudo tools/reload.sh c1100_gs}
BIT=$ROOT/build/$IMAGE/gateware/xilinx_c1100.bit
[[ -f $BIT ]] || BIT=$ROOT/bitstreams/$IMAGE.bit
[[ -f $BIT ]] || { echo "no bitstream for image '$IMAGE'" >&2; exit 1; }

USER_NAME=${SUDO_USER:-$(id -un)}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
VIVADO=${VIVADO:-$(ls -d "$USER_HOME"/Xilinx/*/Vivado/bin 2>/dev/null | sort -r | head -1)}

# Only one process may hold an FTDI channel, and a hard kill leaves all four
# marked open at the driver level with nothing holding them.  So report and
# stop; do not clear it ourselves.
#
# Two things this guard used to get wrong, both already learned and fixed in
# changeVoltage.sh -- the same lesson had to be paid for twice because the two
# tools kept their own copy of it:
#
#   * `pgrep -f` matches the whole command line, so it matched the shell running
#     *this script* whenever the invoking command happened to mention one of
#     these names.  `-x` matches the process name, which is what was meant.
#   * **hw_server is not a blocker.**  Vivado starts one and leaves it running
#     between sessions; the next Vivado reconnects to it rather than fighting
#     it, and it claims the FTDI only while a target is open.  Listing it here
#     made this script refuse to run straight after changeVoltage.sh -- which
#     leaves an hw_server behind every time by design -- so the documented
#     rail-then-reload sequence blocked on its own previous step.
for n in changeVoltage openFPGALoader xsdb; do
    pids=$(pgrep -x "$n" 2>/dev/null | grep -v "^$$\$" || true)
    if [ -n "$pids" ]; then
        echo "reload: JTAG channel held by $n ($pids)" >&2
        echo "stop it with SIGTERM, never SIGKILL" >&2
        exit 1
    fi
done

echo "== 1/3  off the PCIe bus =="
for d in $(lspci -D -n -d 10ee: | awk '{print $1}'); do
    echo "  removing $d"
    echo 1 > "/sys/bus/pci/devices/$d/remove"
done
sleep 1

echo "== 2/3  programming $IMAGE over JTAG =="
sudo -u "$USER_NAME" env PATH="$VIVADO:$PATH" "$ROOT/tools/jtag-load.sh" "$BIT"
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "programming failed; putting the card back on the bus" >&2
    echo 1 > /sys/bus/pci/rescan
    exit $rc
fi

# The rails, read from the device we are already connected to.  Cheap, and the
# only place in the flow where a JTAG session is open anyway.
sudo -u "$USER_NAME" env PATH="$VIVADO:$PATH" vivado -mode batch -notrace -nolog \
     -nojournal -source /dev/stdin <<'TCL' 2>/dev/null | sed -n 's/^RAIL /  /p'
open_hw_manager
connect_hw_server -quiet -allow_non_jtag
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set sm [lindex [get_hw_sysmons] 0]
if {$sm ne ""} {
    refresh_hw_sysmon $sm
    foreach p {VCCINT VCCBRAM VCCAUX TEMPERATURE} {
        puts "RAIL [format %-12s $p] [get_property $p $sm]"
    }
}
close_hw_manager
TCL

echo "== 3/3  back on the bus, driver for $IMAGE =="
exec "$ROOT/tools/pcie-bringup.sh" "$IMAGE"
