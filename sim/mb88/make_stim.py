#!/usr/bin/env python3
"""Turn a MAME capture (sim/namco/capture.lua) into per-chip MCU stimulus.

The lockstep bench runs one MB88xx at a time, so the 06xx is modelled here:
the capture's control/data writes are turned into the chip select, rw and
command-byte events the chip actually saw, on the MCU's own 256 kHz grid.

    make_stim.py <capture.txt> <chip 0..3> <out.txt>

Output lines, in tick order (ticks are MCU cycles, 256 kHz):
    <tick> S <sel> <rw>          chip select level, rw level
    <tick> W <byte>              host write to this chip
    <tick> V <vblank>            vblank level (51xx TC is its inverse)
    <tick> I <in0> <dswa> <dswb> <steer>
    <tick> R <0|1>               reset level (1 = held in reset)
"""
import sys

SYS = 49152000
MCU_DIV = 192          # 256 kHz
BASE_DIV = 1024        # 48 kHz, the 06xx base clock


def main():
    cap, chip, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    events = []
    control = 0
    running = False
    timer_state = False
    read_stretch = False
    period = 1
    next_tick = None          # next 06xx base tick index that fires
    sel = 0
    rw = 0
    last = {"sel": -1, "rw": -1, "vbl": -1, "in": None, "rst": -1}
    reset = 1

    def emit(t, s):
        events.append((t, s))

    def run_timer_until(now_sys):
        """advance the 06xx timer up to (not including) now_sys"""
        nonlocal next_tick, timer_state, read_stretch, sel, rw
        while running and next_tick is not None and next_tick * BASE_DIV < now_sys:
            t = next_tick * BASE_DIV
            timer_state = not timer_state
            if timer_state:
                rw = (control >> 4) & 1
            read_stretch = False
            sel = 1 if (control >> chip) & 1 and timer_state else 0
            if last["rw"] != rw or last["sel"] != sel:
                emit(t, "S %d %d" % (sel, rw))
                last["rw"], last["sel"] = rw, sel
            next_tick += period

    for line in open(cap):
        f = line.split()
        kind, t = f[0], int(f[1])
        run_timer_until(t)
        if kind == "W":
            val = int(f[3])
            if f[2] == "C":
                control = val
                if (control & 0xe0) == 0:
                    running = False
                    timer_state = False
                    next_tick = None
                    if last["sel"] != 0:
                        emit(t, "S 0 %d" % rw)
                        last["sel"] = 0
                else:
                    read_stretch = bool(control & 0x10)
                    running = True
                    period = 1 << (((control >> 5) & 7) - 1)
                    next_tick = t // BASE_DIV + 1
            else:
                if not (control & 0x10) and (control >> chip) & 1:
                    emit(t, "W %d" % val)
        elif kind == "L":
            if int(f[2]) == 1:
                reset = 0 if int(f[3]) else 1
                if last["rst"] != reset:
                    emit(t, "R %d" % reset)
                    last["rst"] = reset
        elif kind == "I":
            key = " ".join(f[2:6])
            if last["in"] != key:
                emit(t, "I " + key)
                last["in"] = key
        elif kind == "F":
            pass

    # vblank edges straight from the raster: 384x264 at 6.144 MHz
    line_sys = 8 * 384
    frame_sys = line_sys * 264
    end = events[-1][0] if events else 0
    f = 0
    while f * frame_sys < end:
        emit(f * frame_sys + 240 * line_sys, "V 1")
        emit((f + 1) * frame_sys + 16 * line_sys, "V 0")
        f += 1

    events.sort(key=lambda e: e[0])
    with open(out, "w") as fh:
        for t, s in events:
            fh.write("%d %s\n" % ((t + MCU_DIV - 1) // MCU_DIV, s))   # to MCU ticks
    print("wrote %s: %d events" % (out, len(events)))


main()
