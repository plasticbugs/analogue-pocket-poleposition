# Namco customs: MB88xx MCU, 06xx, 51xx/52xx/53xx/54xx

`rtl/mb88.sv`, `rtl/namco_06xx.sv`, `rtl/namco_customs.sv`. Every behaviour is
MAME 0.288's (`ref/mame/mb88xx.cpp`, `namco06.cpp`, `namco51..54.cpp`,
`polepos.cpp`) and each piece is checked against MAME as described in §3.

## 1. Ports

### `namco_customs` (what the machine instantiates)

```systemverilog
module namco_customs (
    input  wire         clk,            // 49.152 MHz
    input  wire         reset,          // sync, active high
    input  wire         cen_mcu,        // 256 kHz tick: one MCU cycle (MASTER/8/2/6)
    input  wire         cen_06xx,       // 48 kHz tick: the 06xx base clock (MASTER/8/64)

    // MCU program ROMs (4 x 1 KB): 51xx 0x000, 52xx 0x400, 53xx 0x800, 54xx 0xC00
    input  wire  [11:0] dl_addr,
    input  wire  [7:0]  dl_data,
    input  wire         dl_we,

    // Z80 side of the 06xx
    input  wire         data_wr,        // 1-cycle strobe: Z80 write to 0x9000 (mirror 0x0eff)
    input  wire         ctrl_wr,        // 1-cycle strobe: Z80 write to 0x9100 (mirror 0x0eff)
    input  wire  [7:0]  z80_din,
    output logic [7:0]  data_q,         // Z80 read of 0x9000, valid every cycle
    output logic [7:0]  ctrl_q,         // Z80 read of 0x9100
    output logic        nmi,            // Z80 NMI, active-high level (edge is what the Z80 uses)

    input  wire         iosel,          // LS259 Q1: 0 holds all four customs in reset
    input  wire         vblank,         // screen vblank level: vpos >= 240 || vpos < 16

    input  wire  [7:0]  in0,            // MAME IN0 (active low; bit 2 = program-controlled start)
    input  wire  [7:0]  dswa,
    input  wire  [7:0]  dswb,
    input  wire  [7:0]  steer_pos,      // MAME STEER dial position

    output logic [3:0]  n51_p,          // 51xx P port, raw
    output logic [1:0]  coin_counter,   // {counter 1, counter 0} = {~n51_p[2], ~n51_p[3]}
    output logic        lockout,        // constant 0: MAME binds the 51xx lockout callback but never drives it
    output logic [15:0] smp_addr,       // 52xx sample ROM address
    input  wire  [7:0]  smp_data,       // registered read of smp_addr (0x8000-byte region, 3 x 8K loaded, rest 0)
    output logic [3:0]  n52_p,          // 52xx P port -> 4-bit DAC (CHANL4)
    output logic [3:0]  n54_o_lo,       // 54xx O[3:0] -> CHANL3 (NAMCO_54XX_0_DATA)
    output logic [3:0]  n54_o_hi,       // 54xx O[7:4] -> CHANL2 (NAMCO_54XX_1_DATA)
    output logic [3:0]  n54_r1,         // 54xx R1     -> CHANL1 (NAMCO_54XX_2_DATA)

    output logic [43:0] dbg_pc          // {54xx, 53xx, 52xx, 51xx} 11-bit PCs
);
```

Reads: `data_q`/`ctrl_q` are combinational from registered state, so the Z80
glue can sample them on the cycle of the read. `smp_data` must be the ROM
word at the `smp_addr` presented on the previous clock (the 52xx address only
changes a few times per sample, so one cycle of latency is invisible); the
wrapper returns 0xff for `smp_addr[15]` set, as `namco_52xx_rom_r` does.

### `namco_06xx`

```systemverilog
module namco_06xx (
    input  wire         clk,
    input  wire         reset,
    input  wire         cen_base,       // 48 kHz
    input  wire         data_wr,        // strobes and data from the Z80
    input  wire         ctrl_wr,
    input  wire  [7:0]  din,
    output logic [7:0]  data_q,         // AND of the selected chips' read data (0xff none), 0 in write mode
    output logic [7:0]  ctrl_q,         // control register
    output logic        nmi,
    output logic [3:0]  chip_sel,       // levels -> MCU IRQ inputs
    output logic        rw,             // level, 1 = read
    output logic [3:0]  chip_wr,        // 1-cycle strobes, with chip_wdata
    output logic [7:0]  chip_wdata,
    input  wire  [31:0] chip_rdata      // {chip3, chip2, chip1, chip0}
);
```

### `mb88` (one MCU)

As `docs/interfaces.md`, plus one output added for the 53xx:
`output logic [3:0] r_re` -- a one-cycle strobe per R-port **read**, because
polepos' steering encoder (`steering_changed_r`) has a side effect on every
read of R0 and must advance exactly once per read.

## 2. Design

**Timing model.** All four MCUs run on MAME's cycle budget (`docs/interfaces.md`):
`cen_mcu` adds one cycle of credit, an instruction starts when credit > 0 and
spends what MAME charges it (1, or 2 for `jpa/en/dis/call/jpl`, +3 on interrupt
entry). An instruction takes 2-4 system clocks, so the MCU is always caught up
by the next cycle; throughput is MAME's exactly.

**06xx clock.** MAME aligns its timer to the 48 kHz base clock: the first edge
after a control write is the next base tick strictly after the write, then one
edge every `2^(n-1)` base ticks (`n = control[7:5]`, so `0x71` gives an edge
every 4 base ticks = 83 us, NMI every 167 us). The RTL counts `cen_06xx` pulses
the same way. A control write on the same clock as a base tick re-arms rather
than fires, matching MAME's `from_ticks(total_ticks + 1)`: a write exactly on
a tick gets its first edge one whole tick later. The replay in §3.2 confirms
the edge timing over 77,550 NMIs with no discrepancy.

**Reset.** `iosel` low holds the MCUs in MAME's `INPUT_LINE_RESET` state: no
execution, `device_reset()` values, but input edges and the serial timer
still delivered (see the header of `mb88.sv`). The 06xx is not on IOSEL.

**Glue** is a transliteration of `namco5x.cpp` + `polepos.cpp`:

| chip | K | R0..R3 | O | P |
|---|---|---|---|---|
| 51xx | `{rw, portO[2:0]}` | DSWB lo, DSWB hi, IN0 lo, IN0 hi | portO (also written by the Z80 through the 06xx) | coin counters |
| 53xx | 0 | steering_changed, steering_delta, DSWA lo, DSWA hi | portO | - |
| 52xx | latched cmd | ROM lo, ROM hi (R2/R3 written = address[7:0]) | address[15:8] | DAC |
| 54xx | cmd[7:4] | cmd[3:0]; R1 written = CHANL1 | CHANL3 / CHANL2 | - |

The 51xx TC pin is `~vblank` (`namco_51xx::vblank`: `state ? CLEAR : ASSERT`),
so the MCU's external timer clocks on the vblank rising edge (TC falling).

**Resources** (standalone fit, 5CEBA4F23C8, Quartus 18.1): 1,941 ALMs (11%),
883 registers, 4 M10K (the four MCU ROMs), Fmax 74.9 MHz at 85C / 73.0 MHz at 0C
against the 49.152 MHz requirement (+6.99 ns setup slack, +0.51 ns hold). Each
MCU is ~470 ALMs; the `casez` over 256 opcodes is what costs. If the whole core
ever runs short, the four MCUs execute one instruction per 192 clocks and could
share one datapath with four register contexts.

## 3. Verification

### 3.1 MB88 lockstep against MAME's own code -- `sim/mb88/`

`sim/mb88/gen_shim.py` copies the macro block and the bodies of
`device_reset / serial_timer / write_pla / execute_set_input / pio_enable /
increment_timer / burn_cycles / execute_run` **verbatim** out of
`ref/mame/mb88xx.cpp` into `build/mb88/mb88_mame.inc`; `sim/mb88/mame_mb88.h`
is the 150-line fake device they compile against. The reference is therefore
MAME's code, not a re-transcription of it.

`sim/mb88/tb_mb88.cpp` runs the RTL and MAME one MAME cycle at a time with the
same K/R/SI/IRQ/TC stimulus and after **every cycle** compares PC, PA, all four
stack slots, SI, A, X, Y, st/zf/cf/vf/sf, the latched IRQ and TC levels, pio,
TH/TL/TP, SB, SBcount, serial-timer armed, pending_irq, in_irq, the O latch,
the cycle credit (`m_icount`), all 64 RAM nibbles, the list of instructions
started and every port read/write. Any difference stops the run.

```sh
sim/mb88/build.sh
build/mb88/obj/tb_mb88 directed 20000 99        # every opcode x 20000 random states
build/mb88/obj/tb_mb88 random 10000000 101      # random programs + random pins
python3 sim/mb88/make_stim.py build/namco/capture.txt 0 build/mb88/stim_0.txt   # 0..3
build/mb88/obj/tb_mb88 rom 51 build/mb88/stim_0.txt polepos                     # 51..54
sim/mb88/mutate.sh                              # the bench must catch 16 planted bugs
```

Results observed:

| campaign | compared | result |
|---|---|---|
| directed, 256 opcodes x 20,000 states, 3 cycles each | 15.3 M cycles, 11.7 M instructions; 768 k external / 464 k timer / 388 k serial interrupt entries | 0 mismatches |
| random programs and pins, seeds 1-8 x 5 M, 101-106 x 10 M | 100 M cycles, 98 M instructions, every opcode executed | 0 mismatches |
| 51xx ROM, 40 s of captured polepos stimulus | 9.11 M cycles, 7.33 M instructions, 17,238 IRQs | 0 mismatches |
| 52xx ROM | 9.11 M cycles, 8.69 M instructions, 142,386 timer interrupts | 0 mismatches |
| 53xx ROM | 9.11 M cycles, 8.78 M instructions, 2.15 M port accesses | 0 mismatches |
| 54xx ROM | 9.11 M cycles, 8.80 M instructions, 8,614 IRQs | 0 mismatches |
| mutation check | 16 planted single-line RTL bugs | 16/16 caught |

"MAME fatalerror samples skipped" in the directed/random output are states
where a random `en`/`dis` set the serial mode to 0x10/0x30, which is a
`fatalerror` in MAME; no real program does it and the RTL treats it as off.

The ROM campaigns use stimulus derived from a MAME capture (§3.2) by
`make_stim.py`, which models the 06xx to produce the chip-select, rw, command
and input events each chip saw, rounded to the MCU's 256 kHz grid. Both models
see identical stimulus, and glue feedback (portO, sample address, steering) is
computed from port writes that are themselves compared every cycle.

### 3.2 System replay against the real machine -- `sim/namco/`

`sim/namco/capture.lua` runs MAME polepos for 2400 frames (39.6 s: attract,
coin at frame 600, accelerator from 700 which starts the race, wheel and gear
inputs) and logs, with exact emulated time (`attotime` as 49.152 MHz ticks),
every Z80 access to the 06xx data/control ports and the value MAME returned,
every LS259 write, every NMI entry (fetch of 0x0066) and the input ports.
`sim/namco/tb_replay.cpp` replays the Z80 writes, latch and inputs into
`namco_customs` at exactly those clocks and checks every read value and the
NMI train.

```sh
mkdir -p build/namco/mametmp
NC_OUT=build/namco/capture.txt NC_FRAMES=2400 mame polepos -rompath . -video none -sound none \
    -nothrottle -skip_gameinfo -cfg_directory build/namco/mametmp -nvram_directory build/namco/mametmp \
    -autoboot_script sim/namco/capture.lua
NC_SCENARIO=slow NC_OUT=build/namco/capture_slow.txt NC_FRAMES=2400 mame polepos ... (same flags)
sim/namco/build.sh
build/namco/obj/tb_replay build/namco/capture.txt polepos          # ~4.5 min
build/namco/obj/tb_replay build/namco/capture_slow.txt polepos     # ~7 min
```

Results observed, 39.6 s each:

| | writes replayed | reads checked | read mismatches | NMI |
|---|---|---|---|---|
| fast inputs | 56,031 | 69,789 | 14 (0.020%) | 77,550 RTL edges, 77,550 MAME entries, paired 1:1 |
| slow inputs | 56,031 | 69,790 | 10 (0.014%) | 77,550 / 77,550, paired 1:1 |

Every MAME NMI entry follows an RTL NMI edge by 175-495 ticks (3.6-10.1 us,
mean 5.3 us): the Z80's remaining instruction plus acknowledge. The NMI train
is therefore identical, edge for edge, over 77,550 interrupts.

**The residual read mismatches are the capture's input timing, not the RTL.**
Input port values can only be logged when the Z80 next touches the 06xx (or at
frame end), so the replay can deliver an input change up to a fraction of a
frame later than MAME's devices saw it. All mismatching reads sit in two
clusters, each starting within one frame of an input change: the 51xx counts
the coin one read later, so the credit-count bytes differ for ~0.5 s until the
game has consumed the credit; and with a wheel that moves every frame, a
steering byte lands one read late. Shifting the logged input timeline earlier
with `NC_ISHIFT=<ticks>` moves the clusters instead of the RTL: at
`NC_ISHIFT=400000` (8 ms) the coin cluster vanishes entirely and only steering
bytes -- which move with the shift by construction -- remain (3 reads); at
`NC_ISHIFT=300000` on the fast capture the coin cluster drops to 2 and the
steering bytes go one read early. No mismatch exists that is not tied to an
input edge this way. This cannot matter on hardware: there is no log there --
the MCUs sample the real switches.

### 3.3 Lint and synthesis

```sh
verilator --lint-only -Wall -Wno-PROCASSINIT -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
    --top-module namco_customs rtl/mb88.sv rtl/namco_06xx.sv rtl/namco_customs.sv
docker run --rm --platform linux/amd64 -m 8g -v "$PWD":/build -w /build/build/mb88/quartus \
    raetro/quartus:pocket quartus_sh --flow compile customs.qpf
```

Lint is clean (the three suppressed classes are the declaration-initialiser
style and unused bits, the same set the other cores suppress). The standalone
project in `build/mb88/quartus/` (virtual pins, 49.152 MHz SDC) fits and
closes timing as in §2; `NUM_PARALLEL_PROCESSORS 1` -- the fitter was killed
mid-run with 4 in the Docker container.

## 4. Deviations from MAME

None known. Two things worth recording:

* `pio_enable` with serial mode 0x10 or 0x30 is a MAME `fatalerror`; the RTL
  disarms the serial timer instead. No program in the four ROMs does it.
* The MCU RAM has the `ramstyle = "MLAB"` hint. It changes nothing
  functionally (the lockstep runs were repeated after adding it).
