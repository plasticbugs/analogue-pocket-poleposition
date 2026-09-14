// Lockstep co-simulation: rtl/mb88.sv against MAME's mb88xx.cpp execution code.
//
//   tb_mb88 directed <samples_per_opcode> <seed>
//   tb_mb88 random   <ticks> <seed>
//   tb_mb88 rom      <chip 51|52|53|54> <ticks> <seed>  (real MCU ROM, polepos-like stimulus)
//
// One "tick" is one MAME cycle. Per tick, both models see the same sequence:
//   1. the serial timer fires (if armed)            RTL: on the cen clock
//   2. input line changes are delivered             RTL: pins change after cen
//   3. one more cycle of budget, execute_run()      RTL: next few sys clocks
// After every tick the complete architectural state, RAM, the instructions
// started and every port access are compared. Any difference stops the run.
#include "Vmb88.h"
#include "Vmb88___024root.h"
#include "verilated.h"
#include "mame_mb88.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <random>
#include <sstream>
#include <string>

static const int CLK_PER_TICK = 8;   // sys clocks per MAME cycle in the bench (192 on the board)

struct Ev {
    char kind;   // 'R' read strobe, 'W' R-port write, 'O' O write (mask), 'P' P write
    int port;
    int val;
    bool operator<(const Ev &o) const {
        return std::tie(kind, port, val) < std::tie(o.kind, o.port, o.val);
    }
    bool operator==(const Ev &o) const { return kind == o.kind && port == o.port && val == o.val; }
};

struct Stim {
    bool irq = false, tc = false, si = false;
    uint8_t k = 0;
    uint16_t r = 0;
};

struct Bench {
    Vmb88 *top;
    Vmb88___024root *rp;
    mb88_cpu_device mame;
    std::vector<uint8_t> rom;       // shared program image
    Stim cur;
    std::vector<Ev> ev_rtl, ev_mame;
    std::vector<uint16_t> pcs_rtl;
    uint64_t ticks = 0;
    uint64_t insns = 0;
    std::function<void()> on_port;  // hook for ROM campaigns: react to port writes
    // coverage, observed on the MAME side after each tick
    uint64_t cov_int[8] = {0};      // interrupt entries by vector PC 2/4/6
    uint64_t cov_sf = 0, cov_vf = 0, cov_ser_off = 0, cov_ser_on = 0, cov_rti = 0, cov_ports = 0;
    uint64_t cov_ops[256] = {0};
    bool p_in_irq = false, p_sf = false, p_vf = false, p_armed = false;
    void coverage() {
        if (mame.m_in_irq && !p_in_irq && mame.m_PA == 0 && mame.m_PC <= 6) cov_int[mame.m_PC]++;
        if (!mame.m_in_irq && p_in_irq) cov_rti++;
        if (mame.m_sf && !p_sf) cov_sf++;
        if (mame.m_vf && !p_vf) cov_vf++;
        if (!mame.m_serial_obj.armed && p_armed) cov_ser_off++;
        if (mame.m_serial_obj.armed && !p_armed) cov_ser_on++;
        cov_ports += ev_mame.size();
        for (auto pc : mame.insn_pcs) cov_ops[mame.rom[pc & 0x3ff]]++;
        p_in_irq = mame.m_in_irq; p_sf = mame.m_sf; p_vf = mame.m_vf; p_armed = mame.m_serial_obj.armed;
    }
    std::string coverage_report() {
        std::ostringstream o;
        int unseen = 0; for (int i = 0; i < 256; i++) if (!cov_ops[i]) unseen++;
        o << "  coverage: irq entries ext=" << cov_int[2] << " timer=" << cov_int[4] << " serial=" << cov_int[6]
          << ", rti=" << cov_rti << ", sf sets=" << cov_sf << ", vf sets=" << cov_vf
          << ", serial timer on/off=" << cov_ser_on << "/" << cov_ser_off
          << ", port accesses=" << cov_ports << ", opcodes never executed=" << unseen;
        return o.str();
    }

    Bench() : top(new Vmb88), mame(10, 6), rom(1024, 0) {
        rp = top->rootp;
        top->clk = 0; top->reset = 0; top->cen = 0;
        top->eval();
        mame.m_read_k.f = [this]() { return cur.k; };
        for (int n = 0; n < 4; n++) {
            mame.m_read_r[n].f = [this, n]() { ev_mame.push_back({'R', n, 0}); return (u8)((cur.r >> (4 * n)) & 0xf); };
            mame.m_write_r[n].f = [this, n](u8 v) { ev_mame.push_back({'W', n, v}); };
        }
        mame.m_write_o.f = [this](u8 v, u8 mask) { ev_mame.push_back({'O', mask, v}); };
        mame.m_write_p.f = [this](u8 v) { ev_mame.push_back({'P', 0, v & 0xf}); };
        mame.m_read_si.f = [this]() { return (u8)cur.si; };
    }

    void load_rom(const std::vector<uint8_t> &img) {
        rom = img;
        mame.rom = img;
    }

    // one sys clock with a registered-read ROM
    void clock() {
        uint32_t a = top->rom_addr;
        top->clk = 1; top->eval();
        top->rom_data = rom[a & 0x3ff];
        top->eval();
        // strobes are registered outputs; sample after the edge
        if (top->r_re) for (int n = 0; n < 4; n++) if (top->r_re >> n & 1) ev_rtl.push_back({'R', n, 0});
        if (top->r_we) for (int n = 0; n < 4; n++) if (top->r_we >> n & 1) ev_rtl.push_back({'W', n, (top->r_out >> (4 * n)) & 0xf});
        if (top->o_we) ev_rtl.push_back({'O', top->o_we == 1 ? 0x0f : 0xf0, top->o_out});
        if (top->p_we) ev_rtl.push_back({'P', 0, top->p_out});
        if (top->dbg_insn) pcs_rtl.push_back(top->dbg_pc);
        top->clk = 0; top->eval();
    }

    void reset_both() {
        top->reset = 1; clock(); clock();
        top->reset = 0; clock(); clock();
        mame.device_reset();
        mame.m_icount = 0;
        ev_rtl.clear(); ev_mame.clear(); pcs_rtl.clear(); mame.insn_pcs.clear();
    }

    void apply_pins(const Stim &s) {
        top->irq = s.irq; top->tc = s.tc; top->si = s.si; top->k_in = s.k; top->r_in = s.r;
    }

    // returns false on a MAME fatalerror (state no longer comparable)
    bool tick(const Stim &next) {
        // 1. cen edge: serial timer
        top->cen = 1; clock(); top->cen = 0;
        if (mame.m_serial_obj.armed) mame.serial_timer(0);
        // 2. input changes
        Stim prev = cur;
        cur = next;
        apply_pins(cur);
        top->eval();
        if (prev.irq != cur.irq) mame.execute_set_input(MB88XX_IRQ_LINE, cur.irq);
        if (prev.tc != cur.tc)   mame.execute_set_input(MB88XX_TC_LINE, cur.tc);
        // 3. one cycle of budget
        bool ok = true;
        try { mame.run_cycle(); } catch (shim_fatal &) { ok = false; }
        for (int i = 1; i < CLK_PER_TICK; i++) clock();
        ticks++;
        return ok;
    }

    std::string state_diff() {
        std::ostringstream d;
        auto chk = [&](const char *n, long r, long m) { if (r != m) d << " " << n << " rtl=" << std::hex << r << " mame=" << m << std::dec; };
        chk("PC", rp->mb88__DOT__PC, mame.m_PC);
        chk("PA", rp->mb88__DOT__PA, mame.m_PA);
        for (int i = 0; i < 4; i++) { char n[8]; snprintf(n, 8, "SP%d", i); chk(n, rp->mb88__DOT__SP[i], mame.m_SP[i]); }
        chk("SI", rp->mb88__DOT__SI, mame.m_SI);
        chk("A", rp->mb88__DOT__A, mame.m_A);
        chk("X", rp->mb88__DOT__X, mame.m_X);
        chk("Y", rp->mb88__DOT__Y, mame.m_Y);
        chk("st", rp->mb88__DOT__st, mame.m_st);
        chk("zf", rp->mb88__DOT__zf, mame.m_zf);
        chk("cf", rp->mb88__DOT__cf, mame.m_cf);
        chk("vf", rp->mb88__DOT__vf, mame.m_vf);
        chk("sf", rp->mb88__DOT__sf, mame.m_sf);
        chk("if", rp->mb88__DOT__if_, mame.m_if);
        chk("ctr", rp->mb88__DOT__ctr, mame.m_ctr);
        chk("pio", rp->mb88__DOT__pio, mame.m_pio);
        chk("TH", rp->mb88__DOT__TH, mame.m_TH);
        chk("TL", rp->mb88__DOT__TL, mame.m_TL);
        chk("TP", rp->mb88__DOT__TP, mame.m_TP);
        chk("SB", rp->mb88__DOT__SB, mame.m_SB);
        chk("SBcount", rp->mb88__DOT__SBcount, mame.m_SBcount);
        chk("serial", rp->mb88__DOT__ser_on, mame.m_serial_obj.armed);
        chk("pending", rp->mb88__DOT__pending_irq, mame.m_pending_irq);
        chk("in_irq", rp->mb88__DOT__in_irq, mame.m_in_irq);
        chk("o_output", rp->mb88__DOT__o_output, mame.m_o_output);
        chk("credit", (int8_t)(rp->mb88__DOT__credit << 4) >> 4, mame.m_icount);
        for (int i = 0; i < 64; i++) {
            char n[12]; snprintf(n, 12, "ram%02x", i);
            chk(n, rp->mb88__DOT__ram[i], mame.ram[i] & 0xf);
        }
        // instructions started
        if (pcs_rtl != mame.insn_pcs) {
            d << " insns rtl=[";
            for (auto p : pcs_rtl) d << std::hex << p << " ";
            d << "] mame=[";
            for (auto p : mame.insn_pcs) d << std::hex << p << " ";
            d << "]" << std::dec;
        }
        // port accesses
        auto a = ev_rtl, b = ev_mame;
        std::sort(a.begin(), a.end()); std::sort(b.begin(), b.end());
        if (a != b) {
            d << " ports rtl=[";
            for (auto &e : a) d << e.kind << e.port << ":" << std::hex << e.val << std::dec << " ";
            d << "] mame=[";
            for (auto &e : b) d << e.kind << e.port << ":" << std::hex << e.val << std::dec << " ";
            d << "]";
        }
        return d.str();
    }

    void end_tick_bookkeeping() {
        coverage();
        insns += pcs_rtl.size();
        ev_rtl.clear(); ev_mame.clear(); pcs_rtl.clear(); mame.insn_pcs.clear();
    }

    // force identical architectural state into both models
    void force_state(std::mt19937 &rng) {
        auto R = [&](int bits) { return (uint32_t)(rng() & ((1u << bits) - 1)); };
        mame.m_PC = R(6);
        mame.m_PA = (R(8) < 8) ? R(8) : R(4);     // mostly in range, occasionally wild
        for (int i = 0; i < 4; i++) mame.m_SP[i] = R(16);
        mame.m_SI = R(2);
        mame.m_A = R(4); mame.m_X = R(4); mame.m_Y = R(4);
        mame.m_st = R(1); mame.m_zf = R(1); mame.m_cf = R(1); mame.m_vf = R(1); mame.m_sf = R(1);
        uint8_t pio = R(8);
        if ((pio & 0x30) == 0x10 || (pio & 0x30) == 0x30) pio &= ~0x10;
        mame.m_pio = pio;
        mame.m_TH = R(4); mame.m_TL = R(4); mame.m_TP = R(5);
        mame.m_SB = R(4);
        mame.m_SBcount = (R(2) == 0) ? 995 + R(3) : R(3);
        mame.m_serial_obj.armed = ((pio & 0x30) == 0x20) ? R(1) : 0;
        mame.m_pending_irq = R(3);
        mame.m_in_irq = R(1);
        mame.m_o_output = R(8);
        mame.m_icount = 0;
        for (auto &v : mame.ram) v = R(4);

        rp->mb88__DOT__PC = mame.m_PC;
        rp->mb88__DOT__PA = mame.m_PA;
        for (int i = 0; i < 4; i++) rp->mb88__DOT__SP[i] = mame.m_SP[i];
        rp->mb88__DOT__SI = mame.m_SI;
        rp->mb88__DOT__A = mame.m_A; rp->mb88__DOT__X = mame.m_X; rp->mb88__DOT__Y = mame.m_Y;
        rp->mb88__DOT__st = mame.m_st; rp->mb88__DOT__zf = mame.m_zf; rp->mb88__DOT__cf = mame.m_cf;
        rp->mb88__DOT__vf = mame.m_vf; rp->mb88__DOT__sf = mame.m_sf;
        rp->mb88__DOT__pio = mame.m_pio;
        rp->mb88__DOT__TH = mame.m_TH; rp->mb88__DOT__TL = mame.m_TL; rp->mb88__DOT__TP = mame.m_TP;
        rp->mb88__DOT__SB = mame.m_SB; rp->mb88__DOT__SBcount = mame.m_SBcount;
        rp->mb88__DOT__ser_on = mame.m_serial_obj.armed;
        rp->mb88__DOT__pending_irq = mame.m_pending_irq;
        rp->mb88__DOT__in_irq = mame.m_in_irq;
        rp->mb88__DOT__o_output = mame.m_o_output;
        rp->mb88__DOT__credit = 0;
        for (int i = 0; i < 64; i++) rp->mb88__DOT__ram[i] = mame.ram[i];
        top->eval();
    }
};

static Stim random_stim(std::mt19937 &rng, const Stim &prev, int toggle_permille) {
    Stim s = prev;
    auto roll = [&]() { return (int)(rng() % 1000) < toggle_permille; };
    if (roll()) s.irq = !s.irq;
    if (roll()) s.tc = !s.tc;
    if (roll()) s.si = !s.si;
    if (roll()) s.k = rng() & 0xf;
    if (roll()) s.r = rng() & 0xffff;
    return s;
}

static int fail(Bench &b, const std::string &what, const std::string &d) {
    std::cerr << "MISMATCH " << what << " at tick " << b.ticks << ":" << d << "\n";
    return 1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { std::cerr << "usage: see header\n"; return 2; }
    std::string mode = argv[1];
    Bench b;

    if (mode == "directed") {
        int samples = argc > 2 ? atoi(argv[2]) : 2000;
        uint32_t seed = argc > 3 ? strtoul(argv[3], 0, 0) : 1;
        std::mt19937 rng(seed);
        uint64_t checked = 0, fatals = 0;
        b.reset_both();
        for (int op = 0; op < 256; op++) {
            for (int s = 0; s < samples; s++) {
                std::vector<uint8_t> img(1024);
                for (auto &v : img) v = rng() & 0xff;
                Stim st = random_stim(rng, b.cur, 300);
                b.cur = st; b.apply_pins(st);
                b.force_state(rng);
                // both models agree the pins are already at these levels
                b.mame.m_if = st.irq; b.mame.m_ctr = st.tc;
                b.rp->mb88__DOT__if_ = st.irq; b.rp->mb88__DOT__ctr = st.tc;
                img[(((unsigned)b.mame.m_PA << 6) + b.mame.m_PC) & 0x3ff] = op;
                b.load_rom(img);
                b.top->eval();
                // let the RTL's registered ROM output catch up with the new image
                b.clock();
                b.end_tick_bookkeeping();
                bool fatal = false;
                for (int t = 0; t < 3 && !fatal; t++) {
                    Stim n = random_stim(rng, b.cur, 200);
                    if (!b.tick(n)) { fatal = true; fatals++; break; }
                    std::string d = b.state_diff();
                    if (!d.empty()) {
                        std::ostringstream w; w << "directed op=" << std::hex << op << std::dec << " sample " << s << " step " << t;
                        return fail(b, w.str(), d);
                    }
                    b.end_tick_bookkeeping();
                    checked++;
                }
                if (fatal) { b.reset_both(); b.rp->mb88__DOT__ser_on = b.mame.m_serial_obj.armed; b.top->eval(); }
            }
        }
        std::cout << "directed: 256 opcodes x " << samples << " samples, " << checked
                  << " ticks compared, " << b.insns << " instructions, " << fatals
                  << " MAME fatalerror samples skipped, 0 mismatches\n" << b.coverage_report() << "\n";
        return 0;
    }

    if (mode == "random") {
        uint64_t total = argc > 2 ? strtoull(argv[2], 0, 0) : 1000000;
        uint32_t seed = argc > 3 ? strtoul(argv[3], 0, 0) : 1;
        std::mt19937 rng(seed);
        uint64_t programs = 0, fatals = 0;
        std::vector<uint8_t> img(1024);
        auto new_program = [&]() {
            for (auto &v : img) v = rng() & 0xff;
            b.load_rom(img);
            b.reset_both();
            if (rng() % 4) {
                // start from a random architectural state (interrupts, timers and
                // serial enabled at random) instead of from reset
                b.force_state(rng);
                b.mame.m_if = b.cur.irq; b.mame.m_ctr = b.cur.tc;
                b.rp->mb88__DOT__if_ = b.cur.irq; b.rp->mb88__DOT__ctr = b.cur.tc;
                if (rng() % 4) { b.mame.m_in_irq = false; b.rp->mb88__DOT__in_irq = 0; }
            } else {
                for (int i = 0; i < 64; i++) { uint8_t v = rng() & 0xf; b.mame.ram[i] = v; b.rp->mb88__DOT__ram[i] = v; }
            }
            b.top->eval();
            b.clock();   // registered ROM output catches up with the new image
            b.end_tick_bookkeeping();
            programs++;
        };
        new_program();
        uint64_t since = 0;
        while (b.ticks < total) {
            Stim n = random_stim(rng, b.cur, 20);
            if (!b.tick(n)) {
                // MAME threw out of pio_enable part way through: its serial timer
                // state is now whatever the crash left. Resynchronise the RTL to it.
                fatals++; new_program(); since = 0;
                b.rp->mb88__DOT__ser_on = b.mame.m_serial_obj.armed;
                b.top->eval();
                continue;
            }
            std::string d = b.state_diff();
            if (!d.empty()) return fail(b, "random seed " + std::to_string(seed), d);
            b.end_tick_bookkeeping();
            if (++since == 3000) { new_program(); since = 0; }
        }
        std::cout << "random seed " << seed << ": " << b.ticks << " ticks, " << b.insns
                  << " instructions, " << programs << " programs, " << fatals
                  << " MAME fatalerror restarts, 0 mismatches\n" << b.coverage_report() << "\n";
        return 0;
    }


    if (mode == "rom") {
        // Real MCU ROM in lockstep, driven by stimulus converted from a MAME
        // capture by sim/mb88/make_stim.py: the chip select / rw / command
        // bytes / inputs the chip actually saw, on the MCU's 256 kHz grid.
        if (argc < 5) { std::cerr << "tb_mb88 rom <chip 51|52|53|54> <stim.txt> <romdir> [ticks]\n"; return 2; }
        int chip = atoi(argv[2]);
        std::string stimfile = argv[3], dir = argv[4];
        uint64_t total = argc > 5 ? strtoull(argv[5], 0, 0) : ~0ull;

        auto readfile = [&](const std::string &p, size_t expect) {
            std::ifstream f(p, std::ios::binary);
            if (!f) { std::cerr << "cannot open " << p << "\n"; exit(2); }
            std::vector<uint8_t> v((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            if (v.size() != expect) { std::cerr << p << " size " << v.size() << "\n"; exit(2); }
            return v;
        };
        const char *romname = chip == 51 ? "/51xx.bin" : chip == 52 ? "/52xx.bin" : chip == 53 ? "/53xx.bin" : "/54xx.bin";
        b.load_rom(readfile(dir + romname, 1024));
        std::vector<uint8_t> smp(0x8000, 0);
        if (chip == 52) {
            auto a = readfile(dir + "/pp2_11.2e", 8192), c = readfile(dir + "/pp2_12.2f", 8192), d = readfile(dir + "/pp2_13.1e", 8192);
            memcpy(&smp[0x0000], a.data(), 8192);
            memcpy(&smp[0x2000], c.data(), 8192);
            memcpy(&smp[0x4000], d.data(), 8192);
        }

        // glue state, fed by the port writes both models make (they are compared
        // every tick, so a divergence fails before it can feed anything back)
        uint8_t portO = 0, cmd = 0;
        uint16_t addr52 = 0;
        uint8_t in0 = 0xff, dswa = 0xff, dswb = 0xff, steer = 0;
        uint8_t steer_last = 0; int16_t steer_accum = 0; uint8_t steer_delta = 0;
        int sel = 0, rw = 0, vbl = 0, rst = 1;

        std::ifstream st(stimfile);
        if (!st) { std::cerr << "cannot open " << stimfile << "\n"; return 2; }
        struct Sev { uint64_t t; std::string line; };
        std::vector<Sev> sev;
        { std::string l; while (std::getline(st, l)) if (!l.empty()) { std::istringstream ss(l); uint64_t t; ss >> t; sev.push_back({t, l}); } }

        b.reset_both();
        bool in_reset = true;
        size_t si = 0;
        uint64_t ticks_run = 0, insns0 = 0, port_evs = 0;
        uint64_t last_tick = sev.empty() ? 0 : sev.back().t;
        for (uint64_t tk = 0; tk <= last_tick && ticks_run < total; tk++) {
            while (si < sev.size() && sev[si].t == tk) {
                std::istringstream ss(sev[si].line);
                uint64_t t; char k; ss >> t >> k;
                if (k == 'S') { ss >> sel >> rw; }
                else if (k == 'W') { int v; ss >> v; cmd = v; if (chip == 51) portO = v; }
                else if (k == 'V') { ss >> vbl; }
                else if (k == 'I') { int a, c2, d, e; ss >> a >> c2 >> d >> e; in0 = a; dswa = c2; dswb = d; steer = e; }
                else if (k == 'R') { int r; ss >> r; rst = r; }
                si++;
            }
            if (rst) {
                if (!in_reset) { b.reset_both(); b.rp->mb88__DOT__ser_on = b.mame.m_serial_obj.armed; b.top->eval(); in_reset = true; }
                continue;
            }
            in_reset = false;

            // chip glue: K and the R ports, exactly as the namco5x devices wire them
            Stim s;
            s.irq = sel;
            s.tc  = (chip == 51) ? !vbl : false;
            s.si  = (chip == 52);
            if (chip == 51) {
                s.k = (rw << 3) | (portO & 7);
                s.r = (dswb & 0xf) | ((dswb >> 4) << 4) | ((in0 & 0xf) << 8) | ((in0 >> 4) << 12);
            } else if (chip == 53) {
                uint8_t diff = steer - steer_last;
                int16_t acc = steer_accum + (int16_t)((int8_t)diff * 2);
                uint8_t dl = steer_delta;
                if (acc < 0) { dl = 0; acc++; } else if (acc > 0) { dl = 1; acc--; }
                s.k = 0;
                s.r = (acc & 1) | (steer_delta << 4) | ((dswa & 0xf) << 8) | ((dswa >> 4) << 12);
            } else if (chip == 52) {
                uint8_t v = (addr52 & 0x8000) ? 0xff : smp[addr52 & 0x7fff];
                s.k = cmd & 0xf;
                s.r = (v & 0xf) | ((v >> 4) << 4);
            } else {
                s.k = cmd >> 4;
                s.r = cmd & 0xf;
            }

            if (!b.tick(s)) { std::cerr << "MAME fatalerror on a real ROM at tick " << tk << "\n"; return 1; }
            std::string d = b.state_diff();
            if (!d.empty()) {
                std::ostringstream w; w << "rom " << chip << " stim tick " << tk;
                return fail(b, w.str(), d);
            }
            // feed back this tick's port writes
            for (auto &e : b.ev_mame) {
                port_evs++;
                if (e.kind == 'O') {
                    if (chip == 51) portO = (uint8_t)e.val;
                    if (chip == 52) addr52 = (addr52 & 0x00ff) | ((uint16_t)e.val << 8);
                } else if (e.kind == 'W' && chip == 52) {
                    if (e.port == 2) addr52 = (addr52 & 0xfff0) | (e.val & 0xf);
                    if (e.port == 3) addr52 = (addr52 & 0xff0f) | ((e.val & 0xf) << 4);
                } else if (e.kind == 'R' && chip == 53 && e.port == 0) {
                    uint8_t diff = steer - steer_last;
                    int16_t acc = steer_accum + (int16_t)((int8_t)diff * 2);
                    if (acc < 0) { steer_delta = 0; acc++; } else if (acc > 0) { steer_delta = 1; acc--; }
                    steer_accum = acc; steer_last = steer;
                }
            }
            b.end_tick_bookkeeping();
            ticks_run++;
        }
        std::cout << "rom " << chip << ": " << ticks_run << " ticks compared, " << b.insns
                  << " instructions, " << port_evs << " port accesses, 0 mismatches\n"
                  << b.coverage_report() << "\n";
        return 0;
    }

    std::cerr << "unknown mode\n";
    return 2;
}
