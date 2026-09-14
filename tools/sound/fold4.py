#!/usr/bin/env python3
"""Fold MAME's 4-channel polepos recording (front L, front R, rear L, rear R)
to the stereo the core outputs: L = (FL + RL) / 2, R = (FR + RR) / 2.

    fold4.py mame4.wav stereo.wav
"""
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__file__))
from compare_audio import read_wav

rate, ch, c = read_wav(sys.argv[1])
assert ch == 4, ch
n = len(c[0])
out = bytearray()
for i in range(n):
    out += struct.pack('<hh', (c[0][i] + c[2][i]) // 2, (c[1][i] + c[3][i]) // 2)
with open(sys.argv[2], 'wb') as f:
    f.write(b'RIFF' + struct.pack('<I', 36 + len(out)) + b'WAVEfmt ' +
            struct.pack('<IHHIIHH', 16, 1, 2, rate, rate * 4, 4, 16) + b'data' + struct.pack('<I', len(out)) + out)
