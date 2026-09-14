//------------------------------------------------------------------------------
// Fujitsu MB88xx 4-bit MCU (MB8841/42/43/44 family) -- the CPU inside the Namco
// 51xx, 52xx, 53xx and 54xx customs.
//
// Semantics are MAME 0.288 src/devices/cpu/mb88xx/mb88xx.cpp, instruction for
// instruction, including its timer, serial and interrupt model, and are checked
// in lockstep against that code (sim/mb88). Timing is MAME's cycle budget, not
// the real chip's: a credit counter gains one per `cen` (one MAME cycle, the
// chip clock over 6) and each instruction spends the cycles MAME charges it
// (docs/interfaces.md).
//
// Reset follows MAME's INPUT_LINE_RESET handling: while `reset` is high the CPU
// is suspended (no instructions, no credit) but, as in MAME, input edges and the
// serial timer keep being delivered; device_reset() takes effect on release.
// Everything device_reset() clears is simply held cleared while reset is high,
// which is indistinguishable, except the serial bit counter, which MAME lets
// run on (and so can switch the serial timer off) during suspension.
//------------------------------------------------------------------------------
`default_nettype none

module mb88 #(
    parameter int ROM_AW = 10,          // MB8843/44: 10, MB8841/42: 11
    parameter int RAM_AW = 6            // MB8843/44: 6,  MB8841/42: 7
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               cen,

    output logic [ROM_AW-1:0] rom_addr,
    input  wire  [7:0]        rom_data,

    input  wire  [3:0]        k_in,
    input  wire  [15:0]       r_in,       // {R3,R2,R1,R0}
    output logic [15:0]       r_out    = '0,
    output logic [3:0]        r_we     = '0,
    output logic [3:0]        r_re     = '0,       // 1-cycle strobe per R port read (read side effects)
    output logic [7:0]        o_out,
    output logic [1:0]        o_we     = '0,
    output logic [3:0]        p_out    = '0,
    output logic              p_we     = 1'b0,
    input  wire               si,
    output logic              so,
    input  wire               irq,
    input  wire               tc,

    output logic              dbg_insn = 1'b0,
    output logic [10:0]       dbg_pc   = '0
);

    localparam logic [2:0] INT_SERIAL   = 3'b001;
    localparam logic [2:0] INT_TIMER    = 3'b010;
    localparam logic [2:0] INT_EXTERNAL = 3'b100;
    localparam logic [15:0] SERIAL_DISABLE_THRESH = 16'd1000;

    typedef enum logic [1:0] { S_IDLE, S_OP, S_ARGW, S_ARG } state_t;

    // ---- architectural state (names follow MAME) ---------------------------
    state_t      state   = S_IDLE;
    logic [5:0]  PC      = '0;
    logic [7:0]  PA      = '0;            // u8 in MAME; only INCPC can carry past 0x1f
    logic [15:0] SP [4]  = '{default: '0};
    logic [1:0]  SI      = '0;
    logic [3:0]  A = '0, X = '0, Y = '0;
    logic        st = 1'b1, zf = 1'b0, cf = 1'b0, vf = 1'b0, sf = 1'b0;
    logic        if_     = 1'b0;          // IRQ pin level as last delivered
    logic        ctr     = 1'b0;          // TC pin level as last delivered
    logic [7:0]  pio     = '0;
    logic [3:0]  TH = '0, TL = '0;
    logic [7:0]  TP      = '0;
    logic [3:0]  SB      = '0;
    logic [15:0] SBcount = '0;
    logic        ser_on  = 1'b0;          // serial emu_timer armed
    logic [2:0]  pending_irq = '0;
    logic        in_irq  = 1'b0;
    logic [7:0]  o_output = '0;
    (* ramstyle = "MLAB, no_rw_check" *)
    logic [3:0]  ram [1 << RAM_AW] = '{default: '0};
    logic signed [3:0] credit = '0;
    logic [7:0]  opcode  = '0;
    logic        reset_q = 1'b1;

    // ---- next state ---------------------------------------------------------
    state_t      n_state;
    logic [5:0]  n_PC;
    logic [7:0]  n_PA;
    logic [15:0] n_SP [4];
    logic [1:0]  n_SI;
    logic [3:0]  n_A, n_X, n_Y;
    logic        n_st, n_zf, n_cf, n_vf, n_sf, n_if, n_ctr;
    logic [7:0]  n_pio;
    logic [3:0]  n_TH, n_TL;
    logic [7:0]  n_TP;
    logic [3:0]  n_SB;
    logic [15:0] n_SBcount;
    logic        n_ser_on;
    logic [2:0]  n_pending;
    logic        n_in_irq;
    logic [7:0]  n_o_output;
    logic signed [3:0] n_credit;
    logic [7:0]  n_opcode;

    logic              ram_we;
    logic [RAM_AW-1:0] ram_wa;
    logic [3:0]        ram_wd;
    logic [15:0]       n_r_out;
    logic [3:0]        n_r_we, n_r_re;
    logic [1:0]        n_o_we;
    logic [3:0]        n_p_out;
    logic              n_p_we;
    logic              n_dbg_insn;
    logic [10:0]       n_dbg_pc;

    // scratch
    logic [7:0]  op, arg8, t8;
    logic [2:0]  oc;
    logic        do_exec;
    logic [7:0]  ea;
    logic [3:0]  memv;
    logic [15:0] intpc;
    logic [8:0]  tsum;
    logic [7:0]  newpio;
    logic [4:0]  pla_index;

    wire [13:0] getpc = {PA, PC};         // (PA << 6) + PC
    assign rom_addr = ROM_AW'(getpc);
    assign so = 1'b0;                     // execute_run never drives SO

    function automatic logic [3:0] rport(input logic [15:0] r, input logic [1:0] n);
        return r[{n, 2'b00} +: 4];
    endfunction

    // INCPC on a {PA,PC} pair
    function automatic logic [13:0] incpc(input logic [13:0] p);
        return (p[5:0] == 6'h3f) ? {p[13:6] + 8'd1, 6'd0} : {p[13:6], p[5:0] + 6'd1};
    endfunction

    always_comb begin
        // defaults: hold
        n_state = state;  n_PC = PC;  n_PA = PA;  n_SP = SP;  n_SI = SI;
        n_A = A;  n_X = X;  n_Y = Y;
        n_st = st;  n_zf = zf;  n_cf = cf;  n_vf = vf;  n_sf = sf;
        n_if = if_;  n_ctr = ctr;  n_pio = pio;  n_TH = TH;  n_TL = TL;  n_TP = TP;
        n_SB = SB;  n_SBcount = SBcount;  n_ser_on = ser_on;  n_pending = pending_irq;
        n_in_irq = in_irq;  n_o_output = o_output;  n_credit = credit;  n_opcode = opcode;
        ram_we = 1'b0;  ram_wa = '0;  ram_wd = '0;
        n_r_out = r_out;  n_r_we = '0;  n_r_re = '0;  n_o_we = '0;
        n_p_out = p_out;  n_p_we = 1'b0;
        n_dbg_insn = 1'b0;  n_dbg_pc = dbg_pc;
        op = opcode;  arg8 = rom_data;  t8 = '0;  oc = 3'd1;  do_exec = 1'b0;
        ea = '0;  memv = '0;  intpc = '0;  tsum = '0;  newpio = '0;  pla_index = '0;

        // ---- 1. serial emu_timer (one period per MAME cycle) ----------------
        if (cen && ser_on) begin
            n_SBcount = n_SBcount + 16'd1;
            if (n_SBcount >= SERIAL_DISABLE_THRESH)
                n_ser_on = 1'b0;
            if (!n_sf) begin
                n_SB = {si, n_SB[3:1]};
                if (n_SBcount >= 16'd4) begin
                    n_sf = 1'b1;
                    n_pending = n_pending | INT_SERIAL;
                end
            end
        end

        // ---- 2. input lines (execute_set_input) ------------------------------
        if (!n_if && irq && n_pio[2])
            n_pending = n_pending | INT_EXTERNAL;
        n_if = irq;
        if (n_ctr && !tc && n_pio[6]) begin
            {n_TH, n_TL} = {n_TH, n_TL} + 8'd1;
            if ({n_TH, n_TL} == 8'h00) begin
                n_vf = 1'b1;
                n_pending = n_pending | INT_TIMER;
            end
        end
        n_ctr = tc;

        // ---- 3. instruction sequencing ----------------------------------------
        case (state)
            S_IDLE:
                if (credit > 0) n_state = S_OP;
            S_OP: begin
                op = rom_data;
                n_opcode = rom_data;
                n_dbg_insn = 1'b1;
                n_dbg_pc = 11'(getpc);
                {n_PA, n_PC} = incpc(getpc);
                if (rom_data == 8'h3d || rom_data == 8'h3e || rom_data == 8'h3f ||
                    rom_data[7:4] == 4'h6)
                    n_state = S_ARGW;
                else
                    do_exec = 1'b1;
            end
            S_ARGW:
                n_state = S_ARG;
            S_ARG: begin
                op = opcode;
                do_exec = 1'b1;
            end
            default: n_state = S_IDLE;
        endcase

        if (do_exec) begin
            n_state = S_IDLE;
            ea = {n_X, n_Y};
            memv = ram[RAM_AW'(ea)];

            // ---- 4. the instruction (mb88_cpu_device::execute_run) ------------
            casez (op)
                8'h00: n_st = 1'b1;                                   // nop
                8'h01: begin                                          // outO
                    pla_index = {n_cf, n_A};
                    if (pla_index[4]) begin n_o_output[7:4] = n_A; n_o_we = 2'b10; end
                    else              begin n_o_output[3:0] = n_A; n_o_we = 2'b01; end
                    n_st = 1'b1;
                end
                8'h02: begin n_p_out = n_A; n_p_we = 1'b1; n_st = 1'b1; end            // outP
                8'h03: begin                                          // outR
                    n_r_out[{n_Y[1:0], 2'b00} +: 4] = n_A;
                    n_r_we[n_Y[1:0]] = 1'b1;
                    n_st = 1'b1;
                end
                8'h04: begin n_Y = n_A;  n_st = 1'b1; end             // tay
                8'h05: begin n_TH = n_A; n_st = 1'b1; end             // tath
                8'h06: begin n_TL = n_A; n_st = 1'b1; end             // tatl
                8'h07: begin n_SB = n_A; n_st = 1'b1; end             // tas
                8'h08: begin                                          // icy
                    t8 = {4'd0, n_Y} + 8'd1;
                    n_st = ~t8[4];  n_Y = t8[3:0];  n_zf = (n_Y == 4'd0);
                end
                8'h09: begin                                          // icm
                    t8 = {4'd0, memv} + 8'd1;
                    n_st = ~t8[4];  n_zf = (t8[3:0] == 4'd0);
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = t8[3:0];
                end
                8'h0a: begin                                          // stic
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = n_A;
                    t8 = {4'd0, n_Y} + 8'd1;
                    n_st = ~t8[4];  n_Y = t8[3:0];  n_zf = (n_Y == 4'd0);
                end
                8'h0b: begin                                          // x
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = n_A;
                    n_A = memv;  n_zf = (n_A == 4'd0);  n_st = 1'b1;
                end
                8'h0c: begin                                          // rol
                    t8 = {3'd0, n_A, n_cf};
                    n_st = ~t8[4];  n_cf = t8[4];  n_A = t8[3:0];  n_zf = (n_A == 4'd0);
                end
                8'h0d: begin n_A = memv; n_zf = (n_A == 4'd0); n_st = 1'b1; end        // l
                8'h0e: begin                                          // adc
                    t8 = {4'd0, memv} + {4'd0, n_A} + {7'd0, n_cf};
                    n_st = ~t8[4];  n_cf = t8[4];  n_A = t8[3:0];  n_zf = (n_A == 4'd0);
                end
                8'h0f: begin                                          // and
                    n_A = n_A & memv;  n_zf = (n_A == 4'd0);  n_st = ~n_zf;
                end
                8'h10: begin                                          // daa
                    t8 = (n_cf || n_A > 4'd9) ? {4'd0, n_A} + 8'd6 : {4'd0, n_A};
                    n_st = ~t8[4];  n_cf = t8[4];  n_A = t8[3:0];
                end
                8'h11: begin                                          // das
                    t8 = (n_cf || n_A > 4'd9) ? {4'd0, n_A} + 8'd10 : {4'd0, n_A};
                    n_st = ~t8[4];  n_cf = t8[4];  n_A = t8[3:0];
                end
                8'h12: begin n_A = k_in; n_zf = (n_A == 4'd0); n_st = 1'b1; end        // inK
                8'h13: begin                                          // inR
                    n_A = rport(r_in, n_Y[1:0]);  n_r_re[n_Y[1:0]] = 1'b1;
                    n_zf = (n_A == 4'd0);  n_st = 1'b1;
                end
                8'h14: begin n_A = n_Y;  n_zf = (n_A == 4'd0); n_st = 1'b1; end        // tya
                8'h15: begin n_A = n_TH; n_zf = (n_A == 4'd0); n_st = 1'b1; end        // ttha
                8'h16: begin n_A = n_TL; n_zf = (n_A == 4'd0); n_st = 1'b1; end        // ttla
                8'h17: begin n_A = n_SB; n_zf = (n_A == 4'd0); n_st = 1'b1; end        // tsa
                8'h18: begin                                          // dcy
                    t8 = {4'd0, n_Y} - 8'd1;
                    n_st = ~t8[4];  n_Y = t8[3:0];
                end
                8'h19: begin                                          // dcm
                    t8 = {4'd0, memv} - 8'd1;
                    n_st = ~t8[4];  n_zf = (t8[3:0] == 4'd0);
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = t8[3:0];
                end
                8'h1a: begin                                          // stdc
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = n_A;
                    t8 = {4'd0, n_Y} - 8'd1;
                    n_st = ~t8[4];  n_Y = t8[3:0];  n_zf = (n_Y == 4'd0);
                end
                8'h1b: begin                                          // xx
                    t8[3:0] = n_X;  n_X = n_A;  n_A = t8[3:0];
                    n_zf = (n_A == 4'd0);  n_st = 1'b1;
                end
                8'h1c: begin                                          // ror
                    t8 = {3'd0, n_cf, n_A};
                    n_st = ~t8[0];  n_cf = t8[0];
                    n_A = t8[4:1];
                    n_zf = (n_A == 4'd0);
                end
                8'h1d: begin                                          // st
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = n_A;  n_st = 1'b1;
                end
                8'h1e: begin                                          // sbc
                    t8 = {4'd0, memv} - {4'd0, n_A} - {7'd0, n_cf};
                    n_st = ~t8[4];  n_cf = t8[4];  n_A = t8[3:0];  n_zf = (n_A == 4'd0);
                end
                8'h1f: begin                                          // or
                    n_A = n_A | memv;  n_zf = (n_A == 4'd0);  n_st = ~n_zf;
                end
                8'h20: begin                                          // setR
                    t8[3:0] = rport(r_in, n_Y[3:2]);  n_r_re[n_Y[3:2]] = 1'b1;
                    t8[3:0] = t8[3:0] | (4'd1 << n_Y[1:0]);
                    n_r_out[{n_Y[3:2], 2'b00} +: 4] = t8[3:0];  n_r_we[n_Y[3:2]] = 1'b1;
                    n_st = 1'b1;
                end
                8'h21: begin n_cf = 1'b1; n_st = 1'b1; end            // setc
                8'h22: begin                                          // rstR
                    t8[3:0] = rport(r_in, n_Y[3:2]);  n_r_re[n_Y[3:2]] = 1'b1;
                    t8[3:0] = t8[3:0] & ~(4'd1 << n_Y[1:0]);
                    n_r_out[{n_Y[3:2], 2'b00} +: 4] = t8[3:0];  n_r_we[n_Y[3:2]] = 1'b1;
                    n_st = 1'b1;
                end
                8'h23: begin n_cf = 1'b0; n_st = 1'b1; end            // rstc
                8'h24: begin                                          // tstr
                    t8[3:0] = rport(r_in, n_Y[3:2]);  n_r_re[n_Y[3:2]] = 1'b1;
                    n_st = ~t8[{1'b0, n_Y[1:0]}];
                end
                8'h25: n_st = ~n_if;                                  // tsti
                8'h26: begin n_st = ~n_vf; n_vf = 1'b0; end           // tstv
                8'h27: begin                                          // tsts
                    n_st = ~n_sf;
                    if (n_sf) begin
                        if (n_SBcount >= SERIAL_DISABLE_THRESH)
                            n_ser_on = 1'b1;
                        n_SBcount = '0;
                    end
                    n_sf = 1'b0;
                end
                8'h28: n_st = ~n_cf;                                  // tstc
                8'h29: n_st = ~n_zf;                                  // tstz
                8'h2a: begin                                          // sts
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = n_SB;
                    n_zf = (n_SB == 4'd0);  n_st = 1'b1;
                end
                8'h2b: begin n_SB = memv; n_zf = (n_SB == 4'd0); n_st = 1'b1; end      // ls
                8'h2c: begin                                          // rts
                    n_SI = n_SI - 2'd1;
                    n_PC = SP[n_SI][5:0];  n_PA = {3'd0, SP[n_SI][10:6]};
                    n_st = 1'b1;
                end
                8'h2d: begin                                          // neg
                    n_A = 4'd0 - n_A;  n_st = (n_A != 4'd0);
                end
                8'h2e: begin                                          // c
                    t8 = {4'd0, memv} - {4'd0, n_A};
                    n_cf = t8[4];  n_st = (t8[3:0] != 4'd0);  n_zf = ~n_st;
                end
                8'h2f: begin                                          // eor
                    n_A = n_A ^ memv;  n_st = (n_A != 4'd0);  n_zf = ~n_st;
                end
                8'b0011_00??: begin                                   // sbit
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = memv | (4'd1 << op[1:0]);
                    n_st = 1'b1;
                end
                8'b0011_01??: begin                                   // rbit
                    ram_we = 1'b1;  ram_wa = RAM_AW'(ea);  ram_wd = memv & ~(4'd1 << op[1:0]);
                    n_st = 1'b1;
                end
                8'b0011_10??: n_st = ~memv[op[1:0]];                  // tbit
                8'h3c: begin                                          // rti
                    n_in_irq = 1'b0;
                    n_SI = n_SI - 2'd1;
                    n_PC = SP[n_SI][5:0];  n_PA = {3'd0, SP[n_SI][10:6]};
                    n_st = SP[n_SI][13];  n_zf = SP[n_SI][14];  n_cf = SP[n_SI][15];
                end
                8'h3d: begin                                          // jpa imm
                    n_PA = {3'd0, arg8[4:0]};  n_PC = {n_A, 2'b00};
                    oc = 3'd2;  n_st = 1'b1;
                end
                8'h3e, 8'h3f: begin                                   // en imm / dis imm
                    newpio = (op[0] == 1'b0) ? (n_pio | arg8) : (n_pio & ~arg8);
                    // pio_enable: (re)arm the serial timer when bits 5:4 change.
                    // 0x10/0x30 are a fatalerror in MAME and never happen in a
                    // working program; they are treated as "off" here.
                    if ((n_pio[5:4] ^ newpio[5:4]) != 2'b00)
                        n_ser_on = (newpio[5:4] == 2'b10);
                    n_pio = newpio;
                    {n_PA, n_PC} = incpc({n_PA, n_PC});
                    oc = 3'd2;  n_st = 1'b1;
                end
                8'b0100_00??: begin                                   // setD
                    n_r_re[0] = 1'b1;
                    n_r_out[3:0] = r_in[3:0] | (4'd1 << op[1:0]);  n_r_we[0] = 1'b1;
                    n_st = 1'b1;
                end
                8'b0100_01??: begin                                   // rstD
                    n_r_re[0] = 1'b1;
                    n_r_out[3:0] = r_in[3:0] & ~(4'd1 << op[1:0]);  n_r_we[0] = 1'b1;
                    n_st = 1'b1;
                end
                8'b0100_10??: begin                                   // tstD
                    n_r_re[2] = 1'b1;
                    n_st = ~r_in[{2'b10, op[1:0]}];
                end
                8'b0100_11??: n_st = ~n_A[op[1:0]];                   // tba
                8'b0101_00??: begin                                   // xd
                    ram_we = 1'b1;  ram_wa = RAM_AW'({6'd0, op[1:0]});  ram_wd = n_A;
                    n_A = ram[RAM_AW'({6'd0, op[1:0]})];
                    n_zf = (n_A == 4'd0);  n_st = 1'b1;
                end
                8'b0101_01??: begin                                   // xyd
                    ram_we = 1'b1;  ram_wa = RAM_AW'({6'd1, op[1:0]});  ram_wd = n_Y;
                    n_Y = ram[RAM_AW'({6'd1, op[1:0]})];
                    n_zf = (n_Y == 4'd0);  n_st = 1'b1;
                end
                8'b0101_1???: begin                                   // lxi
                    n_X = {1'b0, op[2:0]};  n_zf = (n_X == 4'd0);  n_st = 1'b1;
                end
                8'b0110_0???: begin                                   // call imm
                    {n_PA, n_PC} = incpc({n_PA, n_PC});
                    oc = 3'd2;
                    if (n_st) begin
                        n_SP[n_SI] = {2'b00, n_PA, n_PC};
                        n_SI = n_SI + 2'd1;
                        n_PC = arg8[5:0];
                        n_PA = {3'd0, op[2:0], arg8[7:6]};
                    end
                    n_st = 1'b1;
                end
                8'b0110_1???: begin                                   // jpl imm
                    {n_PA, n_PC} = incpc({n_PA, n_PC});
                    oc = 3'd2;
                    if (n_st) begin
                        n_PC = arg8[5:0];
                        n_PA = {3'd0, op[2:0], arg8[7:6]};
                    end
                    n_st = 1'b1;
                end
                8'b0111_????: begin                                   // ai
                    t8 = {4'd0, op[3:0]} + {4'd0, n_A};
                    n_st = ~t8[4];  n_cf = t8[4];  n_A = t8[3:0];  n_zf = (n_A == 4'd0);
                end
                8'b1000_????: begin n_Y = op[3:0]; n_zf = (n_Y == 4'd0); n_st = 1'b1; end
                8'b1001_????: begin n_A = op[3:0]; n_zf = (n_A == 4'd0); n_st = 1'b1; end
                8'b1010_????: begin                                   // cyi
                    t8 = {4'd0, op[3:0]} - {4'd0, n_Y};
                    n_cf = t8[4];  n_st = (t8[3:0] != 4'd0);  n_zf = ~n_st;
                end
                8'b1011_????: begin                                   // ci
                    t8 = {4'd0, op[3:0]} - {4'd0, n_A};
                    n_cf = t8[4];  n_st = (t8[3:0] != 4'd0);  n_zf = ~n_st;
                end
                default: begin                                        // jmp
                    if (n_st) n_PC = op[5:0];
                    n_st = 1'b1;
                end
            endcase

            // ---- 5. burn_cycles(oc) -----------------------------------------
            n_credit = n_credit - $signed({1'b0, oc});
            if (n_pio[7]) begin
                tsum = {1'b0, n_TP} + {6'd0, oc};
                if (tsum >= 9'd32) begin
                    tsum = tsum - 9'd32;
                    {n_TH, n_TL} = {n_TH, n_TL} + 8'd1;
                    if ({n_TH, n_TL} == 8'h00) begin
                        n_vf = 1'b1;
                        n_pending = n_pending | INT_TIMER;
                    end
                end
                n_TP = tsum[7:0];
            end

            if (!n_in_irq && (n_pending & n_pio[2:0]) != 3'd0) begin
                n_in_irq = 1'b1;
                intpc = {2'b00, n_PA, n_PC};
                n_SP[n_SI] = intpc | {n_cf, n_zf, n_st, 13'd0};
                n_SI = n_SI + 2'd1;
                if ((n_pending & n_pio[2:0] & INT_EXTERNAL) != 3'd0)      n_PC = 6'h02;
                else if ((n_pending & n_pio[2:0] & INT_TIMER) != 3'd0)    n_PC = 6'h04;
                else                                                      n_PC = 6'h06;
                n_PA = 8'h00;
                n_st = 1'b1;
                n_pending = 3'd0;
                // burn_cycles(3); the nested interrupt check cannot fire (in_irq)
                n_credit = n_credit - 4'sd3;
                if (n_pio[7]) begin
                    tsum = {1'b0, n_TP} + 9'd3;
                    if (tsum >= 9'd32) begin
                        tsum = tsum - 9'd32;
                        {n_TH, n_TL} = {n_TH, n_TL} + 8'd1;
                        if ({n_TH, n_TL} == 8'h00) begin
                            n_vf = 1'b1;
                            n_pending = n_pending | INT_TIMER;
                        end
                    end
                    n_TP = tsum[7:0];
                end
            end
        end

        if (cen) n_credit = n_credit + 4'sd1;
    end

    // ---- register update ----------------------------------------------------
    always_ff @(posedge clk) begin
        reset_q <= reset;
        if (reset) begin
            // suspended: device_reset() values, applied again on release
            state <= S_IDLE;  PC <= '0;  PA <= '0;  SP <= '{default: '0};  SI <= '0;
            A <= '0;  X <= '0;  Y <= '0;
            st <= 1'b1;  zf <= 1'b0;  cf <= 1'b0;  vf <= 1'b0;  sf <= 1'b0;
            pio <= '0;  TH <= '0;  TL <= '0;  TP <= '0;  SB <= '0;
            pending_irq <= '0;  in_irq <= 1'b0;  credit <= '0;
            // what MAME's timers and input lines keep doing while suspended
            if_ <= irq;
            ctr <= tc;
            if (cen && ser_on) begin
                SBcount <= SBcount + 16'd1;
                if (SBcount + 16'd1 >= SERIAL_DISABLE_THRESH) ser_on <= 1'b0;
            end
            r_we <= '0;  r_re <= '0;  o_we <= '0;  p_we <= 1'b0;  dbg_insn <= 1'b0;
        end else begin
            if (reset_q) begin
                // release: the rest of device_reset()
                SBcount <= '0;
            end else begin
                SBcount <= n_SBcount;
            end
            state <= n_state;  PC <= n_PC;  PA <= n_PA;  SP <= n_SP;  SI <= n_SI;
            A <= n_A;  X <= n_X;  Y <= n_Y;
            st <= n_st;  zf <= n_zf;  cf <= n_cf;  vf <= n_vf;  sf <= n_sf;
            if_ <= n_if;  ctr <= n_ctr;  pio <= n_pio;  TH <= n_TH;  TL <= n_TL;  TP <= n_TP;
            SB <= n_SB;  ser_on <= n_ser_on;  pending_irq <= n_pending;
            in_irq <= n_in_irq;  o_output <= n_o_output;  credit <= n_credit;  opcode <= n_opcode;
            if (ram_we) ram[ram_wa] <= ram_wd;
            r_out <= n_r_out;  r_we <= n_r_we;  r_re <= n_r_re;
            o_we <= n_o_we;  p_out <= n_p_out;  p_we <= n_p_we;
            dbg_insn <= n_dbg_insn;  dbg_pc <= n_dbg_pc;
        end
    end

    assign o_out = o_output;

endmodule

`default_nettype wire
