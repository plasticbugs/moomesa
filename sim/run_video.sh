#!/bin/sh
# Frozen-state video gate: every state in sim/states through rtl/moo_video.sv,
# each frame diffed against the picture MAME drew from it.  Zero differing
# pixels on every state, or it fails.  Every change to RTL that draws pixels
# goes through this before it is committed (CLAUDE.md).
#
#   sim/run_video.sh moomesa.rom [state ...] [-lat N]
#
# The RTL's frames land in artifacts/rtl/ as PNGs.
set -e
caller=$(pwd)
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
rom=$1; shift
[ -f "$rom" ] || { echo "usage: sim/run_video.sh moomesa.rom [state ...] [-lat N]" >&2; exit 2; }
case "$rom" in /*) ;; *) rom="$caller/$rom";; esac
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-BLKSEQ -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module moo_video -Mdir obj_video -LDFLAGS -lz \
    "$root"/rtl/moo_video.sv "$root"/rtl/moo_tiles.sv "$root"/rtl/moo_sprites.sv \
    "$root"/rtl/moo_mixer.sv tb_video.cpp > obj_video.log 2>&1 \
    || { tail -40 obj_video.log; exit 1; }
extra=""
states=""
while [ $# -gt 0 ]; do
    case "$1" in
        -lat) extra="$extra -lat $2"; shift 2;;
        -perturb) extra="$extra -perturb"; shift;;
        /*) states="$states $1"; shift;;
        *) states="$states $caller/$1"; shift;;
    esac
done
[ -n "$states" ] || states=$(ls "$root"/sim/states/*/state_*.bin.gz)
mkdir -p "$root/artifacts/rtl"
fail=0; n=0
for s in $states; do
    name=$(basename "$(dirname "$s")")_$(basename "$s" .bin.gz)
    n=$((n+1))
    ./obj_video/Vmoo_video "$rom" "$s" $extra -png "$root/artifacts/rtl/$name.png" || fail=$((fail+1))
done
echo "$n states, $((n-fail)) pixel-identical to MAME"
[ $fail -eq 0 ]
