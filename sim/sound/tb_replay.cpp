// Replay a MAME sound-write log through pp_sound and write the result as a
// 4-channel wav, so it can be compared with MAME's own -wavwrite recording.
//
//   tb_replay <polepos.rom> <sndlog.txt> <out.wav> [seconds]
#include "Vpp_sound.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vpp_sound *dut;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

struct Ev { double t; char kind; int a, b; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: tb_replay rom log out.wav [seconds]\n"); return 2; }
    double seconds = argc > 4 ? atof(argv[4]) : 20.0;

    std::vector<unsigned char> rom;
    { FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
      int c; while ((c = fgetc(f)) != EOF) rom.push_back((unsigned char)c); fclose(f); }

    std::vector<Ev> ev;
    { FILE *f = fopen(argv[2], "r"); if (!f) { perror(argv[2]); return 2; }
      char line[256];
      while (fgets(line, sizeof line, f)) {
          double t; char k; unsigned a = 0, b = 0;
          if (sscanf(line, "%lf %c %x %x", &t, &k, &a, &b) >= 3) ev.push_back({t, k, (int)a, (int)b});
      }
      fclose(f); }
    printf("%zu events, %.1f s\n", ev.size(), seconds);

    dut = new Vpp_sound;
    dut->reset = 1; dut->clson = 0;
    dut->mame_mix = 1;      // compared with MAME's recording: MAME's discrete routing
    dut->n54_o_lo = 0; dut->n54_o_hi = 0; dut->n54_r1 = 0; dut->n52_p = 0;
    for (int i = 0; i < 8; i++) tick();
    for (unsigned a = 0x24000; a < 0x24000 + 16384; a++) { dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1; tick(); }
    for (unsigned a = 0x2F000; a < 0x2F000 + 256; a++)   { dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1; tick(); }
    dut->dl_we = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;

    int nsamples = (int)(seconds * 48000);
    std::vector<short> wav(nsamples * 4, 0);
    size_t e = 0;
    // Events carry MAME's emulated time; place each on the 49.152 MHz clock it
    // belongs to, one write per clock (the write ports share data buses).
    long long clk_now = 0;
    long long next_ev_clk = ev.empty() ? -1 : (long long)(ev[0].t * 49152000.0);
    for (int s = 0; s < nsamples; s++) {
        for (int c = 0; c < 1024; c++) {
            dut->wsg_we = 0; dut->engine_lsb_we = 0; dut->engine_msb_we = 0;
            if (e < ev.size() && next_ev_clk <= clk_now) {
                const Ev &v = ev[e++];
                switch (v.kind) {
                    case 'w': dut->wsg_we = 1; dut->wsg_addr = v.a; dut->wsg_wdata = v.b; break;
                    case 'l': dut->engine_lsb_we = 1; dut->engine_data = v.a; break;
                    case 'm': dut->engine_msb_we = 1; dut->engine_data = v.a; break;
                    default:  dut->clson = v.a & 1; break;
                }
                next_ev_clk = (e < ev.size()) ? (long long)(ev[e].t * 49152000.0) : -1;
                if (next_ev_clk >= 0 && next_ev_clk <= clk_now) next_ev_clk = clk_now + 1;
            }
            tick();
            clk_now++;
        }
        wav[s * 4 + 0] = (short)dut->dbg_spk0;
        wav[s * 4 + 1] = (short)dut->dbg_spk1;
        wav[s * 4 + 2] = (short)dut->dbg_spk2;
        wav[s * 4 + 3] = (short)dut->dbg_spk3;
    }
    FILE *f = fopen(argv[3], "wb");
    int data = (int)wav.size() * 2, hdr = 36 + data, rate = 48000, byterate = 48000 * 8;
    short fmt = 1, ch = 4, align = 8, bits = 16; int sz = 16;
    fwrite("RIFF", 1, 4, f); fwrite(&hdr, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&sz, 4, 1, f); fwrite(&fmt, 2, 1, f); fwrite(&ch, 2, 1, f);
    fwrite(&rate, 4, 1, f); fwrite(&byterate, 4, 1, f);
    fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
    fwrite(wav.data(), 2, wav.size(), f);
    fclose(f);
    printf("wrote %s\n", argv[3]);
    return 0;
}
