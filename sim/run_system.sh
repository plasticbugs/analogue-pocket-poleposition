#!/bin/sh
# Full-system bench: build the whole machine and run it.
#   sim/run_system.sh <frames> [tb_system options...]
# Output goes to build/sys/rtl_<frames>.ppm (and .txt with -ram).
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_system
mkdir -p build/sys
[ -f build/polepos.rom ] || python3 tools/mra_build.py polepos.mra polepos build/polepos.rom

RTL="$(ls rtl/*.sv rtl/*.v) modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v \
     modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v"

verilator --cc --exe --build -j 0 -O2 \
    -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module polepos_core --Mdir "$BUILD" -o tb_system \
    -Irtl -Imodules/cpu-tv80 $RTL sim/tb_system.cpp >/dev/null

frames=$1; shift
"$BUILD/tb_system" build/polepos.rom "$frames" "build/sys/rtl_$frames.ppm" "$@"
