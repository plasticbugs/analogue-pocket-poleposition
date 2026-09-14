// Sound bench: drive pp_sound and the MAME-transcribed reference model with the
// same stream of register writes and compare every 48 kHz sample.
//
//   tb_sound <polepos.rom> [samples] [--wav out.wav] [--script file]
//
// Without a script it runs a deterministic pseudo-random exercise of every
// input: WSG registers, engine registers, and the 54xx/52xx nibbles.
#include "Vpp_sound.h"
#include "verilated.h"
#include "pp_snd_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>

static Vpp_sound *dut;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

// Verilator hands 27-bit ports back zero-extended: sign-extend before use, or
// every negative sample reads as about +32.
static double q26(uint32_t v) {
    return (double)(int32_t)v / 67108864.0;
}

struct Event { int sample; int kind; int a; int b; };   // kind 0 wsg, 1 lsb, 2 msb, 3 nibbles, 4 clson

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: tb_sound rom [samples]\n"); return 2; }
    int nsamples = (argc > 2) ? atoi(argv[2]) : 20000;
    const char *wav_path = nullptr;
    int trace = 0, trace_from = 0, nibble_rate = 60;
    for (int i = 3; i < argc - 1; i++)
        if (!strcmp(argv[i], "--nibble-rate")) nibble_rate = atoi(argv[i + 1]);
    for (int i = 3; i < argc - 1; i++) {
        if (!strcmp(argv[i], "--trace")) trace = atoi(argv[i + 1]);
        if (!strcmp(argv[i], "--from")) trace_from = atoi(argv[i + 1]);
    }
    for (int i = 3; i < argc - 1; i++)
        if (!strcmp(argv[i], "--wav")) wav_path = argv[i + 1];
    bool mame_mix = false;
    for (int i = 3; i < argc; i++)
        if (!strcmp(argv[i], "--mame-mix")) mame_mix = true;

    std::vector<unsigned char> rom;
    { FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
      int c; while ((c = fgetc(f)) != EOF) rom.push_back((unsigned char)c); fclose(f); }
    if (rom.size() < 0x2F100) { fprintf(stderr, "rom too short\n"); return 2; }

    dut = new Vpp_sound;
    dut->reset = 1; dut->clson = 0; dut->mame_mix = mame_mix;
    for (int i = 0; i < 16; i++) tick();

    // download: engine ROM and waveform PROM
    for (unsigned a = 0x24000; a < 0x24000 + 16384; a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1; tick();
    }
    for (unsigned a = 0x2F000; a < 0x2F000 + 256; a++) {
        dut->dl_addr = a; dut->dl_data = rom[a]; dut->dl_we = 1; tick();
    }
    dut->dl_we = 0;
    for (int i = 0; i < 16; i++) tick();
    // Reset holds the rate divider at zero, so releasing it here starts the
    // first 48/192/24 kHz tick on the bench's first sample edge: both sides
    // then see every write on the same internal tick.
    dut->reset = 0;

    ppsnd::Machine ref;
    ref.mame_mix = mame_mix;
    ref.wsg.wave = &rom[0x2F000];
    ref.engine.rom = &rom[0x24000];

    // deterministic stimulus
    std::vector<Event> events;
    uint32_t seed = 12345;
    auto rnd = [&]() { seed = seed * 1103515245u + 12345u; return (seed >> 16) & 0x7fff; };
    for (int s = 0; s < nsamples; s++) {
        if (s == 10) events.push_back({s, 4, 1, 0});               // sound enable
        if (s > 20 && (rnd() % 40) == 0) {
            int reg = rnd() % 0x40;
            events.push_back({s, 0, reg, (int)(rnd() & 0xff)});
        }
        // one engine register per sample: both share the same data bus, so two
        // writes in one sample would be a bench artefact, not a test
        if (s > 20 && (rnd() % 300) == 0)
            events.push_back({s, (rnd() & 1) ? 1 : 2, (int)(rnd() & 0xff), 0});
        if (s > 20 && (rnd() % nibble_rate) == 0)
            events.push_back({s, 3, (int)(rnd() & 0xfff), (int)(rnd() & 0xf)});
        if (s == nsamples / 2) events.push_back({s, 4, 0, 0});      // mute
        if (s == nsamples / 2 + 500) events.push_back({s, 4, 1, 0});
    }

    size_t ev = 0;
    double max_err_l = 0, max_err_r = 0, sum2 = 0;
    double max_err_spk[4] = {0, 0, 0, 0};
    std::vector<short> wav;
    int worst_sample = -1;
    int first_pos_diff = -1;

    for (int s = 0; s < nsamples; s++) {
        // apply this sample's events to both sides, aligned to the sample edge
        dut->wsg_we = 0; dut->engine_lsb_we = 0; dut->engine_msb_we = 0;
        while (ev < events.size() && events[ev].sample == s) {
            const Event &e = events[ev++];
            switch (e.kind) {
                case 0:
                    dut->wsg_we = 1; dut->wsg_addr = e.a; dut->wsg_wdata = e.b;
                    ref.wsg.write(e.a, e.b);
                    break;
                case 1:
                    dut->engine_lsb_we = 1; dut->engine_data = e.a;
                    ref.engine.write_lsb(e.a);
                    break;
                case 2:
                    dut->engine_msb_we = 1; dut->engine_data = e.a;
                    ref.engine.write_msb(e.a);
                    break;
                case 3:
                    dut->n54_o_lo = e.a & 0xf; dut->n54_o_hi = (e.a >> 4) & 0xf;
                    dut->n54_r1 = (e.a >> 8) & 0xf; dut->n52_p = e.b & 0xf;
                    ref.n54[0] = e.a & 0xf; ref.n54[1] = (e.a >> 4) & 0xf;
                    ref.n54[2] = (e.a >> 8) & 0xf; ref.n52 = e.b & 0xf;
                    break;
                default:
                    dut->clson = e.a;
                    ref.wsg.enable = e.a;
                    ref.engine.clson(e.a);
                    break;
            }
        }
        // one 48 kHz sample = 1024 clocks; writes land on the first
        for (int c = 0; c < 1024; c++) {
            tick();
            if (c == 0) { dut->wsg_we = 0; dut->engine_lsb_we = 0; dut->engine_msb_we = 0; }
        }

        double l, r, spk[4];
        // the model's per-block values, for the trace
        double ref_w0 = 0, ref_disc = 0, ref_eng = 0;
        {
            double before_eng_prev = ref.eng_prev, before_eng_cur = ref.eng_cur;
            (void)before_eng_prev; (void)before_eng_cur;
        }
        ref.step_stereo(l, r, spk);
        ref_w0   = ref.last_wsg0;
        ref_disc = ref.last_dsum;
        ref_eng  = ref.last_eng;
        if (trace && s >= trace_from && s < trace_from + trace) {
            printf("s%-5d wsg0 ref %10.6f rtl %10.6f | disc ref %10.6f rtl %10.6f | eng ref %10.6f rtl %10.6f | L ref %8.1f rtl %6d\n",
                   s, ref_w0, q26(dut->dbg_wsg0),
                   ref_disc, q26(dut->dbg_disc),
                   ref_eng, q26(dut->dbg_eng),
                   l, (int)(short)dut->audio_l);
            printf("        eng pos ref %10u rtl %10u | step ref %6u rtl %6u | msb %02x lsb %02x en %d\n",
                   ref.engine.position, (unsigned)dut->dbg_eng_pos,
                   (unsigned)(((3072000u/16u) * ((ref.engine.msb + 1) * 64 + ref.engine.lsb + 1) / 4096u) << 12) / 24000u,
                   (unsigned)dut->dbg_eng_step, ref.engine.msb, ref.engine.lsb, ref.engine.enable);
        }

        if (first_pos_diff < 0 && ref.engine.position != (unsigned)dut->dbg_eng_pos)
            first_pos_diff = s;
        if (s > 40) {   // skip the reset transient of the DC blocker
            double el = std::fabs(l - (double)(short)dut->audio_l);
            double er = std::fabs(r - (double)(short)dut->audio_r);
            if (el > max_err_l) { max_err_l = el; worst_sample = s; }
            if (er > max_err_r) max_err_r = er;
            sum2 += el * el + er * er;
            const short rtl_spk[4] = {(short)dut->dbg_spk0, (short)dut->dbg_spk1,
                                      (short)dut->dbg_spk2, (short)dut->dbg_spk3};
            for (int c = 0; c < 4; c++) {
                // stream units -> 16 bit, the same scaling the wav uses
                double want = spk[c] * 32768.0;
                if (want > 32767) want = 32767;
                if (want < -32768) want = -32768;
                double d = std::fabs(want - (double)rtl_spk[c]);
                if (d > max_err_spk[c]) max_err_spk[c] = d;
            }
        }
        if (wav_path) { wav.push_back((short)dut->audio_l); wav.push_back((short)dut->audio_r); }
    }

    printf("samples %d, engine position first differs at sample %d\n", nsamples, first_pos_diff);
    printf("stereo out: max err L %.2f LSB, R %.2f LSB, rms %.3f LSB (worst at sample %d)\n",
           max_err_l, max_err_r, std::sqrt(sum2 / (2.0 * nsamples)), worst_sample);
    printf("speaker channels: max err %.2f %.2f %.2f %.2f LSB\n",
           max_err_spk[0], max_err_spk[1], max_err_spk[2], max_err_spk[3]);

    if (wav_path) {
        FILE *f = fopen(wav_path, "wb");
        int data = wav.size() * 2, hdr = 36 + data;
        fwrite("RIFF", 1, 4, f); fwrite(&hdr, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
        int sz = 16; short fmt = 1, ch = 2; int rate = 48000, byterate = 48000 * 4;
        short align = 4, bits = 16;
        fwrite(&sz, 4, 1, f); fwrite(&fmt, 2, 1, f); fwrite(&ch, 2, 1, f);
        fwrite(&rate, 4, 1, f); fwrite(&byterate, 4, 1, f);
        fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
        fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f);
        fwrite(wav.data(), 2, wav.size(), f);
        fclose(f);
        printf("wrote %s\n", wav_path);
    }
    bool ok = max_err_l < 3 && max_err_r < 3;
    delete dut;
    return ok ? 0 : 1;
}
