#!/usr/bin/env python3
"""Render dumped Pole Position states and diff them against MAME's snapshots.

    tools/render_model.py artifacts/state_p02100.txt [more states...]

The MAME snapshot for state_<tag>.txt is taken to be mame_<tag>.png in the same
directory. Writes <state>_ref.png and, on a mismatch, <state>_diff.png with the
differing pixels marked. Exit status is 0 only when every render is
pixel-identical to MAME.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppvideo as pv


def diff(a, b, w, h, out_path):
    bad, cells = 0, {}
    out = bytearray(a)
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * 3
            if a[o:o + 3] != b[o:o + 3]:
                bad += 1
                out[o:o + 3] = b'\xff\x00\xff'
                cells[(x // 8, y // 8)] = cells.get((x // 8, y // 8), 0) + 1
    if bad:
        pv.write_png(out_path, w, h, out)
        top = sorted(cells.items(), key=lambda kv: -kv[1])[:12]
        print('  hotspots (8x8 cell -> count):',
              ', '.join(f'({cx},{cy})={n}' for (cx, cy), n in top))
    return bad


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rom = pv.Rom()
    fails = 0
    for state_path in sys.argv[1:]:
        st = pv.load_state(state_path)
        img = pv.to_rgb_visible(rom, pv.render(rom, st))
        base = os.path.splitext(state_path)[0]
        pv.write_png(base + '_ref.png', pv.VIS_W, pv.VIS_H, img)
        tag = os.path.basename(base)[len('state_'):]
        mame = os.path.join(os.path.dirname(state_path), f'mame_{tag}.png')
        if not os.path.exists(mame):
            print(f'---- {tag}: rendered, no MAME snapshot to compare')
            continue
        mw, mh, mimg = pv.read_png(mame)
        if (mw, mh) != (pv.VIS_W, pv.VIS_H):
            print(f'FAIL {tag}: MAME snapshot is {mw}x{mh}')
            fails += 1
            continue
        bad = diff(img, mimg, mw, mh, base + '_diff.png')
        if bad:
            print(f'FAIL {tag}: {bad} differing pixels -> {base}_diff.png')
            fails += 1
        else:
            print(f'OK   {tag}: 0 differing pixels')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
