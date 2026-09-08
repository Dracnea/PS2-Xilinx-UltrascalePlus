#!/usr/bin/env bash
#
# Boot a real PS2 BIOS on the C1100's IOP, end to end.
#
#   sudo tools/ps2iop/bios-hw.sh /path/to/rom0.bin [seconds] [extra bios_run.py args]
#
# e.g.  sudo tools/ps2iop/bios-hw.sh rom0.bin 30 --dump-ram 0x200000
# to take the IOP's whole RAM afterwards and read it with iop_ram_map.py.
#
# Root is needed only for the PCIe part: dropping the identity the host
# enumerated before the image was loaded, rescanning, and inserting the
# LitePCIe driver built for this image. The BIOS run itself happens as the
# invoking user (SUDO_USER), so nothing it writes is root-owned.
#
# Loads bitstreams/c1100_ps2_diag.bit (the IOP plus UARTbone, a POST ring with
# IOP cycle stamps, a stall detector, the serial console FIFO and a LiteScope
# on the CPU bus) unless the card already holds it, then runs
# tools/ps2iop/bios_run.py, which streams the 4 MB image into the IOP ROM,
# releases reset, watches POST, and afterwards prints the POST ring, the
# console text the IOP printed, the stall state and the bus trace.
#
# Everything lands in build/ps2_bios/<timestamp>-<image name>/.
# BIOS images are the operator's own dumps and live outside this repository.
set -uo pipefail
cd "$(dirname "$0")/../.."
BIOS=${1:?path to a PS2 BIOS dump (rom0, 4 MB)}
SECS=${2:-5}
shift $(( $# > 2 ? 2 : $# ))
EXTRA=("$@")
[[ -f $BIOS ]] || { echo "no such file: $BIOS" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run with sudo (the PCIe rescan and the driver need root)" >&2; exit 1; }

USER_NAME=${SUDO_USER:-dracnea}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
BIT=bitstreams/c1100_ps2_diag.bit
SW=${LITEPCIE_SW:-$PWD/build/c1100_ps2_diag/software}
as_user() { runuser -u "$USER_NAME" -- "$@"; }

[[ -f $SW/kernel/litepcie.ko ]] || { echo "no driver for this image: $SW/kernel/litepcie.ko (build it: make -C $SW/kernel)" >&2; exit 1; }

echo "== load $BIT (skip with SKIP_LOAD=1)"
if [[ -z ${SKIP_LOAD:-} ]]; then
    as_user env PATH="$PATH" FJTAG="${FJTAG:-}" tools/jtag-load.sh "$BIT" || { echo "FAIL: JTAG load"; exit 1; }
fi

echo "== PCIe: drop the stale identity, rescan, driver"
rmmod litepcie 2>/dev/null
for d in $(lspci -D -n -d 10ee: | awk '{print $1}'); do echo 1 > "/sys/bus/pci/devices/$d/remove"; done
sleep 1; echo 1 > /sys/bus/pci/rescan; sleep 2
lspci -nn -d 10ee:
insmod "$SW/kernel/litepcie.ko" || { echo "FAIL: insmod"; dmesg | tail -10; exit 1; }
sleep 1
[[ -e /etc/udev/rules.d/99-litepcie.rules ]] || { cp tools/99-litepcie.rules /etc/udev/rules.d/; udevadm control --reload-rules; udevadm trigger; }
chgrp plugdev /dev/litepcie0 && chmod 0660 /dev/litepcie0
lspci -vv -s "$(lspci -D -n -d 10ee: | awk '{print $1}' | head -1 | cut -d: -f2-)" 2>/dev/null | grep -E 'Region 0|LnkSta:'

echo "== BIOS run as $USER_NAME"
as_user env HOME="$USER_HOME" tools/ps2iop/bios_run.py "$BIOS" --seconds "$SECS" "${EXTRA[@]}"
rc=$?
chown -R "$USER_NAME" build/ps2_bios 2>/dev/null
exit $rc
