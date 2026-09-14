#!/bin/sh
# Steering bench: pp_steer against the original D-pad steering and the stick rates.
set -e
cd "$(dirname "$0")/.."
BUILD=build/sim_steer
verilator --cc --exe --build -j 0 -O2 -Wall -Wno-fatal --top-module pp_steer --Mdir "$BUILD" -o tb_steer \
    target/pocket/pp_steer.sv sim/tb_steer.cpp >/dev/null
"$BUILD/tb_steer"
