#!/bin/sh
# K054539 gate: MAME's own K054539 code (sim/k539_ref.cpp) and rtl/k054539.sv
# fed the same command log, compared sample by sample.
#
#   sim/check_k539.sh moomesa.rom [k539.log[.gz]] [secs]
#
# With no log, sim/k539_play40.log.gz: 40 s of attract and one player's play
# (101,193 writes) recorded from MAME 0.288 with the dump_state.lua inputs.
#
# The log comes from MAME: OUT=k539.log tools/mame.sh -seconds_to_run N
#   -autoboot_script tools/log_k054539.lua.  Pass: no sample more than 8 LSB
# from MAME's (the RTL's volume tables are Q16 roundings of MAME's doubles).
set -e
caller=$(pwd)
here=$(cd "$(dirname "$0")" && pwd)
rom=$1; lg=${2:-$here/k539_play40.log.gz}; secs=${3:-40}
case "$rom" in /*) ;; *) rom="$caller/$rom";; esac
case "$lg" in /*) ;; *) lg="$caller/$lg";; esac
tmp=$(mktemp -d)
case "$lg" in *.gz) gunzip -c "$lg" > "$tmp/k539.log"; lg="$tmp/k539.log";; esac
c++ -O2 -std=c++17 -o "$tmp/k539_ref" "$here/k539_ref.cpp"
"$tmp/k539_ref" "$rom" "$lg" "$secs" "$tmp/ref.wav"
"$here/run_k539.sh" "$rom" "$lg" -secs "$secs" -wav "$tmp/rtl.wav" 2>/dev/null | tail -1
python3 - "$tmp/ref.wav" "$tmp/rtl.wav" <<'PY'
import struct, math, sys
def rd(p):
    b = open(p, 'rb').read()[44:]
    return struct.unpack('<%dh' % (len(b) // 2), b)
a, b = rd(sys.argv[1]), rd(sys.argv[2])
n = min(len(a), len(b))
d = [abs(a[i] - b[i]) for i in range(n)]
sig = sum(x * x for x in a[:n]) / n
err = sum((a[i] - b[i]) ** 2 for i in range(n)) / n
snr = 10 * math.log10(sig / err) if err else float('inf')
print(f'{n // 2} stereo samples: max |RTL - MAME| {max(d)} LSB, rms MAME {math.sqrt(sig):.1f}, '
      f'rms difference {math.sqrt(err):.2f}, SNR {snr:.1f} dB')
sys.exit(0 if max(d) <= 8 else 1)
PY
rc=$?
rm -rf "$tmp"
exit $rc
