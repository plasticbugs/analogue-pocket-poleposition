// Minimal stand-in for MAME's device framework, just enough to compile the
// MB88xx execution code copied verbatim from ref/mame/mb88xx.cpp
// (build/mb88/mb88_mame.inc, made by sim/mb88/gen_shim.py).
//
// Timing model: one call to tick() is one MAME cycle (chip clock / 6). The
// serial emu_timer fires once per cycle while armed, then input line changes
// are delivered, then execute_run() runs with one more cycle of budget. The RTL
// bench drives mb88.sv in exactly that order (see tb_mb88.cpp).
#pragma once
#include <cstdint>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <stdexcept>
#include <vector>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef int32_t s32;

enum { MB88XX_IRQ_LINE = 0, MB88XX_TC_LINE };

struct attotime {
    bool never_;
    double hz;
    static const attotime never;
    static attotime from_hz(double h) { return attotime{false, h}; }
};
inline const attotime attotime::never{true, 0};

struct shim_timer {
    bool armed = false;
    void adjust(const attotime &start, int = 0, const attotime & = attotime::never) {
        armed = !start.never_;
    }
};

struct shim_fatal : std::runtime_error {
    using std::runtime_error::runtime_error;
};

[[noreturn]] inline void fatalerror(const char *fmt, ...) {
    char buf[256];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    throw shim_fatal(buf);
}

#define TIMER_CALLBACK_MEMBER(name) void name(s32 param)

struct wr_cb {
    std::function<void(u8)> f;
    void operator()(u8 v) const { if (f) f(v); }
    void operator()(int, u8 v, u8 mask) const { (void)mask; if (f) f(v); }
};
struct wr_o_cb {
    std::function<void(u8, u8)> f;           // value, mask
    void operator()(int, u8 v, u8 mask) const { if (f) f(v, mask); }
};
struct rd_cb {
    std::function<u8()> f;
    u8 operator()() const { return f ? f() : 0; }
};

class mb88_cpu_device {
public:
    // ---- the fake framework -------------------------------------------------
    struct rom_t {
        std::vector<u8> *mem; u32 mask;
        u8 read_byte(u32 a) const { return (*mem)[a & mask]; }
    };
    struct ram_t {
        std::vector<u8> *mem; u32 mask;
        u8 read_byte(u32 a) const { return (*mem)[a & mask]; }
        void write_byte(u32 a, u8 v) { (*mem)[a & mask] = v; }
    };

    std::vector<u8> rom, ram;
    rom_t m_cache;
    ram_t m_data;
    shim_timer m_serial_obj;
    shim_timer *m_serial = &m_serial_obj;
    u32 m_clock = 1536000;
    u32 clock() const { return m_clock; }
    int insn_count = 0;
    std::vector<u16> insn_pcs;

    mb88_cpu_device(int program_width, int data_width)
        : rom(1u << program_width, 0), ram(1u << data_width, 0) {
        m_cache = rom_t{&rom, (1u << program_width) - 1};
        m_data  = ram_t{&ram, (1u << data_width) - 1};
        // device_start
        m_if = 0; m_ctr = 0; m_o_output = 0;
        m_pla_data = nullptr; m_pla_bits = 8;
    }

    void standard_irq_callback(int, int) {}
    void debugger_instruction_hook(int pc) { insn_count++; insn_pcs.push_back((u16)(pc & 0x7ff)); } // dbg_pc is 11 bits
    void logerror(const char *, ...) {}

    // one MAME cycle
    void run_cycle() { m_icount += 1; execute_run(); }

    // ---- MAME state (names and types exactly as mb88xx.h) ---------------------
    u8   m_PC = 0;
    u8   m_PA = 0;
    u16  m_SP[4] = {0, 0, 0, 0};
    u8   m_SI = 0;
    u8   m_A = 0;
    u8   m_X = 0;
    u8   m_Y = 0;
    u8   m_st = 1;
    u8   m_zf = 0;
    u8   m_cf = 0;
    u8   m_vf = 0;
    u8   m_sf = 0;
    u8   m_if = 0;
    u8   m_pio = 0;
    u8   m_TH = 0;
    u8   m_TL = 0;
    u8   m_TP = 0;
    u8   m_ctr = 0;
    u8   m_SB = 0;
    u16  m_SBcount = 0;
    u8  *m_pla_data;
    u8   m_pla_bits;
    u8   m_o_output = 0;
    rd_cb m_read_k;
    wr_o_cb m_write_o;
    wr_cb m_write_p;
    rd_cb m_read_r[4];
    wr_cb m_write_r[4];
    rd_cb m_read_si;
    wr_cb m_write_so;
    u8   m_pending_irq = 0;
    bool m_in_irq = false;
    int  m_icount = 0;

    // ---- MAME code (bodies in build/mb88/mb88_mame.inc) ----------------------
    void device_reset();
    TIMER_CALLBACK_MEMBER(serial_timer);
    void write_pla(u8 index);
    void execute_set_input(int inputnum, int state);
    void pio_enable(u8 newpio);
    void increment_timer();
    void burn_cycles(int cycles);
    void execute_run();
};

#include "mb88_mame.inc"
