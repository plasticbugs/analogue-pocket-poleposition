#!/bin/sh
# Z8002 lockstep regression against MAME's own z8000 code.
#
#   sim/z8002/regress.sh          quick set (about a minute)
#   sim/z8002/regress.sh full     adds the long ROM runs (about three minutes)
set -e
cd "$(dirname "$0")/../.."
./sim/z8002/build.sh
TB=build/z8002/obj/tb_z8002
fail=0

run() { echo "== $*"; $TB "$@" || fail=1; }

# every DAB input, then every first word MAME can dispatch (random states)
run dab
run directed 1 4
run directed 2 4
# random code and data, with interrupt line events at instruction boundaries
for seed in 8 9 10 11 12 13; do run random 100000 $seed --irq; done

# the game's own code, from reset, with NVI once per frame
if [ ! -f build/z8002/sub1.bin ]; then
    python3 - <<'EOF'
def inter(hi, lo, out):
    a = open('polepos/' + hi, 'rb').read()
    b = open('polepos/' + lo, 'rb').read()
    d = bytearray(0x8000)
    for i in range(len(a)):
        d[2 * i] = a[i]
        d[2 * i + 1] = b[i]
    open(out, 'wb').write(bytes(d))
inter('pp3_2.8l', 'pp3_1.8m', 'build/z8002/sub1.bin')
inter('pp3_6.4l', 'pp3_5.4m', 'build/z8002/sub2.bin')
EOF
fi
N=300000
[ "$1" = full ] && N=3000000
run rom build/z8002/sub1.bin $N
run rom build/z8002/sub2.bin $N

[ $fail -eq 0 ] && echo "z8002: all campaigns match MAME" || echo "z8002: DIVERGENCE"
exit $fail
