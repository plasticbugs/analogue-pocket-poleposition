// Cabinet filter bench: the gain of each Cabinet Reverb level's low-pass preset
// at a set of frequencies, measured on the platform's own filter RTL running at
// the Pocket's audio clock -- the numbers core_top.sv quotes.
//
//   sim/run_cabfilter.sh
#include "Vtb_cabfilter_top.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>

static Vtb_cabfilter_top *dut;
static void clk() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

// one 48 kHz sample is 256 MCLK periods
static double run(double f, int samples, bool measure) {
    static long n = 0;
    double acc = 0, ref = 0;
    for (int s = 0; s < samples; s++, n++) {
        double x = 12000.0 * std::sin(2 * M_PI * f * n / 48000.0);
        dut->core_l = (uint16_t)(int16_t)std::lround(x);
        for (int c = 0; c < 256; c++) clk();
        if (measure) { double y = (int16_t)dut->audio_l; acc += y * y; ref += x * x; }
    }
    return measure ? std::sqrt(acc / ref) : 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_cabfilter_top;
    dut->reset = 1; dut->afilter_sw = 0; dut->core_l = 0;
    for (int i = 0; i < 64; i++) clk();
    dut->reset = 0;
    run(1000, 12000, false);                      // past the chain's power-up mute

    const struct { int sw; const char *name; } lv[] = {{0, "Off"}, {8, "Light"}, {6, "Medium"}, {4, "Heavy"}};
    const double fr[] = {100, 1000, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 12000, 16000};
    printf("%-7s", "level");
    for (double f : fr) printf(" %6.0f", f);
    printf("   (dB relative to 1 kHz)\n");
    for (auto &l : lv) {
        dut->afilter_sw = l.sw;
        run(1000, 4800, false);                   // settle on the new preset
        double g1k = 0, g[16];
        int i = 0;
        for (double f : fr) {
            run(f, 960, false);
            g[i] = run(f, 4800, true);
            if (f == 1000) g1k = g[i];
            i++;
        }
        printf("%-7s", l.name);
        for (int k = 0; k < i; k++) printf(" %6.1f", 20 * std::log10(g[k] / g1k));
        printf("   1 kHz gain %.2f dB\n", 20 * std::log10(g1k));
    }
    delete dut;
    return 0;
}
