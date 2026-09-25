#!/bin/sh
# Fast whole-machine bench: rtl/moomesa_core.sv from reset against ideal
# memories.  For the game; sim/run_system.sh is the one with the real memory
# glue, and the one to pass before a flash.
#
#   sim/run_machine.sh moomesa.rom [-frames N] [-o DIR] [-snap a,b] [-every N] [-wav f] ...
set -e
caller=$(pwd)
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
. "$here/waivers.sh"
# TRACE=1 exposes the core's internals to the bench (-trace, -dump); it makes
# the simulation several times slower, so it is off by default
PUBLIC=""; MDIR=obj_machine
if [ -n "$TRACE" ]; then PUBLIC="--public-flat-rw -CFLAGS -DTRACE"; MDIR=obj_machine_trace; fi
MODS=$(ls "$root"/modules/*/*.v "$root"/modules/*/*.sv 2>/dev/null || true)
verilator --cc --exe --build -j "${JOBS:-8}" -O3 --x-assign fast --x-initial fast $PUBLIC \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD --no-assert-case \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    "$WAIVERS" -I"$root"/rtl --top-module moomesa_core -Mdir $MDIR -LDFLAGS -lz \
    "$root"/rtl/*.sv $MODS tb_machine.cpp > obj_machine.log 2>&1 \
    || { grep -E "%Error" obj_machine.log | head -30; tail -5 obj_machine.log; exit 1; }
# fx68k reads its microcode from the working directory
for f in "$root"/modules/cpu-fx68k/*.mem; do ln -sf "$f" "$here/$(basename "$f")"; done
rom=$1; shift
case "$rom" in /*) ;; *) rom="$caller/$rom";; esac
exec ./$MDIR/Vmoomesa_core "$rom" "$@"
