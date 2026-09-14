#!/usr/bin/env python3
"""Per-sound levels from a recording of the service-mode sound test.

    sound_levels.py <stereo.wav> [first_frame=400] [frames_per_sound=120]

The test is driven by stepping the shifter LO->HI every frames_per_sound frames
from first_frame (tools/... svc3.lua and the bench's -in0file replay do this),
so sound N plays from first_frame + (N-1) * frames_per_sound. Prints DC-removed
RMS and peak of the left channel over each sound's window.
"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare_audio import read_wav

path = sys.argv[1]
f0 = int(sys.argv[2]) if len(sys.argv) > 2 else 400
per = int(sys.argv[3]) if len(sys.argv) > 3 else 120
rate, ch, c = read_wav(path)
fps = 6144000 / 384 / 264
for n in range(1, 21):
    t0 = (f0 + per * (n - 1)) / fps + 0.05
    t1 = t0 + per / fps - 0.1
    x = c[0][int(t0 * rate):int(t1 * rate)]
    if not x:
        break
    m = sum(x) / len(x)
    rms = math.sqrt(sum((v - m) ** 2 for v in x) / len(x))
    pk = max(abs(v - m) for v in x)
    print(f'sound {n:2d}  {t0:6.2f}-{t1:6.2f} s  rms {rms:7.0f}  peak {pk:6.0f}')
