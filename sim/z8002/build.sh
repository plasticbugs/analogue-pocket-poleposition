#!/bin/sh
# Build the Z8002 lockstep co-simulation harness.
set -e
cd "$(dirname "$0")/../.."
mkdir -p build/z8002/ref
python3 sim/z8002/gen_decode.py ref/mame rtl/z8002_dec.svh build/z8002/handlers.txt >/dev/null
python3 sim/z8002/gen_shim.py ref/mame build/z8002/ref >/dev/null
verilator --cc --exe --build -j 0 -O2 --public-flat-rw \
    -Wno-fatal -Irtl --Mdir build/z8002/obj --top-module z8002 -o tb_z8002 \
    -CFLAGS "-I../../../sim/z8002 -I../../../build/z8002/ref -I../../../ref/mame -O1 -w" \
    rtl/z8002.sv sim/z8002/tb_z8002.cpp build/z8002/ref/z8k_ref_gen.cpp >/dev/null
echo "built build/z8002/obj/tb_z8002"
