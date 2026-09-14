#!/usr/bin/env python3
"""Diff a 256x224 PPM from an RTL bench against a MAME snapshot.

    diff_frames.py rtl.ppm mame.png [diff.png]

Prints the worst 8x8 cells on a mismatch so the failure has somewhere to start.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppvideo as pv


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ppm, png = sys.argv[1], sys.argv[2]
    diff_out = sys.argv[3] if len(sys.argv) > 3 else os.path.splitext(ppm)[0] + '_diff.png'
    w, h, img = pv.read_ppm(ppm)
    mw, mh, mimg = pv.read_png(png)
    tag = os.path.basename(ppm)
    if (w, h) != (mw, mh):
        print(f'FAIL {tag}: size {w}x{h} vs MAME {mw}x{mh}')
        return 1
    bad, cells = 0, {}
    out = bytearray(img)
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * 3
            if img[o:o + 3] != mimg[o:o + 3]:
                bad += 1
                out[o:o + 3] = b'\xff\x00\xff'
                cells[(x // 8, y // 8)] = cells.get((x // 8, y // 8), 0) + 1
    if bad == 0:
        print(f'OK   {tag}: 0 differing pixels')
        return 0
    pv.write_png(diff_out, w, h, out)
    top = sorted(cells.items(), key=lambda kv: -kv[1])[:12]
    print(f'FAIL {tag}: {bad} differing pixels of {w*h} -> {diff_out}')
    print('  hotspots (8x8 cell -> count):',
          ', '.join(f'({cx},{cy})={n}' for (cx, cy), n in top))
    return 1


if __name__ == '__main__':
    sys.exit(main())
