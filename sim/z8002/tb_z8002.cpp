// Lockstep co-simulation: rtl/z8002.sv against MAME 0.288's own z8000 opcode
// code (compiled by sim/z8002/gen_shim.py into a standalone model).
//
// Both sides keep their own 64K memory. After every step -- one iteration of
// MAME's execute_run() loop, i.e. an interrupt service and/or one instruction --
// the harness compares all registers, PC, FCW, NSP/PSAP, the interrupt request
// latch, the halt flag, the cycle cost charged, the exact sequence of bus
// writes and the set of bus reads. The first divergence stops the run and is
// printed with context.
//
//   tb_z8002 directed [seed]
//   tb_z8002 random <steps> <seed> [--irq]
//   tb_z8002 rom <sub1.bin> <steps>
#include "Vz8002.h"
#include "Vz8002_z8002.h"
#include "verilated.h"
#include "z8k_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>

static const int S_BOUND = 0;

struct Acc {
    int kind;      // 0 fetch, 1 read, 2 write
    bool io, byte;
    uint16_t addr, val;
};

static uint64_t rng_s = 1;
static uint32_t rnd() {
    rng_s = rng_s * 6364136223846793005ULL + 1442695040888963407ULL;
    return (uint32_t)(rng_s >> 33);
}

static uint16_t io_word(uint16_t a) { return (uint16_t)(a * 0x9e37u ^ 0x5a5a); }

struct Sim {
    VerilatedContext ctx;
    Vz8002 *top;
    z8k_bus rbus;              // reference memory + log
    z8002_device *ref;
    uint8_t mem[0x10000];      // RTL memory

    std::vector<Acc> rtl_acc;
    long long model_credit = 0;
    long long steps = 0, insns = 0, clocks = 0, charged = 0, busy = 0, worst = 0, worst_op = 0, skipped = 0;
    int cen_div = 16, cen_cnt = 0;
    int lat_max = 2;           // bus ack latency, randomised 0..lat_max
    int pend = -1;             // cycles left before ack

    Sim() {
        top = new Vz8002(&ctx);
        ref = new z8002_device(&rbus);
        memset(mem, 0, sizeof mem);
        top->clk = 0; top->reset = 1; top->cen = 0;
        top->nmi = top->nvi = top->vi = top->nvi_evt = top->vi_evt = 0;
        top->bus_ack = 0; top->bus_rdata = 0;
        for (int i = 0; i < 8; i++) cycle(false);
        top->reset = 0;
    }

    uint16_t rd16(const uint8_t *m, uint16_t a) { return (uint16_t)(m[a] << 8 | m[(uint16_t)(a + 1)]); }

    void serve() {
        if (!top->bus_req) { pend = -1; top->bus_ack = 0; return; }
        if (pend < 0) pend = lat_max ? (int)(rnd() % (lat_max + 1)) : 0;
        if (pend > 0) { pend--; top->bus_ack = 0; return; }
        pend = -1;
        uint16_t a = top->bus_addr;
        Acc ac;
        ac.io = top->bus_io;
        ac.byte = top->bus_byte;
        ac.kind = top->bus_we ? 2 : (top->z8002->st >= 3 && top->z8002->st <= 6) ? 0 : 1;
        if (top->bus_we) {
            if (ac.byte) {
                ac.addr = a;
                ac.val = (a & 1) ? (top->bus_wdata & 0xff) : (top->bus_wdata >> 8);
                if (!ac.io) mem[a] = (uint8_t)ac.val;
            } else {
                ac.addr = a & 0xfffe;
                ac.val = top->bus_wdata;
                if (!ac.io) { mem[ac.addr] = ac.val >> 8; mem[(uint16_t)(ac.addr + 1)] = ac.val & 0xff; }
            }
            top->bus_rdata = 0;
        } else {
            uint16_t w = ac.io ? io_word((uint16_t)(a & 0xfffe)) : rd16(mem, (uint16_t)(a & 0xfffe));
            top->bus_rdata = w;
            if (ac.byte) { ac.addr = a; ac.val = (a & 1) ? (w & 0xff) : (w >> 8); }
            else { ac.addr = a & 0xfffe; ac.val = w; }
        }
        rtl_acc.push_back(ac);
        top->bus_ack = 1;
    }

    // one clk cycle; returns true if the core finished a step on this edge
    bool cycle(bool allow_cen = true) {
        top->clk = 0; top->eval();
        bool cen = false;
        if (allow_cen && ++cen_cnt >= cen_div) { cen_cnt = 0; cen = true; }
        top->cen = cen;
        serve();
        top->eval();
        top->clk = 1; top->eval();
        clocks++;
        if (top->z8002->st != 0) busy++;   // not idle at an instruction boundary
        top->bus_ack = 0;
        bool done = top->z8002->step_done;
        if (!done && cen) model_credit++;
        else if (done) pending_cen = cen;
        return done;
    }
    bool pending_cen = false;
    int eff_credit() { return (int16_t)top->z8002->credit; }

    bool at_boundary() { return top->z8002->st == S_BOUND && top->z8002->sub == 0; }

    // ---- comparison ------------------------------------------------------
    std::string diff;
    template <typename A, typename B> bool chk(const char *what, A r, B x) {
        if ((uint64_t)r == (uint64_t)x) return true;
        char buf[160];
        snprintf(buf, sizeof buf, "%s: rtl %llx ref %llx\n", what, (unsigned long long)r, (unsigned long long)x);
        diff += buf;
        return false;
    }

    bool compare() {
        bool ok = true;
        auto &R = top->z8002->R;
        for (int i = 0; i < 16; i++) {
            char nm[8]; snprintf(nm, sizeof nm, "R%d", i);
            ok &= chk(nm, R[i], ref->R(i));
        }
        ok &= chk("PC", top->z8002->pc, ref->m_pc & 0xffff);
        ok &= chk("FCW", top->z8002->fcw, ref->m_fcw);
        ok &= chk("NSPOFF", top->z8002->nsp, ref->m_nspoff);
        ok &= chk("NSPSEG", top->z8002->nspseg, ref->m_nspseg);
        ok &= chk("PSAPOFF", top->z8002->psap, ref->m_psapoff);
        ok &= chk("PSAPSEG", top->z8002->psapseg, ref->m_psapseg);
        ok &= chk("REFRESH", top->z8002->refresh, ref->m_refresh);
        ok &= chk("IRQ_REQ", top->z8002->irq_req, ref->m_irq_req);
        ok &= chk("HALT", top->z8002->halt, (int)ref->m_halt);
        ok &= chk("CREDIT", (int16_t)top->z8002->credit, model_credit);

        // writes: exact sequence; reads: as a set (MAME re-reads some vectors)
        std::vector<Acc> rw, rr;
        for (auto &a : rtl_acc) (a.kind == 2 ? rw : rr).push_back(a);
        std::vector<z8k_access> fw, fr;
        for (auto &a : rbus.log) (a.kind == z8k_access::WRITE ? fw : fr).push_back(a);
        if (rw.size() != fw.size()) {
            char b[96]; snprintf(b, sizeof b, "write count: rtl %zu ref %zu\n", rw.size(), fw.size());
            diff += b; ok = false;
        } else {
            for (size_t i = 0; i < rw.size(); i++) {
                if (rw[i].addr != fw[i].addr || rw[i].val != fw[i].val ||
                    rw[i].byte != fw[i].byte || rw[i].io != fw[i].io) {
                    char b[160];
                    snprintf(b, sizeof b, "write %zu: rtl %s%s %04x=%04x ref %s%s %04x=%04x\n", i,
                             rw[i].io ? "io " : "", rw[i].byte ? "b" : "w", rw[i].addr, rw[i].val,
                             fw[i].io ? "io " : "", fw[i].byte ? "b" : "w", fw[i].addr, fw[i].val);
                    diff += b; ok = false;
                }
            }
        }
        auto key = [](bool io, bool byte, uint16_t a) { return (io ? 1u << 20 : 0u) | (byte ? 1u << 19 : 0u) | a; };
        std::map<uint32_t, int> refset;
        for (auto &a : fr) refset[key(a.io, a.byte, a.addr)]++;
        for (auto &a : rr)
            if (!refset.count(key(a.io, a.byte, a.addr))) {
                char b[96];
                snprintf(b, sizeof b, "read not in ref: %s%s %04x\n", a.io ? "io " : "", a.byte ? "b" : "w", a.addr);
                diff += b; ok = false;
            }
        std::map<uint32_t, int> rtlset;
        for (auto &a : rr) rtlset[key(a.io, a.byte, a.addr)]++;
        for (auto &a : fr)
            if (!rtlset.count(key(a.io, a.byte, a.addr))) {
                char b[96];
                snprintf(b, sizeof b, "read missing in rtl: %s%s %04x\n", a.io ? "io " : "", a.byte ? "b" : "w", a.addr);
                diff += b; ok = false;
            }
        if (ok && memcmp(mem, rbus.mem, sizeof mem) != 0) {
            for (int i = 0; i < 0x10000; i++)
                if (mem[i] != rbus.mem[i]) {
                    char b[96]; snprintf(b, sizeof b, "memory %04x: rtl %02x ref %02x\n", i, mem[i], rbus.mem[i]);
                    diff += b; break;
                }
            ok = false;
        }
        return ok;
    }

    // MAME shifts by counts >= 32 are C++ undefined behaviour; skip those
    // instructions rather than pretend the model defines them.
    bool ub_at_pc() {
        uint16_t pc = top->z8002->pc & 0xfffe;
        uint16_t op = rd16(mem, pc);
        uint8_t hi = op >> 8, lo = op & 0xf;
        if (hi != 0xb2 && hi != 0xb3) return false;
        if (lo == 1 || lo == 9 || (hi == 0xb3 && (lo == 5 || lo == 0xd))) {
            uint16_t imm = rd16(mem, (uint16_t)(pc + 2));
            if (hi == 0xb2) imm = (int16_t)(int8_t)(imm & 0xff);
            int cnt = (imm & 0x8000) ? ((-(int16_t)imm) & 0xff) : (imm & 0xff);
            return cnt > 31;
        }
        if (hi == 0xb2 && lo == 3) {   // sdlb: unsigned count
            uint16_t o1 = rd16(mem, (uint16_t)(pc + 2));
            return (top->z8002->R[(o1 >> 8) & 15] & 0xff) > 31;
        }
        return false;
    }
    // the same test applied to an instruction that has already run (an
    // interrupt taken at the start of a step can land on one the pre-step
    // check never saw)
    bool ub_executed(uint16_t op0, uint16_t op1, const uint16_t *regs_before) {
        uint8_t hi = op0 >> 8, lo = op0 & 0xf;
        if (hi != 0xb2 && hi != 0xb3) return false;
        if (lo == 1 || lo == 9 || (hi == 0xb3 && (lo == 5 || lo == 0xd))) {
            uint16_t imm = op1;
            if (hi == 0xb2) imm = (uint16_t)(int16_t)(int8_t)(imm & 0xff);
            int cnt = (imm & 0x8000) ? ((-(int16_t)imm) & 0xff) : (imm & 0xff);
            return cnt > 31;
        }
        if (hi == 0xb2 && lo == 3) return (regs_before[(op1 >> 8) & 15] & 0xff) > 31;
        return false;
    }
    // take the reference's state as truth (used only after a skipped step)
    void resync() {
        for (int i = 0; i < 16; i++) top->z8002->R[i] = ref->R(i);
        top->z8002->pc = ref->m_pc & 0xffff;
        top->z8002->fcw = ref->m_fcw;
        top->z8002->nsp = ref->m_nspoff;
        top->z8002->nspseg = ref->m_nspseg;
        top->z8002->psap = ref->m_psapoff;
        top->z8002->psapseg = ref->m_psapseg;
        top->z8002->refresh = ref->m_refresh;
        top->z8002->irq_req = ref->m_irq_req;
        top->z8002->halt = ref->m_halt;
        top->z8002->credit = (int16_t)model_credit;
        memcpy(mem, rbus.mem, sizeof mem);
    }
    void poke(uint16_t a, uint16_t v) {
        mem[a] = v >> 8; mem[(uint16_t)(a + 1)] = v & 0xff;
        rbus.mem[a] = v >> 8; rbus.mem[(uint16_t)(a + 1)] = v & 0xff;
    }

    long long trace_from = 0;
    int inj_nvi_evt = 0, inj_vi_evt = 0;
    FILE *pctrace = nullptr;
    // run one step on both sides, compare. false => divergence
    bool step_both() {
        if (trace_from && steps + 1 >= trace_from)
            printf("[%lld] pc %04x irq rtl %02x ref %02x fcw %04x lines %d%d%d evt %d%d credit rtl %d (raw %d pend %d) model %lld st %d\n",
                   steps + 1, top->z8002->pc, top->z8002->irq_req, ref->m_irq_req, ref->m_fcw,
                   top->nmi, top->nvi, top->vi, top->nvi_evt, top->vi_evt,
                   eff_credit(), eff_credit(), 0, model_credit, (int)top->z8002->st);
        if (ub_at_pc() && !top->z8002->halt) poke(top->z8002->pc & 0xfffe, 0x8d07);   // nop
        rtl_acc.clear();
        rbus.log.clear();
        uint16_t ppc = top->z8002->pc;
        uint16_t regs_before[16];
        for (int i = 0; i < 16; i++) regs_before[i] = ref->R(i);

        uint16_t was_halt = top->z8002->halt;
        // hardware pulses *_evt for exactly one clock; do the same here so the
        // core's edge detection sees one event per set_input_line call
        top->nvi_evt = inj_nvi_evt; top->vi_evt = inj_vi_evt;
        inj_nvi_evt = inj_vi_evt = 0;
        long long guard = 0;
        long long busy0 = busy;
        bool first = true;
        while (!cycle()) {
            if (first) { top->nvi_evt = 0; top->vi_evt = 0; first = false; }
            if (++guard > 200000) { diff += "rtl step did not finish\n"; return false; }
        }
        top->nvi_evt = 0; top->vi_evt = 0;
        ref->m_icount = (int)model_credit;
        bool ran = ref->step();
        charged += model_credit - ref->m_icount;
        model_credit = ref->m_icount;
        if (pending_cen) { model_credit++; pending_cen = false; }
        steps++;
        if (busy - busy0 > worst) { worst = busy - busy0; worst_op = ref->m_op[0]; }
        if (ran) insns++;
        if (pctrace && ran) fprintf(pctrace, "%04X\n", (unsigned)(ref->m_ppc & 0xffff));
        if (ran && ub_executed((uint16_t)ref->m_op[0], (uint16_t)ref->m_op[1], regs_before)) {
            skipped++;
            resync();
            return true;
        }
        if (!compare()) {
            printf("\n*** divergence at step %lld (pc %04x%s, op %04x/%04x op1 %04x cls %d cyc %d)\n%s",
                   steps, ppc, was_halt ? ", halted" : "",
                   (unsigned)top->z8002->op0, (unsigned)ref->m_op[0], (unsigned)top->z8002->op1,
                   (int)top->z8002->c_cls, (int)top->z8002->c_cyc, diff.c_str());
            printf("    lines: rtl nmi %d nvi %d vi %d (q %d %d %d) evt %d %d | ref state nvi %d vi %d nmi %d\n",
                   top->nmi, top->nvi, top->vi, top->z8002->nmi_q, top->z8002->nvi_q, top->z8002->vi_q,
                   top->nvi_evt, top->vi_evt, ref->m_irq_state[0], ref->m_irq_state[1], ref->m_nmi_state);
            return false;
        }
        return true;
    }

    // set both sides to the same arbitrary state
    void set_state(const uint16_t r[16], uint16_t pc, uint16_t fcw, uint16_t nsp, uint16_t psap) {
        for (int i = 0; i < 16; i++) { top->z8002->R[i] = r[i]; ref->R(i) = r[i]; }
        top->z8002->pc = pc;   ref->m_pc = pc;
        top->z8002->fcw = fcw; ref->m_fcw = fcw;
        top->z8002->nsp = nsp; ref->m_nspoff = nsp;
        top->z8002->psap = psap; ref->m_psapoff = psap;
        top->z8002->irq_req = 0; ref->m_irq_req = 0;
        top->z8002->halt = 0;  ref->m_halt = false;
        top->z8002->credit = 0; model_credit = 0;
        top->z8002->refresh = 0; ref->m_refresh = 0;
        top->z8002->psapseg = 0; ref->m_psapseg = 0;
        top->z8002->nspseg = 0;  ref->m_nspseg = 0;
    }
    void sync_mem() { memcpy(rbus.mem, mem, sizeof mem); }
};

// ---------------------------------------------------------------------------
static void rand_state(Sim &s, bool sys = true) {
    uint16_t r[16];
    for (int i = 0; i < 16; i++) r[i] = (uint16_t)rnd();
    r[15] = 0x8000 | (rnd() & 0x7ffe);      // keep the stack inside RAM
    uint16_t fcw = (uint16_t)((rnd() & 0x38ff) | (sys ? 0x4000 : 0));
    s.set_state(r, (uint16_t)(rnd() & 0x7ffe), fcw, (uint16_t)(0x8000 | (rnd() & 0x7ffe)), (uint16_t)(rnd() & 0xfffe));
}

static int directed(Sim &s, int reps) {
    // every first word MAME's table can dispatch, at every table entry, run as a
    // single step from a randomised machine state
    for (int i = 0; i < 0x10000; i++) s.mem[i] = (uint8_t)(rnd() >> 3);
    s.sync_mem();
    int fails = 0;
    for (int op = 0; op < 0x10000; op++) {
        for (int rep = 0; rep < reps; rep++) {
            uint16_t pc = 0x1000;
            s.poke(pc, (uint16_t)op);
            s.poke(pc + 2, (uint16_t)rnd());
            s.poke(pc + 4, (uint16_t)rnd());
            rand_state(s, (rnd() & 3) != 0);      // mostly system mode, sometimes user
            s.top->z8002->pc = pc; s.ref->m_pc = pc;
            s.model_credit = 0;
            s.top->z8002->credit = 0;
            for (int i = 0; i < 40 && (int16_t)s.top->z8002->credit <= 0; i++) s.cycle();
            s.model_credit = (int16_t)s.top->z8002->credit;
            if (!s.step_both()) {
                printf("    (opcode %04x rep %d)\n", op, rep);
                if (++fails > 4) return 1;
            }
        }
        if ((op & 0xfff) == 0xfff) { printf("  opcodes through %04x ok (%lld steps)\n", op, s.steps); fflush(stdout); }
    }
    return fails ? 1 : 0;
}

// every DAB input: 256 values x C x H x D
static int dab_all(Sim &s) {
    for (int i = 0; i < 0x10000; i++) s.mem[i] = 0;
    s.sync_mem();
    for (int idx = 0; idx < 2048; idx++) {
        uint16_t r[16] = {0};
        r[0] = (uint16_t)((idx & 0xff) << 8);          // RH0
        r[15] = 0x8000;
        uint16_t fcw = 0x4000;
        if (idx & 0x100) fcw |= 0x0080;                // C
        if (idx & 0x200) fcw |= 0x0004;                // H
        if (idx & 0x400) fcw |= 0x0008;                // DA
        s.poke(0x1000, 0xb000);                        // dab rbh0
        s.set_state(r, 0x1000, fcw, 0x8000, 0);
        for (int i = 0; i < 40 && (int16_t)s.top->z8002->credit <= 0; i++) s.cycle();
        s.model_credit = (int16_t)s.top->z8002->credit;
        if (!s.step_both()) { printf("    (dab index %03x)\n", idx); return 1; }
    }
    return 0;
}

static int random_run(Sim &s, long long nsteps, bool irq) {
    for (int i = 0; i < 0x10000; i++) s.mem[i] = (uint8_t)rnd();
    s.sync_mem();
    rand_state(s, (rnd() & 3) != 0);
    for (long long i = 0; i < nsteps; i++) {
        if (irq && (rnd() % 64) == 0) {
            // deliver a line change at an instruction boundary, to both sides
            int which = rnd() % 3;
            int state = rnd() & 1;
            if (which == 0) { s.top->nmi = state; s.ref->execute_set_input(INPUT_LINE_NMI, state ? ASSERT_LINE : CLEAR_LINE); }
            // an ASSERT while the line is already high is still an event for
            // MAME, which is what the *_evt pulses carry
            // every set_input_line call is an event, even when the level does
            // not change; *_evt carries that, with the level saying which kind
            if (which == 1) { s.top->nvi = state; s.inj_nvi_evt = 1; s.ref->execute_set_input(z8002_device::NVI_LINE, state ? ASSERT_LINE : CLEAR_LINE); }
            if (which == 2) { s.top->vi = state;  s.inj_vi_evt = 1;  s.ref->execute_set_input(z8002_device::VI_LINE, state ? ASSERT_LINE : CLEAR_LINE); }
            s.top->eval();
        } else if (irq && (rnd() % 128) == 0 && s.top->nvi) {
            // MAME re-arms on every ASSERT even when the line is already high
            s.inj_nvi_evt = 1;
            s.ref->execute_set_input(z8002_device::NVI_LINE, ASSERT_LINE);
        }
        if (!s.step_both()) return 1;
        // keep it out of the weeds: random re-seed of state every so often
        if ((rnd() % 4096) == 0) rand_state(s, (rnd() & 3) != 0);   // sometimes user mode, for privilege traps
        if (s.top->z8002->halt && !irq) rand_state(s, (rnd() & 3) != 0);
    }
    return 0;
}

static int rom_run(Sim &s, const char *path, long long nsteps, long long frame_cycles) {
    FILE *f = fopen(path, "rb");
    if (!f) { printf("cannot open %s\n", path); return 1; }
    memset(s.mem, 0, sizeof s.mem);
    fread(s.mem, 1, 0x8000, f);
    fclose(f);
    s.sync_mem();
    uint16_t r[16] = {0};
    s.set_state(r, 0, 0, 0, 0);
    s.top->z8002->irq_req = 1;   // power-on reset request
    s.ref->m_irq_req = 1;
    long long cyc = 0;
    for (long long i = 0; i < nsteps; i++) {
        // NVI at the top of vblank, exactly as polepos.cpp's scanline callback
        cyc += 40;
        if (cyc >= frame_cycles) {
            cyc = 0;
            s.top->nvi = 1; s.inj_nvi_evt = 1;
            s.ref->execute_set_input(z8002_device::NVI_LINE, ASSERT_LINE);
        }
        if (!s.step_both()) return 1;
        // the game acknowledges by writing 0 to 0x6000; mirror that on the line
        for (auto &a : s.rtl_acc)
            if (a.kind == 2 && (a.addr & 0xe000) == 0x6000) {
                bool en = a.val & 1;
                if (!en) { s.top->nvi = 0; s.inj_nvi_evt = 1; s.ref->execute_set_input(z8002_device::NVI_LINE, CLEAR_LINE); }
            }
        s.top->eval();
    }
    return 0;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::string mode = argc > 1 ? argv[1] : "random";
    Sim s;
    if (getenv("Z8K_TRACE")) s.trace_from = atoll(getenv("Z8K_TRACE"));
    if (getenv("Z8K_PCTRACE")) s.pctrace = fopen(getenv("Z8K_PCTRACE"), "w");
    int rc = 0;
    if (mode == "directed") {
        rng_s = argc > 2 ? atoll(argv[2]) : 1;
        rc = directed(s, argc > 3 ? atoi(argv[3]) : 1);
    } else if (mode == "random") {
        long long n = argc > 2 ? atoll(argv[2]) : 100000;
        rng_s = argc > 3 ? atoll(argv[3]) : 1;
        bool irq = argc > 4 && std::string(argv[4]) == "--irq";
        rc = random_run(s, n, irq);
    } else if (mode == "dab") {
        rc = dab_all(s);
    } else if (mode == "rom") {
        long long n = argc > 3 ? atoll(argv[3]) : 100000;
        rng_s = 7;
        rc = rom_run(s, argv[2], n, 50688);   // 3.072 MHz / 60.606 Hz
    } else {
        printf("usage: tb_z8002 directed|random|rom ...\n");
        return 2;
    }
    if (s.pctrace) fclose(s.pctrace);
    printf("%s: %lld steps, %lld instructions -> %s\n", mode.c_str(), s.steps, s.insns,
           rc ? "DIVERGENCE" : "match");
    if (s.steps)
        printf("  budget: %.2f cpu cycles/instruction = %.1f sys clocks at 16x; core used %.2f clocks/instruction\n",
               (double)s.charged / s.steps, 16.0 * s.charged / s.steps, (double)s.busy / s.steps);
    if (s.steps) printf("  worst single step: %lld clocks (op %04x)\n", s.worst, (unsigned)s.worst_op);
    if (s.skipped) printf("  %lld steps skipped (shift count >= 32: undefined behaviour in MAME's C++)\n", s.skipped);
    return rc;
}
