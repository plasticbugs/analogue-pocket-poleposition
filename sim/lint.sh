#!/bin/sh
# Lint the core with Verilator, locally and in CI from this one script.
#
# Warning names come and go between Verilator releases, and naming one the
# installed version does not know is a hard error, so each suppression is
# probed against the installed binary first. -Wno-fatal makes verilator exit 0
# regardless, so the output is filtered instead: findings in vendored modules/
# and platform/ are noise we do not control, findings in our own rtl/ and
# target/ fail the run.
set -e
cd "$(dirname "$0")/.."

SUPPRESS="DECLFILENAME UNUSEDSIGNAL VARHIDDEN PINCONNECTEMPTY PROCASSINIT TIMESCALEMOD SYNCASYNCNET GENUNNAMED UNUSEDPARAM"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'module probe; endmodule\n' > "$tmp/probe.v"

FLAGS="-Wall -Wno-fatal"
for w in $SUPPRESS; do
    if verilator --lint-only "-Wno-$w" "$tmp/probe.v" >/dev/null 2>&1; then
        FLAGS="$FLAGS -Wno-$w"
    else
        echo "note: this Verilator has no -Wno-$w, skipping it"
    fi
done

verilator --version
echo "lint flags: $FLAGS"

RTL="$(ls rtl/*.sv rtl/*.v) $(ls modules/cpu-tv80/tv80_core.v modules/cpu-tv80/tv80_alu.v modules/cpu-tv80/tv80_mcode.v modules/cpu-tv80/tv80_reg.v) ${STUBS:-}"

out=$tmp/lint.out
set +e
verilator --lint-only $FLAGS --top-module polepos_core -Irtl -Imodules/cpu-tv80 $RTL > "$out" 2>&1
set -e
cat "$out"
ours=$(grep -E '^%(Warning|Error)' "$out" | grep -vE ': *(modules|build)/' || true)
if [ -n "$ours" ]; then
    echo; echo "lint FAILED -- warnings in our own RTL:"; echo "$ours"; exit 1
fi

# The Pocket top level. core_pll is a Quartus megafunction Verilator cannot
# see, so that one message is ignored by text rather than by code.
out2=$tmp/lint_top.out
set +e
verilator --lint-only $FLAGS -Wno-PINMISSING --top-module core_top -Irtl -Imodules/cpu-tv80 \
    -y platform/pocket -y platform/pocket/interface -y platform/pocket/memory \
    -y platform/pocket/video -y platform/pocket/audio -y platform/pocket/helpers \
    -y platform/pocket/peripherals -y platform/pocket/support \
    $RTL target/pocket/pp_steer.sv target/pocket/core_top.sv > "$out2" 2>&1
set -e
top=$(grep -E '^%(Warning|Error)' "$out2" | grep -E ': *target/pocket/' \
      | grep -v 'Cannot find file containing module' || true)
if [ -n "$top" ]; then
    echo; echo "lint FAILED -- warnings in target/pocket/:"; echo "$top"; cat "$out2"; exit 1
fi
echo; echo "lint clean (warnings from vendored modules/ and platform/ ignored)"
