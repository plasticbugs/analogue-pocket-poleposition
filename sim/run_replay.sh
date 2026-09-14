#!/bin/sh
# Replay a MAME sound-write log through the RTL and compare with MAME's audio.
#   sim/run_replay.sh <log> <mame.wav> <seconds>
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_replay
verilator --cc --exe --build -j 0 -O2 -Wno-fatal --top-module pp_sound --Mdir "$BUILD" -o tb_replay \
    +incdir+rtl -CFLAGS -I../../sim/sound \
    rtl/pp_ram.sv rtl/pp_biquad.sv rtl/pp_wsg.sv rtl/pp_engine.sv rtl/pp_discrete.sv rtl/pp_sound.sv \
    sim/sound/tb_replay.cpp >/dev/null
"$BUILD/tb_replay" build/polepos.rom "$1" build/sound/rtl.wav "${3:-20}"
python3 tools/sound/compare_audio.py build/sound/rtl.wav "$2"
