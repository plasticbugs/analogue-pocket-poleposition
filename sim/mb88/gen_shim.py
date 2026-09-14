#!/usr/bin/env python3
"""Extract MAME's MB88xx execution code verbatim into a standalone C++ include.

The reference model for the lockstep bench is MAME's own code, not a
re-transcription: the macro block and the bodies of the functions that define
behaviour are copied textually from ref/mame/mb88xx.cpp (MAME 0.288) and
compiled against the small fake device in mame_mb88.h.
"""
import re, sys, os

SRC = sys.argv[1] if len(sys.argv) > 1 else "ref/mame/mb88xx.cpp"
OUT = sys.argv[2] if len(sys.argv) > 2 else "build/mb88/mb88_mame.inc"
src = open(SRC).read()

out = ["// GENERATED from %s by sim/mb88/gen_shim.py -- do not edit\n" % SRC]

# the MACROS block
m = re.search(r"#define SERIAL_PRESCALE.*?#define INCPC\(\)[^\n]*\n", src, re.S)
if not m:
    sys.exit("macro block not found")
out.append(m.group(0))

FUNCS = ["device_reset", "serial_timer", "write_pla", "execute_set_input",
         "pio_enable", "increment_timer", "burn_cycles", "execute_run"]
for fn in FUNCS:
    # header line: "... mb88_cpu_device::fn(" possibly inside TIMER_CALLBACK_MEMBER(...)
    hm = re.search(r"^[^\n]*mb88_cpu_device::%s\b[^\n]*\n\{" % fn, src, re.M)
    if not hm:
        sys.exit("function %s not found" % fn)
    start = hm.start()
    # match braces from the opening brace
    i = hm.end() - 1
    depth = 0
    while True:
        c = src[i]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0: break
        i += 1
    out.append(src[start:i + 1] + "\n\n")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w").write("".join(out))
print("wrote", OUT)
