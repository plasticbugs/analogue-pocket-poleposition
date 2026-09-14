#!/bin/sh
# Frozen-state video bench: build once, then render every captured state in
# the RTL and diff it against MAME's snapshot.
#   sim/run_video.sh [state files...]     (default: artifacts/state_*.txt)
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
BUILD=build/sim_video
[ -f build/polepos.rom ] || python3 tools/mra_build.py polepos.mra polepos build/polepos.rom

verilator --cc --exe --build -j 0 -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-PROCASSINIT \
    --top-module tb_video_top --Mdir "$BUILD" -o tb_video \
    rtl/pp_ram.sv rtl/pp_video.sv sim/tb_video_top.sv sim/tb_video.cpp >/dev/null

states=${*:-$(ls "$OUT"/state_*.txt)}
fail=0
for s in $states; do
    tag=$(basename "$s" .txt); tag=${tag#state_}
    dir=$(dirname "$s")
    "$BUILD/tb_video" build/polepos.rom "$s" "build/rtl_$tag.ppm" || { echo "bench failed on $tag"; fail=1; }
    python3 tools/diff_frames.py "build/rtl_$tag.ppm" "$dir/mame_$tag.png" "build/rtl_${tag}_diff.png" || fail=1
done
[ $fail -eq 0 ] && echo "RTL matches MAME on every state" || echo "FAILURES"
exit $fail
