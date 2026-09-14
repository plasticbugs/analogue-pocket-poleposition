// Discrete-only bench: pp_discrete against ppsnd::Discrete, sample by sample.
#include "Vpp_discrete.h"
#include "verilated.h"
#include "pp_snd_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

static Vpp_discrete *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
static double q26(uint32_t v) { return (double)(int32_t)v / 67108864.0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int n = argc > 1 ? atoi(argv[1]) : 20000;
    int rate = argc > 2 ? atoi(argv[2]) : 60;
    dut = new Vpp_discrete;
    dut->reset = 1;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;

    ppsnd::Discrete ref;
    int n54[3] = {0, 0, 0}, n52 = 0;
    uint32_t seed = 7;
    auto rnd = [&]() { seed = seed * 1103515245u + 12345u; return (seed >> 16) & 0x7fff; };
    double maxerr = 0; int worst = -1; long clip_count = 0; int first_diff = -1;
    for (int s = 0; s < n; s++) {
        if (s > 5 && (int)(rnd() % rate) == 0) {
            n54[0] = rnd() & 15; n54[1] = rnd() & 15; n54[2] = rnd() & 15; n52 = rnd() & 15;
        }
        dut->n54_0 = n54[0]; dut->n54_1 = n54[1]; dut->n54_2 = n54[2]; dut->n52 = n52;
        dut->cen_48k = 1; tick(); dut->cen_48k = 0;
        for (int k = 0; k < 1023; k++) tick();
        double d[4];
        // does the model's CHANL3 section sit on a rail this sample?
        double pre = ref.ch[2].y1;
        ref.step(n54, n52, d);
        bool clipped = (d[2] <= -2.0 + 1e-9) || (d[2] >= 1.5 - 1e-9);
        if (clipped) clip_count++;
        (void)pre;
        double want = d[0] + d[1] + d[2] + d[3];
        double got = q26(dut->out);
        if (s > 3) {
            double e = std::fabs(want - got);
            if (e > maxerr) { maxerr = e; worst = s; }
            if (first_diff < 0 && e > 1e-5) first_diff = s;
        }
        if ((s > worst - 2 && s <= worst && maxerr > 1e-5) || s < 4) {
            printf("s%-5d sum ref %12.8f rtl %12.8f | ch ref %9.6f %9.6f %9.6f %9.6f | rtl %9.6f %9.6f %9.6f\n",
                   s, want, got, d[0], d[1], d[2], d[3],
                   q26((uint32_t)dut->dbg_y[0]) - 2.0,
                   q26((uint32_t)dut->dbg_y[1]) - 2.0,
                   q26((uint32_t)dut->dbg_y[2]) - 2.0);
        }
    }
    printf("discrete: max err %.8f V at sample %d, first > 1e-5 at %d, rail-clipped samples %ld/%d (change every ~%d)\n",
           maxerr, worst, first_diff, clip_count, n, rate);
    return maxerr < 1e-5 ? 0 : 1;
}
