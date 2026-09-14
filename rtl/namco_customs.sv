//------------------------------------------------------------------------------
// Pole Position's Namco custom I/O: the 06xx and the four MB88xx-based chips
// behind it, wired as MAME 0.288 src/mame/namco/polepos.cpp wires them.
//
//   06xx chip 0  51xx (MB8843)  coin/credit I/O: DSWB, IN0
//   06xx chip 1  53xx (MB8843)  steering + DSWA
//   06xx chip 2  52xx (MB8843)  sample player (voice ROMs)
//   06xx chip 3  54xx (MB8844)  noise / tyre screech generator
//
// All four are held in reset while the LS259's IOSEL output (latch bit 1) is
// low. Per-chip glue follows namco51/52/53/54.cpp; the steering encoder is
// polepos_state::steering_changed_r / steering_delta_r, which has a side effect
// on every read of the 53xx's R0 and so lives here, next to that read.
//------------------------------------------------------------------------------
`default_nettype none

module namco_customs (
    input  wire         clk,
    input  wire         reset,
    input  wire         cen_mcu,        // 256 kHz: one MCU cycle
    input  wire         cen_06xx,       // 48 kHz: the 06xx base clock

    // MCU program ROM download: 51xx 0x000, 52xx 0x400, 53xx 0x800, 54xx 0xC00
    input  wire  [11:0] dl_addr,
    input  wire  [7:0]  dl_data,
    input  wire         dl_we,

    // Z80 side of the 06xx
    input  wire         data_wr,        // strobe: Z80 write to 0x9000 (mirror)
    input  wire         ctrl_wr,        // strobe: Z80 write to 0x9100 (mirror)
    input  wire  [7:0]  z80_din,
    output logic [7:0]  data_q,         // Z80 read of 0x9000
    output logic [7:0]  ctrl_q,         // Z80 read of 0x9100
    output logic        nmi,            // to the Z80 NMI input, active high

    input  wire         iosel,          // LS259 Q1: 0 holds all four customs in reset
    input  wire         vblank,         // screen vblank, active high (51xx TC)

    // machine inputs, as MAME's ports (active low where MAME's are)
    input  wire  [7:0]  in0,            // IN0 (bit 2 is the program-controlled start)
    input  wire  [7:0]  dswa,
    input  wire  [7:0]  dswb,
    input  wire  [7:0]  steer_pos,      // STEER dial position (MAME's STEER port)

    // outputs
    output logic [3:0]  n51_p = '0,     // 51xx P port, raw
    output logic [1:0]  coin_counter,   // polepos_state::out(): {counter 1, counter 0}
    output logic        lockout,        // 51xx lockout: bound in MAME but never driven
    output logic [15:0] smp_addr,       // 52xx sample ROM address
    input  wire  [7:0]  smp_data,       // registered read of smp_addr, region is 0x8000 long
    output logic [3:0]  n52_p = '0,     // 52xx P port -> sample DAC
    output logic [3:0]  n54_o_lo = '0,  // 54xx O low nibble  (pins 4-7,  CHANL3)
    output logic [3:0]  n54_o_hi = '0,  // 54xx O high nibble (pins 8-11, CHANL2)
    output logic [3:0]  n54_r1 = '0,    // 54xx R1            (pins 17-20, CHANL1)

    // debug
    output logic [43:0] dbg_pc          // {54xx, 53xx, 52xx, 51xx} 11-bit PCs
);

    // ---- MCU program ROMs -----------------------------------------------------
    logic [7:0] rom51 [1024] = '{default: '0};
    logic [7:0] rom52 [1024] = '{default: '0};
    logic [7:0] rom53 [1024] = '{default: '0};
    logic [7:0] rom54 [1024] = '{default: '0};
    logic [9:0] ra51, ra52, ra53, ra54;
    logic [7:0] rd51 = '0, rd52 = '0, rd53 = '0, rd54 = '0;

    always_ff @(posedge clk) begin
        if (dl_we && dl_addr[11:10] == 2'd0) rom51[dl_addr[9:0]] <= dl_data;
        rd51 <= rom51[ra51];
    end
    always_ff @(posedge clk) begin
        if (dl_we && dl_addr[11:10] == 2'd1) rom52[dl_addr[9:0]] <= dl_data;
        rd52 <= rom52[ra52];
    end
    always_ff @(posedge clk) begin
        if (dl_we && dl_addr[11:10] == 2'd2) rom53[dl_addr[9:0]] <= dl_data;
        rd53 <= rom53[ra53];
    end
    always_ff @(posedge clk) begin
        if (dl_we && dl_addr[11:10] == 2'd3) rom54[dl_addr[9:0]] <= dl_data;
        rd54 <= rom54[ra54];
    end

    wire mcu_reset = reset | ~iosel;

    // polepos_state::out(): coin_counter_w(1, BIT(~data, 2)), coin_counter_w(0, BIT(~data, 3))
    assign coin_counter = {~n51_p[2], ~n51_p[3]};
    assign lockout      = 1'b0;

    // ---- 06xx -------------------------------------------------------------------
    logic [3:0]  chip_sel, chip_wr;
    logic        rw;
    logic [7:0]  chip_wdata;
    logic [7:0]  portO51 = '0, portO53 = '0;

    namco_06xx u06 (
        .clk        (clk),
        .reset      (reset),
        .cen_base   (cen_06xx),
        .data_wr    (data_wr),
        .ctrl_wr    (ctrl_wr),
        .din        (z80_din),
        .data_q     (data_q),
        .ctrl_q     (ctrl_q),
        .nmi        (nmi),
        .chip_sel   (chip_sel),
        .rw         (rw),
        .chip_wr    (chip_wr),
        .chip_wdata (chip_wdata),
        .chip_rdata ({8'hff, 8'hff, portO53, portO51})
    );

    // ---- 51xx: I/O ----------------------------------------------------------------
    logic [15:0] r51_out;  logic [3:0] r51_we, r51_re;
    logic [7:0]  o51;      logic [1:0] o51_we;
    logic [3:0]  p51;      logic       p51_we;
    logic        so51, dbg51_insn;

    mb88 #(.ROM_AW(10), .RAM_AW(6)) u51 (
        .clk (clk), .reset (mcu_reset), .cen (cen_mcu),
        .rom_addr (ra51), .rom_data (rd51),
        .k_in ({rw, portO51[2:0]}),
        .r_in ({in0[7:4], in0[3:0], dswb[7:4], dswb[3:0]}),
        .r_out (r51_out), .r_we (r51_we), .r_re (r51_re),
        .o_out (o51), .o_we (o51_we), .p_out (p51), .p_we (p51_we),
        .si (1'b0), .so (so51),
        .irq (chip_sel[0]),
        .tc (~vblank),                  // namco_51xx::vblank: state ? CLEAR : ASSERT
        .dbg_insn (dbg51_insn), .dbg_pc (dbg_pc[10:0])
    );

    always_ff @(posedge clk) begin
        if (chip_wr[0]) portO51 <= chip_wdata;     // namco_51xx::write
        if (o51_we != 2'b00) portO51 <= o51;       // namco_51xx::O_w
        if (p51_we) n51_p <= p51;
    end

    // ---- 53xx: steering and DSWA ----------------------------------------------------
    // polepos_state::steering_changed_r (runs on every R0 read) and steering_delta_r
    logic [7:0]         steer_last  = '0;
    logic               steer_delta = 1'b0;
    logic signed [15:0] steer_accum = '0;
    logic signed [15:0] acc_add, acc_next;
    logic               delta_next;
    logic [7:0]         steer_diff;

    always_comb begin
        steer_diff = steer_pos - steer_last;
        acc_add    = steer_accum + 16'($signed({{8{steer_diff[7]}}, steer_diff}) * 2);
        acc_next   = acc_add;
        delta_next = steer_delta;
        if (acc_add < 0)      begin delta_next = 1'b0; acc_next = acc_add + 16'sd1; end
        else if (acc_add > 0) begin delta_next = 1'b1; acc_next = acc_add - 16'sd1; end
    end

    logic [15:0] r53_out;  logic [3:0] r53_we, r53_re;
    logic [7:0]  o53;      logic [1:0] o53_we;
    logic [3:0]  p53;      logic       p53_we;
    logic        so53, dbg53_insn;

    mb88 #(.ROM_AW(10), .RAM_AW(6)) u53 (
        .clk (clk), .reset (mcu_reset), .cen (cen_mcu),
        .rom_addr (ra53), .rom_data (rd53),
        .k_in (4'd0),                   // namco_53xx_k_r: hardwired to 0
        .r_in ({dswa[7:4], dswa[3:0], 3'd0, steer_delta, 3'd0, acc_next[0]}),
        .r_out (r53_out), .r_we (r53_we), .r_re (r53_re),
        .o_out (o53), .o_we (o53_we), .p_out (p53), .p_we (p53_we),
        .si (1'b0), .so (so53),
        .irq (chip_sel[1]),
        .tc (1'b0),
        .dbg_insn (dbg53_insn), .dbg_pc (dbg_pc[32:22])
    );

    always_ff @(posedge clk) begin
        if (o53_we != 2'b00) portO53 <= o53;       // namco_53xx::O_w
        if (r53_re[0]) begin                       // the read's side effect
            steer_accum <= acc_next;
            steer_delta <= delta_next;
            steer_last  <= steer_pos;
        end
    end

    // ---- 52xx: sample player ----------------------------------------------------------
    logic [7:0]  cmd52 = '0;
    logic [15:0] address52 = '0;
    logic [15:0] r52_out;  logic [3:0] r52_we, r52_re;
    logic [7:0]  o52;      logic [1:0] o52_we;
    logic [3:0]  p52;      logic       p52_we;
    logic        so52, dbg52_insn;
    wire  [7:0]  rom52_byte = address52[15] ? 8'hff : smp_data;   // namco_52xx_rom_r

    assign smp_addr = address52;

    mb88 #(.ROM_AW(10), .RAM_AW(6)) u52 (
        .clk (clk), .reset (mcu_reset), .cen (cen_mcu),
        .rom_addr (ra52), .rom_data (rd52),
        .k_in (cmd52[3:0]),
        .r_in ({8'd0, rom52_byte[7:4], rom52_byte[3:0]}),
        .r_out (r52_out), .r_we (r52_we), .r_re (r52_re),
        .o_out (o52), .o_we (o52_we), .p_out (p52), .p_we (p52_we),
        .si (1'b1),                     // pulled to +5V
        .so (so52),
        .irq (chip_sel[2]),
        .tc (1'b0),                     // GND on polepos
        .dbg_insn (dbg52_insn), .dbg_pc (dbg_pc[21:11])
    );

    always_ff @(posedge clk) begin
        if (chip_wr[2]) cmd52 <= chip_wdata;
        if (r52_we[2]) address52[3:0] <= r52_out[11:8];
        if (r52_we[3]) address52[7:4] <= r52_out[15:12];
        if (o52_we != 2'b00) address52[15:8] <= o52;
        if (p52_we) n52_p <= p52;
    end

    // ---- 54xx: noise generator ---------------------------------------------------------
    logic [7:0]  cmd54 = '0;
    logic [15:0] r54_out;  logic [3:0] r54_we, r54_re;
    logic [7:0]  o54;      logic [1:0] o54_we;
    logic [3:0]  p54;      logic       p54_we;
    logic        so54, dbg54_insn;

    mb88 #(.ROM_AW(10), .RAM_AW(6)) u54 (
        .clk (clk), .reset (mcu_reset), .cen (cen_mcu),
        .rom_addr (ra54), .rom_data (rd54),
        .k_in (cmd54[7:4]),
        .r_in ({12'd0, cmd54[3:0]}),
        .r_out (r54_out), .r_we (r54_we), .r_re (r54_re),
        .o_out (o54), .o_we (o54_we), .p_out (p54), .p_we (p54_we),
        .si (1'b0), .so (so54),
        .irq (chip_sel[3]),
        .tc (1'b0),
        .dbg_insn (dbg54_insn), .dbg_pc (dbg_pc[43:33])
    );

    always_ff @(posedge clk) begin
        if (chip_wr[3]) cmd54 <= chip_wdata;
        if (o54_we[0]) n54_o_lo <= o54[3:0];
        if (o54_we[1]) n54_o_hi <= o54[7:4];
        if (r54_we[1]) n54_r1 <= r54_out[7:4];
    end

endmodule

`default_nettype wire
