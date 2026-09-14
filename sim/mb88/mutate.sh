#!/bin/sh
# Mutation check: prove the lockstep bench catches small RTL errors.
# Each mutation is applied to a scratch copy of rtl/mb88.sv; the bench must FAIL.
set -e
cd "$(dirname "$0")/../.."
python3 sim/mb88/gen_shim.py ref/mame/mb88xx.cpp build/mb88/mb88_mame.inc >/dev/null
mkdir -p build/mb88/mut
i=0
while IFS= read -r line; do
    from=${line%%@@*}; to=${line#*@@}
    [ -z "$from" ] && continue
    i=$((i+1))
    python3 - "$from" "$to" <<'PY'
import sys
s = open('rtl/mb88.sv').read()
f, t = sys.argv[1], sys.argv[2]
assert s.count(f) >= 1, f
open('build/mb88/mut/mb88.sv', 'w').write(s.replace(f, t, 1))
PY
    verilator --cc --exe --build -j 0 -O1 --public-flat-rw -Wno-fatal \
        --top-module mb88 --Mdir build/mb88/mut/obj -o tb \
        -CFLAGS "-std=c++17 -O1 -I$PWD/sim/mb88 -I$PWD/build/mb88" \
        build/mb88/mut/mb88.sv sim/mb88/tb_mb88.cpp >/dev/null 2>&1
    if build/mb88/mut/obj/tb directed 200 3 >/dev/null 2>&1 && build/mb88/mut/obj/tb random 300000 3 >/dev/null 2>&1; then
        echo "mutation $i NOT caught: $from -> $to"
    else
        echo "mutation $i caught"
    fi
done <<'LIST'
t8 = {4'd0, memv} - {4'd0, n_A} - {7'd0, n_cf};@@t8 = {4'd0, memv} - {4'd0, n_A} + {7'd0, n_cf};
n_st = ~t8[4];  n_Y = t8[3:0];@@n_st = t8[4];  n_Y = t8[3:0];
if (tsum >= 9'd32) begin@@if (tsum >= 9'd31) begin
n_PC = 6'h04;@@n_PC = 6'h05;
n_ser_on = (newpio[5:4] == 2'b10);@@n_ser_on = 1'b1;
if (n_SBcount >= 16'd4) begin@@if (n_SBcount >= 16'd5) begin
n_SP[n_SI] = intpc | {n_cf, n_zf, n_st, 13'd0};@@n_SP[n_SI] = intpc | {n_zf, n_cf, n_st, 13'd0};
if (!n_if && irq && n_pio[2])@@if (!n_if && irq && n_pio[1])
n_A = n_A & memv;  n_zf = (n_A == 4'd0);  n_st = ~n_zf;@@n_A = n_A | memv;  n_zf = (n_A == 4'd0);  n_st = ~n_zf;
n_st = ~memv[op[1:0]];@@n_st = memv[op[1:0]];
if (pla_index[4]) begin n_o_output[7:4] = n_A; n_o_we = 2'b10; end@@if (pla_index[4]) begin n_o_output[7:4] = n_A; n_o_we = 2'b01; end
n_vf = 1'b0; end           // tstv@@n_vf = n_vf; end           // tstv
n_credit = n_credit - 4'sd3;@@n_credit = n_credit - 4'sd2;
n_PA = {3'd0, SP[n_SI][10:6]};@@n_PA = {3'd0, SP[n_SI][11:7]};
if (n_SBcount >= SERIAL_DISABLE_THRESH)@@if (n_SBcount > SERIAL_DISABLE_THRESH)
n_A = rport(r_in, n_Y[1:0]);  n_r_re[n_Y[1:0]] = 1'b1;@@n_A = rport(r_in, n_Y[1:0]);  n_r_re[n_Y[1:0]] = 1'b0;
LIST
