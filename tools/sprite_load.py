#!/usr/bin/env python3
"""Sprite engine line budget, measured on dumped states.

    tools/sprite_load.py artifacts/state_*.txt

For every visible line: how many of the 64 sprites cross it, how many of those
are 32x32, and the clock cost of rendering that line with the engine in
rtl/pp_sprites.sv (constants below mirror it).
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppvideo as pv

SCAN = 3          # clocks per sprite slot tested and missed
HIT_BIG = 3 + 16 + 64 + 3
HIT_SMALL = 3 + 8 + 32 + 3


def main():
    worst = []
    for p in sys.argv[1:]:
        st = pv.load_state(p)
        n = [0] * 264
        nb = [0] * 264
        for i in range(64):
            sy = 512 - (st.sprite[0x380 + 2 * i] & 0x1ff) + 1
            sz0 = st.sprite[0x780 + 2 * i]
            sizey = (sz0 & 0x3f00) >> 8
            for y in range(sizey + 1):
                yy = (sy + y) & 0x1ff
                if 0x10 <= yy < 0xf0:
                    n[yy] += 1
                    nb[yy] += 1 if sz0 & 0x8000 else 0
        cost = [64 * SCAN + nb[y] * (HIT_BIG - SCAN) + (n[y] - nb[y]) * (HIT_SMALL - SCAN) for y in range(264)]
        y = max(range(264), key=lambda k: cost[k])
        worst.append((cost[y], max(n), os.path.basename(p), y, n[y], nb[y]))
    worst.sort(reverse=True)
    for c, m, name, y, k, b in worst[:12]:
        print(f'{name}: worst line {y} costs {c} clocks ({k} sprites, {b} big); busiest line has {m}')


if __name__ == '__main__':
    main()
