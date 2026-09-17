#!/usr/bin/env bash
#
# The display and the rasteriser, fighting over gs_lmem's one read port.
#
#   sim/gs/run_contend.sh [--seed N] [--tags N]
#
# gs_lmem has one read port and gs_top now has three customers.  The rasteriser
# cannot be refused -- its port has no ready signal -- so it wins; PCRTC can be
# refused, which is what gs_pcrtc's rd_ready was added for; the host is last.
# A misrouted return would hand the rasteriser the display's pixel in the middle
# of a read-modify-write blend, which looks like a blender bug and is not one.
#
# The test: run the same GIF stream twice, once with the display idle and once
# with it reading the whole of a 64x64 raster, and require the framebuffer to
# come out bit-identical.  The display's *picture* is not checked here --
# run_pcrtc_diff.sh checks pictures against pcrtc_ref.py -- because what is
# being tested is the arbiter, not the CRTC.
#
# **And require that the fight actually happened.**  A PCRTC that never asked
# for memory would pass this trivially, so CRTCRD and CRTCSTALL are checked to
# be non-zero: the first says the display read at all, the second says it was
# refused at least once and therefore that the grant path was exercised.
#
# SPDX-License-Identifier: BSD-2-Clause
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SEED=1; TAGS=24
while [[ $# -gt 0 ]]; do case $1 in
  --seed) SEED=$2; shift 2;; --tags) TAGS=$2; shift 2;;
  *) echo "unknown: $1" >&2; exit 2;; esac; done

command -v xvhdl >/dev/null 2>&1 || . "$HOME/Xilinx/2026.1/Vivado/settings64.sh"
W="$HERE/work/contend$$"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
python3 "$HERE/gen_gif.py" --seed "$SEED" --tags "$TAGS" > packets.hex

xvhdl -2008 "$ROOT/rtl/gs/gs_addr_pkg.vhd" "$ROOT/rtl/gs/gs_edge_dda.vhd" \
      "$ROOT/rtl/gs/gs_chan_dda.vhd" "$ROOT/rtl/gs/gs_texaddr.vhd" "$ROOT/rtl/gs/gs_clut.vhd" "$ROOT/rtl/gs/gs_texsample.vhd" "$ROOT/rtl/gs/gs_texcache.vhd" "$ROOT/rtl/gs/gs_gif.vhd" \
      "$ROOT/rtl/gs/gs_lmem.vhd" "$ROOT/rtl/gs/gs_pcrtc.vhd" \
      "$ROOT/rtl/gs/gs_top.vhd" > xvhdl.log 2>&1 || { tail -20 xvhdl.log; exit 1; }
xvlog -sv "$HERE/tb_gs_top.sv" > xvlog.log 2>&1 || { tail -20 xvlog.log; exit 1; }
xelab -debug off tb_gs_top -s tb > xelab.log 2>&1 || { tail -30 xelab.log; exit 1; }

run () {   # $1 = 0 or 1, display off or on
   xsim tb -R -testplusarg "packets=packets.hex" -testplusarg "dumpbase=0" \
        -testplusarg "dumplen=16" -testplusarg "display=$1" \
        > "xsim$1.log" 2>&1 || { tail -30 "xsim$1.log"; exit 1; }
   if grep -q STALLED "xsim$1.log"; then
      echo "FAIL  seed $SEED display=$1: $(grep STALLED "xsim$1.log")"; exit 1
   fi
}
run 0
run 1

off=$(grep '^VMSUM' xsim0.log | awk '{print $2}')
on=$( grep '^VMSUM' xsim1.log | awk '{print $2}')
rd=$( grep '^CRTCRD' xsim1.log | awk '{print $2}')
st=$( grep '^CRTCSTALL' xsim1.log | awk '{print $2}')
px=$( grep '^PXCOUNT' xsim1.log | awk '{print $2}')
rd0=$(grep '^CRTCRD' xsim0.log | awk '{print $2}')

echo "  display off: framebuffer $off, crtc reads $rd0"
echo "  display on : framebuffer $on, crtc reads $rd, refused $st, pixels $px"

fail=0
[[ "$off" == "$on" ]] || { echo "FAIL  the display changed the framebuffer: $off -> $on"; fail=1; }
[[ "${rd0:-0}" == "0" ]] || { echo "FAIL  the display read memory while disabled ($rd0 reads)"; fail=1; }
[[ "${rd:-0}" -gt 0 ]]   || { echo "FAIL  the display never read memory, so nothing contended"; fail=1; }
[[ "${st:-0}" -gt 0 ]]   || { echo "FAIL  the display was never refused, so the grant path is untested"; fail=1; }
[[ "${px:-0}" -gt 0 ]]   || { echo "FAIL  the display produced no pixels"; fail=1; }
[[ $fail -eq 0 ]] || exit 1
echo "PASS  seed $SEED: $rd reads, $st refused, framebuffer unchanged at $on"
