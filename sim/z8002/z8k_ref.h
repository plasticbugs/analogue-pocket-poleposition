// Standalone reference model of MAME 0.288's Z8002 core.
//
// The class below mirrors z8002_device's data members exactly (names and
// types), so that MAME's z8000ops.hxx / z8000tbl.hxx and the functions
// gen_shim.py extracts from z8000.cpp compile unmodified against it. Only the
// device plumbing is replaced: memory_access becomes a logging 64K memory,
// devcb callbacks return their unbound defaults, logging is a no-op.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cassert>
#include <vector>
#include <functional>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int32_t s32;
typedef uint32_t offs_t;

// little-endian host register union layout (MAME util::BYTE*_XOR_BE)
constexpr inline int BYTE_XOR_BE(int a)  { return a ^ 1; }
constexpr inline int BYTE4_XOR_BE(int a) { return a ^ 3; }
constexpr inline int BYTE8_XOR_BE(int a) { return a ^ 7; }
#define BIT(x, n) (((x) >> (n)) & 1)
inline u16 swapendian_int16(u16 v) { return (u16)((v << 8) | (v >> 8)); }

enum { ENDIANNESS_BIG = 1 };
enum { CLEAR_LINE = 0, ASSERT_LINE = 1 };
enum { INPUT_LINE_NMI = 32 };

// One access as seen on the CPU's bus.
struct z8k_access {
    enum Kind { FETCH, READ, WRITE } kind;
    bool io;          // I/O space
    bool byte;        // byte access (else word)
    u16  addr;        // byte: exact byte address; word: even address
    u16  val;
};

// Memory the model runs against: a flat 64K byte array (big endian words),
// plus an I/O read function. Every access is logged.
struct z8k_bus {
    u8 mem[0x10000];
    std::function<u16(u16)> io_read_word;   // word at even port address
    std::vector<z8k_access> log;
    bool logging = true;
    z8k_bus() { memset(mem, 0, sizeof(mem)); io_read_word = [](u16 a) { return (u16)(a * 0x9e37u ^ 0x5a5a); }; }
    u16 word(u16 a) const { return (u16)(mem[a] << 8 | mem[(u16)(a + 1)]); }
};

struct fake_space {
    z8k_bus *bus = nullptr;
    bool io = false;
    bool fetch = false;
    void rec(z8k_access::Kind k, bool byte, u16 a, u16 v) {
        if (bus->logging) bus->log.push_back({k, io, byte, a, v});
    }
    u16 native(u16 a) { return io ? bus->io_read_word(a) : bus->word(a); }
    u8 read_byte(offs_t address) {
        u16 a = address & 0xffff;
        u16 w = native(a & 0xfffe);
        u8 v = (a & 1) ? (w & 0xff) : (w >> 8);
        rec(fetch ? z8k_access::FETCH : z8k_access::READ, true, a, v);
        return v;
    }
    u16 read_word(offs_t address) {
        u16 a = address & 0xfffe;
        u16 v = native(a);
        rec(fetch ? z8k_access::FETCH : z8k_access::READ, false, a, v);
        return v;
    }
    u16 read_word(offs_t address, u16 mask) {
        u16 a = address & 0xfffe;
        u16 v = native(a) & mask;
        rec(fetch ? z8k_access::FETCH : z8k_access::READ, mask != 0xffff, a, v);
        return v;
    }
    void write_word(offs_t address, u16 data, u16 mask = 0xffff) {
        u16 a = address & 0xfffe;
        if (mask == 0xffff) {
            rec(z8k_access::WRITE, false, a, data);
            if (!io) { bus->mem[a] = data >> 8; bus->mem[(u16)(a + 1)] = data & 0xff; }
        } else if (mask == 0xff00) {
            rec(z8k_access::WRITE, true, a, data >> 8);
            if (!io) bus->mem[a] = data >> 8;
        } else if (mask == 0x00ff) {
            rec(z8k_access::WRITE, true, (u16)(a + 1), data & 0xff);
            if (!io) bus->mem[(u16)(a + 1)] = data & 0xff;
        } else {
            assert(!"unexpected write mask");
        }
    }
};

template <int A, int B, int C, int D>
struct memory_access { using specific = fake_space; using cache = fake_space; };

struct fake_iack { u16 operator()(u32) { return 0xffff; } };
struct fake_iack_arr { fake_iack a[4]; fake_iack &operator[](int i) { return a[i]; } };
struct fake_line { void operator()(int) {} };

#define LOG(...) ((void)0)
#define ATTR_COLD

class z8002_device
{
public:
	static constexpr uint8_t Z8000_EPU     = 0x80;
	static constexpr uint8_t Z8000_TRAP    = 0x40;
	static constexpr uint8_t Z8000_NMI     = 0x20;
	static constexpr uint8_t Z8000_SEGTRAP = 0x10;
	static constexpr uint8_t Z8000_NVI     = 0x08;
	static constexpr uint8_t Z8000_VI      = 0x04;
	static constexpr uint8_t Z8000_SYSCALL = 0x02;
	static constexpr uint8_t Z8000_RESET   = 0x01;
	enum { NVI_LINE = 0, VI_LINE = 1, NMI_LINE = INPUT_LINE_NMI };

	fake_iack_arr m_iack_in;
	fake_line m_mo_out;

	uint32_t  m_op[4];
	uint32_t  m_ppc;
	uint32_t  m_pc;
	uint16_t  m_psapseg;
	uint16_t  m_psapoff;
	uint16_t  m_fcw;
	uint16_t  m_refresh;
	uint16_t  m_nspseg;
	uint16_t  m_nspoff;
	uint8_t   m_irq_req;
	uint16_t  m_irq_vec;
	uint32_t  m_op_valid;
	union
	{
		uint8_t   B[16];
		uint16_t  W[16];
		uint32_t  L[8];
		uint64_t  Q[4];
	} m_regs;
	int m_nmi_state;
	int m_irq_state[2];
	int m_mi;
	bool m_halt;
	memory_access<23, 1, 0, ENDIANNESS_BIG>::cache m_cache;
	memory_access<23, 1, 0, ENDIANNESS_BIG>::cache m_opcache;
	memory_access<23, 1, 0, ENDIANNESS_BIG>::specific m_program;
	memory_access<23, 1, 0, ENDIANNESS_BIG>::specific m_data;
	memory_access<23, 1, 0, ENDIANNESS_BIG>::specific m_stack;
	memory_access<16, 1, 0, ENDIANNESS_BIG>::specific m_io;
	memory_access<16, 1, 0, ENDIANNESS_BIG>::specific m_sio;
	int m_icount;
	const int m_vector_mult = 1;

	template <typename... T> void logerror(T &&...) {}
	void standard_irq_callback(int, u32) {}

	// ---- harness API -------------------------------------------------------
	z8002_device(z8k_bus *bus) {
		for (fake_space *s : {&m_cache, &m_opcache, &m_program, &m_data, &m_stack, &m_io, &m_sio}) s->bus = bus;
		m_cache.fetch = m_opcache.fetch = true;
		m_io.io = m_sio.io = true;
		clear_internal_state();   // device_start
		init_tables();
		m_mi = CLEAR_LINE;
		m_halt = false;
		m_icount = 0;
		device_reset();
	}
	// One iteration of execute_run()'s loop body. Returns true if an
	// instruction was fetched and executed (false: halted).
	bool step();
	int handler_index(u16 op) const { return z8000_exec[op]; }
	int handler_cycles(u16 op) const { return table[z8000_exec[op]].cycles; }
	u16 &R(int n) { return m_regs.W[BYTE4_XOR_BE(n)]; }

	// ---- z8002_device members (declarations as in z8000.h) -----------------
	void device_reset();
	void execute_set_input(int inputnum, int state);
	void clear_internal_state();
	void init_tables();
	bool get_segmented_mode() const;
	static inline uint32_t addr_add(uint32_t addr, uint32_t addend);
	static inline uint32_t addr_sub(uint32_t addr, uint32_t subtrahend);
	inline uint16_t RDOP();
	inline uint32_t get_operand(int opnum);
	inline uint32_t get_addr_operand(int opnum);
	inline uint32_t get_raw_addr_operand(int opnum);
	uint32_t adjust_addr_for_nonseg_mode(uint32_t addr);
	inline uint8_t RDMEM_B(memory_access<23, 1, 0, ENDIANNESS_BIG>::specific &space, uint32_t addr);
	inline uint16_t RDMEM_W(memory_access<23, 1, 0, ENDIANNESS_BIG>::specific &space, uint32_t addr);
	inline uint32_t RDMEM_L(memory_access<23, 1, 0, ENDIANNESS_BIG>::specific &space, uint32_t addr);
	inline void WRMEM_B(memory_access<23, 1, 0, ENDIANNESS_BIG>::specific &space, uint32_t addr, uint8_t value);
	inline void WRMEM_W(memory_access<23, 1, 0, ENDIANNESS_BIG>::specific &space, uint32_t addr, uint16_t value);
	inline void WRMEM_L(memory_access<23, 1, 0, ENDIANNESS_BIG>::specific &space, uint32_t addr, uint32_t value);
	inline uint8_t RDPORT_B(int mode, uint16_t addr);
	inline uint16_t RDPORT_W(int mode, uint16_t addr);
	inline void WRPORT_B(int mode, uint16_t addr, uint8_t value);
	inline void WRPORT_W(int mode, uint16_t addr, uint16_t value);
	inline void cycles(int cycles);
	void PUSH_PC();
	void CHANGE_FCW(uint16_t fcw);
	static inline uint32_t make_segmented_addr(uint32_t addr);
	static inline uint32_t segmented_addr(uint32_t addr);
	inline uint32_t addr_from_reg(int regno);
	inline void addr_to_reg(int regno, uint32_t addr);
	inline void add_to_addr_reg(int regno, uint16_t addend);
	inline void sub_from_addr_reg(int regno, uint16_t subtrahend);
	inline void set_pc(uint32_t addr);
	inline uint8_t RDIR_B(uint8_t reg);
	inline uint16_t RDIR_W(uint8_t reg);
	inline uint32_t RDIR_L(uint8_t reg);
	inline void WRIR_B(uint8_t reg, uint8_t value);
	inline void WRIR_W(uint8_t reg, uint16_t value);
	inline void WRIR_L(uint8_t reg, uint32_t value);
	inline uint8_t RDBX_B(uint8_t reg, uint16_t idx);
	inline uint16_t RDBX_W(uint8_t reg, uint16_t idx);
	inline uint32_t RDBX_L(uint8_t reg, uint16_t idx);
	inline void WRBX_B(uint8_t reg, uint16_t idx, uint8_t value);
	inline void WRBX_W(uint8_t reg, uint16_t idx, uint16_t value);
	inline void WRBX_L(uint8_t reg, uint16_t idx, uint32_t value);
	inline void PUSHW(uint8_t dst, uint16_t value);
	inline uint16_t POPW(uint8_t src);
	inline void PUSHL(uint8_t dst, uint32_t value);
	inline uint32_t POPL(uint8_t src);
	inline uint8_t ADDB(uint8_t dest, uint8_t value);
	inline uint16_t ADDW(uint16_t dest, uint16_t value);
	inline uint32_t ADDL(uint32_t dest, uint32_t value);
	inline uint8_t ADCB(uint8_t dest, uint8_t value);
	inline uint16_t ADCW(uint16_t dest, uint16_t value);
	inline uint8_t SUBB(uint8_t dest, uint8_t value);
	inline uint16_t SUBW(uint16_t dest, uint16_t value);
	inline uint32_t SUBL(uint32_t dest, uint32_t value);
	inline uint8_t SBCB(uint8_t dest, uint8_t value);
	inline uint16_t SBCW(uint16_t dest, uint16_t value);
	inline uint8_t ORB(uint8_t dest, uint8_t value);
	inline uint16_t ORW(uint16_t dest, uint16_t value);
	inline uint8_t ANDB(uint8_t dest, uint8_t value);
	inline uint16_t ANDW(uint16_t dest, uint16_t value);
	inline uint8_t XORB(uint8_t dest, uint8_t value);
	inline uint16_t XORW(uint16_t dest, uint16_t value);
	inline void CPB(uint8_t dest, uint8_t value);
	inline void CPW(uint16_t dest, uint16_t value);
	inline void CPL(uint32_t dest, uint32_t value);
	inline uint8_t COMB(uint8_t dest);
	inline uint16_t COMW(uint16_t dest);
	inline uint8_t NEGB(uint8_t dest);
	inline uint16_t NEGW(uint16_t dest);
	inline void TESTB(uint8_t result);
	inline void TESTW(uint16_t dest);
	inline void TESTL(uint32_t dest);
	inline uint8_t INCB(uint8_t dest, uint8_t value);
	inline uint16_t INCW(uint16_t dest, uint16_t value);
	inline uint8_t DECB(uint8_t dest, uint8_t value);
	inline uint16_t DECW(uint16_t dest, uint16_t value);
	inline uint32_t MULTW(uint16_t dest, uint16_t value);
	inline uint64_t MULTL(uint32_t dest, uint32_t value);
	inline uint32_t DIVW(uint32_t dest, uint16_t value);
	inline uint64_t DIVL(uint64_t dest, uint32_t value);
	inline uint8_t RLB(uint8_t dest, uint8_t twice);
	inline uint16_t RLW(uint16_t dest, uint8_t twice);
	inline uint8_t RLCB(uint8_t dest, uint8_t twice);
	inline uint16_t RLCW(uint16_t dest, uint8_t twice);
	inline uint8_t RRB(uint8_t dest, uint8_t twice);
	inline uint16_t RRW(uint16_t dest, uint8_t twice);
	inline uint8_t RRCB(uint8_t dest, uint8_t twice);
	inline uint16_t RRCW(uint16_t dest, uint8_t twice);
	inline uint8_t SDAB(uint8_t dest, int8_t count);
	inline uint16_t SDAW(uint16_t dest, int8_t count);
	inline uint32_t SDAL(uint32_t dest, int8_t count);
	inline uint8_t SDLB(uint8_t dest, int8_t count);
	inline uint16_t SDLW(uint16_t dest, int8_t count);
	inline uint32_t SDLL(uint32_t dest, int8_t count);
	inline uint8_t SLAB(uint8_t dest, uint8_t count);
	inline uint16_t SLAW(uint16_t dest, uint8_t count);
	inline uint32_t SLAL(uint32_t dest, uint8_t count);
	inline uint8_t SLLB(uint8_t dest, uint8_t count);
	inline uint16_t SLLW(uint16_t dest, uint8_t count);
	inline uint32_t SLLL(uint32_t dest, uint8_t count);
	inline uint8_t SRAB(uint8_t dest, uint8_t count);
	inline uint16_t SRAW(uint16_t dest, uint8_t count);
	inline uint32_t SRAL(uint32_t dest, uint8_t count);
	inline uint8_t SRLB(uint8_t dest, uint8_t count);
	inline uint16_t SRLW(uint16_t dest, uint8_t count);
	inline uint32_t SRLL(uint32_t dest, uint8_t count);
	inline void Interrupt();
	uint32_t GET_PC(uint32_t VEC);
	uint32_t get_reset_pc();
	uint16_t GET_FCW(uint32_t VEC);
	uint32_t F_SEG_Z8001();
	uint32_t PSA_ADDR();
	uint32_t read_irq_vector();
	void zinvalid();

#define Z8K_DECLARE_OPS
#include "z8k_ref_ops.inc"
#undef Z8K_DECLARE_OPS

	typedef void (z8002_device::*opcode_func)();
	struct Z8000_init {
		int     beg, end, step;
		int     size, cycles;
		opcode_func opcode;
	};
	static const Z8000_init table[];
	u16 z8000_exec[0x10000];
	u8 z8000_zsp[256];
};

// Only CHANGE_FCW of the Z8001 appears in z8000ops.hxx; it is compiled but never used.
class z8001_device : public z8002_device
{
public:
	void CHANGE_FCW(uint16_t fcw);
};
