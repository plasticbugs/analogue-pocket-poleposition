#!/bin/sh
# Engine-only and discrete-only benches against the MAME transcription.
#   sim/run_disc_eng.sh
set -e
cd "$(dirname "$0")/.."
[ -f build/polepos.rom ] || python3 tools/mra_build.py polepos.mra polepos build/polepos.rom
verilator --cc --exe --build -j 0 -O2 -Wno-fatal --top-module pp_engine --Mdir build/sim_engine \
    -o tb_engine +incdir+rtl -CFLAGS -I../../sim/sound \
    rtl/pp_ram.sv rtl/pp_biquad.sv rtl/pp_engine.sv sim/sound/tb_engine.cpp >/dev/null
verilator --cc --exe --build -j 0 -O2 -Wno-fatal --top-module pp_discrete --Mdir build/sim_disc \
    -o tb_disc +incdir+rtl -CFLAGS -I../../sim/sound \
    rtl/pp_ram.sv rtl/pp_biquad.sv rtl/pp_discrete.sv sim/sound/tb_discrete.cpp >/dev/null
fail=0
for p in "0x2a 0x15" "0x3f 0x3f" "0x08 0x21" "0x1f 0x00" "0x00 0x01"; do
    build/sim_engine/tb_engine build/polepos.rom 8000 $p | tail -1 || fail=1
done
for r in 10 60 400 4000; do
    build/sim_disc/tb_disc 20000 $r | tail -1 || fail=1
done
exit $fail
