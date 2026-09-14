#!/usr/bin/env python3
"""Generate the Pocket artwork: the 36x36 core icon and the 521x165 platform
banner, raw 16-bit, five bits per gun with the top bit unused.

Drawn in greys on purpose: Analogue documents the pixel format as BGRA5551 but
the field order only shows up on hardware, and with r == g == b the two
candidate orders are indistinguishable. Colour can come once that is confirmed.

Nothing here is taken from the game's ROMs.

    tools/make_images.py          writes into pkg/pocket/
"""
import os, struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

FONT = {
    'A': ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    'C': ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    'E': ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    'I': ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    'L': ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    'M': ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    'N': ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    'O': ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    'P': ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    'S': ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    '1': ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    '2': ["01110", "10001", "00001", "00110", "01000", "10000", "11111"],
    '8': ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    '9': ["01110", "10001", "10001", "01111", "00001", "10001", "01110"],
    ' ': ["00000"] * 7,
}


def pack(rgb5):
    r, g, b = rgb5
    return struct.pack('<H', (r << 10) | (g << 5) | b)


class Img:
    def __init__(self, w, h, fill=(0, 0, 0)):
        self.w, self.h = w, h
        self.px = [fill] * (w * h)

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(self.h, y1)):
            for x in range(max(0, x0), min(self.w, x1)):
                self.px[y * self.w + x] = c

    def text(self, x, y, s, c, scale=1, spacing=1):
        cx = x
        for ch in s.upper():
            g = FONT.get(ch, FONT[' '])
            for row, bits in enumerate(g):
                for col, bit in enumerate(bits):
                    if bit == '1':
                        self.rect(cx + col * scale, y + row * scale,
                                  cx + (col + 1) * scale, y + (row + 1) * scale, c)
            cx += (len(g[0]) + spacing) * scale
        return cx

    def save(self, path):
        with open(path, 'wb') as f:
            for c in self.px:
                f.write(pack(c))


W = (31, 31, 31)
L = (24, 24, 24)
G = (16, 16, 16)
D = (7, 7, 7)
K = (0, 0, 0)


def road(img, x0, x1, y_top, y_bot, cx):
    """A road narrowing to a vanishing point at (cx, y_top), with kerb stripes."""
    h = y_bot - y_top
    for y in range(y_top, y_bot):
        t = (y - y_top) / h
        half = 2 + (x1 - x0) / 2 * t
        l, r = int(cx - half), int(cx + half)
        img.rect(l, y, r, y + 1, D)
        kerb = max(1, int(half / 8))
        stripe = W if int(t * t * 18) % 2 == 0 else G
        img.rect(l - kerb, y, l, y + 1, stripe)
        img.rect(r, y, r + kerb, y + 1, stripe)
        if int(t * t * 12) % 2 == 0:            # centre line dashes
            img.rect(int(cx) - max(1, kerb // 2), y, int(cx) + max(1, kerb // 2), y + 1, L)


def car(img, x, y, s):
    art = [
        "..XXXX..",
        "X.XXXX.X",
        "X..XX..X",
        "...XX...",
        "X.XXXX.X",
        "XXXXXXXX",
        "X.XXXX.X",
    ]
    for r, row in enumerate(art):
        for col, ch in enumerate(row):
            if ch == 'X':
                img.rect(x + col * s, y + r * s, x + (col + 1) * s, y + (r + 1) * s, W)


def main():
    core = os.path.join(ROOT, 'pkg', 'pocket', 'Cores', 'plasticbugs.poleposition')
    plats = os.path.join(ROOT, 'pkg', 'pocket', 'Platforms', '_images')
    os.makedirs(core, exist_ok=True)
    os.makedirs(plats, exist_ok=True)

    icon = Img(36, 36, K)
    icon.rect(0, 12, 36, 13, G)                 # horizon
    road(icon, 0, 36, 13, 36, 18)
    car(icon, 14, 24, 1)
    icon.save(os.path.join(core, 'icon.bin'))

    ban = Img(521, 165, K)
    for y in range(60):
        v = 1 + (y * 4) // 60
        ban.rect(0, y, 521, y + 1, (v, v, v))
    ban.rect(0, 60, 521, 61, G)
    road(ban, 0, 300, 61, 165, 120)
    car(ban, 96, 110, 6)
    ban.text(300, 40, 'POLE', W, scale=6, spacing=1)
    ban.text(300, 88, 'POSITION', W, scale=4, spacing=1)
    ban.text(300, 130, 'NAMCO 1982', G, scale=2, spacing=1)
    ban.save(os.path.join(plats, 'poleposition.bin'))
    for p in (os.path.join(core, 'icon.bin'), os.path.join(plats, 'poleposition.bin')):
        print('wrote', os.path.relpath(p, ROOT), os.path.getsize(p), 'bytes')


if __name__ == '__main__':
    main()
