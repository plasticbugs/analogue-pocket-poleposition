#!/usr/bin/env python3
"""Find which RTL frame best reproduces a MAME frame.

    find_skew.py <dir> <mame_frame> [script letter]

Compares mame_<s><frame>.txt against every rtl_<s>NNNNN.txt in <dir> and
prints differing-entry counts per region, best match first.
"""
import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff_state import load

d, mf = sys.argv[1], int(sys.argv[2])
sc = sys.argv[3] if len(sys.argv) > 3 else 'a'
_, mr = load(os.path.join(d, f'mame_{sc}{mf:05d}.txt'))
rows = []
for p in sorted(glob.glob(os.path.join(d, f'rtl_{sc}*.txt'))):
    rf = int(os.path.basename(p)[5:10])
    _, rr = load(p)
    per = {k: sum(1 for a, b in zip(rr[k], mr[k]) if a != b) for k in mr}
    rows.append((sum(per.values()), rf, per))
rows.sort()
for tot, rf, per in rows[:8]:
    print(f'rtl {rf} (skew {rf - mf:+d}): {tot} differing  ' +
          ' '.join(f'{k}={v}' for k, v in per.items()))
