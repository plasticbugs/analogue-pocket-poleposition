#!/bin/sh
# Build the 06xx + customs replay bench.
set -e
cd "$(dirname "$0")/../.."
verilator --cc --exe --build -j 0 -O2 -Wno-fatal \
    --top-module namco_customs --Mdir build/namco/obj -o tb_replay \
    -CFLAGS "-std=c++17 -O2" \
    rtl/mb88.sv rtl/namco_06xx.sv rtl/namco_customs.sv sim/namco/tb_replay.cpp >/dev/null
echo "built build/namco/obj/tb_replay"
