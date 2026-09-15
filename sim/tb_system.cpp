// Full-system bench: the whole machine on the real CPUs.
//
//   tb_system <polepos.rom> <frames> <out.ppm> [-ram out.txt] [-script attract|play|steer]
//              [-trace trace.txt] [-dump N,N,... -dumpdir DIR]
//              [-z80log file -z80from F -z80to F]   Z80 fetches and I/O reads
//              [-events file -evto F]   handshake events with time in lines
//              [-wav out.wav]   the machine's stereo output, 48 kHz
//              [-in0file f]     IN0 per frame (hex, one line per frame, as MAME read it)
//              [-mamemix]       route the discrete sound as MAME does, to compare with its wavs
//
// Loads the ROM image through the download port, releases reset and runs the
// machine for <frames> frames of its own raster, driving the same input
// schedule tools/dumpsys.lua gives MAME. At the top of vblank of the last frame
// it writes the visible picture and, with -ram, every memory the game state
// lives in -- Z80 work RAM, NVRAM, the four shared video memories, the scroll
// registers and the latch -- in the format tools/diff_state.py compares.
#include "Vpolepos_core.h"
#include "Vpolepos_core___024root.h"
#include "Vpolepos_core_polepos_core.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cmath>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vpolepos_core *top;
static unsigned last_rd_a, last_rd_v; static bool last_rd_io, rd_pend;
static long long cycles = 0;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cycles++;
}

// The input schedule, in frames from power-on. Mirrors tools/dumpsys.lua.
struct Inputs { bool coin; unsigned accel, brake; unsigned steer; bool gear_hi; };
static Inputs schedule(const std::string &script, int frame) {
    Inputs in{false, 0, 0, 0, false};
    if (script == "play") {
        in.coin = frame >= 600 && frame < 606;
        in.accel = frame >= 700 ? 0x90 : 0;
        if (frame >= 900) {
            int phase = (frame / 90) % 4;
            in.steer = (phase == 1) ? (frame * 3) & 0xff : (phase == 3) ? (-frame * 3) & 0xff : 0;
        }
    }
    if (script == "steer") {
        // a race, then the wheel turned at the Pocket's fastest rates and let
        // go, to see whether the 53xx keeps up (PP_STEERLOG=1 prints it)
        static unsigned pos = 0;
        in.coin = frame >= 600 && frame < 606;
        in.accel = frame >= 700 ? 0x90 : 0;
        if (frame > 900 && frame <= 1020) pos += 6;          // High, held
        if (frame > 1080 && frame <= 1200) pos -= 4;         // Medium, held
        if (frame > 1260 && frame <= 1380) pos += 2;         // Medium, first half second
        in.steer = pos & 0xff;
    }
    return in;
}

static void dump_state(const char *ram_path, int frame) {
    FILE *r = fopen(ram_path, "w");
    auto *m = top->rootp->polepos_core;
    fprintf(r, "frame %d\n", frame);
    fprintf(r, "hscroll %04x\nvscroll %04x\nlatch %02x\n",
            m->__PVT__hscroll, m->__PVT__vscroll, top->dbg_latch);
    auto dump16 = [&](const char *name, auto &mem, int n) {
        fprintf(r, "%s\n", name);
        for (int i = 0; i < n; i++)
            fprintf(r, "%04x%s", (unsigned)mem[i], (i % 16 == 15) ? "\n" : "");
    };
    auto dump8 = [&](const char *name, auto &mem, int n) {
        fprintf(r, "%s\n", name);
        for (int i = 0; i < n; i++) fprintf(r, "%02x%s", (unsigned)mem[i], (i % 32 == 31) ? "\n" : "");
    };
    dump16("SPRITE", m->u_shared__DOT__u_sprite__DOT__mem, 0x800);
    dump16("ROAD",   m->u_shared__DOT__u_road__DOT__mem,   0x400);
    dump16("ALPHA",  m->u_shared__DOT__u_alpha__DOT__mem,  0x400);
    dump16("VIEW",   m->u_shared__DOT__u_view__DOT__mem,   0x800);
    // MAME's 0x8000-0x83FF read includes the WSG registers at 0x3C0-0x3FF
    fprintf(r, "Z80RAM\n");
    for (int i = 0; i < 0x400; i++) {
        unsigned v = (i >= 0x3c0) ? (unsigned)m->u_sound__DOT__u_wsg__DOT__regs[i - 0x3c0] : (unsigned)m->u_sram__DOT__mem[i];
        fprintf(r, "%02x%s", v, (i % 32 == 31) ? "\n" : "");
    }
    dump8("NVRAM",   m->u_nvram__DOT__mem, 0x800);
    fprintf(r, "END\n");
    fclose(r);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: tb_system rom frames out.ppm [-ram f] [-script s] [-trace f]\n"); return 2; }
    Verilated::commandArgs(argc, argv);
    const char *rom_path = argv[1];
    int frames = atoi(argv[2]);
    const char *ppm_path = argv[3];
    const char *ram_path = nullptr, *trace_path = nullptr;
    std::vector<int> dump_frames;
    std::string dump_dir = "build/sys";
    const char *z80log_path = nullptr;
    int z80from = 0, z80to = 0;
    const char *events_path = nullptr;
    const char *wav_path = nullptr;
    int mame_mix = 0;
    std::vector<unsigned> in0_seq;
    int evto = 0;
    std::string script = "attract";
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "-ram") && i + 1 < argc) ram_path = argv[++i];
        else if (!strcmp(argv[i], "-script") && i + 1 < argc) script = argv[++i];
        else if (!strcmp(argv[i], "-trace") && i + 1 < argc) trace_path = argv[++i];
        else if (!strcmp(argv[i], "-dumpdir") && i + 1 < argc) dump_dir = argv[++i];
        else if (!strcmp(argv[i], "-z80log") && i + 1 < argc) z80log_path = argv[++i];
        else if (!strcmp(argv[i], "-z80from") && i + 1 < argc) z80from = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-z80to") && i + 1 < argc) z80to = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-events") && i + 1 < argc) events_path = argv[++i];
        else if (!strcmp(argv[i], "-wav") && i + 1 < argc) wav_path = argv[++i];
        else if (!strcmp(argv[i], "-mamemix")) mame_mix = 1;
        else if (!strcmp(argv[i], "-in0file") && i + 1 < argc) {
            FILE *fi = fopen(argv[++i], "r"); unsigned v;
            while (fi && fscanf(fi, "%x", &v) == 1) in0_seq.push_back(v);
            if (fi) fclose(fi);
        }
        else if (!strcmp(argv[i], "-evto") && i + 1 < argc) evto = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-dump") && i + 1 < argc) {
            for (char *t = strtok(argv[++i], ","); t; t = strtok(nullptr, ",")) dump_frames.push_back(atoi(t));
        }
    }

    top = new Vpolepos_core;
    top->reset = 1; top->pause = 0;
    top->in0 = 0xff; top->dswa = 0xff; top->dswb = 0x74;
    top->steer_pos = 0; top->accel = 0; top->brake = 0;
    top->mame_mix = mame_mix;
    top->dl_we = 0;
    for (int i = 0; i < 8; i++) tick();

    FILE *f = fopen(rom_path, "rb");
    if (!f) { perror(rom_path); return 2; }
    std::vector<unsigned char> rom;
    int c;
    while ((c = fgetc(f)) != EOF) rom.push_back((unsigned char)c);
    fclose(f);
    for (size_t a = 0; a < rom.size(); a++) {
        top->dl_addr = a; top->dl_data = rom[a]; top->dl_we = 1;
        tick();
    }
    top->dl_we = 0;
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;

    FILE *trace = trace_path ? fopen(trace_path, "w") : nullptr;
    FILE *z80log = z80log_path ? fopen(z80log_path, "w") : nullptr;
    FILE *events = events_path ? fopen(events_path, "w") : nullptr;
    const long long t0 = cycles;   // reset release
    bool s_ack_q[2] = {false, false};
    std::vector<int16_t> wav;
    bool m1_q = true, rd_q = true, wr_q = true;

    std::vector<unsigned char> img(256 * 224 * 3, 0);
    int frame = 0, row = 0, col = 0;
    bool vb_q = true, de_q = false;
    unsigned in0 = 0xff;
    long long guard = 0;
    while (frame < frames && guard++ < 4000000000LL) {
        tick();
        if (wav_path && top->audio_ce) { wav.push_back((int16_t)top->audio_l); wav.push_back((int16_t)top->audio_r); }
        // PP_CHANLOG=1: RMS of each discrete channel (CHANL1..4, volts, DC
        // removed) and which voices route it, once every 60 frames
        static const bool chanlog = getenv("PP_CHANLOG") != nullptr;
        if (chanlog && top->audio_ce) {
            static double s1[4], s2[4]; static long n = 0; static int last_frame = -1;
            auto *m = top->rootp->polepos_core;
            const int32_t c[4] = {(int32_t)m->u_sound__DOT__u_discrete__DOT__chanl1, (int32_t)m->u_sound__DOT__u_discrete__DOT__chanl2,
                                  (int32_t)m->u_sound__DOT__u_discrete__DOT__chanl3, (int32_t)m->u_sound__DOT__u_discrete__DOT__chanl4};
            for (int k = 0; k < 4; k++) { double v = c[k] / 67108864.0; s1[k] += v; s2[k] += v * v; }
            n++;
            if (frame % 60 == 0 && frame != last_frame && n > 0) {
                last_frame = frame;
                printf("chanl frame %d rms", frame);
                for (int k = 0; k < 4; k++) { double mu = s1[k] / n; printf(" %.3f", std::sqrt(std::max(0.0, s2[k] / n - mu * mu))); s1[k] = s2[k] = 0; }
                printf(" | sel");
                for (int v = 0; v < 8; v++) { unsigned sel = m->u_sound__DOT__u_wsg__DOT__regs[v * 4 + 0x23]; if (sel & 8) printf(" v%d:C%u", v, (sel & 3) + 1); }
                printf("\n");
                n = 0;
            }
        }
        if (events && frame < evto) {
            auto *m = top->rootp->polepos_core;
            double lines = (cycles - t0) / 3072.0;
            unsigned a = m->__PVT__cpu_a;
            if (m->__PVT__wr_edge) {
                if (m->__PVT__sel_a0 && ((a & 7) == 0 || (a & 7) == 4 || (a & 7) == 5))
                    fprintf(events, "%10.3f lines  z80 latch bit %u = %u\n", lines, a & 7, (unsigned)m->__PVT__cpu_do & 1);
                if (a == 0x4048 || a == 0x4049)
                    fprintf(events, "%10.3f lines  z80 writes %04x = %02x\n", lines, a, (unsigned)m->__PVT__cpu_do);
            }
            for (int k = 0; k < 2; k++) {
                bool ack = m->__PVT__sub_req[k] && (m->__PVT__loc_ack[k] || ((m->__PVT__shr_ack >> (k + 1)) & 1));
                unsigned sa = m->__PVT__sub_addr[k];
                if (ack && !s_ack_q[k] && m->__PVT__sub_we[k] && sa >= 0x8090 && sa <= 0x8093)
                    fprintf(events, "%10.3f lines  sub%d writes %04x = %04x\n", lines, k + 1, sa, (unsigned)m->__PVT__sub_wdata[k]);
                s_ack_q[k] = ack;
            }
        }
        if (z80log && frame >= z80from && frame < z80to) {
            auto *m = top->rootp->polepos_core;
            bool m1 = !m->__PVT__cpu_m1_n && !m->__PVT__cpu_mreq_n;
            bool rd = !m->__PVT__cpu_rd_n, wr = !m->__PVT__cpu_wr_n;
            unsigned a = m->__PVT__cpu_a;
            if (m1 && m1_q) fprintf(z80log, "%04X\n", a);
            // value reads from I/O-like addresses, sampled at the end of the strobe
            if (!rd && !rd_q) { }
            if (rd_q == false && !rd) {}
            if (rd && !m1 && ((a & 0xf000) == 0x9000 || (a & 0xf300) == 0xa000 || !m->__PVT__cpu_iorq_n))
                last_rd_a = a, last_rd_v = m->__PVT__cpu_di, last_rd_io = !m->__PVT__cpu_iorq_n, rd_pend = true;
            if (!rd && rd_pend) { fprintf(z80log, "  rd %s%04X=%02X\n", last_rd_io ? "io " : "", last_rd_a, last_rd_v); rd_pend = false; }
            m1_q = !m1;
            (void)wr; (void)wr_q;
        }
        if (top->dbg_frame) {
            // start of row 240, the instant MAME's frame_done runs (frame N
            // at N x 264 lines of emulated time; the raster starts at row 240)
            frame++;
            // PP_STEERLOG=1: the steering encoder's backlog each frame (counts
            // of wheel movement the 53xx has not yet polled out, x2)
            static const bool steerlog = getenv("PP_STEERLOG") != nullptr;
            if (steerlog)
                printf("steer frame %d pos %u backlog %d\n", frame, (unsigned)top->steer_pos,
                       (int)(int16_t)top->rootp->polepos_core->u_customs__DOT__steer_accum);
            Inputs in = schedule(script, frame);
            in0 = 0xff;
            if (in.coin) in0 &= ~0x10;
            if (in.gear_hi) in0 &= ~0x02;
            // MAME's line N is IN0 as read at the end of frame N: it applies from frame N+1
            if (!in0_seq.empty()) in0 = in0_seq[std::min((size_t)frame, in0_seq.size()) - 1];
            top->in0 = in0;
            top->accel = in.accel; top->brake = in.brake; top->steer_pos = in.steer;
            for (int df : dump_frames) if (df == frame) {
                char path[512];
                snprintf(path, sizeof path, "%s/rtl_%c%05d.txt", dump_dir.c_str(), script[0], frame);
                dump_state(path, frame);
            }
            if (z80log && frame >= z80from && frame < z80to) fprintf(z80log, "frame %d\n", frame);
            if (trace) fprintf(trace, "frame %d z80pc %04x sub1 %04x sub2 %04x latch %02x clocks %lld\n",
                               frame, (unsigned)top->rootp->polepos_core->__PVT__u_z80__DOT__i_tv80_core__DOT__PC,
                               top->dbg_sub1_pc, top->dbg_sub2_pc, top->dbg_latch, cycles);
            if (trace) {
                auto *m = top->rootp->polepos_core;
                fprintf(trace, "    regs");
                for (int k = 0; k < 8; k++)
                    fprintf(trace, " %d:%02x%02x", k, (unsigned)m->__PVT__u_z80__DOT__i_tv80_core__DOT__i_reg__DOT__RegsH[k],
                            (unsigned)m->__PVT__u_z80__DOT__i_tv80_core__DOT__i_reg__DOT__RegsL[k]);
                fprintf(trace, "\n");
            }
        }
        if (!top->cen_pix) continue;
        bool vb = top->vblank;
        if (vb && !vb_q) { row = 0; col = 0; }
        vb_q = vb;
        if (top->de) {
            if (row < 224 && col < 256) {
                int o = (row * 256 + col) * 3;
                img[o] = top->red; img[o + 1] = top->green; img[o + 2] = top->blue;
            }
            if (++col == 256) { col = 0; row++; }
        }
    }
    if (trace) fclose(trace);
    if (z80log) fclose(z80log);
    if (events) fclose(events);
    if (wav_path) {
        FILE *w = fopen(wav_path, "wb");
        uint32_t n = wav.size() * 2;
        auto u32 = [&](uint32_t v) { fwrite(&v, 4, 1, w); };
        auto u16 = [&](uint16_t v) { fwrite(&v, 2, 1, w); };
        fwrite("RIFF", 1, 4, w); u32(36 + n); fwrite("WAVEfmt ", 1, 8, w);
        u32(16); u16(1); u16(2); u32(48000); u32(48000 * 4); u16(4); u16(16);
        fwrite("data", 1, 4, w); u32(n); fwrite(wav.data(), 2, wav.size(), w);
        fclose(w);
    }

    FILE *o = fopen(ppm_path, "wb");
    fprintf(o, "P6\n256 224\n255\n");
    fwrite(img.data(), 1, img.size(), o);
    fclose(o);

    if (ram_path) dump_state(ram_path, frame);
    printf("ran %d frames, %lld clocks, watchdog %d, video overrun %d\n",
           frame, cycles, top->dbg_watchdog, top->dbg_vid_overrun);
    int bad = top->dbg_watchdog || top->dbg_vid_overrun;
    delete top;
    return bad;
}
