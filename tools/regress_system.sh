#!/bin/sh
# Boot the game on both sides -- MAME and the RTL -- with the same input
# schedule, stop at the same frame, and compare memories and picture.
#
#   tools/regress_system.sh <frame> [attract|play]
#
# FRAME_SKEW is the RTL frame count that reproduces MAME frame N; see
# docs/verification.md for how it was measured.
set -e
cd "$(dirname "$0")/.."
frame=${1:-600}
script=${2:-attract}
skew=${FRAME_SKEW:-0}
OUT=build/sys
mkdir -p "$OUT" build/mamecfg
tag=$(printf "%s%05d" "$(echo $script | cut -c1)" "$frame")

rm -rf "$OUT/snap"
PP_OUT="$OUT" PP_FRAME="$frame" PP_SCRIPT="$script" \
mame polepos -rompath . -video none -sound none -nothrottle -skip_gameinfo -snapview native \
    -snapshot_directory "$OUT/snap" -cfg_directory build/mamecfg -nvram_directory "$OUT/nv_$tag" \
    -autoboot_script tools/dumpsys.lua > "$OUT/mame_$tag.log" 2>&1
grep -q '^\[pp\] done at frame' "$OUT/mame_$tag.log" || { echo "MAME stopped early, see $OUT/mame_$tag.log"; exit 1; }
mv "$(ls "$OUT"/snap/polepos/*.png | head -1)" "$OUT/mame_$tag.png"
rm -rf "$OUT/snap" "$OUT/nv_$tag"

rtl_frames=$((frame + skew))
sim/run_system.sh "$rtl_frames" -ram "$OUT/rtl_$tag.txt" -script "$script"
mv "build/sys/rtl_$rtl_frames.ppm" "$OUT/rtl_$tag.ppm"

python3 tools/diff_state.py "$OUT/rtl_$tag.txt" "$OUT/mame_$tag.txt" ${SKIP:+-skip "$SKIP"} || true
python3 tools/diff_frames.py "$OUT/rtl_$tag.ppm" "$OUT/mame_$tag.png" "$OUT/diff_$tag.png"
