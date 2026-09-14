// Steering bench: target/pocket/pp_steer.sv against the behaviour it must have.
//
//   D-pad at Medium turns exactly as the core's original steering did (2 counts
//   a frame, 4 once held 32 frames), Low and High at half and 1.5x that;
//   the stick turns in proportion to deflection, up to the D-pad's held rate,
//   either direction, from either stick, and not at all inside the dead zone.
//
//   sim/run_steer.sh
#include "Vpp_steer.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>

static Vpp_steer *dut;
static int fails = 0;

static void clk() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
// one frame: a few clocks for the input pipeline to settle, then the tick
static void frame() {
    for (int i = 0; i < 6; i++) clk();
    dut->frame_tick = 1; clk(); dut->frame_tick = 0;
}
static void check(bool ok, const char *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) fails++;
}
static void release() {
    dut->left = 0; dut->right = 0; dut->stick_active = 0;
    dut->stick_lx = 0x80; dut->stick_rx = 0x80;
    frame();
}

// the original core_top steering, frame by frame
struct Old {
    int pos = 0, held = 0;
    void step(bool l, bool r) {
        if (l ^ r) {
            int d = (held >= 32) ? 4 : 2;
            if (held < 63) held++;
            pos = (pos + (r ? d : -d)) & 0xff;
        } else held = 0;
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vpp_steer;
    dut->reset = 1; dut->sens = 0;
    release();
    for (int i = 0; i < 4; i++) clk();
    dut->reset = 0;

    // ---- D-pad at Medium, against the original, through a scripted pattern
    {
        Old old;
        bool same = true;
        srand(7);
        int dir = 0, left_for = 0;
        for (int f = 0; f < 4000; f++) {
            if (left_for-- <= 0) { dir = rand() % 4; left_for = rand() % 90; }
            bool l = dir == 1 || dir == 3, r = dir == 2 || dir == 3;
            dut->left = l; dut->right = r;
            frame();
            old.step(l, r);
            if (dut->pos != old.pos) { same = false; printf("  frame %d: rtl %d old %d\n", f, dut->pos, old.pos); break; }
        }
        check(same, "D-pad Medium matches the original steering for 4000 frames");
    }

    // ---- D-pad rates per sensitivity: first 32 frames, then held
    const int want_b[4] = {2, 1, 3, 3};
    for (int s = 0; s < 4; s++) {
        release();
        dut->sens = s;
        int p0 = dut->pos;
        dut->right = 1;
        for (int f = 0; f < 32; f++) frame();
        int early = (dut->pos - p0) & 0xff;
        int p1 = dut->pos;
        for (int f = 0; f < 10; f++) frame();
        int late = (dut->pos - p1) & 0xff;
        char msg[120];
        snprintf(msg, sizeof msg, "D-pad sens %d: %d counts in 32 frames (want %d), %d in the next 10 (want %d)",
                 s, early, 32 * want_b[s], late, 20 * want_b[s]);
        check(early == 32 * want_b[s] && late == 20 * want_b[s], msg);
        release();
    }

    // ---- stick: proportional rate, averaged over 600 frames
    struct Case { int sens; int lx, rx; double want; const char *name; };
    const Case cases[] = {
        {0, 0xFF, 0x80,  4.0, "Medium, left stick full right"},
        {0, 0x00, 0x80, -4.0, "Medium, left stick full left"},
        {1, 0xFF, 0x80,  2.0, "Low, full right"},
        {2, 0xFF, 0x80,  6.0, "High, full right"},
        {0, 0x80 + 16 + 55, 0x80, 4.0 * 55 / 111, "Medium, half way past the dead zone"},
        {0, 0x80 + 16 + 5,  0x80, 4.0 * 5 / 111,  "Medium, just past the dead zone"},
        {0, 0x80, 0x00, -4.0, "Medium, right stick full left"},
        {0, 0x80 + 10, 0x80, 0.0, "inside the dead zone"},
    };
    for (const Case &c : cases) {
        release();
        dut->sens = c.sens;
        dut->stick_lx = c.lx; dut->stick_rx = c.rx; dut->stick_active = 1;
        dut->left = c.lx < 0x80 || c.rx < 0x80; dut->right = c.lx > 0x80 || c.rx > 0x80;  // as the framework merges them
        for (int f = 0; f < 4; f++) frame();                   // pipeline in
        int p0 = dut->pos, total = 0, prev = p0;
        const int N = 600;
        for (int f = 0; f < N; f++) {
            frame();
            total += (int8_t)(uint8_t)(dut->pos - prev);
            prev = dut->pos;
        }
        double rate = (double)total / N;
        char msg[160];
        snprintf(msg, sizeof msg, "stick %s: %.3f counts/frame (want %.3f)", c.name, rate, c.want);
        check(std::fabs(rate - c.want) <= 0.03 + 0.02 * std::fabs(c.want), msg);
    }

    printf(fails ? "steer: %d FAILED\n" : "steer: ok\n", fails);
    delete dut;
    return fails ? 1 : 0;
}
