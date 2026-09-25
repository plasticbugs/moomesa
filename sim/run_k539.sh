#!/bin/sh
# Replay MAME's K054539 command stream into rtl/k054539.sv (sim/tb_k539.cpp).
#   sim/run_k539.sh moomesa.rom k539.log [-secs S] [-wav out.wav] [-lat N]
set -e
caller=$(pwd)
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
verilator --cc --exe --build -j "${JOBS:-8}" -O3 --public-flat-rw \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -I"$root"/rtl --top-module k054539 -Mdir obj_k539 \
    "$root"/rtl/k054539.sv tb_k539.cpp > obj_k539.log 2>&1 || { grep -E "%Error" obj_k539.log | head; exit 1; }
rom=$1; lg=$2; shift 2
case "$rom" in /*) ;; *) rom="$caller/$rom";; esac
case "$lg" in /*) ;; *) lg="$caller/$lg";; esac
exec ./obj_k539/Vk054539 "$rom" "$lg" "$@"
