#!/usr/bin/env bash
#
# PS2 IOP on the C1100: everything after the JTAG load, in one command.
#
#   sudo tools/ps2iop/hw-test.sh            # from the repo root
#
# Root is needed for the PCIe part only: dropping the stale identity the host
# enumerated at boot, rescanning, loading litepcie.ko and installing the udev
# rule that makes /dev/litepcie0 group-readable. The tests themselves then run
# as the invoking user (SUDO_USER), so nothing they write is root-owned.
# Everything is logged to build/ps2_hw/<timestamp>.log.
#
# Prerequisite: bitstreams/c1100_ps2_iop.bit loaded over JTAG (fjtag --load
# reports DONE=1 EOS=1 CRC_ERR=0).
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
CSR=bitstreams/c1100_ps2_iop.csr.csv
ROM=sim/boot_test.hex
LOG=build/ps2_hw/$(date +%Y%m%d-%H%M%S).log

if [[ $EUID -ne 0 ]]; then echo "run with sudo (root is needed for the PCIe rescan and the driver)" >&2; exit 1; fi
USER_NAME=${SUDO_USER:-dracnea}
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
SW=${LITEPCIE_SW:-$PWD/build/c1100_ps2_iop/software}   # the driver must match the image (csr.h)
mkdir -p build/ps2_hw; chown "$USER_NAME" build/ps2_hw
exec > >(tee "$LOG") 2>&1
echo "== $(date -Is)  PS2 IOP hardware test, log $LOG"

# ---- root part: PCIe identity, driver, permissions ----------------------
echo "== PCIe before"; lspci -nn -d 10ee:
for d in $(lspci -D -n -d 10ee: | awk '{print $1}'); do
    echo "removing $d"; echo 1 > "/sys/bus/pci/devices/$d/remove"
done
sleep 1; echo 1 > /sys/bus/pci/rescan; sleep 2
echo "== PCIe after"; lspci -nn -d 10ee:
DEV=$(lspci -D -n -d 10ee: | awk '{print $1}' | head -1)
[[ -n ${DEV:-} ]] || { echo "FAIL: no Xilinx device after rescan"; exit 1; }
lspci -s "${DEV#0000:}" -vv 2>/dev/null | grep -E 'Region|LnkSta:'
lspci -n -s "${DEV#0000:}" | grep -q '10ee:9034' || echo "WARN: expected 10ee:9034 (LitePCIe endpoint), got $(lspci -n -s "${DEV#0000:}")"

rmmod litepcie 2>/dev/null
insmod "$SW/kernel/litepcie.ko" || { echo "FAIL: insmod $SW/kernel/litepcie.ko"; dmesg | tail -20; exit 1; }
sleep 1
if [[ ! -e /etc/udev/rules.d/99-litepcie.rules ]]; then
    cp tools/99-litepcie.rules /etc/udev/rules.d/ && udevadm control --reload-rules && udevadm trigger
    echo "installed /etc/udev/rules.d/99-litepcie.rules"
fi
chgrp plugdev /dev/litepcie0 && chmod 0660 /dev/litepcie0
ls -la /dev/litepcie*
dmesg | grep -i litepcie | tail -8
"$SW/user/litepcie_util" info 2>&1 | head -20

# ---- user part: the tests -----------------------------------------------
run_as_user() { runuser -u "$USER_NAME" -- "$@"; }
POST="tools/ps2iop/iop_post.py --csr $CSR"
step() { echo; echo "---- $*"; }

step "1. status at power-up: expect locked=1, POST 00, post_count 0, rom_count 0, reset 1"
run_as_user $POST status
step "2. heartbeat: two reads 0.5 s apart must differ (IOP clock domain running)"
a=$(run_as_user $POST status | grep -o 'heartbeat [01]'); sleep 0.5
b=$(run_as_user $POST status | grep -o 'heartbeat [01]'); echo "$a / $b"
[[ "$a" != "$b" ]] && echo "heartbeat: toggling, OK" || echo "heartbeat: NOT toggling (check locked; then MMCM fallback DIVCLK 1 / MULT 11.0)"

step "3. ROM load: 4096 words, rom_count must read 4096"
run_as_user $POST reset hold
run_as_user $POST load "$ROM"
run_as_user $POST status

# Stage 0E reads a sector, so a disc has to be present and something has to
# answer the sector requests.  DISC may be an ISO, a block device or a drive --
# discserve.py does not care which (docs/disc-path.md).
DISC=${DISC:-"discs/Star Wars - Battlefront II (USA) (v2.01).iso"}

step "4. boot_test.s, pad0 = 0x5A3C (what the testbench drives), no disc: expect POST 01..0D then EE at 0E"
run_as_user $POST run "$ROM" --timeout 10 --pad0 0x5A3C

if [[ -e $DISC ]]; then
    step "5. the same run with $DISC in the drive: expect POST 01..0E then AA, PASS"
    run_as_user $POST cdvd disc on
    run_as_user tools/ps2iop/discserve.py "$DISC" --csr "$CSR" --seconds 30 &
    SERVER=$!
    sleep 0.5
    run_as_user $POST run "$ROM" --timeout 20 --pad0 0x5A3C
    step "5b. what the IOP actually asked the drive for"
    run_as_user $POST cdvd log
    kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null
else
    step "5. SKIPPED: no disc at $DISC -- stage 0E cannot pass without one"
fi

step "6. pad0 = 0xFFFF (nothing pressed): stage 09 must now report EE, proving the pad CSR reaches SIO2"
run_as_user $POST cdvd disc off
run_as_user $POST run "$ROM" --timeout 10 --pad0 0xFFFF

if [[ -e $DISC ]]; then
    step "7. repeat the passing run 5x for stability (each must PASS)"
    run_as_user $POST cdvd disc on
    for i in 1 2 3 4 5; do
        run_as_user tools/ps2iop/discserve.py "$DISC" --csr "$CSR" --seconds 25 --quiet &
        SERVER=$!
        sleep 0.3
        run_as_user $POST run "$ROM" --timeout 20 --pad0 0x5A3C | tail -1
        kill $SERVER 2>/dev/null; wait $SERVER 2>/dev/null
    done
fi

step "8. final status"
run_as_user $POST status
echo; echo "== done $(date -Is); log: $LOG"
