# Internal module interfaces

Conventions every RTL module in `rtl/` follows, so the CPU cores, the Namco
customs, video and sound can be written and verified separately and still
plug together.

## Clocking

One system clock for the whole machine: **`clk` = 49.152 MHz**, which is
2 x the 24.576 MHz board crystal. Everything else is a clock enable derived
from one divider chain, so every rate is an exact integer ratio of the crystal:

| enable      | rate        | sys clocks | used by |
|-------------|-------------|-----------:|---------|
| `cen_pix`   | 6.144 MHz   | 8          | video dot clock (MASTER/4) |
| `cen_cpu`   | 3.072 MHz   | 16         | Z80, both Z8002 (MASTER/8) |
| `cen_mcu`   | 256 kHz     | 192        | 51xx/52xx/53xx/54xx instruction rate (MASTER/8/2/6) |
| `cen_06xx`  | 48 kHz      | 1024       | 06xx base clock (MASTER/8/64) |

Resets are synchronous and active high (`reset`).

## Timing model for the CPU cores: cycle credit

MAME charges each instruction a fixed number of CPU cycles (the Z8000 table's
cycle column, the MB88xx `oc` count) and the CPU runs until its budget for the
timeslice is spent. The RTL cores reproduce that budget exactly rather than
the real chips' bus timing:

* a signed credit counter increments on every `cen` pulse;
* at an instruction boundary, if credit > 0, the core starts the next
  instruction and immediately subtracts that instruction's cycle cost
  (including MAME's data-dependent adjustments, e.g. MULTW/MULTL);
* the instruction itself then executes in however many sys clocks it needs
  (memory handshakes included) while credit keeps accruing.

Execution is far faster than the budget, so average throughput is set by the
credit alone and matches MAME's CPU speed cycle for cycle.

## Z8002 (`rtl/z8002.sv`)

```systemverilog
module z8002 (
    input  wire        clk,
    input  wire        reset,       // sync, active high; reset sequence per MAME
    input  wire        cen,         // 3.072 MHz credit tick
    input  wire        nmi,         // active high, edge (MAME NMI_LINE semantics)
    input  wire        nvi,         // active high level (MAME NVI_LINE semantics)
    input  wire        vi,          // active high level (MAME VI_LINE semantics)

    // memory / IO bus: request-acknowledge
    output logic        bus_req,    // an access is pending
    output logic        bus_we,     // 1 = write
    output logic        bus_io,     // 1 = I/O space (IN/OUT family), 0 = memory
    output logic        bus_byte,   // 1 = byte access at bus_addr, 0 = word at bus_addr & ~1
    output logic [15:0] bus_addr,
    output logic [15:0] bus_wdata,  // word writes: the word; byte writes: {b,b}
    input  wire         bus_ack,    // access completes on this cycle
    input  wire  [15:0] bus_rdata,  // word at (bus_addr & ~1), valid when bus_ack

    // debug / verification
    output logic        dbg_insn,   // 1-cycle pulse when an instruction starts
    output logic [15:0] dbg_pc      // address of the instruction that started
);
```

* Byte access at an even address is the **high** byte of the word, odd is the
  **low** byte (big endian, MAME `RDMEM_B`/`WRMEM_B`). The bus always returns
  the whole word; the core picks the byte. For byte writes the glue writes only
  the addressed byte.
* The CPU holds every bus output stable while `bus_req && !bus_ack`. `bus_ack`
  may come in the same cycle as `bus_req` or any later cycle.
* Interrupt acknowledge pushes `0xFFFF` as the vector word (MAME's unbound
  `m_iack_in` default).

## MB88xx 4-bit MCU (`rtl/mb88.sv`)

```systemverilog
module mb88 #(parameter ROM_AW = 10, RAM_AW = 6) (
    input  wire        clk,
    input  wire        reset,       // sync, active high (MAME device_reset)
    input  wire        cen,         // 256 kHz credit tick (one MAME cycle)

    output logic [ROM_AW-1:0] rom_addr,  // registered-read ROM outside
    input  wire  [7:0]        rom_data,  // valid the cycle after rom_addr

    input  wire  [3:0]  k_in,
    input  wire  [15:0] r_in,       // R0..R3 nibbles: {R3,R2,R1,R0}
    output logic [15:0] r_out,      // last value written to each R port
    output logic [3:0]  r_we,       // 1-cycle strobe per R port write
    output logic [7:0]  o_out,      // PLA output latch (8-bit PLA mode)
    output logic [1:0]  o_we,       // strobes: [0] low nibble written, [1] high nibble
    output logic [3:0]  p_out,
    output logic        p_we,
    input  wire         si,
    output logic        so,
    input  wire         irq,        // logical level; rising edge latches (MAME IRQ_LINE)
    input  wire         tc,         // logical level; falling edge clocks timer (MAME TC_LINE)

    output logic        dbg_insn,
    output logic [10:0] dbg_pc
);
```

Port reads (`r_in`, `k_in`, `si`) are sampled combinationally at the point the
instruction executes, exactly as MAME calls its read callbacks.
