#!/bin/sh
# Build the MB88xx lockstep bench (RTL vs MAME's mb88xx.cpp execution code).
set -e
cd "$(dirname "$0")/../.."
python3 sim/mb88/gen_shim.py ref/mame/mb88xx.cpp build/mb88/mb88_mame.inc >/dev/null
verilator --cc --exe --build -j 0 -O2 --public-flat-rw -Wno-fatal \
    --top-module mb88 --Mdir build/mb88/obj -o tb_mb88 \
    -CFLAGS "-std=c++17 -O2 -I$PWD/sim/mb88 -I$PWD/build/mb88" \
    rtl/mb88.sv sim/mb88/tb_mb88.cpp >/dev/null
echo "built build/mb88/obj/tb_mb88"
