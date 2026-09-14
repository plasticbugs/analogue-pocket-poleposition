#!/bin/sh
# Capture a spread of machine states + matching MAME snapshots.
#
#   tools/capture_states.sh                       default spread
#   SCRIPT=play FRAMES="1200 1500" tools/capture_states.sh
#
# One MAME run per input script; every frame listed is dumped from that run.
# Snapshots come out numbered in capture order and are renamed to the frame.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
ROMPATH=${ROMPATH:-.}
mkdir -p "$OUT" build/mamecfg

run() {
    script=$1; shift
    frames="$*"
    snapdir="$OUT/snap_$script"
    rm -rf "$snapdir"
    PP_OUT="$OUT" PP_FRAMES="$frames" PP_SCRIPT="$script" \
    mame polepos -rompath "$ROMPATH" -video none -sound none -nothrottle -skip_gameinfo -snapview native \
        -snapshot_directory "$snapdir" -cfg_directory build/mamecfg \
        -nvram_directory build/mamecfg/nv_$script -autoboot_script tools/dumpstate.lua \
        >"$OUT/mame_$script.log" 2>&1
    rm -rf build/mamecfg/nv_$script
    # A MAME that is sent SIGTERM exits cleanly, so exit status proves nothing:
    # only the script's own completion line does.
    grep -q '^\[pp\] done at frame' "$OUT/mame_$script.log" || {
        echo "MAME stopped early (see $OUT/mame_$script.log)"; exit 1; }
    set -- $(ls "$snapdir"/polepos/*.png | sort)
    for f in $frames; do
        tag=$(printf "%s%05d" "$(echo $script | cut -c1)" "$f")
        [ -n "$1" ] || { echo "missing snapshot for frame $f"; exit 1; }
        mv "$1" "$OUT/mame_$tag.png"; shift
        echo "captured $script $tag"
    done
    rm -rf "$snapdir"
}

if [ -n "$FRAMES" ]; then
    run "${SCRIPT:-attract}" $FRAMES
else
    run attract 300 600 900 1200 1800 2400 3000 3600
    run play 1200 1500 1800 2100 2400 2700 3000
fi
