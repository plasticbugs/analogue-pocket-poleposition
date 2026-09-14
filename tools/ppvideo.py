"""Pole Position video model: the executable spec for the video hardware.

A direct transcription of MAME 0.288's polepos_v.cpp, together with the parts
of MAME's gfx decode, tilemap and indirect-palette machinery it relies on,
written so it can be read while writing RTL instead of re-deriving from C++.

Layer order is MAME's screen_update:
  1. background tilemap, opaque, bitmap rows 0..127 only
  2. road, bitmap rows 128..255
  3. 64 zoomed sprites, in table order (later entries win)
  4. alpha tilemap, transparent where the colour PROM gives 15

Coordinates are bitmap coordinates: the raster is 384x264 with 256x224 visible
at x 0..255, y 16..239.

No third-party modules: PNG in and out are done with zlib and struct.
"""
import os, zlib, struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')

# ---------------------------------------------------------------- .rom layout
# (offset, length) in the flat image built from polepos.mra
ROM_Z80      = (0x00000, 0x3000)
ROM_SUB1_E   = (0x03000, 0x2000)
ROM_SUB1_O   = (0x05000, 0x2000)
ROM_SUB2_E   = (0x07000, 0x2000)
ROM_SUB2_O   = (0x09000, 0x2000)
ROM_CHARS    = (0x0B000, 0x1000)
ROM_TILES    = (0x0C000, 0x1000)
ROM_SPR_S    = (0x0D000, 0x4000)   # planes 0+1 then planes 2+3, 0x2000 each
ROM_SPR_B    = (0x11000, 0xC000)   # planes 0+1 (0x6000) then planes 2+3 (0x6000)
ROM_ROAD     = (0x1D000, 0x5000)   # control 0x2000, bits1 0x2000, bits2 0x1000
ROM_SCALE    = (0x22000, 0x1000)
ROM_MCU      = (0x23000, 0x1000)
ROM_ENGINE   = (0x24000, 0x4000)
ROM_VOICE    = (0x28000, 0x6000)
PROM_RED     = (0x2E000, 0x100)
PROM_GREEN   = (0x2E100, 0x100)
PROM_BLUE    = (0x2E200, 0x100)
PROM_ALPHA   = (0x2E300, 0x100)
PROM_BG      = (0x2E400, 0x100)
PROM_VPOS_L  = (0x2E500, 0x100)
PROM_VPOS_M  = (0x2E600, 0x100)
PROM_VPOS_H  = (0x2E700, 0x100)
PROM_ROADCOL = (0x2E800, 0x400)
PROM_SPRCOL  = (0x2EC00, 0x400)
PROM_WAVE    = (0x2F000, 0x100)
ROM_SIZE     = 0x2F100

SCR_W, SCR_H = 384, 264
VIS_X0, VIS_X1 = 0, 256
VIS_Y0, VIS_Y1 = 16, 240
VIS_W, VIS_H = VIS_X1 - VIS_X0, VIS_Y1 - VIS_Y0


# ------------------------------------------------------------------- PNG i/o
def read_png(path):
    d = open(path, 'rb').read()
    pos, idat, plte = 8, b'', None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        if tag == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', d[pos + 8:pos + 18])
            ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
        elif tag == b'PLTE':
            plte = d[pos + 8:pos + 8 + ln]
        elif tag == b'IDAT':
            idat += d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * ch
    img = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        row = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f:
            for x in range(stride):
                a = row[x - ch] if x >= ch else 0
                b = prev[x]
                c = prev[x - ch] if x >= ch else 0
                if f == 1:   row[x] = (row[x] + a) & 0xff
                elif f == 2: row[x] = (row[x] + b) & 0xff
                elif f == 3: row[x] = (row[x] + (a + b) // 2) & 0xff
                elif f == 4:
                    pp = a + b - c
                    pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                    row[x] = (row[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))) & 0xff
        prev = row
        for x in range(w):
            o = (y * w + x) * 3
            if ct == 3:
                pi = row[x] * 3
                img[o:o + 3] = plte[pi:pi + 3]
            elif ct == 0:
                img[o:o + 3] = bytes([row[x]] * 3)
            else:
                img[o:o + 3] = row[x * ch:x * ch + 3]
    return w, h, img


def write_png(path, w, h, img):
    raw = b''.join(b'\x00' + bytes(img[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(tag, d):
        c = tag + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n'
                           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw, 6))
                           + chunk(b'IEND', b''))


def read_ppm(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'P6'):
        raise SystemExit(f'{path}: not a P6 ppm')
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(d) and d[i:i + 1].isspace():
            i += 1
        if d[i:i + 1] == b'#':
            while d[i:i + 1] != b'\n':
                i += 1
            continue
        j = i
        while not d[j:j + 1].isspace():
            j += 1
        fields.append(int(d[i:j]))
        i = j
    return fields[0], fields[1], bytearray(d[i + 1:])


# --------------------------------------------------------------------- ROM
class Rom:
    def __init__(self, path=None):
        path = path or os.path.join(ROOT, 'build', 'polepos.rom')
        d = open(path, 'rb').read()
        if len(d) != ROM_SIZE:
            raise SystemExit(f'{path}: expected {ROM_SIZE} bytes, got {len(d)}')
        cut = lambda r: d[r[0]:r[0] + r[1]]
        self.data = d
        self.chars, self.tiles = cut(ROM_CHARS), cut(ROM_TILES)
        self.road = cut(ROM_ROAD)
        self.scale = cut(ROM_SCALE)
        self.alpha_prom, self.bg_prom = cut(PROM_ALPHA), cut(PROM_BG)
        self.road_prom, self.spr_prom = cut(PROM_ROADCOL), cut(PROM_SPRCOL)

        # 128 physical colours (the upper 128 PROM entries are blanking black).
        # 2.2k/1k/470/220 ohm ladder, MAME weights 0x0e 0x1f 0x43 0x8f.
        def gun(v):
            return (0x0e * (v & 1) + 0x1f * ((v >> 1) & 1)
                    + 0x43 * ((v >> 2) & 1) + 0x8f * ((v >> 3) & 1))
        r, g, b = cut(PROM_RED), cut(PROM_GREEN), cut(PROM_BLUE)
        self.palette = [(gun(r[i]), gun(g[i]), gun(b[i])) for i in range(128)]

        # vertical position modifier: three nibble PROMs -> 12 bits
        vl, vm, vh = cut(PROM_VPOS_L), cut(PROM_VPOS_M), cut(PROM_VPOS_H)
        self.vpos = [vl[i] + (vm[i] << 4) + (vh[i] << 8) for i in range(256)]

        # MAME's big-sprite region is 0x10000 bytes with the planes 2+3 half
        # starting at 0x8000; the image packs out the two empty 0x2000 holes.
        big = cut(ROM_SPR_B)
        self.big_region = (big[0:0x6000] + bytes(0x2000) + big[0x6000:0xC000] + bytes(0x2000))
        self.small_region = cut(ROM_SPR_S)

        self.char_px = decode_2bpp(self.chars)
        self.tile_px = decode_2bpp(self.tiles)
        self.small_px = decode_sprites(self.small_region, 16)
        self.big_px = decode_sprites(self.big_region, 32)

    # indirect pen -> palette index, per MAME polepos_palette()
    def alpha_color(self, pen):          # pens 0x000-0x1ff
        c = self.alpha_prom[pen & 0xff]
        if c == 15:
            return 0x2f
        return (0x060 if pen & 0x100 else 0x020) + c

    def bg_color(self, pen):             # pens 0x200-0x2ff (relative)
        return self.bg_prom[pen & 0xff]

    def sprite_color(self, pen):         # pens 0x300-0xaff (relative)
        c = self.spr_prom[pen & 0x3ff]
        if c == 15:
            return 0x1f
        return (0x050 if pen & 0x400 else 0x010) + c

    def road_color(self, pen):           # pens 0xb00-0xeff (relative)
        return 0x040 + self.road_prom[pen & 0x3ff]


def _readbit(src, bit):
    return (src[bit >> 3] << (bit & 7)) & 0x80


def decode_2bpp(rom):
    """charlayout_2bpp: 8x8, planes {0,4}, x {0,1,2,3,64,65,66,67}, y*8, 128 bits.
    MAME plane 0 is the MSB of the pen."""
    xo = (0, 1, 2, 3, 64, 65, 66, 67)
    out = []
    for code in range(len(rom) * 8 // 128):
        base = code * 128
        px = [0] * 64
        for y in range(8):
            for x in range(8):
                o = base + y * 8 + xo[x]
                px[y * 8 + x] = ((2 if _readbit(rom, o) else 0) |
                                 (1 if _readbit(rom, o + 4) else 0))
        out.append(px)
    return out


def decode_sprites(region, size):
    """small/bigspritelayout: planes {0, 4, half+0, half+4}, x = 8*(x//4) + x%4,
    rows 2*size bits apart, charincrement size*2*size bits, RGN_FRAC(1,2)."""
    half = len(region) // 2 * 8
    inc = size * 2 * size
    out = []
    for code in range(half // inc):
        base = code * inc
        px = [0] * (size * size)
        for y in range(size):
            for x in range(size):
                o = base + y * 2 * size + 8 * (x // 4) + (x % 4)
                px[y * size + x] = ((8 if _readbit(region, o) else 0) |
                                    (4 if _readbit(region, o + 4) else 0) |
                                    (2 if _readbit(region, half + o) else 0) |
                                    (1 if _readbit(region, half + o + 4) else 0))
        out.append(px)
    return out


# ------------------------------------------------------------------- state
def load_state(path):
    """Read a dump written by tools/dumpstate.lua: 16-bit words per region."""
    regions, cur, meta = {}, None, {}
    for line in open(path):
        line = line.strip()
        if not line or line == 'END':
            continue
        if line.isupper() and line.isalpha():
            cur = line
            regions[cur] = []
        elif cur is None:
            k, _, v = line.partition(' ')
            meta[k] = v
        else:
            regions[cur] += [int(line[i:i + 4], 16) for i in range(0, len(line), 4)]
    st = State()
    st.frame = int(meta.get('frame', '0'))
    st.hscroll = int(meta.get('hscroll', '0'), 16)
    st.vscroll = int(meta.get('vscroll', '0'), 16)
    st.chacl = int(meta.get('chacl', '1'))
    st.sprite, st.road = regions['SPRITE'], regions['ROAD']
    st.alpha, st.view = regions['ALPHA'], regions['VIEW']
    return st


class State:
    pass


# ------------------------------------------------------------------ render
def render(rom, st):
    """Return the full 384x264 bitmap as palette indices (0..127)."""
    bm = [0] * (SCR_W * SCR_H)

    # 1. background: 64x16 tiles, TILEMAP_SCAN_COLS, x scroll mod 512,
    #    clipped to bitmap rows 0..127
    scroll = st.hscroll & 0xffff
    for y in range(0, 128):
        ty, py = y >> 3, y & 7
        row = y * SCR_W
        for x in range(0, 256):
            sx = (x + scroll) & 0x1ff
            tx, px = sx >> 3, sx & 7
            word = st.view[tx * 16 + ty]
            code = ((word & 0xff) | ((word & 0x4000) >> 6)) % 256
            color = ((word & 0x3f00) >> 8) % 64
            pix = rom.tile_px[code][py * 8 + px]
            bm[row + x] = rom.bg_color(color * 4 + pix)

    # 2. road
    for y in range(128, 256):
        yoffs = ((rom.vpos[y] + st.vscroll) >> 3) & 0x1ff
        roadpal = st.road[yoffs] & 15
        pen_base = roadpal << 6
        xoffs = st.road[0x380 + (y & 0x7f)] & 0x3ff
        xscroll = xoffs & 7
        xoffs &= ~7
        line = []
        for _ in range(256 // 8 + 1):
            if xoffs & 0x200:
                line += [pen_base] * 8
            else:
                romoffs = ((y & 0x7f) << 6) + ((xoffs & 0x1f8) >> 3)
                control = rom.road[romoffs]
                bits1 = rom.road[0x2000 + romoffs]
                bits2 = rom.road[0x4000 + ((romoffs & 0xfff) | ((romoffs & 0x1000) >> 1))]
                roadval = control & 0x3f
                carin = control >> 7
                for i in range(8, 0, -1):
                    bits = ((bits1 >> i) & 1) + (((bits2 >> i) & 1) << 1)
                    if not carin and bits:
                        bits += 1
                    line.append(pen_base | (roadval & 0x3f))
                    roadval += bits
            xoffs += 8
        row = y * SCR_W
        for x in range(256):
            bm[row + x] = rom.road_color(line[x + xscroll])

    # 3. sprites
    for i in range(64):
        py_w, px_w = st.sprite[0x380 + 2 * i], st.sprite[0x381 + 2 * i]
        sz0, sz1 = st.sprite[0x780 + 2 * i], st.sprite[0x781 + 2 * i]
        sx = (px_w & 0x3ff) - 0x40 + 4
        sy = 512 - (py_w & 0x1ff) + 1
        sizex = (sz1 & 0x3f00) >> 8
        sizey = (sz0 & 0x3f00) >> 8
        code = sz0 & 0x7f
        flipx = (sz0 >> 7) & 1
        color = sz1 & 0x3f
        if sy >= 128:
            color |= 0x40
        zoom_sprite(rom, bm, bool(sz0 & 0x8000), code, color, flipx, sx, sy, sizex, sizey)

    # 4. alpha: 32x32 tiles, TILEMAP_SCAN_ROWS, transparent where PROM == 15
    for ty in range(32):
        for tx in range(32):
            idx = ty * 32 + tx
            word = st.alpha[idx]
            code = (word & 0xff) | ((word & 0x4000) >> 6)
            color = (word & 0x3f00) >> 8
            if st.chacl == 0:
                code &= 0xff
                color = 0
            if idx >= 32 * 16:
                color |= 0x40
            code %= 256
            color %= 128
            px = rom.char_px[code]
            for py in range(8):
                y = ty * 8 + py
                row = y * SCR_W
                for pxx in range(8):
                    pen = color * 4 + px[py * 8 + pxx]
                    c = rom.alpha_color(pen)
                    if c != 0x2f:
                        bm[row + tx * 8 + pxx] = c
    return bm


def zoom_sprite(rom, bm, big, code, color, flipx, sx, sy, sizex, sizey):
    gfx = rom.big_px if big else rom.small_px
    w = 32 if big else 16
    data = gfx[code % len(gfx)]
    coloroffs = color * 16
    transmask = 0
    for pen in range(16):
        if rom.sprite_color(coloroffs + pen) == 0x1f:
            transmask |= 1 << pen
    offsxor = (0x1f if big else 0x0f) if flipx else 0
    for y in range(sizey + 1):
        yy = (sy + y) & 0x1ff
        if 0x10 <= yy < 0xf0:
            dy = rom.scale[(y << 6) + sizey] & 0x1f
            xx = sx & 0x3ff
            siz = 0
            offs = 0
            if not big:
                dy >>= 1
            row = dy * w
            for _ in range(0x40 if big else 0x20):
                if xx < 0x100:
                    pen = data[row + ((offs // 2) ^ offsxor)]
                    if not (transmask >> pen) & 1:
                        bm[yy * SCR_W + xx] = rom.sprite_color(coloroffs + pen)
                offs += 1
                siz = siz + 1 + sizex
                if siz & 0x40:
                    siz &= 0x3f
                    xx = (xx + 1) & 0x3ff


def to_rgb_visible(rom, bm):
    out = bytearray(VIS_W * VIS_H * 3)
    i = 0
    for y in range(VIS_Y0, VIS_Y1):
        row = y * SCR_W
        for x in range(VIS_X0, VIS_X1):
            r, g, b = rom.palette[bm[row + x]]
            out[i] = r; out[i + 1] = g; out[i + 2] = b
            i += 3
    return out
