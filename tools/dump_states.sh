#!/bin/sh
# Dump video states from MAME, checking that the run actually reached every
# frame asked for.  MAME sometimes ends a headless run early without saying
# so, which would otherwise show up much later as a missing state file.
#
#   [COIN=n START=n PLAY=n SERVICE=1 SVC_STEP=n] tools/dump_states.sh <dir> <frames,...> [extra mame args]
#
# Each run gets its own empty MAME cfg and nvram directories, so no setting
# saved by an earlier run (a service switch left on, an EEPROM changed in the
# test menu) leaks into this one (METHODOLOGY 5.29).  The states are gzipped
# afterwards; tools/moo_state.py reads either.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$1; frames=$2; shift 2
mkdir -p "$dir"
last=$(printf '%s' "$frames" | tr ',' '\n' | sort -n | tail -1)
# the K053252 retimes MAME's screen to 59.19 Hz, so frames/60 undercounts
secs=$(( last / 59 + 5 ))
for try in 1 2 3 4 5; do
    rm -f "$dir"/run.txt
    scratch=$(mktemp -d)
    DUMPFRAMES="$frames" DUMP_DIR="$dir" "$root/tools/mame.sh" \
        -seconds_to_run "$secs" -autoboot_script "$root/tools/dump_state.lua" \
        -cfg_directory "$scratch/cfg" -nvram_directory "$scratch/nvram" \
        "$@" >/dev/null 2>&1 || true
    rm -rf "$scratch"
    if [ -f "$dir/run.txt" ] && ! grep -q MISSING "$dir/run.txt"; then
        echo "$(grep '^frames' "$dir/run.txt"), all states present (attempt $try)"
        for f in "$dir"/state_*.bin; do gzip -9f "$f"; done
        exit 0
    fi
    echo "attempt $try incomplete, retrying" >&2
done
echo "error: MAME would not complete the run" >&2
exit 1
