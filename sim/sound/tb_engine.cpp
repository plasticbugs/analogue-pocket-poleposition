// Engine-only bench: pp_engine against ppsnd::Engine, sample by sample.
#include "Vpp_engine.h"
#include "verilated.h"
#include "pp_snd_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>

static Vpp_engine *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
static double q26(uint32_t v) { return (double)(int32_t)v / 67108864.0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<unsigned char> rom;
    FILE *f = fopen(argv[1], "rb");
    int c; while ((c = fgetc(f)) != EOF) rom.push_back((unsigned char)c); fclose(f);
    int nsamples = argc > 2 ? atoi(argv[2]) : 2000;
    int msb = argc > 3 ? (int)strtol(argv[3], 0, 0) : 0x2a, lsb = argc > 4 ? (int)strtol(argv[4], 0, 0) : 0x15;

    dut = new Vpp_engine;
    dut->reset = 1; dut->clson = 1;
    for (int i = 0; i < 8; i++) tick();
    for (unsigned a = 0; a < 16384; a++) { dut->rom_wa = a; dut->rom_d = rom[0x24000 + a]; dut->rom_we = 1; tick(); }
    dut->rom_we = 0;
    dut->reset = 0;

    ppsnd::Engine ref;
    ref.rom = &rom[0x24000];

    double maxerr = 0; int worst = -1;
    for (int s = 0; s < nsamples; s++) {
        dut->cen_24k = 1; dut->lsb_we = 0; dut->msb_we = 0;
        if (s == 2) { dut->msb_we = 1; dut->wdata = msb; ref.write_msb(msb); }
        if (s == 3) { dut->lsb_we = 1; dut->wdata = lsb | 1; ref.write_lsb(lsb | 1); }
        tick();                       // the tick edge: cen and any write land together
        dut->cen_24k = 0; dut->lsb_we = 0; dut->msb_we = 0;
        for (int k = 0; k < 2047; k++) tick();
        double r = ref.step();
        double g = q26(dut->out);
        if (s > 4) {
            double e = std::fabs(r - g);
            if (e > maxerr) { maxerr = e; worst = s; }
        }
        if (s < 8) {
            double rx = (3.4 / 255 * ref.rom[((ref.msb >> 3) & 7) * 0x800 + ((ref.position >> 12) & 0x7ff)] - 2)
                        * VOLUME_TABLE[(ref.msb >> 3) & 7];
            printf("      x ref %10.6f rtl %10.6f | y ref %10.6f %10.6f %10.6f rtl %10.6f %10.6f %10.6f\n",
                   rx, q26(dut->dbg_x),
                   ref.f[0].y1, ref.f[1].y1, ref.f[2].y1,
                   q26((uint32_t)(dut->dbg_y[0])), q26((uint32_t)(dut->dbg_y[1])), q26((uint32_t)(dut->dbg_y[2])));
        }
        if (s < 12 || (s > worst - 3 && s < worst + 3 && maxerr > 1e-4))
            printf("s%-4d ref %12.8f rtl %12.8f | pos ref %10u rtl %10u | step ref %u rtl %u\n",
                   s, r, g, ref.position, (unsigned)dut->dbg_pos,
                   (unsigned)(((3072000u / 16u) * ((ref.msb + 1) * 64 + ref.lsb + 1) / 4096u) << 12) / 24000u,
                   (unsigned)dut->dbg_step);
    }
    printf("engine: max err %.8f V at sample %d (msb %02x lsb %02x)\n", maxerr, worst, msb, lsb);
    return maxerr < 1e-4 ? 0 : 1;
}
