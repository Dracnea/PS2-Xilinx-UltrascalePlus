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
# Default to whatever tools/jtag-load.sh last put on the card, not to a name
# fixed in this script.  A stale default is worse than no default: the driver
# loads, every ioctl succeeds, and each one writes to an address that belongs to
# a different design -- which is silent, and cost a day to find once already.
if [[ $# -ge 1 ]]; then
    IMAGE=$1
elif [[ -r build/.last-loaded ]]; then
    IMAGE=$(< build/.last-loaded)
    echo "image: $IMAGE (from build/.last-loaded)"
else
    echo "no image named and build/.last-loaded is missing" >&2
    echo "name the image that is on the card, e.g. sudo $0 c1100_ps2_iop" >&2
    echo "available: $(cd build 2>/dev/null && ls -d */ 2>/dev/null | tr -d / | tr '\n' ' ')" >&2
    exit 1
fi
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
# Build it if it is missing rather than skipping the check.  The identifier read
# is the one step that confirms the host is talking to the bitstream you think is
# on the card, so quietly skipping it is the wrong default -- and it is a
# thirty-second native build with no cross toolchain involved.  Built as the
# invoking user so the objects are not left root-owned.
if [[ ! -x $SW/user/litepcie_util ]]; then
    echo "litepcie_util not built; building it"
    if ! runuser -u "$USER_NAME" -- make -C "$SW/user" >/dev/null 2>&1; then
        echo "  build failed; run: make -C $SW/user"
    fi
fi
if [[ -x $SW/user/litepcie_util ]]; then
    info=$("$SW/user/litepcie_util" info 2>&1)
    echo "$info" | head -40

    # Verify rather than display.  The identifier lives at a different address in
    # every design, so reading the expected string back is what proves the driver
    # and the gateware agree -- and reading anything else is the one cheap signal
    # that they do not.  Printing it unchecked is how a mismatch goes unnoticed:
    # the garbage scrolls past among thirty other lines.
    want=$(awk -F, '$1=="constant" && $2=="config_identifier" {print $3}' "$PWD/build/$IMAGE/csr.csv" 2>/dev/null)
    echo
    if [[ -z $want ]]; then
        echo "WARNING: no config_identifier in build/$IMAGE/csr.csv; cannot verify the match"
    elif echo "$info" | grep -qF "$want"; then
        echo "identifier matches build/$IMAGE: '$want'"
    else
        echo "FAIL: the card does not report the identifier of build/$IMAGE" >&2
        echo "  expected: '$want'" >&2
        echo "  the driver just loaded was generated with build/$IMAGE, so if the" >&2
        echo "  bitstream on the card is a different design then every CSR the" >&2
        echo "  driver touches is at the wrong address and nothing will work." >&2
        echo "  Name the image that is actually on the card and run this again." >&2
        exit 1
    fi
else
    echo "litepcie_util still not available; skipping the identifier read" >&2
    echo "that check is what catches a driver built for a different design; do not skip it" >&2
    exit 1
fi
