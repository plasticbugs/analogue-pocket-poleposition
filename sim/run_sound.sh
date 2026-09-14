#!/bin/sh
# Sound bench: RTL against the MAME-transcribed reference model.
#   sim/run_sound.sh [samples]
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_sound
[ -f build/polepos.rom ] || python3 tools/mra_build.py polepos.mra polepos build/polepos.rom
verilator --cc --exe --build -j 0 -O2 \
    -Wno-fatal --top-module pp_sound --Mdir "$BUILD" -o tb_sound \
    +incdir+rtl -CFLAGS -I../../sim/sound \
    rtl/pp_ram.sv rtl/pp_biquad.sv rtl/pp_wsg.sv rtl/pp_engine.sv rtl/pp_discrete.sv rtl/pp_sound.sv \
    sim/sound/tb_sound.cpp >/dev/null
"$BUILD/tb_sound" build/polepos.rom "${1:-20000}" ${2:+--wav} ${2:-}
