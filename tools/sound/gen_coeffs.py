#!/usr/bin/env python3
"""Compute every filter coefficient and DAC table the Pole Position sound
hardware needs, straight from MAME's formulas, and emit them as a SystemVerilog
include and a C++ header so the RTL and the reference model cannot drift.

    tools/sound/gen_coeffs.py [--engine-rate 48000|24000]

MAME quirk: polepos_sound_device designs its three engine filters with
machine().sample_rate() (48 kHz) but steps them at OUTPUT_RATE (24 kHz), so on
a real MAME run the engine filter corners land at half their design frequency.
--engine-rate 48000 reproduces MAME exactly; 24000 gives the circuit's intended
response. The choice only changes the numbers in this file.
"""
import math, sys, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')

def RES_K(x): return x * 1000.0
def CAP_U(x): return x * 1e-6

# ---------------------------------------------------------------- engine
R166, R167, R168 = 1000.0, 2200.0, 4700.0
def shunt(r): return 1.0 / (1.0 / r + 1.0 / 250.0)
# MAME's volume_table: note the copy/paste in polepos_a.cpp -- R167_SHUNT and
# R168_SHUNT are both computed from R166. Reproduced exactly.
R166_SHUNT = shunt(R166)
R167_SHUNT = shunt(R166)
R168_SHUNT = shunt(R166)
VOLUME_TABLE = [
    (R168_SHUNT + R167_SHUNT + R166_SHUNT + 2200) / 10000,
    (R168_SHUNT + R167_SHUNT + R166       + 2200) / 10000,
    (R168_SHUNT + R167       + R166_SHUNT + 2200) / 10000,
    (R168_SHUNT + R167       + R166       + 2200) / 10000,
    (R168       + R167_SHUNT + R166_SHUNT + 2200) / 10000,
    (R168       + R167_SHUNT + R166       + 2200) / 10000,
    (R168       + R167       + R166_SHUNT + 2200) / 10000,
    (R168       + R167       + R166       + 2200) / 10000,
]
R_FILT_OUT = [RES_K(4.7), RES_K(7.5), RES_K(10)]
R_FILT_TOTAL = 1.0 / sum(1.0 / r for r in R_FILT_OUT)

FILTER_LOWPASS, FILTER_HIGHPASS, FILTER_BANDPASS = 0, 1, 2


def filter2(rate, ftype, fc, d, gain=1.0):
    """MAME calculate_filter2_coefficients / filter2_context::setup."""
    two_over_T = 2.0 * rate
    two_over_T_squared = two_over_T * two_over_T
    w = rate * 2.0 * math.tan(math.pi * fc / rate)
    w2 = w * w
    den = two_over_T_squared + d * w * two_over_T + w2
    a1 = 2.0 * (-two_over_T_squared + w2) / den
    a2 = (two_over_T_squared - d * w * two_over_T + w2) / den
    if ftype == FILTER_LOWPASS:
        b0 = b2 = w2 / den
        b1 = 2.0 * b0
    elif ftype == FILTER_BANDPASS:
        b0 = d * w * two_over_T / den
        b1 = 0.0
        b2 = -b0
    else:
        b0 = b2 = two_over_T_squared / den
        b1 = -2.0 * b0
    return dict(b0=b0 * gain, b1=b1 * gain, b2=b2 * gain, a1=a1, a2=a2)


def opamp_m_bandpass(rate, r1, r2, r3, c1, c2):
    """polepos_sound_device::filter2_context::opamp_m_bandpass_setup."""
    if r2 == 0:
        gain, r_in = 1.0, r1
    else:
        gain = r2 / (r1 + r2)
        r_in = 1.0 / (1.0 / r1 + 1.0 / r2)
    fc = 1.0 / (2 * math.pi * math.sqrt(r_in * r3 * c1 * c2))
    d = (c1 + c2) / math.sqrt(r3 / r_in * c1 * c2)
    gain *= -r3 / r_in * c2 / (c1 + c2)
    return filter2(rate, FILTER_BANDPASS, fc, d, gain), fc, d, gain


def opamp_filt_bp1m(rate, r1, r2, r3, rF, c1, c2):
    """DISCRETE_OP_AMP_FILTER with DISC_OP_AMP_FILTER_IS_BAND_PASS_1M, non-Norton.
    r_total is r1 || r2 || r3 (the bias resistor counts); the input is scaled by
    r_total/r1 before the biquad."""
    rt = 1.0 / r1
    if r2: rt += 1.0 / r2
    if r3: rt += 1.0 / r3
    rt = 1.0 / rt
    fc = 1.0 / (2 * math.pi * math.sqrt(rt * rF * c1 * c2))
    d = (c1 + c2) / math.sqrt(rF / rt * c1 * c2)
    gain = -rF / rt * c2 / (c1 + c2)
    co = filter2(rate, FILTER_BANDPASS, fc, d, gain)
    return co, rt, fc, d, gain


# --------------------------------------------------------------- discrete
DAC_54 = [RES_K(47), RES_K(22), RES_K(10), RES_K(4.7)]        # bits 0..3
DAC_52 = [RES_K(100), RES_K(47), RES_K(22), RES_K(10)]
DAC_R_54 = 1.0 / sum(1.0 / r for r in DAC_54)
DAC_R_52 = 1.0 / sum(1.0 / r for r in DAC_52)
VREF = 5.0 * (RES_K(1) / (RES_K(1.5) + RES_K(1)))
OP_AMP_VP_RAIL_OFFSET = 1.5

# The board's 4051 puts CHANL1..4 into a WSG voice in place of its waveform
# DAC, and the voice's four volume sections scale it (namco.cpp's header; MAME
# itself routes the discrete outputs straight to the speakers). To mix a volt of
# CHANL against WSG sample codes: the waveform DAC is a 4.7K/2.2K/1K/470 ladder
# off an LS273, so its 15 codes span the latch's high level -- taken as the same
# unmeasured 4 V MAME uses for the 54xx/52xx ladders. One WSG code times one
# volume step is 1/MIX_RES (1024) in stream units, before the 0.80 route.
WSG_CODES_PER_VOLT = 15.0 / 4.0
GAIN_ROUTE = WSG_CODES_PER_VOLT / 1024.0 * 0.80


def dac_r1(ladder, von=4.0):
    r_total = 1.0 / sum(1.0 / r for r in ladder)
    out = []
    for i in range(1 << len(ladder)):
        i_total = sum(von / ladder[b] for b in range(len(ladder)) if (i >> b) & 1)
        out.append(i_total * r_total)
    return out


CHANL_FILT = [
    # (r1, r2, r3, rF, c1, c2) for CHANL1..3 (54xx outputs 2, 1, 0)
    (DAC_R_54 + RES_K(22), 0, RES_K(12), RES_K(120), CAP_U(0.0022), CAP_U(0.0022)),
    (DAC_R_54 + RES_K(15), 0, RES_K(15), RES_K(120), CAP_U(0.022),  CAP_U(0.022)),
    (DAC_R_54 + RES_K(22), 0, RES_K(22), RES_K(180), CAP_U(0.047),  CAP_U(0.047)),
]


def main():
    engine_rate = 48000.0
    if '--engine-rate' in sys.argv:
        engine_rate = float(sys.argv[sys.argv.index('--engine-rate') + 1])

    lines_c, lines_sv = [], []
    report = []

    # engine filters: two op-amp bandpass sections and one 950 Hz highpass
    eng = []
    co, fc, d, g = opamp_m_bandpass(engine_rate, RES_K(220), RES_K(33), RES_K(390), CAP_U(.01), CAP_U(.01))
    eng.append(co); report.append(f'engine BP1 fc={fc:.1f} d={d:.3f} gain={g:.3f}')
    co, fc, d, g = opamp_m_bandpass(engine_rate, RES_K(150), RES_K(22), RES_K(330), CAP_U(.0047), CAP_U(.0047))
    eng.append(co); report.append(f'engine BP2 fc={fc:.1f} d={d:.3f} gain={g:.3f}')
    co = filter2(engine_rate, FILTER_HIGHPASS, 950, 1.0 / .707, 1.0)
    eng.append(co); report.append('engine HP3 fc=950 d=1.414')

    # discrete: three 54xx bandpass sections at 48 kHz
    disc = []
    for i, (r1, r2, r3, rF, c1, c2) in enumerate(CHANL_FILT):
        co, rt, fc, d, g = opamp_filt_bp1m(48000.0, r1, r2, r3, rF, c1, c2)
        disc.append((co, rt / r1))
        report.append(f'54xx CHANL{i+1} fc={fc:.1f} d={d:.3f} gain={g:.3f} rt/r1={rt/r1:.5f}')
    # 52xx: highpass 100 Hz then lowpass 1200 Hz
    hp52 = filter2(48000.0, FILTER_HIGHPASS, 100, 1.0 / 0.3)
    lp52 = filter2(48000.0, FILTER_LOWPASS, 1200, 1.0 / 0.8)

    def fmt(v, q):
        iv = int(round(v * (1 << q)))
        return iv

    Q_COEF = 30
    Q_VAL = 26

    h = ['// Generated by tools/sound/gen_coeffs.py -- do not edit',
         f'// engine filter design rate: {engine_rate:.0f} Hz', '#pragma once', '']
    h.append(f'static const double VREF = {VREF!r};')
    h.append(f'static const double R_FILT_TOTAL = {R_FILT_TOTAL!r};')
    h.append('static const double R_FILT_OUT[3] = {%s};' % ', '.join(repr(r) for r in R_FILT_OUT))
    h.append('static const double VOLUME_TABLE[8] = {%s};' % ', '.join(repr(v) for v in VOLUME_TABLE))
    h.append('static const double DAC54[16] = {%s};' % ', '.join(repr(v) for v in dac_r1(DAC_54)))
    h.append('static const double DAC52[16] = {%s};' % ', '.join(repr(v) for v in dac_r1(DAC_52)))
    for i, co in enumerate(eng):
        h.append('static const double ENG%d[5] = {%r, %r, %r, %r, %r};' % (i, co['b0'], co['b1'], co['b2'], co['a1'], co['a2']))
    for i, (co, scale) in enumerate(disc):
        h.append('static const double D54_%d[6] = {%r, %r, %r, %r, %r, %r};' % (i, co['b0'], co['b1'], co['b2'], co['a1'], co['a2'], scale))
    h.append('static const double D52_HP[5] = {%r, %r, %r, %r, %r};' % (hp52['b0'], hp52['b1'], hp52['b2'], hp52['a1'], hp52['a2']))
    h.append('static const double D52_LP[5] = {%r, %r, %r, %r, %r};' % (lp52['b0'], lp52['b1'], lp52['b2'], lp52['a1'], lp52['a2']))
    d54v = dac_r1(DAC_54)
    for i, (_, sc) in enumerate(disc):
        h.append('static const double D54_X%d[16] = {%s};' % (i, ', '.join(repr((d54v[n] - VREF) * sc) for n in range(16))))
    d52v = dac_r1(DAC_52)
    h.append('static const double D52_X[16] = {%s};' % ', '.join(repr(d52v[n] - VREF) for n in range(16)))
    # ---- SystemVerilog: fixed point
    s = ['// Generated by tools/sound/gen_coeffs.py -- do not edit',
         f'// engine filter design rate: {engine_rate:.0f} Hz',
         f'// coefficients are signed Q{Q_COEF}, voltages signed Q{Q_VAL}', '']
    s.append(f"localparam int Q_COEF = {Q_COEF};")
    s.append(f"localparam int Q_VAL  = {Q_VAL};")
    s.append(f"localparam logic signed [31:0] VREF_Q   = 32'sd{fmt(VREF, Q_VAL)};")
    # engine per-slot input mapping: x = vol*(3.4/255*data - 2)
    ka = [VOLUME_TABLE[s_] * 3.4 / 255.0 for s_ in range(8)]
    kb = [VOLUME_TABLE[s_] * -2.0 for s_ in range(8)]
    s.append("localparam logic signed [31:0] ENG_KA [0:7] = '{%s};" % ', '.join(f"32'sd{fmt(v, Q_COEF)}" for v in ka))
    s.append("localparam logic signed [31:0] ENG_KB [0:7] = '{%s};" % ', '.join(f"-32'sd{abs(fmt(v, Q_VAL))}" for v in kb))
    w = [(R_FILT_TOTAL / 2.0) / r for r in R_FILT_OUT]
    s.append("localparam logic signed [31:0] ENG_W  [0:2] = '{%s};" % ', '.join(f"32'sd{fmt(v, Q_COEF)}" for v in w))
    s.append("localparam logic signed [31:0] DAC54_Q [0:15] = '{%s};" % ', '.join(f"32'sd{fmt(v, Q_VAL)}" for v in dac_r1(DAC_54)))
    s.append("localparam logic signed [31:0] DAC52_Q [0:15] = '{%s};" % ', '.join(f"32'sd{fmt(v, Q_VAL)}" for v in dac_r1(DAC_52)))

    # biquad section table: 8 sections
    # 0..2 engine (24 kHz), 3..5 54xx (48 kHz), 6..7 52xx HP/LP (48 kHz)
    secs = []
    for co in eng:
        secs.append((co, 0.0, -2.0, 1.5, 0, 1))       # vref, lo, hi, clip_state, clip_out
    for co, scale in disc:
        secs.append((co, VREF, 0.0, 5.0 - OP_AMP_VP_RAIL_OFFSET, 1, 1))
    for co in (hp52, lp52):
        secs.append((co, 0.0, -8.0, 8.0, 0, 0))
    for name, idx in (('B0', 'b0'), ('B1', 'b1'), ('B2', 'b2'), ('A1', 'a1'), ('A2', 'a2')):
        s.append("localparam logic signed [31:0] %s_Q [0:7] = '{%s};" % (
            name, ', '.join(("32'sd%d" % fmt(c[0][idx], Q_COEF)) if fmt(c[0][idx], Q_COEF) >= 0
                            else ("-32'sd%d" % -fmt(c[0][idx], Q_COEF)) for c in secs)))
    s.append("localparam logic signed [31:0] VREF_S  [0:7] = '{%s};" % ', '.join(f"32'sd{fmt(c[1], Q_VAL)}" for c in secs))
    s.append("localparam logic signed [31:0] LO_S    [0:7] = '{%s};" % ', '.join(
        (f"32'sd{fmt(c[2], Q_VAL)}" if fmt(c[2], Q_VAL) >= 0 else f"-32'sd{-fmt(c[2], Q_VAL)}") for c in secs))
    s.append("localparam logic signed [31:0] HI_S    [0:7] = '{%s};" % ', '.join(f"32'sd{fmt(c[3], Q_VAL)}" for c in secs))
    s.append("localparam logic [7:0] CLIP_STATE = 8'b%s;" % ''.join('1' if c[4] else '0' for c in reversed(secs)))
    s.append("localparam logic [7:0] CLIP_OUT   = 8'b%s;" % ''.join('1' if c[5] else '0' for c in reversed(secs)))
    # 54xx input scaling r_total/r1 per section
    # Per-nibble input tables: (DAC - vRef) * (r_total/r1), so the RTL needs no
    # multiplier in front of the filters. CHANL1..3 take 54xx outputs 2,1,0.
    d54v = dac_r1(DAC_54)
    for i, (_, sc) in enumerate(disc):
        vals = [(d54v[n] - VREF) * sc for n in range(16)]
        s.append("localparam logic signed [31:0] D54_X%d [0:15] = '{%s};" % (
            i, ', '.join((f"32'sd{fmt(v, Q_VAL)}" if fmt(v, Q_VAL) >= 0 else f"-32'sd{-fmt(v, Q_VAL)}") for v in vals)))
    d52v = dac_r1(DAC_52)
    vals = [d52v[n] - VREF for n in range(16)]
    s.append("localparam logic signed [31:0] D52_X [0:15] = '{%s};" % ', '.join(
        (f"32'sd{fmt(v, Q_VAL)}" if fmt(v, Q_VAL) >= 0 else f"-32'sd{-fmt(v, Q_VAL)}") for v in vals))
    # section 7 (52xx low pass) takes section 6's output, not its own input
    s.append("localparam logic [7:0] CHAIN_MASK = 8'b10000000;")
    s.append(f"localparam logic signed [31:0] CLAMP52_HI = 32'sd{fmt(5.0 - OP_AMP_VP_RAIL_OFFSET - VREF, Q_VAL)};")
    s.append(f"localparam logic signed [31:0] GAIN52 = 32'sd{fmt(0.5, Q_COEF)};")
    # stream gains from the machine config, folded into the mixer
    s.append(f"localparam logic signed [31:0] GAIN_WSG  = 32'sd{fmt(0.80, Q_COEF)};")
    s.append(f"localparam logic signed [31:0] GAIN_ENG  = 32'sd{fmt(0.90 * 0.77, Q_COEF)};")
    s.append(f"localparam logic signed [31:0] GAIN_DISC = 32'sd{fmt(0.90 * (32767.0 / 2.0) / 32768.0, Q_COEF)};")
    # routed CHANL x summed volume steps, taken >>> 8 before this gain
    s.append(f"localparam logic signed [31:0] GAIN_ROUTE8 = 32'sd{fmt(GAIN_ROUTE * 256.0, Q_COEF)};")
    h.append(f'static const double GAIN_ROUTE = {GAIN_ROUTE!r};')

    # ---- WSG decimation FIR: 192 kHz -> 48 kHz, 32 taps, Hamming windowed sinc
    N, FC = 32, 20000.0 / 192000.0   # normalised cutoff (cycles/sample)
    taps = []
    for n in range(N):
        m = n - (N - 1) / 2.0
        v = 2 * FC if abs(m) < 1e-9 else math.sin(2 * math.pi * FC * m) / (math.pi * m)
        v *= 0.54 - 0.46 * math.cos(2 * math.pi * n / (N - 1))
        taps.append(v)
    g = sum(taps)
    taps = [t / g for t in taps]
    s.append("localparam int FIR_N = %d;" % N)
    s.append("localparam logic signed [17:0] FIR_Q [0:%d] = '{%s};" % (
        N - 1, ', '.join((f"18'sd{int(round(t * 65536))}" if t >= 0 else f"-18'sd{-int(round(t * 65536))}") for t in taps)))
    h.append('static const int FIR_N = %d;' % N)
    h.append('static const double FIR[%d] = {%s};' % (N, ', '.join(repr(t) for t in taps)))
    open(os.path.join(ROOT, 'sim', 'sound', 'pp_snd_coeffs.h'), 'w').write('\n'.join(h) + '\n')

    open(os.path.join(ROOT, 'rtl', 'pp_snd_coeffs.svh'), 'w').write('\n'.join(s) + '\n')
    print('\n'.join(report))
    print(f'VREF={VREF} DAC_R_54={DAC_R_54:.1f} DAC_R_52={DAC_R_52:.1f} R_FILT_TOTAL={R_FILT_TOTAL:.1f}')
    print('wrote rtl/pp_snd_coeffs.svh and sim/sound/pp_snd_coeffs.h')


if __name__ == '__main__':
    main()
