// Replay MAME's recorded Z80 <-> 06xx traffic into rtl/namco_customs.sv and
// check that the RTL answers the same bytes and raises NMI at the same times.
//
//   tb_replay <capture.txt> <mcu_rom_dir> [--until <ticks>]
//
// Times in the capture are sys clock ticks at 49.152 MHz, floor(t * 49152000)
// from MAME's attotime, so the 06xx's 48 kHz base clock (every 1024 ticks) and
// the MCUs' 256 kHz cycle (every 192) land exactly where MAME put them.
#include "Vnamco_customs.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>

static std::vector<uint8_t> readfile(const std::string &p, size_t expect = 0) {
    std::ifstream f(p, std::ios::binary);
    if (!f) { std::cerr << "cannot open " << p << "\n"; exit(2); }
    std::vector<uint8_t> v((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (expect && v.size() != expect) { std::cerr << p << ": expected " << expect << " bytes, got " << v.size() << "\n"; exit(2); }
    return v;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { std::cerr << "usage: tb_replay <capture.txt> <romdir> [--until ticks]\n"; return 2; }
    uint64_t until = ~0ull;
    for (int i = 3; i < argc - 1; i++) if (!strcmp(argv[i], "--until")) until = strtoull(argv[i + 1], 0, 0);

    std::string dir = argv[2];
    auto r51 = readfile(dir + "/51xx.bin", 1024), r52 = readfile(dir + "/52xx.bin", 1024);
    auto r53 = readfile(dir + "/53xx.bin", 1024), r54 = readfile(dir + "/54xx.bin", 1024);
    std::vector<uint8_t> smp(0x8000, 0);     // MAME's "52xx" region: 3 x 8K loaded, rest 0
    {
        auto a = readfile(dir + "/pp2_11.2e", 8192), b = readfile(dir + "/pp2_12.2f", 8192), c = readfile(dir + "/pp2_13.1e", 8192);
        memcpy(&smp[0x0000], a.data(), 8192);
        memcpy(&smp[0x2000], b.data(), 8192);
        memcpy(&smp[0x4000], c.data(), 8192);
    }

    Vnamco_customs *top = new Vnamco_customs;
    top->clk = 0; top->reset = 1; top->cen_mcu = 0; top->cen_06xx = 0;
    top->dl_we = 0; top->data_wr = 0; top->ctrl_wr = 0; top->z80_din = 0;
    top->iosel = 0; top->vblank = 0;
    top->in0 = 0xff; top->dswa = 0xff; top->dswb = 0xff; top->steer_pos = 0;
    top->smp_data = 0;
    top->eval();

    auto raw_clock = [&]() {
        uint32_t sa = top->smp_addr;
        top->clk = 1; top->eval();
        top->smp_data = smp[sa & 0x7fff];
        top->eval();
        top->clk = 0; top->eval();
    };

    // download the four MCU ROMs
    for (int chip = 0; chip < 4; chip++) {
        const std::vector<uint8_t> &src = chip == 0 ? r51 : chip == 1 ? r52 : chip == 2 ? r53 : r54;
        for (int i = 0; i < 1024; i++) {
            top->dl_addr = (chip << 10) | i;
            top->dl_data = src[i];
            top->dl_we = 1;
            raw_clock();
        }
    }
    top->dl_we = 0;
    top->reset = 0;
    top->eval();

    // ---- replay -------------------------------------------------------------
    std::ifstream cap(argv[1]);
    if (!cap) { std::cerr << "cannot open " << argv[1] << "\n"; return 2; }

    uint64_t now = 0;                 // sys clock ticks since MAME time 0
    bool prev_nmi = false;
    std::vector<uint64_t> rtl_nmi;    // rising edges
    std::vector<uint64_t> mame_nmi;
    uint64_t reads = 0, read_bad = 0, writes = 0;
    bool verbose = getenv("NC_VERBOSE") != nullptr;
    uint64_t vfrom = getenv("NC_FROM") ? strtoull(getenv("NC_FROM"), 0, 0) : 0;
    uint64_t vto = getenv("NC_TO") ? strtoull(getenv("NC_TO"), 0, 0) : 0;
    uint64_t first_bad = 0;
    std::string first_bad_desc;

    // execute the clock at index `now`: everything an event at tick t must see
    // has to be set before this runs, so events at t land in clock t exactly
    // where MAME put them.
    auto step = [&]() {
        top->cen_mcu  = (now % 192) == 0;
        top->cen_06xx = (now % 1024) == 0;
        // screen: 384 x 264 at 6.144 MHz; vblank lines 240..263 and 0..15
        uint64_t line = (now / 8 / 384) % 264;
        uint64_t frame = now / 8 / 384 / 264;
        top->vblank = (line >= 240) || (line < 16 && frame > 0);
        raw_clock();
        if (top->nmi && !prev_nmi) {
            rtl_nmi.push_back(now);
            if (verbose && now >= vfrom && now <= vto) printf("%llu RTL NMI edge\n", (unsigned long long)now);
        }
        prev_nmi = top->nmi;
        now++;
    };

    auto advance_to = [&](uint64_t target) {
        while (now < target && now < until) step();
    };

    int64_t ishift = getenv("NC_ISHIFT") ? strtoll(getenv("NC_ISHIFT"), 0, 0) : 0;
    struct Event { uint64_t t; std::string line; };
    std::vector<Event> events;
    {
        std::string l;
        while (std::getline(cap, l)) {
            std::istringstream ss(l);
            char k; uint64_t tt;
            ss >> k >> tt;
            // input state is only logged when the Z80 next touches the 06xx, so it
            // can lag what MAME's devices saw by a few ms; NC_ISHIFT moves input
            // events earlier to test how much of a difference that makes
            if (k == 'I' && ishift > 0) tt = (tt > (uint64_t)ishift) ? tt - ishift : 0;
            events.push_back({tt, l});
        }
        std::stable_sort(events.begin(), events.end(), [](const Event &a, const Event &b) { return a.t < b.t; });
    }

    for (auto &ev : events) {
        std::string line = ev.line;
        std::istringstream s(line);
        char kind; uint64_t t;
        s >> kind >> t;
        t = ev.t;
        if (t > until) break;
        advance_to(t);
        if (now >= until) break;
        if (kind == 'W' || kind == 'R') {
            std::string port; int val;
            s >> port >> val;
            if (kind == 'W') {
                if (verbose && t >= vfrom && t <= vto) printf("%llu W %s %02x\n", (unsigned long long)t, port.c_str(), val);
                top->z80_din = val;
                top->data_wr = (port == "D");
                top->ctrl_wr = (port == "C");
                step();
                top->data_wr = 0; top->ctrl_wr = 0;
                top->eval();
                writes++;
            } else {
                int got = (port == "C") ? top->ctrl_q : top->data_q;
                reads++;
                if (verbose && t >= vfrom && t <= vto)
                    printf("%llu R %s rtl=%02x mame=%02x\n", (unsigned long long)t, port.c_str(), got, val);
                if (got != val) {
                    if (read_bad < 20)
                        printf("  read mismatch #%llu at tick %llu (%.4f s) port %s: rtl=%02x mame=%02x\n",
                               (unsigned long long)read_bad + 1, (unsigned long long)t, t / 49152000.0, port.c_str(), got, val);
                    if (!read_bad) {
                        first_bad = t;
                        std::ostringstream d;
                        d << "read " << port << " at tick " << t << ": rtl=" << std::hex << got << " mame=" << val << std::dec;
                        first_bad_desc = d.str();
                    }
                    read_bad++;
                }
            }
        } else if (kind == 'L') {
            int bit, d; s >> bit >> d;
            if (bit == 1) { top->iosel = d; top->eval(); }
        } else if (kind == 'I') {
            int in0, dswa, dswb, steer; s >> in0 >> dswa >> dswb >> steer;
            top->in0 = in0; top->dswa = dswa; top->dswb = dswb; top->steer_pos = steer;
            top->eval();
        } else if (kind == 'N') {
            mame_nmi.push_back(t);
        }
    }

    // ---- NMI train ----------------------------------------------------------
    // Each MAME NMI entry (the Z80's fetch of 0x0066) follows an RTL NMI edge by
    // however long the Z80 took to finish its instruction and acknowledge.
    size_t i = 0, j = 0, paired = 0, unmatched_mame = 0; int dup_report = 0;
    int64_t dmin = 1 << 30, dmax = -(1 << 30);
    double dsum = 0;
    while (j < mame_nmi.size()) {
        while (i + 1 < rtl_nmi.size() && rtl_nmi[i + 1] <= mame_nmi[j]) i++;
        if (i < rtl_nmi.size() && rtl_nmi[i] <= mame_nmi[j]) {
            static size_t last_i = (size_t)-1;
            if (i == last_i && dup_report < 12) { printf("  two MAME NMI entries on one RTL edge: edge %llu entries %llu and %llu\n", (unsigned long long)rtl_nmi[i], (unsigned long long)mame_nmi[j-1], (unsigned long long)mame_nmi[j]); dup_report++; }
            last_i = i;
            int64_t d = (int64_t)(mame_nmi[j] - rtl_nmi[i]);
            dmin = std::min(dmin, d); dmax = std::max(dmax, d); dsum += d;
            paired++;
        } else {
            unmatched_mame++;
        }
        j++;
    }

    std::cout << "replayed to tick " << now << " (" << (double)now / 49152000.0 << " s)\n";
    std::cout << "  control/data writes: " << writes << "\n";
    std::cout << "  reads checked: " << reads << ", mismatches: " << read_bad;
    if (read_bad) std::cout << "  first: " << first_bad_desc;
    std::cout << "\n";
    std::cout << "  NMI edges: rtl " << rtl_nmi.size() << ", mame entries " << mame_nmi.size()
              << ", paired " << paired << ", unmatched " << unmatched_mame << "\n";
    if (paired)
        std::cout << "  NMI entry delay after RTL edge: min " << dmin << " max " << dmax
                  << " mean " << (dsum / paired) << " ticks (" << (dsum / paired / 49.152) << " us)\n";
    return read_bad ? 1 : 0;
}
