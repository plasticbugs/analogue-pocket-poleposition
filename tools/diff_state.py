#!/usr/bin/env python3
"""Compare two machine-state dumps region by region.

    diff_state.py rtl.txt mame.txt [-skip REGION[:lo-hi],...]

Both files use the format tools/dumpsys.lua and sim/tb_system.cpp write: a few
"name value" header lines, then upper-case region names each followed by hex
rows. Word regions are 4 hex digits per entry, byte regions 2. Prints the first
differences of every region and exits 1 if any differ.

-skip names ranges that are legitimately different (a stack below SP, a frame
counter sampled at a different instant). Use it sparingly and say why.
"""
import sys


def load(path):
    meta, regions, cur, width = {}, {}, None, 4
    for line in open(path):
        line = line.strip()
        if not line or line == 'END':
            continue
        if line.isupper() and line[0].isalpha() and any(c not in '0123456789ABCDEF' for c in line):
            cur = line
            regions[cur] = []
            width = None
        elif cur is None:
            k, _, v = line.partition(' ')
            meta[k] = v
        else:
            if width is None:
                width = 2 if cur in ('Z80RAM', 'NVRAM') else 4
            regions[cur] += [int(line[i:i + width], 16) for i in range(0, len(line), width)]
    return meta, regions


def main():
    args = [a for a in sys.argv[1:]]
    skips = {}
    if '-skip' in args:
        i = args.index('-skip')
        for item in args[i + 1].split(','):
            name, _, rng = item.partition(':')
            lo, _, hi = rng.partition('-')
            skips.setdefault(name, []).append((int(lo, 0), int(hi, 0)) if rng else (0, 1 << 30))
        del args[i:i + 2]
    if len(args) < 2:
        sys.exit(__doc__)
    ma, ra = load(args[0])
    mb, rb = load(args[1])
    bad = 0
    for k in ('hscroll', 'vscroll', 'latch'):
        if ma.get(k) != mb.get(k):
            print(f'DIFF {k}: {ma.get(k)} vs {mb.get(k)}')
            bad += 1
    for name in ra:
        if name not in rb:
            print(f'DIFF {name}: missing from {args[1]}')
            bad += 1
            continue
        a, b = ra[name], rb[name]
        if len(a) != len(b):
            print(f'DIFF {name}: length {len(a)} vs {len(b)}')
            bad += 1
            continue
        diffs = [i for i in range(len(a)) if a[i] != b[i]
                 and not any(lo <= i < hi for lo, hi in skips.get(name, []))]
        if diffs:
            bad += 1
            show = ', '.join(f'[{i:04x}] {a[i]:04x}!={b[i]:04x}' for i in diffs[:8])
            print(f'DIFF {name}: {len(diffs)} entries: {show}')
        else:
            print(f'ok   {name}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
