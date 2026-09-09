#!/usr/bin/env bash
# Build hbm_dma_stage against a specific image's software tree.
#
#   tools/ps2iop/build-dma-stage.sh [image]     # default c1100_ps2_iop
#
# The CSR addresses come from that build's csr.h, so the binary only matches the
# bitstream it was built for -- the same rule as the driver.  Output lands next
# to litepcie_util in that tree.
set -euo pipefail
cd "$(dirname "$0")/../.."
IMAGE=${1:-c1100_ps2_iop}
SW="$PWD/build/$IMAGE/software"
[[ -d $SW/user/liblitepcie ]] || { echo "no software tree at $SW; build the image first" >&2; exit 1; }
[[ -f $SW/user/liblitepcie/liblitepcie.a ]] || make -C "$SW/user" >/dev/null
gcc -O2 -Wall -g \
    -I"$SW/kernel" -I"$SW/user/liblitepcie" \
    -o "$SW/user/hbm_dma_stage" tools/ps2iop/hbm_dma_stage.c \
    "$SW/user/liblitepcie/liblitepcie.a" -lm
echo "built $SW/user/hbm_dma_stage"
