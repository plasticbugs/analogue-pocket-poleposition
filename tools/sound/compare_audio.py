#!/usr/bin/env python3
"""Compare two multi-channel 16-bit wavs: DC-removed RMS and per-band energy.

    compare_audio.py rtl.wav mame.wav [start_s] [end_s]

Both are box-decimated to 8 kHz before the band analysis, which also discards
the ultrasonic content MAME's resampler has already removed. A flat ratio
across the bands is a level error; a sloping one is a filter error.
"""
import sys, struct, math, cmath


def read_wav(path):
    d = open(path, 'rb').read()
    pos, fmt, data = 12, None, None
    while pos < len(d) - 8:
        cid = d[pos:pos + 4]
        sz = struct.unpack('<I', d[pos + 4:pos + 8])[0]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', d[pos + 8:pos + 24])
        elif cid == b'data':
            data = d[pos + 8:pos + 8 + sz]
            break
        pos += 8 + sz + (sz & 1)
    ch, rate = fmt[1], fmt[2]
    n = len(data) // 2 // ch
    samples = struct.unpack('<%dh' % (n * ch), data[:n * ch * 2])
    return rate, ch, [list(samples[c::ch]) for c in range(ch)]


def dc_removed_rms(x):
    if not x:
        return 0.0
    m = sum(x) / len(x)
    return math.sqrt(sum((v - m) ** 2 for v in x) / len(x))


def decimate(x, factor):
    """Box-average by an integer factor: drops the ultrasonic content MAME's
    resampler has already removed, and keeps the FFT small enough for pure
    Python."""
    out = []
    for i in range(0, len(x) - factor + 1, factor):
        out.append(sum(x[i:i + factor]) / factor)
    return out


def band_energy(x, rate, bands):
    if rate >= 48000:
        x = decimate(x, 6)
        rate //= 6
    n = min(len(x), 1 << (len(x).bit_length() - 1))
    x = x[:n]
    m = sum(x) / n
    x = [(v - m) * (0.5 - 0.5 * math.cos(2 * math.pi * i / n)) for i, v in enumerate(x)]
    # simple radix-2 FFT
    def fft(a):
        n = len(a)
        if n == 1:
            return a
        ev, od = fft(a[0::2]), fft(a[1::2])
        out = [0] * n
        for k in range(n // 2):
            t = cmath.exp(-2j * math.pi * k / n) * od[k]
            out[k] = ev[k] + t
            out[k + n // 2] = ev[k] - t
        return out
    sp = fft([complex(v) for v in x])
    out = []
    for lo, hi in bands:
        klo = min(int(lo * n / rate), n // 2)
        khi = min(int(hi * n / rate), n // 2)
        out.append(sum(abs(sp[k]) ** 2 for k in range(klo, max(khi, klo + 1))))
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    r1, c1, a = read_wav(sys.argv[1])
    r2, c2, b = read_wav(sys.argv[2])
    t0 = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    t1 = float(sys.argv[4]) if len(sys.argv) > 4 else min(len(a[0]) / r1, len(b[0]) / r2)
    bands = [(100, 300), (300, 800), (800, 2000), (2000, 5000), (5000, 12000)]
    print(f'{sys.argv[1]}: {c1} ch @ {r1} Hz, {len(a[0])/r1:.2f} s')
    print(f'{sys.argv[2]}: {c2} ch @ {r2} Hz, {len(b[0])/r2:.2f} s')
    print(f'window {t0:.2f}..{t1:.2f} s')
    for c in range(min(c1, c2)):
        xa = a[c][int(t0 * r1):int(t1 * r1)]
        xb = b[c][int(t0 * r2):int(t1 * r2)]
        ra, rb = dc_removed_rms(xa), dc_removed_rms(xb)
        ea = band_energy(xa, r1, bands)
        eb = band_energy(xb, r2, bands)
        ratios = ' '.join(f'{(x / y) ** 0.5:5.2f}' if y > 0 else '  inf' for x, y in zip(ea, eb))
        db = 20 * math.log10(ra / rb) if rb > 0 and ra > 0 else float('nan')
        print(f'  ch{c}: rms rtl {ra:8.1f} mame {rb:8.1f} ratio {ra/rb if rb else 0:5.3f} ({db:+.2f} dB) | band ratios {ratios}')


if __name__ == '__main__':
    main()
