#!/usr/bin/env bash
#
# Bring the LitePCIe endpoint up on a freshly JTAG-programmed card.
#
# The host enumerates BARs at boot, so a card that previously held a bitstream
# without a PCIe endpoint still shows its stale factory identity after a JTAG
# load. This removes that stale device, rescans, loads the driver and verifies.
#
# Run as root, from anywhere:
#
#   sudo /path/to/FPGA-Retro/tools/pcie-bringup.sh [image]
#
# `image` is the build directory name of the bitstream that is on the card, so
# the driver inserted is the one generated with it -- that has to match, or
# every register reads at the wrong address (docs/c1100-pcie-transport.md).
# Default c1100_ps2_diag. Override the whole path with LITEPCIE_SW if the
# build lives somewhere else.
set -uo pipefail
cd "$(dirname "$0")/.."          # so a relative invocation works from anywhere

if [[ $EUID -ne 0 ]]; then echo "must run as root: sudo $0" >&2; exit 1; fi

# sudo leaves HOME as root's, so find the invoking user's checkout instead.
USER_NAME=${SUDO_USER:-$(id -un)}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
IMAGE=${1:-c1100_ps2_diag}
SW=${LITEPCIE_SW:-$PWD/build/$IMAGE/software}

if [[ ! -f $SW/kernel/litepcie.ko ]]; then
    echo "no driver at $SW/kernel/litepcie.ko" >&2
    echo "build it:  make -C $SW/kernel" >&2
    echo "or name the image on the card, e.g.  sudo $0 c1100_ps2_diag" >&2
    exit 1
fi
echo "driver: $SW/kernel/litepcie.ko"

echo "== before =="
lspci -nn -d 10ee: || true

# Remove every Xilinx-vendor device so the stale factory identity goes too.
for d in $(lspci -D -n -d 10ee: | awk '{print $1}'); do
    echo "removing $d"
    echo 1 > "/sys/bus/pci/devices/$d/remove"
done

sleep 1
echo "rescanning..."
echo 1 > /sys/bus/pci/rescan
sleep 2

echo
echo "== after =="
lspci -nn -d 10ee: || true

DEV=$(lspci -D -n -d 10ee: | awk '{print $1}' | head -1)
if [[ -z ${DEV:-} ]]; then
    echo "FAIL: no Xilinx device enumerated after rescan" >&2
    exit 1
fi
echo
echo "== BARs =="
lspci -s "${DEV#0000:}" -vv 2>/dev/null | grep -E 'Region|LnkSta:|LnkCap:'

echo
echo "== driver =="
rmmod litepcie 2>/dev/null
if insmod "$SW/kernel/litepcie.ko"; then
    echo "litepcie loaded"
else
    echo "FAIL: insmod litepcie.ko" >&2
    dmesg | tail -20
    exit 1
fi
sleep 1
ls -la /dev/litepcie* 2>/dev/null || echo "no /dev/litepcie* nodes"

echo
echo "== dmesg =="
dmesg | grep -i litepcie | tail -25

echo
echo "== identifier / CSR =="
if [[ -x $SW/user/litepcie_util ]]; then
    "$SW/user/litepcie_util" info 2>&1 | head -40
else
    echo "litepcie_util not built (make -C $SW/user); skipping the identifier read"
fi
