// Reference model of the Pole Position sound hardware, transcribed from MAME
// 0.288 (namco.cpp polepos_wsg_device, polepos_a.cpp engine + discrete nodes).
// Double precision, one function per MAME stream update, so the RTL can be
// held to it sample by sample.
#pragma once
#include <cstdint>
#include <cmath>
#include <cstring>
#include <vector>
#include "pp_snd_coeffs.h"

namespace ppsnd {

// ------------------------------------------------------------------ WSG
// MAME: 8 voices, internal rate 192 kHz (clock 48 kHz x 4), 17 fractional bits,
// stream.add_int(..., waveform * volume, MIX_RES=1024).
struct Wsg {
    uint8_t regs[0x40] = {0};
    const uint8_t *wave = nullptr;   // 256-byte PROM, low nibble
    bool enable = false;
    uint32_t counter[8] = {0};

    void write(unsigned offset, uint8_t data) { regs[offset & 0x3f] = data; }

    int volume(int ch, int which) const {
        if (regs[ch * 4 + 0x23] & 8) return 0;       // 54xx/52xx selected: silent
        switch (which) {
            case 0: return regs[ch * 4 + 0x03] >> 4;
            case 1: return regs[ch * 4 + 0x03] & 0x0f;
            case 2: return regs[ch * 4 + 0x23] >> 4;
            default: return regs[ch * 4 + 0x02] >> 4;
        }
    }

    // one 192 kHz sample into out[4]
    void step(double out[4]) {
        out[0] = out[1] = out[2] = out[3] = 0.0;
        if (!enable) return;
        for (int ch = 0; ch < 8; ch++) {
            int v[4];
            bool any = false;
            for (int i = 0; i < 4; i++) { v[i] = volume(ch, i); any |= v[i] != 0; }
            unsigned freq = regs[ch * 4 + 0x00] | (regs[ch * 4 + 0x01] << 8);
            unsigned sel = regs[ch * 4 + 0x23] & 7;
            unsigned pos = (counter[ch] >> 17) & 0x1f;
            int w = (wave[(sel * 32 + pos) & 0xff] & 0x0f) - 8;
            for (int i = 0; i < 4; i++)
                if (v[i]) out[i] += double(w * v[i]) / 1024.0;
            // MAME only advances the counter inside namco_update_one, which is
            // called only for non-zero volumes: a fully silent voice freezes.
            if (any) counter[ch] = (counter[ch] + freq) & 0x3fffff;
        }
    }
};

// -------------------------------------------------------------- biquads
struct Biquad {
    double b0 = 0, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    void set(const double c[5]) { b0 = c[0]; b1 = c[1]; b2 = c[2]; a1 = c[3]; a2 = c[4]; }
    // MAME's filter2_context::step: history keeps the unclipped output
    double step(double x) {
        double y = -a1 * y1 - a2 * y2 + b0 * x + b1 * x1 + b2 * x2;
        x2 = x1; x1 = x; y2 = y1; y1 = y;
        return y;
    }
    // MAME's DST_OP_AMP_FILT BAND_PASS_1M: output is offset by vRef, clipped to
    // the rails, and the clipped value (minus vRef) is what goes into y1.
    double step_opamp(double v, double vref, double lo, double hi) {
        double out = -a1 * y1 - a2 * y2 + b0 * v + b1 * x1 + b2 * x2 + vref;
        x2 = x1; x1 = v; y2 = y1;
        if (out > hi) out = hi;
        if (out < lo) out = lo;
        y1 = out - vref;
        return out;
    }
};

// ----------------------------------------------------------- engine
struct Engine {
    const uint8_t *rom = nullptr;    // 16384 bytes
    uint32_t position = 0;
    uint8_t msb = 0, lsb = 0;
    bool enable = false;
    Biquad f[3];

    Engine() { f[0].set(ENG0); f[1].set(ENG1); f[2].set(ENG2); }

    void write_lsb(uint8_t d) { lsb = d & 62; enable = d & 1; }
    void write_msb(uint8_t d) { msb = d & 63; }
    // LS259 Q2 falling edge: MAME's clson_w(0) zeroes both registers
    void clson(bool state) { if (!state) { write_lsb(0); write_msb(0); } }

    // one 24 kHz sample
    double step() {
        if (!enable) return 0.0;
        uint32_t clock = (3072000u / 16u) * ((msb + 1) * 64 + lsb + 1) / (64 * 64);
        uint32_t step_ = (clock << 12) / 24000u;
        unsigned slot = (msb >> 3) & 7;
        double volume = VOLUME_TABLE[slot];
        const uint8_t *base = rom + slot * 0x800;
        double x = (3.4 / 255 * base[(position >> 12) & 0x7ff] - 2) * volume;
        double i_total = 0;
        for (int i = 0; i < 3; i++) {
            double y = f[i].step(x);
            if (y > 1.5) y = 1.5;
            if (y < -2) y = -2;
            i_total += y / R_FILT_OUT[i];
        }
        i_total *= R_FILT_TOTAL / 2;
        position += step_;
        return i_total;
    }
};

// --------------------------------------------------------- discrete
struct Discrete {
    Biquad ch[3];      // 54xx band-pass sections (CHANL1..3)
    Biquad hp, lp;     // 52xx
    double scale[3];

    const double *x54[3] = {D54_X0, D54_X1, D54_X2};

    Discrete() {
        const double *c[3] = {D54_0, D54_1, D54_2};
        for (int i = 0; i < 3; i++) { ch[i].set(c[i]); scale[i] = c[i][5]; }
        hp.set(D52_HP);
        lp.set(D52_LP);
    }

    // one 48 kHz sample. n54[0..2] = NAMCO_54XX_0/1/2_DATA, n52 = 52xx P.
    // Returns the four discrete outputs already scaled as MAME's
    // DISCRETE_OUTPUT(node, 32767/2) writes them into the stream.
    void step(const int n54[3], int n52, double out[4]) {
        // CHANL1 <- 54xx_2, CHANL2 <- 54xx_1, CHANL3 <- 54xx_0
        const int order[3] = {2, 1, 0};
        for (int i = 0; i < 3; i++) {
            double v = x54[i][n54[order[i]] & 15];
            double o = ch[i].step_opamp(v, VREF, 0.0, 5.0 - 1.5);
            out[i] = o - VREF;
        }
        double v = D52_X[n52 & 15];
        v = hp.step(v);
        v = lp.step(v);
        v *= 0.5;
        if (v < 0) v = 0;
        double clamp_hi = 5.0 - 1.5 - VREF;
        if (v > clamp_hi) v = clamp_hi;
        out[3] = v;
    }
};

// ------------------------------------------------------------ machine
// Routes, from the polepos machine config:
//   WSG out n      -> speaker channel n, gain 0.80  (0,1 = front L/R, 2,3 = rear)
//   engine         -> every speaker channel, gain 0.90 * 0.77
//   discrete, board (default): CHANL c through the volume sections of every
//                  voice whose 4051 selects it, GAIN_ROUTE per volt per step
//   discrete, mame_mix: all four outputs to every speaker channel, gain 0.90
struct Machine {
    Wsg wsg;
    Engine engine;
    Discrete discrete;
    int n54[3] = {0, 0, 0};
    int n52 = 0;
    bool mame_mix = false;

    // decimation state for the 192 kHz WSG
    double fir_hist[4][FIR_N] = {{0}};
    double fir_latch[4] = {0, 0, 0, 0};
    int fir_pos = 0;

    // engine 24 kHz -> 48 kHz linear interpolation
    double eng_prev = 0, eng_cur = 0;
    int eng_phase = 0;

    double dc_x1_l = 0, dc_x1_r = 0, dc_y_l = 0, dc_y_r = 0;
    // last values of each block, for bench traces
    double last_wsg0 = 0, last_dsum = 0, last_eng = 0;

    // Produce one 48 kHz output sample set (4 speaker channels).
    void step48(double spk[4]) {
        double acc[4] = {0, 0, 0, 0};
        // pp_wsg.sv filters right after the first of the four 192 kHz ticks in
        // a sample period, so the model decimates on the same phase.
        for (int k = 0; k < 4; k++) {
            double w[4];
            wsg.step(w);
            for (int c = 0; c < 4; c++) fir_hist[c][fir_pos] = w[c];
            fir_pos = (fir_pos + 1) % FIR_N;
            if (k == 0) {
                for (int c = 0; c < 4; c++) {
                    double sum = 0;
                    for (int i = 0; i < FIR_N; i++)
                        sum += FIR[i] * fir_hist[c][(fir_pos + i) % FIR_N];
                    fir_latch[c] = sum;
                }
            }
        }
        for (int c = 0; c < 4; c++) {
            acc[c] = fir_latch[c] * 0.80;
            if (c == 0) last_wsg0 = fir_latch[c];
        }
        // the 24 kHz stream lands on every other output sample; the one in
        // between is the midpoint, exactly as pp_sound.sv interpolates
        double e;
        if (eng_phase == 0) { eng_prev = eng_cur; eng_cur = engine.step(); e = eng_cur; }
        else                { e = (eng_prev + eng_cur) * 0.5; }
        eng_phase ^= 1;
        double d[4];
        discrete.step(n54, n52, d);
        double dsum = d[0] + d[1] + d[2] + d[3];
        last_dsum = dsum;
        last_eng = e;
        const double gain_disc = 0.90 * (32767.0 / 2.0) / 32768.0;
        double routed[4] = {0, 0, 0, 0};
        if (!mame_mix && wsg.enable) {
            for (int ch = 0; ch < 8; ch++) {
                uint8_t sel = wsg.regs[ch * 4 + 0x23];
                if (!(sel & 8)) continue;
                const int vol[4] = {wsg.regs[ch * 4 + 0x03] >> 4, wsg.regs[ch * 4 + 0x03] & 0x0f,
                                    sel >> 4, wsg.regs[ch * 4 + 0x02] >> 4};
                const double boost = ((sel & 3) == 1) ? 4.0 : 1.0;   // CHANL2, pp_sound's CHANL2_BOOST
                for (int k = 0; k < 4; k++) routed[k] += d[sel & 3] * vol[k] * boost;
            }
        }
        for (int c = 0; c < 4; c++)
            spk[c] = acc[c] + 0.90 * 0.77 * e
                   + (mame_mix ? gain_disc * dsum : GAIN_ROUTE * routed[c]);
    }

    // Stereo fold and DC blocker, matching pp_sound.sv, in 16-bit units.
    void step_stereo(double &l, double &r, double spk[4]) {
        step48(spk);
        double fl = (spk[0] + spk[2]) * 0.5;
        double fr = (spk[1] + spk[3]) * 0.5;
        double yl = fl - dc_x1_l + dc_y_l * (1.0 - 1.0 / 2048.0);
        double yr = fr - dc_x1_r + dc_y_r * (1.0 - 1.0 / 2048.0);
        dc_x1_l = fl; dc_x1_r = fr; dc_y_l = yl; dc_y_r = yr;
        // pp_sound.sv clips the 16-bit result, so the model does too
        l = yl * 32768.0; r = yr * 32768.0;
        if (l > 32767) l = 32767; if (l < -32768) l = -32768;
        if (r > 32767) r = 32767; if (r < -32768) r = -32768;
    }
};

}  // namespace ppsnd
