#!/bin/sh
# Cabinet filter bench: responses of the four Cabinet Reverb low-pass settings.
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_cabfilter
F=platform/pocket/audio/filters
verilator --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-lint -Wno-style --top-module tb_cabfilter_top \
    --Mdir "$BUILD" -o tb_cabfilter \
    $F/arcade_filters.sv $F/iir_filter_tap.sv $F/iir_filter.sv $F/dc_blocker.sv $F/audio_mix.sv $F/audio_filters.sv \
    sim/tb_cabfilter_top.sv sim/tb_cabfilter.cpp >/dev/null
"$BUILD/tb_cabfilter"
