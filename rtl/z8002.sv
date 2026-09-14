//------------------------------------------------------------------------------
// Zilog Z8002 (non-segmented Z8000) for the Pole Position core.
//
// This is not a model of the chip's bus timing. It is an executable copy of
// MAME 0.288's z8000 core -- flag quirks, operand-nibble quirks, cycle costs,
// interrupt latching and all -- because MAME is the oracle every other part of
// this core is checked against. sim/z8002 runs it in lockstep with MAME's own
// opcode source and compares every register, flag and bus access after every
// instruction. docs/z8002.md has the design notes and the verification record.
//
// Timing is MAME's cycle budget (docs/interfaces.md): `cen` accrues one credit
// per CPU clock, an instruction starts only with credit > 0 and is charged its
// table cost up front. Execution itself takes a handful of `clk` cycles.
//
// Structure: a fetch/decode front end (the decode function is generated from
// MAME's opcode table, rtl/z8002_dec.svh), then one micro-sequence per handler
// class. Each micro-step changes at most one register, in the same order as
// the MAME statements it mirrors, so register aliasing (pop into the stack
// register, index == destination, ...) resolves exactly as it does in C++.
//------------------------------------------------------------------------------
`default_nettype none

module z8002 (
    input  wire         clk,
    input  wire         reset,      // sync, active high: MAME device_reset
    input  wire         cen,        // 3.072 MHz credit tick

    input  wire         nmi,        // active high; rising edge requests NMI
    input  wire         nvi,        // active high level (NVI_LINE state)
    input  wire         vi,         // active high level (VI_LINE state)
    // One-cycle pulse: "set_input_line was called this cycle", the level above
    // saying whether it asserts or clears. MAME acts on every such call, not
    // only on changes, and Pole Position makes redundant calls both ways (NVI
    // asserted every frame; cleared on every write of 0 to the enable latch),
    // which is observable. Tie low if the glue only ever changes levels.
    input  wire         nvi_evt,
    input  wire         vi_evt,

    output logic        bus_req = 1'b0,
    output logic        bus_we = 1'b0,
    output logic        bus_io = 1'b0,
    output logic        bus_byte = 1'b0,
    output logic [15:0] bus_addr = 16'h0,
    output logic [15:0] bus_wdata = 16'h0,
    input  wire         bus_ack,
    input  wire  [15:0] bus_rdata,

    output logic        dbg_insn = 1'b0,
    output logic [15:0] dbg_pc = 16'h0
);

`include "z8002_dec.svh"

    // FCW bits
    localparam int F_C = 7, F_Z = 6, F_S = 5, F_V = 4, F_DA = 3, F_H = 2;
    localparam int F_NVIE = 11, F_VIE = 12, F_EPU = 13, F_SN = 14;
    // irq_req bits (MAME Z8000_*)
    localparam int Q_RESET = 0, Q_SYSCALL = 1, Q_VI = 2, Q_NVI = 3, Q_NMI = 5, Q_TRAP = 6, Q_EPU = 7;

    localparam logic [3:0] S_BOUND = 4'd0, S_INT = 4'd1, S_HALTCHK = 4'd2, S_FETCH0 = 4'd3,
                           S_DECODE = 4'd4, S_EXT1 = 4'd5, S_EXT2 = 4'd6, S_EXEC = 4'd7,
                           S_MUL = 4'd8, S_DIV = 4'd9, S_DIVFIN = 4'd10, S_PREDEC = 4'd11;

    // ---- architectural state ------------------------------------------------
    logic [15:0] R [16] /* verilator public */;
    logic [15:0] pc      /* verilator public */ = 16'h0;
    logic [15:0] fcw     /* verilator public */ = 16'h0;
    logic [15:0] nsp     /* verilator public */ = 16'h0;
    logic [15:0] nspseg  /* verilator public */ = 16'h0;
    logic [15:0] psap    /* verilator public */ = 16'h0;
    logic [15:0] psapseg /* verilator public */ = 16'h0;
    logic [15:0] refresh /* verilator public */ = 16'h0;
    logic [7:0]  irq_req /* verilator public */ = 8'h01;
    logic        halt    /* verilator public */ = 1'b0;
    logic        nmi_q = 1'b0, nvi_q = 1'b0, vi_q = 1'b0;
    logic        nvi_ev_q = 1'b0, vi_ev_q = 1'b0;
    logic signed [15:0] credit /* verilator public */ = 16'sd0;
    // pulses when one iteration of MAME's execute_run() loop body is complete
    // (an instruction, an interrupt entry, or a halted no-op); the co-simulation
    // harness uses it to step the reference model in lockstep.
    logic step_done /* verilator public */ = 1'b0;

    initial for (int i = 0; i < 16; i++) R[i] = 16'h0;

    // ---- sequencer ------------------------------------------------------------
    logic [3:0]  st  /* verilator public */ = S_BOUND;
    logic [4:0]  sub /* verilator public */ = 5'd0;
    logic [15:0] op0 /* verilator public */ = 16'h0;
    logic [15:0] op1 = 16'h0, op2 = 16'h0;
    logic [9:0]  c_cyc  /* verilator public */ = '0;
    // The decode table is registered in S_PREDEC before S_DECODE uses it: the
    // table followed by the credit adder in one clock was the slowest path in
    // the whole core (-1.0 ns at 49.152 MHz). The extra clock per instruction
    // is invisible: the cost is still charged in S_DECODE, and the core uses
    // about 6 clocks of the ~99 each instruction's budget allows.
    logic [34:0] cw_q = '0;
    // MULTL's data-dependent cost (7 cycles per set bit of the multiplicand)
    // precomputed from the register every clock: register mux, popcount and
    // x7 in front of the credit adder were the next slowest path. The operand
    // register cannot change between decode and the multiply's setup step,
    // so the value used there is always the one MAME would compute.
    logic [8:0]  mul_pop7 = '0;
    // Shift counts, taken as the count word arrives in S_EXT1: every shift
    // form has that word and executes in S_EXEC the clock after, and nothing
    // writes a register in between. Selecting and negating the count in front
    // of the barrel shifter was the last failing path at 49.152 MHz.
    logic [7:0]  sh_cnt_q = '0, dyn_raw_q = '0, dyn_mag_q = '0;
    logic        sh_right_q = 1'b0;
    logic [5:0]  c_cls  /* verilator public */ = '0;
    logic [1:0]  c_sz = '0;
    logic [4:0]  c_aop = '0;
    logic [3:0]  c_mode = '0;
    logic [3:0]  c_var = '0;
    logic [1:0]  c_nxt = '0;
    logic [15:0] ea = '0, t16 = '0, t16b = '0;
    logic [31:0] ta = '0, tb = '0;
    logic [3:0]  lreg = '0;          // LDM register index
    logic [3:0]  lcnt = '0;          // LDM word count
    logic [2:0]  ikind = '0;         // interrupt being serviced
    logic [6:0]  iter = '0;
    logic signed [32:0] m_a = '0, m_b = '0;
    logic signed [65:0] m_p = '0;
    logic [63:0] dq = '0;            // division dividend / quotient shift register
    logic [32:0] drem = '0;          // division partial remainder
    logic [31:0] dvs = '0;           // divisor magnitude
    logic        dneg_q = 1'b0, dneg_r = 1'b0;
    logic [63:0] ddest = '0;         // original dividend (for divide by zero)
    logic        dzero = 1'b0;

    wire [3:0] n1 = op0[11:8], n2 = op0[7:4], n3 = op0[3:0];
    wire [3:0] o1n1 = op1[11:8], o1n2 = op1[7:4], o1n3 = op1[3:0];

    // ---- register views (MAME RB/RW/RL/RQ) ---------------------------------------
    function automatic logic [7:0] rb(input logic [3:0] n);
        rb = n[3] ? R[{1'b0, n[2:0]}][7:0] : R[{1'b0, n[2:0]}][15:8];
    endfunction
    function automatic logic [31:0] rl(input logic [3:0] n);
        rl = {R[{n[3:1], 1'b0}], R[{n[3:1], 1'b1}]};
    endfunction
    function automatic logic [63:0] rqv(input logic [3:0] n);
        rqv = {R[{n[3:2], 2'b00}], R[{n[3:2], 2'b01}], R[{n[3:2], 2'b10}], R[{n[3:2], 2'b11}]};
    endfunction
    function automatic logic [31:0] rv32(input logic [1:0] sz, input logic [3:0] n);
        case (sz)
            2'd0:    rv32 = {24'b0, rb(n)};
            2'd1:    rv32 = {16'b0, R[n]};
            default: rv32 = rl(n);
        endcase
    endfunction
    function automatic logic [31:0] rq32(input logic [3:0] n);
        rq32 = {R[{n[3:2], 2'b10}], R[{n[3:2], 2'b11}]};
    endfunction
    function automatic logic [63:0] rv(input logic [1:0] sz, input logic [3:0] n);
        case (sz)
            2'd0:    rv = {56'b0, rb(n)};
            2'd1:    rv = {48'b0, R[n]};
            2'd2:    rv = {32'b0, rl(n)};
            default: rv = rqv(n);
        endcase
    endfunction

    // ---- condition codes -----------------------------------------------------------
    function automatic logic ccv(input logic [3:0] c, input logic [7:0] f);
        logic lt;
        lt = f[F_V] ^ f[F_S];
        case (c)
            4'h0: ccv = 1'b0;
            4'h1: ccv = lt;
            4'h2: ccv = f[F_Z] | lt;
            4'h3: ccv = f[F_Z] | f[F_C];
            4'h4: ccv = f[F_V];
            4'h5: ccv = f[F_S];
            4'h6: ccv = f[F_Z];
            4'h7: ccv = f[F_C];
            4'h8: ccv = 1'b1;
            4'h9: ccv = ~lt;
            4'hA: ccv = ~(f[F_Z] | lt);
            4'hB: ccv = ~(f[F_Z] | f[F_C]);
            4'hC: ccv = ~f[F_V];
            4'hD: ccv = ~f[F_S];
            4'hE: ccv = ~f[F_Z];
            default: ccv = ~f[F_C];
        endcase
    endfunction

    function automatic logic [5:0] popcnt32(input logic [31:0] x);
        popcnt32 = 6'd0;
        for (int i = 0; i < 32; i++) popcnt32 = popcnt32 + {5'b0, x[i]};
    endfunction
    function automatic logic msb(input logic [1:0] sz, input logic [31:0] x);
        msb = (sz == 2'd0) ? x[7] : (sz == 2'd1) ? x[15] : x[31];
    endfunction
    function automatic logic [31:0] szmask(input logic [1:0] sz);
        szmask = (sz == 2'd0) ? 32'hff : (sz == 2'd1) ? 32'hffff : 32'hffff_ffff;
    endfunction

    // ---- arithmetic/logic unit: MAME ADDB..DECW ----------------------------------------
    // returns {result, new flag byte}
    function automatic logic [39:0] alu(input logic [4:0] op, input logic [1:0] sz,
                                        input logic [31:0] d, input logic [31:0] v,
                                        input logic [7:0] f);
        logic [31:0] m, dm, vm, r;
        logic [32:0] s;
        logic [4:0]  hn;
        logic        ci, c, z, sg, ov;
        logic [7:0]  nf;
        m  = szmask(sz);
        dm = d & m;
        vm = v & m;
        nf = f;
        r  = dm;
        s  = '0;
        hn = '0;
        ci = 1'b0;
        case (op)
            A_ADD, A_ADC, A_INC: begin
                ci = (op == A_ADC) & f[F_C];
                s  = {1'b0, dm} + {1'b0, vm} + {32'b0, ci};
                hn = {1'b0, dm[3:0]} + {1'b0, vm[3:0]} + {4'b0, ci};
            end
            A_SUB, A_SBC, A_DEC, A_CP, A_CPIMM: begin
                ci = (op == A_SBC) & f[F_C];
                s  = {1'b0, dm} - {1'b0, vm} - {32'b0, ci};
                hn = {1'b0, dm[3:0]} - {1'b0, vm[3:0]} - {4'b0, ci};
            end
            A_NEG: s = {1'b0, 32'b0} - {1'b0, dm};
            default: ;
        endcase
        case (op)
            A_ADD, A_ADC, A_INC, A_SUB, A_SBC, A_DEC, A_CP, A_CPIMM, A_NEG: r = s[31:0] & m;
            A_OR:            r = dm | vm;
            A_AND:           r = dm & vm;
            A_XOR:           r = dm ^ vm;
            A_COM:           r = ~dm & m;
            A_TSET:          r = m;
            A_CLR:           r = 32'b0;
            A_LD, A_LDIMM:   r = vm;
            A_RES:           r = dm & ~v & m;
            A_SET:           r = (dm | v) & m;
            default:         r = dm;          // TEST, BIT
        endcase
        c  = (sz == 2'd0) ? s[8] : (sz == 2'd1) ? s[16] : s[32];
        z  = (r == 32'b0);
        sg = msb(sz, r);
        case (op)
            A_ADD, A_ADC, A_INC: ov = (msb(sz, dm) == msb(sz, vm)) && (sg != msb(sz, dm));
            default:             ov = (msb(sz, dm) != msb(sz, vm)) && (sg != msb(sz, dm));
        endcase
        case (op)
            A_ADD, A_ADC: begin
                nf[F_C] = c; nf[F_Z] = z; nf[F_S] = sg; nf[F_V] = ov;
                if (sz == 2'd0) begin nf[F_H] = hn[4]; nf[F_DA] = 1'b0; end
            end
            A_SUB, A_SBC: begin
                nf[F_C] = c; nf[F_Z] = z; nf[F_S] = sg; nf[F_V] = ov;
                if (sz == 2'd0) begin nf[F_H] = hn[4]; nf[F_DA] = 1'b1; end
            end
            A_CP, A_CPIMM: begin
                nf[F_C] = c; nf[F_Z] = z; nf[F_S] = sg; nf[F_V] = ov;
            end
            A_INC, A_DEC: begin
                nf[F_Z] = z; nf[F_S] = sg; nf[F_V] = ov;
            end
            A_NEG: begin
                nf[F_C] = ~z; nf[F_Z] = z; nf[F_S] = sg;
                nf[F_V] = (r == ((sz == 2'd0) ? 32'h80 : 32'h8000));
            end
            A_OR, A_AND, A_XOR, A_COM, A_TEST: begin
                nf[F_Z] = z; nf[F_S] = sg;
                if (sz == 2'd0) nf[F_V] = ~^r[7:0];
            end
            A_TSET: nf[F_S] = msb(sz, dm);
            A_BIT:  nf[F_Z] = ((dm & v) == 32'b0);
            default: ;
        endcase
        alu = {r, nf};
    endfunction

    // ---- shifts: MAME SLL/SRL/SLA/SRA (count 0..255) and SDA/SDL (signed count) ----------
    // returns {result, carry}
    // One shifter for every shift and dynamic-shift instruction: result in
    // [32:1], the last bit shifted out in [0]. Counts run to 255, as MAME's
    // count parameters do.
    function automatic logic [32:0] shift(input logic [1:0] sz, input logic [31:0] d,
                                          input logic [7:0] n, input logic right, input logic arith);
        logic [31:0] se;
        logic [63:0] w;
        logic [5:0]  wb;
        wb = (sz == 2'd0) ? 6'd8 : (sz == 2'd1) ? 6'd16 : 6'd32;
        se = (sz == 2'd0) ? {{24{arith & d[7]}}, d[7:0]} :
             (sz == 2'd1) ? {{16{arith & d[15]}}, d[15:0]} : d;
        if (right) begin
            // not a ternary: mixing a signed and an unsigned operand there makes
            // the whole expression unsigned, and the arithmetic shift zero-fills
            w = {se, 32'b0} >> n;
            if (arith) w = $signed({se, 32'b0}) >>> n;
            shift = {w[63:32] & szmask(sz), w[31]};
        end else begin
            w = {32'b0, d & szmask(sz)} << n;
            shift = {w[31:0] & szmask(sz), w[wb]};
        end
    endfunction

    // ---- effective address -------------------------------------------------------------
    wire [3:0] bn = (c_cls == C_PUSH || c_cls == C_POP || (c_cls == C_UN && c_var[0])) ? n3 : n2;
    logic [15:0] ea_c;
    always_comb begin
        case (c_mode)
            M_IR:    ea_c = R[bn];
            M_X:     ea_c = op1 + R[bn];
            M_REL:   ea_c = pc + op1;
            M_BA:    ea_c = R[bn] + op1;
            M_BX:    ea_c = R[bn] + R[o1n1];
            default: ea_c = op1;
        endcase
    end

    wire        bdone = bus_req & bus_ack;
    wire [7:0]  rbyte_ea = ea_c[0] ? bus_rdata[7:0] : bus_rdata[15:8];

    wire [15:0] vec_off = (ikind == 3'd1) ? 16'h0004 : (ikind == 3'd2) ? 16'h0008 :
                          (ikind == 3'd3) ? 16'h000c : (ikind == 3'd4) ? 16'h0014 :
                          (ikind == 3'd5) ? 16'h0018 : 16'h001c;
    wire [7:0]  ibit    = (ikind == 3'd1) ? 8'h80 : (ikind == 3'd2) ? 8'h40 :
                          (ikind == 3'd3) ? 8'h02 : (ikind == 3'd4) ? 8'h20 :
                          (ikind == 3'd5) ? 8'h08 : 8'h04;

    // IMM source operand
    wire [31:0] imm_v = (c_sz == 2'd0) ? {24'b0, op1[7:0]} : (c_sz == 2'd1) ? {16'b0, op1} : {op1, op2};


    always_ff @(posedge clk) begin : seq
        // per-cycle actions, applied at the end of the block
        logic        w_en;  logic [1:0] w_sz;  logic [3:0] w_n;  logic [31:0] w_lo;  logic [31:0] w_hi;
        logic [63:0] w_v;
        logic        rq;    logic rq_we, rq_io, rq_byte;  logic [15:0] rq_a, rq_d;
        logic        chg;   logic [15:0] chg_v;
        logic [7:0]  i_set, i_clr;
        logic signed [15:0] cdelta;
        logic        czero;
        logic        fl_en; logic [7:0] fl_v;
        logic [39:0] au;
        logic        au_go, au_wreg, au_fl, au_zcc, au_rqd;
        logic [4:0]  au_op;
        logic [3:0]  au_n, au_cc;
        logic [31:0] au_d, au_v;
        logic [32:0] sh;
        logic        sh_dir, sh_arith;
        logic [7:0]  sh_n;
        logic [31:0] tmp32;
        logic [63:0] tmp64;
        logic [15:0] k;
        logic        done;
        logic        fin;
        logic        hit;
        logic [7:0]  irq_live;

        w_en = 1'b0; w_sz = 2'd1; w_n = 4'd0; w_lo = 32'd0; w_hi = 32'd0;
        rq = 1'b0; rq_we = 1'b0; rq_io = 1'b0; rq_byte = 1'b0; rq_a = 16'h0; rq_d = 16'h0;
        chg = 1'b0; chg_v = 16'h0;
        i_set = 8'h0; i_clr = 8'h0;
        cdelta = 16'sd0; czero = 1'b0;
        fl_en = 1'b0; fl_v = fcw[7:0];
        au = '0; sh = '0; tmp32 = '0; tmp64 = '0; k = '0;
        done = 1'b0; fin = 1'b0; hit = 1'b0;
        au_go = 1'b0; au_wreg = 1'b0; au_fl = 1'b0; au_zcc = 1'b0; au_rqd = 1'b0;
        au_op = A_LD; au_n = 4'd0; au_cc = 4'd0; au_d = 32'b0; au_v = 32'b0;
        sh_dir = 1'b0; sh_arith = 1'b0; sh_n = 8'b0;
        dbg_insn <= 1'b0;
        step_done <= 1'b0;
        mul_pop7 <= {3'b0, popcnt32(rq32(n3))} * 9'd7;

        // Input lines, evaluated before the sequencer: MAME applies interrupt
        // line events between instructions, so a request raised now must be
        // visible to the boundary check in this same cycle.
        //
        // An event is a call to set_input_line: the line's *level* decides
        // whether it asserts or clears, and a repeated call with an unchanged
        // level is still an event (MAME's polepos glue makes both kinds -- it
        // asserts NVI every frame and clears it on every write of 0 to the NVI
        // enable latch). So an event here is a change of level, or a pulse on
        // *_evt with the level as it stands.
        irq_live = irq_req;
        if (nmi && !nmi_q) irq_live[Q_NMI] = 1'b1;
        if (nvi ? ((!nvi_q) || (nvi_evt && !nvi_ev_q)) : 1'b0) begin
            if (fcw[F_NVIE]) irq_live[Q_NVI] = 1'b1;
        end else if (!nvi && (nvi_q || (nvi_evt && !nvi_ev_q)) && !fcw[F_NVIE])
            irq_live[Q_NVI] = 1'b0;
        if (vi ? ((!vi_q) || (vi_evt && !vi_ev_q)) : 1'b0) begin
            if (fcw[F_VIE]) irq_live[Q_VI] = 1'b1;
        end else if (!vi && (vi_q || (vi_evt && !vi_ev_q)) && !fcw[F_VIE])
            irq_live[Q_VI] = 1'b0;
        nmi_q <= nmi;
        nvi_q <= nvi;
        vi_q  <= vi;
        nvi_ev_q <= nvi_evt;
        vi_ev_q  <= vi_evt;

        if (reset) begin
            st <= S_BOUND;
            sub <= 5'd0;
            i_set[Q_RESET] = 1'b1;
            halt <= 1'b0;
            refresh <= refresh & 16'h7fff;
            credit <= 16'sd0;
        end else begin
            case (st)
            // ---------------------------------------------------------------------
            S_BOUND: begin
                sub <= 5'd0;
                if (credit > 16'sd0) begin
                    if (irq_live != 8'h0) st <= S_INT;
                    else if (halt)        begin czero = 1'b1; fin = 1'b1; end
                    else                  st <= S_FETCH0;
                end
            end

            // ---- z8002_device::Interrupt() ----------------------------------------
            S_INT: begin
                case (sub)
                5'd0: begin
                    if (irq_req[Q_RESET]) begin
                        i_clr = ~8'h0C;
                        sub <= 5'd20;
                    end else begin
                        hit = 1'b1;
                        if      (irq_req[Q_EPU])                    ikind <= 3'd1;
                        else if (irq_req[Q_TRAP])                   ikind <= 3'd2;
                        else if (irq_req[Q_SYSCALL])                ikind <= 3'd3;
                        else if (irq_req[Q_NMI])                    ikind <= 3'd4;
                        else if (irq_req[Q_NVI] && fcw[F_NVIE])     ikind <= 3'd5;
                        else if (irq_req[Q_VI] && fcw[F_VIE])       ikind <= 3'd6;
                        else                                        hit = 1'b0;
                        if (hit) sub <= 5'd1;
                        else     st <= S_HALTCHK;
                    end
                end
                5'd1: begin     // CHANGE_FCW(fcw | F_S_N), remember the old FCW
                    t16b <= fcw;
                    if (ikind >= 3'd4) halt <= 1'b0;
                    chg = 1'b1; chg_v = fcw | 16'h4000;
                    sub <= 5'd2;
                end
                5'd2, 5'd4, 5'd6: begin     // PUSHW: SP -= 2
                    w_en = 1'b1; w_n = 4'd15; w_lo = {16'b0, R[15] - 16'd2};
                    sub <= sub + 5'd1;
                end
                5'd3, 5'd5, 5'd7: begin
                    rq = 1'b1; rq_we = 1'b1; rq_a = R[15];
                    rq_d = (sub == 5'd3) ? pc : (sub == 5'd5) ? t16b :
                           (ikind <= 3'd3) ? op0 : 16'hffff;
                    if (bdone) sub <= sub + 5'd1;
                end
                5'd8: begin     // pc = GET_PC(vec) for NVI/VI happens before the clear; reads are free of side effects
                    i_clr = ibit;
                    sub <= 5'd9;
                end
                5'd9: begin
                    rq = 1'b1; rq_a = psap + vec_off;
                    if (bdone) begin t16 <= bus_rdata; sub <= 5'd10; end
                end
                5'd10: begin
                    chg = 1'b1; chg_v = t16;
                    sub <= 5'd11;
                end
                5'd11: begin
                    rq = 1'b1; rq_a = (ikind == 3'd6) ? (psap + 16'h021c) : (psap + vec_off + 16'd2);
                    if (bdone) begin pc <= bus_rdata; st <= S_HALTCHK; end
                end
                // reset
                5'd20: begin
                    rq = 1'b1; rq_a = 16'h0002;
                    if (bdone) begin t16 <= bus_rdata; sub <= 5'd21; end
                end
                5'd21: begin
                    chg = 1'b1; chg_v = t16;
                    sub <= 5'd22;
                end
                5'd22: begin
                    rq = 1'b1; rq_a = 16'h0004;
                    if (bdone) begin pc <= bus_rdata; st <= S_HALTCHK; end
                end
                default: st <= S_HALTCHK;
                endcase
            end

            S_HALTCHK: begin
                sub <= 5'd0;
                if (halt) begin czero = 1'b1; fin = 1'b1; st <= S_BOUND; end
                else      st <= S_FETCH0;
            end

            // ---- fetch and decode -------------------------------------------------
            S_FETCH0: begin
                rq = 1'b1; rq_a = pc;
                if (bdone) begin
                    op0 <= bus_rdata;
                    pc <= pc + 16'd2;
                    dbg_insn <= 1'b1;
                    dbg_pc <= pc;
                    st <= S_PREDEC;
                end
            end

            S_PREDEC: begin
                cw_q <= z8k_dec(op0);
                st <= S_DECODE;
            end

            S_DECODE: begin : decode
                logic [34:0] cw;
                cw = cw_q;
                c_cyc  <= cw[34:25];
                c_cls  <= cw[24:19];
                c_sz   <= cw[18:17];
                c_aop  <= cw[16:12];
                c_mode <= cw[11:8];
                c_var  <= cw[7:4];
                c_nxt  <= cw[3:2];
                cdelta = -$signed({6'b0, cw[34:25]});
                sub <= 5'd0;
                if (cw[1] && !fcw[F_SN]) begin
                    i_set[Q_TRAP] = 1'b1;           // CHECK_PRIVILEGED_INSTR
                    fin = 1'b1;
                    st <= S_BOUND;
                end else if (cw[0] && !fcw[F_EPU]) begin
                    i_set[Q_EPU] = 1'b1;            // CHECK_EXT_INSTR
                    fin = 1'b1;
                    st <= S_BOUND;
                end else if (cw[3:2] != 2'd0)
                    st <= S_EXT1;
                else
                    st <= S_EXEC;
            end

            S_EXT1: begin
                rq = 1'b1; rq_a = pc;
                if (bdone) begin : ext1
                    logic [15:0] si, sn;
                    logic [7:0]  dr;
                    op1 <= bus_rdata;
                    pc <= pc + 16'd2;
                    st <= (c_nxt == 2'd2) ? S_EXT2 : S_EXEC;
                    // SLL/SRL/SLA/SRA immediate: low byte of the (negated, if
                    // negative) operand, as MAME's uint8_t count parameter sees it.
                    // SDL/SDA dynamic: signed low byte of the count register.
                    si = (c_sz == 2'd0) ? {{8{bus_rdata[7]}}, bus_rdata[7:0]} : bus_rdata;
                    sn = 16'd0 - si;
                    sh_right_q <= si[15];
                    sh_cnt_q   <= si[15] ? sn[7:0] : si[7:0];
                    dr = R[bus_rdata[11:8]][7:0];
                    dyn_raw_q  <= dr;
                    dyn_mag_q  <= dr[7] ? (8'd0 - dr) : dr;
                end
            end

            S_EXT2: begin
                rq = 1'b1; rq_a = pc;
                if (bdone) begin
                    op2 <= bus_rdata;
                    pc <= pc + 16'd2;
                    st <= S_EXEC;
                end
            end

            // ---- execute -------------------------------------------------------------
            S_EXEC: begin
                case (c_cls)
                // ------------------------------------------------------------------
                C_ALU: begin
                    case (sub)
                    5'd0: begin
                        if (c_mode == M_IMM || c_mode == M_R) begin
                            au_go = 1'b1; au_op = c_aop; au_d = rv32(c_sz, n3);
                            au_v = (c_mode == M_IMM) ? imm_v : rv32(c_sz, n2);
                            au_wreg = (c_aop != A_CP); au_n = n3; au_fl = 1'b1;
                            done = 1'b1;
                        end else begin
                            rq = 1'b1; rq_a = ea_c; rq_byte = (c_sz == 2'd0);
                            if (bdone) begin
                                ta <= (c_sz == 2'd0) ? {24'b0, rbyte_ea} :
                                      (c_sz == 2'd1) ? {16'b0, bus_rdata} : {bus_rdata, 16'b0};
                                sub <= (c_sz == 2'd2) ? 5'd1 : 5'd2;
                            end
                        end
                    end
                    5'd1: begin
                        rq = 1'b1; rq_a = {ea_c[15:1], 1'b0} + 16'd2;
                        if (bdone) begin ta[15:0] <= bus_rdata; sub <= 5'd2; end
                    end
                    default: begin
                        au_go = 1'b1; au_op = c_aop; au_d = rv32(c_sz, n3); au_v = ta;
                        au_wreg = (c_aop != A_CP); au_n = n3; au_fl = 1'b1;
                        done = 1'b1;
                    end
                    endcase
                end

                // ------------------------------------------------------------------
                C_MUL, C_DIV: begin
                    case (sub)
                    5'd0: begin
                        if (c_mode == M_IMM || c_mode == M_R) begin
                            ta <= (c_mode == M_IMM) ? ((c_sz == 2'd1) ? {16'b0, op1} : {op1, op2})
                                                    : ((c_sz == 2'd1) ? {16'b0, R[n2]} : rl(n2));
                            sub <= 5'd2;
                        end else begin
                            rq = 1'b1; rq_a = ea_c;
                            if (bdone) begin
                                if (c_sz == 2'd1) begin ta <= {16'b0, bus_rdata}; sub <= 5'd2; end
                                else begin ta <= {bus_rdata, 16'b0}; sub <= 5'd1; end
                            end
                        end
                    end
                    5'd1: begin
                        rq = 1'b1; rq_a = {ea_c[15:1], 1'b0} + 16'd2;
                        if (bdone) begin ta[15:0] <= bus_rdata; sub <= 5'd2; end
                    end
                    default: begin
                        if (c_cls == C_MUL) begin
                            // MULTW(uint16 dest = low word of RL, uint16 value)
                            // MULTL(uint32 dest = low long of RQ, uint32 value)
                            if (c_sz == 2'd1) begin
                                m_a <= {{17{R[{n3[3:1], 1'b1}][15]}}, R[{n3[3:1], 1'b1}]};
                                m_b <= {{17{ta[15]}}, ta[15:0]};
                                if (ta[15:0] == 16'h0) cdelta = 16'sd52;
                            end else begin
                                tmp32 = rq32(n3);
                                m_a <= {tmp32[31], tmp32};
                                m_b <= {ta[31], ta};
                                if (ta == 32'h0) cdelta = 16'sd252;
                                else cdelta = -$signed({7'b0, mul_pop7});
                            end
                            iter <= 7'd0;
                            st <= S_MUL;
                        end else begin
                            // DIVW(uint32 dest = RL, uint16 value) / DIVL(uint64 dest = RQ, uint32 value)
                            if (c_sz == 2'd1) begin
                                tmp64 = {32'b0, rl(n3)};
                                dneg_q <= tmp64[31] ^ ta[15];
                                dneg_r <= tmp64[31];
                                dvs    <= ta[15] ? {16'b0, 16'd0 - ta[15:0]} : {16'b0, ta[15:0]};
                                dzero  <= (ta[15:0] == 16'h0);
                                tmp32  = tmp64[31] ? (32'd0 - tmp64[31:0]) : tmp64[31:0];
                                dq     <= {tmp32, 32'b0};
                                iter   <= 7'd32;
                            end else begin
                                tmp64 = rqv(n3);
                                dneg_q <= tmp64[63] ^ ta[31];
                                dneg_r <= tmp64[63];
                                dvs    <= ta[31] ? (32'd0 - ta) : ta;
                                dzero  <= (ta == 32'h0);
                                dq     <= tmp64[63] ? (64'd0 - tmp64) : tmp64;
                                iter   <= 7'd64;
                            end
                            ddest <= (c_sz == 2'd1) ? {32'b0, rl(n3)} : rqv(n3);
                            drem  <= 33'd0;
                            st <= S_DIV;
                        end
                    end
                    endcase
                end

                // ------------------------------------------------------------------
                C_UN: begin : un
                    logic rd_need, wr_need;
                    logic [31:0] uv;
                    rd_need = !(c_aop == A_CLR || c_aop == A_LDIMM);
                    wr_need = !(c_aop == A_TEST || c_aop == A_CPIMM || c_aop == A_BIT);
                    case (c_aop)
                        A_INC, A_DEC:     uv = {28'b0, n3} + 32'd1;
                        A_RES, A_SET, A_BIT: uv = {16'b0, 16'h1 << n3};
                        A_LDIMM, A_CPIMM: uv = (c_mode == M_IR) ? {16'b0, op1} : {16'b0, op2};
                        default:          uv = 32'b0;
                    endcase
                    if (c_sz == 2'd0 && (c_aop == A_LDIMM || c_aop == A_CPIMM)) uv = {24'b0, uv[7:0]};
                    if (c_mode == M_R) begin
                        au_go = 1'b1; au_op = c_aop; au_d = rv32(c_sz, n2); au_v = uv;
                        au_wreg = wr_need; au_n = n2; au_fl = 1'b1;
                        done = 1'b1;
                    end else begin
                        case (sub)
                        5'd0: begin
                            if (rd_need) begin
                                rq = 1'b1; rq_a = ea_c; rq_byte = (c_sz == 2'd0) && !c_var[1];
                                if (bdone) begin
                                    ta <= (c_var[1]) ? {24'b0, bus_rdata[7:0]} :
                                          (c_sz == 2'd0) ? {24'b0, rbyte_ea} :
                                          (c_sz == 2'd1) ? {16'b0, bus_rdata} : {bus_rdata, 16'b0};
                                    sub <= (c_sz == 2'd2) ? 5'd1 : 5'd2;
                                end
                            end else sub <= 5'd2;
                        end
                        5'd1: begin
                            rq = 1'b1; rq_a = {ea_c[15:1], 1'b0} + 16'd2;
                            if (bdone) begin ta[15:0] <= bus_rdata; sub <= 5'd2; end
                        end
                        default: begin
                            au_go = 1'b1; au_op = c_aop; au_d = ta; au_v = uv;
                            if (wr_need) begin
                                rq = 1'b1; rq_we = 1'b1; rq_a = ea_c; rq_byte = (c_sz == 2'd0);
                                au_rqd = 1'b1;
                                if (bdone) begin au_fl = 1'b1; done = 1'b1; end
                            end else begin
                                au_fl = 1'b1; done = 1'b1;
                            end
                        end
                        endcase
                    end
                end

                // ------------------------------------------------------------------
                C_BITDYN: begin
                    au_go = 1'b1; au_op = c_aop; au_d = rv32(c_sz, o1n1);
                    au_v = {16'b0, 16'h1 << ((c_sz == 2'd0) ? {1'b0, R[n3][2:0]} : R[n3][3:0])};
                    au_fl = (c_aop == A_BIT);
                    au_wreg = (c_aop != A_BIT); au_n = o1n1;
                    done = 1'b1;
                end

                // ------------------------------------------------------------------
                C_STORE: begin
                    tmp32 = rv32(c_sz, n3);
                    case (sub)
                    5'd0: begin
                        rq = 1'b1; rq_we = 1'b1; rq_a = ea_c; rq_byte = (c_sz == 2'd0);
                        rq_d = (c_sz == 2'd0) ? {tmp32[7:0], tmp32[7:0]} : (c_sz == 2'd1) ? tmp32[15:0] : tmp32[31:16];
                        if (bdone) begin
                            if (c_sz == 2'd2) sub <= 5'd1; else done = 1'b1;
                        end
                    end
                    default: begin
                        rq = 1'b1; rq_we = 1'b1; rq_a = {ea_c[15:1], 1'b0} + 16'd2; rq_d = tmp32[15:0];
                        if (bdone) done = 1'b1;
                    end
                    endcase
                end

                // ------------------------------------------------------------------
                C_EX: begin
                    if (c_mode == M_R) begin
                        case (sub)
                        5'd0: begin     // tmp = R(src); R(src) = R(dst)
                            ta <= rv32(c_sz, n2);
                            w_en = 1'b1; w_sz = c_sz; w_n = n2; w_lo = rv32(c_sz, n3);
                            sub <= 5'd1;
                        end
                        default: begin
                            w_en = 1'b1; w_sz = c_sz; w_n = n3; w_lo = ta;
                            done = 1'b1;
                        end
                        endcase
                    end else begin
                        case (sub)
                        5'd0: begin
                            rq = 1'b1; rq_a = ea_c; rq_byte = (c_sz == 2'd0);
                            if (bdone) begin
                                ta <= (c_sz == 2'd0) ? {24'b0, rbyte_ea} : {16'b0, bus_rdata};
                                sub <= 5'd1;
                            end
                        end
                        5'd1: begin
                            tmp32 = rv32(c_sz, n3);
                            rq = 1'b1; rq_we = 1'b1; rq_a = ea_c; rq_byte = (c_sz == 2'd0);
                            rq_d = (c_sz == 2'd0) ? {tmp32[7:0], tmp32[7:0]} : tmp32[15:0];
                            if (bdone) sub <= 5'd2;
                        end
                        default: begin
                            w_en = 1'b1; w_sz = c_sz; w_n = n3; w_lo = ta;
                            done = 1'b1;
                        end
                        endcase
                    end
                end

                // ------------------------------------------------------------------
                C_PUSH: begin
                    k = (c_sz == 2'd2) ? 16'd4 : 16'd2;
                    case (sub)
                    5'd0: begin
                        if (c_mode == M_IMM) begin ta <= {16'b0, op1}; sub <= 5'd2; end
                        else if (c_mode == M_R) begin ta <= rv32(c_sz, n3); sub <= 5'd2; end
                        else begin
                            rq = 1'b1; rq_a = ea_c;
                            if (bdone) begin
                                if (c_sz == 2'd1) begin ta <= {16'b0, bus_rdata}; sub <= 5'd2; end
                                else begin ta <= {bus_rdata, 16'b0}; sub <= 5'd1; end
                            end
                        end
                    end
                    5'd1: begin
                        rq = 1'b1; rq_a = {ea_c[15:1], 1'b0} + 16'd2;
                        if (bdone) begin ta[15:0] <= bus_rdata; sub <= 5'd2; end
                    end
                    5'd2: begin
                        w_en = 1'b1; w_n = n2; w_lo = {16'b0, R[n2] - k};
                        sub <= 5'd3;
                    end
                    5'd3: begin
                        rq = 1'b1; rq_we = 1'b1; rq_a = R[n2];
                        rq_d = (c_sz == 2'd2) ? ta[31:16] : ta[15:0];
                        if (bdone) begin
                            if (c_sz == 2'd2) sub <= 5'd4; else done = 1'b1;
                        end
                    end
                    default: begin
                        rq = 1'b1; rq_we = 1'b1; rq_a = {R[n2][15:1], 1'b0} + 16'd2; rq_d = ta[15:0];
                        if (bdone) done = 1'b1;
                    end
                    endcase
                end

                // ------------------------------------------------------------------
                C_POP: begin
                    k = (c_sz == 2'd2) ? 16'd4 : 16'd2;
                    case (sub)
                    5'd0: begin
                        ea <= ea_c;       // DA/X destination is addressed before the pop
                        rq = 1'b1; rq_a = R[n2];
                        if (bdone) begin
                            if (c_sz == 2'd1) begin ta <= {16'b0, bus_rdata}; sub <= 5'd2; end
                            else begin ta <= {bus_rdata, 16'b0}; sub <= 5'd1; end
                        end
                    end
                    5'd1: begin
                        rq = 1'b1; rq_a = {R[n2][15:1], 1'b0} + 16'd2;
                        if (bdone) begin ta[15:0] <= bus_rdata; sub <= 5'd2; end
                    end
                    5'd2: begin
                        w_en = 1'b1; w_n = n2; w_lo = {16'b0, R[n2] + k};
                        sub <= 5'd3;
                    end
                    5'd3: begin
                        if (c_mode == M_R) begin
                            w_en = 1'b1; w_sz = c_sz; w_n = n3; w_lo = ta;
                            done = 1'b1;
                        end else begin
                            rq = 1'b1; rq_we = 1'b1;
                            rq_a = (c_mode == M_IR) ? R[n3] : ea;
                            rq_d = (c_sz == 2'd2) ? ta[31:16] : ta[15:0];
                            if (bdone) begin
                                if (c_sz == 2'd2) sub <= 5'd4; else done = 1'b1;
                            end
                        end
                    end
                    default: begin
                        rq = 1'b1; rq_we = 1'b1;
                        rq_a = {((c_mode == M_IR) ? R[n3][15:1] : ea[15:1]), 1'b0} + 16'd2;
                        rq_d = ta[15:0];
                        if (bdone) done = 1'b1;
                    end
                    endcase
                end

                // ------------------------------------------------------------------
                C_LDA: begin
                    case (c_var)
                    4'd0: begin w_en = 1'b1; w_n = n3; w_lo = {16'b0, pc + op1}; done = 1'b1; end
                    4'd3: begin w_en = 1'b1; w_n = n3; w_lo = {16'b0, op1}; done = 1'b1; end
                    4'd1, 4'd2: begin
                        if (sub == 5'd0) begin
                            w_en = 1'b1; w_n = n3; w_lo = {16'b0, R[n2]};
                            sub <= 5'd1;
                        end else begin
                            w_en = 1'b1; w_n = n3;
                            w_lo = {16'b0, R[n3] + ((c_var == 4'd1) ? op1 : R[o1n1])};
                            done = 1'b1;
                        end
                    end
                    default: begin
                        if (sub == 5'd0) begin
                            t16 <= R[n2];
                            w_en = 1'b1; w_n = n3; w_lo = {16'b0, op1};
                            sub <= 5'd1;
                        end else begin
                            w_en = 1'b1; w_n = n3; w_lo = {16'b0, R[n3] + t16};
                            done = 1'b1;
                        end
                    end
                    endcase
                end

                // ------------------------------------------------------------------
                C_JP: begin
                    if (ccv(n3, fcw[7:0])) pc <= ea_c;
                    done = 1'b1;
                end

                C_CALL, C_CALR: begin
                    case (sub)
                    5'd0: begin
                        w_en = 1'b1; w_n = 4'd15; w_lo = {16'b0, R[15] - 16'd2};
                        sub <= 5'd1;
                    end
                    5'd1: begin
                        rq = 1'b1; rq_we = 1'b1; rq_a = R[15]; rq_d = pc;
                        if (bdone) sub <= 5'd2;
                    end
                    default: begin
                        if (c_cls == C_CALL) pc <= ea_c;
                        else pc <= pc + (op0[11] ? (16'd4096 - {4'b0, op0[10:0], 1'b0})
                                                 : (16'd0 - {4'b0, op0[10:0], 1'b0}));
                        done = 1'b1;
                    end
                    endcase
                end

                C_RET: begin
                    if (!ccv(n3, fcw[7:0])) done = 1'b1;
                    else begin
                        case (sub)
                        5'd0: begin
                            rq = 1'b1; rq_a = R[15];
                            if (bdone) begin t16 <= bus_rdata; sub <= 5'd1; end
                        end
                        default: begin
                            w_en = 1'b1; w_n = 4'd15; w_lo = {16'b0, R[15] + 16'd2};
                            pc <= t16;
                            done = 1'b1;
                        end
                        endcase
                    end
                end

                C_JR: begin
                    if (ccv(n1, fcw[7:0])) pc <= pc + {{7{op0[7]}}, op0[7:0], 1'b0};
                    done = 1'b1;
                end

                C_DJNZ: begin
                    if (c_sz == 2'd0) begin
                        tmp32 = {24'b0, rb(n1) - 8'd1};
                        w_en = 1'b1; w_sz = 2'd0; w_n = n1; w_lo = tmp32;
                        if (tmp32[7:0] != 8'h0) pc <= pc - {8'b0, op0[6:0], 1'b0};
                    end else begin
                        tmp32 = {16'b0, R[n1] - 16'd1};
                        w_en = 1'b1; w_n = n1; w_lo = tmp32;
                        if (tmp32[15:0] != 16'h0) pc <= pc - {8'b0, op0[6:0], 1'b0};
                    end
                    done = 1'b1;
                end

                // ------------------------------------------------------------------
                C_IRET: begin
                    case (sub)
                    5'd0, 5'd2, 5'd4: begin
                        rq = 1'b1; rq_a = R[15];
                        if (bdone) begin
                            if (sub == 5'd2) t16 <= bus_rdata;
                            if (sub == 5'd4) t16b <= bus_rdata;
                            sub <= sub + 5'd1;
                        end
                    end
                    5'd1, 5'd3: begin
                        w_en = 1'b1; w_n = 4'd15; w_lo = {16'b0, R[15] + 16'd2};
                        sub <= sub + 5'd1;
                    end
                    5'd5: begin
                        w_en = 1'b1; w_n = 4'd15; w_lo = {16'b0, R[15] + 16'd2};
                        pc <= t16b;
                        sub <= 5'd6;
                    end
                    default: begin
                        chg = 1'b1; chg_v = t16;
                        done = 1'b1;
                    end
                    endcase
                end

                C_LDPS: begin
                    case (sub)
                    5'd0: begin
                        rq = 1'b1; rq_a = ea_c;
                        if (bdone) begin t16 <= bus_rdata; sub <= 5'd1; end
                    end
                    5'd1: begin
                        rq = 1'b1; rq_a = ea_c + 16'd2;
                        if (bdone) begin t16b <= bus_rdata; sub <= 5'd2; end
                    end
                    default: begin
                        pc <= t16b;
                        chg = 1'b1; chg_v = t16;
                        done = 1'b1;
                    end
                    endcase
                end

                C_HALT: begin
                    halt <= 1'b1;
                    czero = 1'b1;
                    done = 1'b1;
                end

                C_DIEI: begin
                    chg = 1'b1;
                    if (c_var == 4'd0) chg_v = fcw & ({3'b0, n3[1:0], 11'b0} | 16'he7ff);
                    else               chg_v = fcw | {3'b0, ~n3[1:0], 11'b0};
                    done = 1'b1;
                end

                C_LDCTL: begin
                    if (c_var == 4'd0) begin
                        case (n3[2:0])
                            3'd2: begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, fcw}; end
                            3'd3: begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, refresh}; end
                            3'd4: begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, psapseg}; end
                            3'd5: begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, psap}; end
                            3'd6: begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, nspseg}; end
                            3'd7: begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, nsp}; end
                            default: ;
                        endcase
                    end else begin
                        case (n3[2:0])
                            3'd2: begin chg = 1'b1; chg_v = R[n2]; end
                            3'd3: refresh <= R[n2];
                            3'd4: psapseg <= R[n2];
                            3'd5: psap <= R[n2];
                            3'd6: nspseg <= R[n2];
                            3'd7: nsp <= R[n2];
                            default: ;
                        endcase
                    end
                    done = 1'b1;
                end

                C_MREQ: begin
                    fl_en = 1'b1; fl_v[F_Z] = 1'b1; fl_v[F_S] = 1'b0;
                    done = 1'b1;
                end

                C_TRAPREQ: begin
                    if (c_var == 4'd0) i_set[Q_SYSCALL] = 1'b1;
                    else               i_set[Q_TRAP] = 1'b1;
                    done = 1'b1;
                end

                C_FLAGS: begin
                    case (c_var)
                        4'd0: begin fl_en = 1'b1; fl_v = fcw[7:0] | (op0[7:0] & 8'hf0); end
                        4'd1: begin fl_en = 1'b1; fl_v = fcw[7:0] & ~(op0[7:0] & 8'hf0); end
                        4'd2: begin fl_en = 1'b1; fl_v = fcw[7:0] ^ (op0[7:0] & 8'hf0); end
                        4'd3: begin w_en = 1'b1; w_sz = 2'd0; w_n = n2; w_lo = {24'b0, fcw[7:0] & 8'hfc}; end
                        default: begin fl_en = 1'b1; fl_v = (fcw[7:0] & 8'h03) | (rb(n2) & 8'hfc); end
                    endcase
                    done = 1'b1;
                end

                // ------------------------------------------------------------------
                C_SHIFT: begin : shf
                    logic [31:0] d, r;
                    logic        cy, isrot, vsign, vclr;
                    logic [7:0]  nf;
                    d  = rv32(c_sz, n2);
                    nf = fcw[7:0];
                    r  = d;
                    cy = 1'b0;
                    isrot = 1'b0; vsign = 1'b0; vclr = 1'b0;
                    case (c_var)
                    4'd0, 4'd1, 4'd2, 4'd3: begin : rot
                        // RL/RLC/RR/RRC, once or twice (bit 1 of NIB3)
                        logic [31:0] r1;
                        logic c1, w8;
                        isrot = 1'b1;
                        w8 = (c_sz == 2'd0);
                        case (c_var)
                        4'd0: begin
                            r1 = w8 ? {24'b0, d[6:0], d[7]} : {16'b0, d[14:0], d[15]};
                            r  = n3[1] ? (w8 ? {24'b0, r1[6:0], r1[7]} : {16'b0, r1[14:0], r1[15]}) : r1;
                            cy = r[0];
                        end
                        4'd1: begin
                            c1 = w8 ? d[7] : d[15];
                            r1 = w8 ? {24'b0, d[6:0], fcw[F_C]} : {16'b0, d[14:0], fcw[F_C]};
                            if (n3[1]) begin
                                r  = w8 ? {24'b0, r1[6:0], c1} : {16'b0, r1[14:0], c1};
                                cy = w8 ? r1[7] : r1[15];
                            end else begin r = r1; cy = c1; end
                        end
                        4'd2: begin
                            r1 = w8 ? {24'b0, d[0], d[7:1]} : {16'b0, d[0], d[15:1]};
                            r  = n3[1] ? (w8 ? {24'b0, r1[0], r1[7:1]} : {16'b0, r1[0], r1[15:1]}) : r1;
                            cy = msb(c_sz, r);
                        end
                        default: begin
                            c1 = d[0];
                            r1 = w8 ? {24'b0, fcw[F_C], d[7:1]} : {16'b0, fcw[F_C], d[15:1]};
                            if (n3[1]) begin
                                r  = w8 ? {24'b0, c1, r1[7:1]} : {16'b0, c1, r1[15:1]};
                                cy = r1[0];
                            end else begin r = r1; cy = c1; end
                        end
                        endcase
                        nf[F_V] = msb(c_sz, r) ^ msb(c_sz, d);
                    end
                    4'd4: begin     // sll/srl imm: V untouched
                        sh_n = sh_cnt_q; sh_dir = sh_right_q;
                    end
                    4'd5: begin     // sla/sra imm: V set on a sign change, cleared by sra
                        sh_n = sh_cnt_q; sh_dir = sh_right_q; sh_arith = sh_right_q;
                        vsign = ~sh_right_q; vclr = sh_right_q;
                    end
                    4'd8: begin     // sdlb: MAME shifts right by the unsigned low byte
                        sh_n = dyn_raw_q; sh_dir = 1'b1;
                    end
                    default: begin  // sdl (6) / sda (7): signed count
                        sh_n = dyn_mag_q; sh_dir = dyn_raw_q[7];
                        sh_arith = (c_var == 4'd7) & dyn_raw_q[7];
                        vsign = 1'b1;
                    end
                    endcase
                    if (!isrot) begin
                        sh = shift(c_sz, d, sh_n, sh_dir, sh_arith);
                        r  = sh[32:1];
                        cy = (sh_n == 8'd0) ? 1'b0 : sh[0];
                        if (vsign) nf[F_V] = msb(c_sz, r) ^ msb(c_sz, d);
                        if (vclr)  nf[F_V] = 1'b0;
                    end
                    nf[F_C] = cy; nf[F_Z] = (r == 32'b0); nf[F_S] = msb(c_sz, r);
                    w_en = 1'b1; w_sz = c_sz; w_n = n2; w_lo = r;
                    fl_en = 1'b1; fl_v = nf;
                    done = 1'b1;
                end

                C_DAB: begin : dab
                    logic [8:0] dv;
                    dv = z8k_dab({fcw[F_DA], fcw[F_H], fcw[F_C], rb(n2)});
                    w_en = 1'b1; w_sz = 2'd0; w_n = n2; w_lo = {23'b0, dv};
                    fl_en = 1'b1;
                    fl_v[F_C] = dv[8]; fl_v[F_Z] = (dv[7:0] == 8'h0); fl_v[F_S] = dv[7];
                    done = 1'b1;
                end

                C_EXTS: begin
                    w_en = 1'b1; w_n = n2;
                    case (c_sz)
                        2'd0: begin w_sz = 2'd1; w_lo = {16'b0, {8{R[n2][7]}}, R[n2][7:0]}; end
                        2'd1: begin w_sz = 2'd2; tmp32 = rl(n2); w_lo = {{16{tmp32[15]}}, tmp32[15:0]}; end
                        default: begin w_sz = 2'd3; tmp32 = rq32(n2); w_hi = {32{tmp32[31]}}; w_lo = tmp32; end
                    endcase
                    done = 1'b1;
                end

                C_TCC: begin
                    tmp32 = rv32(c_sz, n2);
                    w_en = 1'b1; w_sz = c_sz; w_n = n2;
                    w_lo = {16'b0, tmp32[15:1], ccv(n3, fcw[7:0])};
                    done = 1'b1;
                end

                C_LDK: begin
                    w_en = 1'b1; w_n = n2; w_lo = {28'b0, n3};
                    done = 1'b1;
                end

                C_LDBS: begin
                    w_en = 1'b1; w_sz = 2'd0; w_n = n1; w_lo = {24'b0, op0[7:0]};
                    done = 1'b1;
                end

                C_RXDB: begin
                    // a = NIB2, b = NIB3
                    if (sub == 5'd0) begin
                        ta[7:0] <= (c_var == 4'd0) ? rb(n3) : rb(n2);
                        w_en = 1'b1; w_sz = 2'd0; w_n = n2;
                        w_lo = (c_var == 4'd0) ? {24'b0, (rb(n2) >> 4) | (rb(n3) << 4)}
                                               : {24'b0, (rb(n2) << 4) | (rb(n3) & 8'h0f)};
                        sub <= 5'd1;
                    end else begin
                        tmp32[7:0] = (c_var == 4'd0) ? ((rb(n3) & 8'hf0) | (ta[7:0] & 8'h0f))
                                                     : ((rb(n3) & 8'hf0) | (ta[7:0] >> 4));
                        w_en = 1'b1; w_sz = 2'd0; w_n = n3; w_lo = {24'b0, tmp32[7:0]};
                        fl_en = 1'b1; fl_v[F_Z] = (tmp32[7:0] == 8'h0);
                        done = 1'b1;
                    end
                end

                // ---- ZBA/ZBB: CPI/CPS/LD block family -----------------------------------
                C_BLK: begin : blk
                    logic lds, cps, dec, rep;
                    lds = n3[0];
                    cps = n3[1];
                    dec = n3[3];
                    // MAME's byte cpsib (0010) repeats like cpsirb; every other
                    // non-R form repeats only with bit 2 set
                    rep = n3[2] | ((c_sz == 2'd0) && (n3 == 4'b0010));
                    k   = (c_sz == 2'd0) ? 16'd1 : 16'd2;
                    case (sub)
                    5'd0: begin     // LD: @src; CP: @src; CPS: @dst first
                        rq = 1'b1; rq_byte = (c_sz == 2'd0);
                        rq_a = (cps && !lds) ? R[o1n2] : R[n2];
                        if (bdone) begin
                            tmp32 = (c_sz == 2'd0) ? {24'b0, (rq_a[0] ? bus_rdata[7:0] : bus_rdata[15:8])} : {16'b0, bus_rdata};
                            ta <= tmp32;
                            sub <= lds ? 5'd3 : cps ? 5'd1 : 5'd2;
                        end
                    end
                    5'd1: begin     // CPS: @src
                        rq = 1'b1; rq_byte = (c_sz == 2'd0); rq_a = R[n2];
                        if (bdone) begin
                            tb <= (c_sz == 2'd0) ? {24'b0, (rq_a[0] ? bus_rdata[7:0] : bus_rdata[15:8])} : {16'b0, bus_rdata};
                            sub <= 5'd2;
                        end
                    end
                    5'd2: begin     // compare, then Z = cc
                        au_go = 1'b1; au_op = A_CP;
                        au_d = cps ? ta : rv32(c_sz, o1n2);
                        au_v = cps ? tb : ta;
                        au_fl = 1'b1; au_zcc = 1'b1; au_cc = o1n3;
                        sub <= 5'd4;
                    end
                    5'd3: begin     // LD: write @dst
                        rq = 1'b1; rq_we = 1'b1; rq_byte = (c_sz == 2'd0); rq_a = R[o1n2];
                        rq_d = (c_sz == 2'd0) ? {ta[7:0], ta[7:0]} : ta[15:0];
                        if (bdone) sub <= 5'd4;
                    end
                    5'd4: begin     // src +/-
                        w_en = 1'b1; w_n = n2; w_lo = {16'b0, dec ? (R[n2] - k) : (R[n2] + k)};
                        sub <= (lds || cps) ? 5'd5 : 5'd6;
                    end
                    5'd5: begin     // dst +/-
                        w_en = 1'b1; w_n = o1n2; w_lo = {16'b0, dec ? (R[o1n2] - k) : (R[o1n2] + k)};
                        sub <= 5'd6;
                    end
                    default: begin  // --count, V, repeat
                        tmp32[15:0] = R[o1n1] - 16'd1;
                        w_en = 1'b1; w_n = o1n1; w_lo = {16'b0, tmp32[15:0]};
                        fl_en = 1'b1; fl_v[F_V] = (tmp32[15:0] == 16'h0);
                        if (tmp32[15:0] != 16'h0) begin
                            if (lds) begin if (o1n3 == 4'h0) pc <= pc - 16'd4; end
                            else if (rep && !fcw[F_Z]) pc <= pc - 16'd4;
                        end
                        done = 1'b1;
                    end
                    endcase
                end

                // ---- ZB8: TRI/TRD/TRTI/TRTD ------------------------------------------------
                C_TR: begin : tr
                    logic dec, rep, tst;
                    dec = n3[3];
                    rep = n3[2];
                    tst = n3[1];
                    case (sub)
                    5'd0: begin
                        ea <= R[n2];
                        rq = 1'b1; rq_byte = 1'b1; rq_a = R[n2];
                        if (bdone) begin
                            ta[7:0] <= R[n2][0] ? bus_rdata[7:0] : bus_rdata[15:8];
                            sub <= 5'd1;
                        end
                    end
                    5'd1: begin
                        rq = 1'b1; rq_byte = 1'b1; rq_a = R[o1n2] + {8'b0, ta[7:0]};
                        if (bdone) begin
                            tb[7:0] <= rq_a[0] ? bus_rdata[7:0] : bus_rdata[15:8];
                            sub <= tst ? 5'd3 : 5'd2;
                        end
                    end
                    5'd2: begin
                        rq = 1'b1; rq_we = 1'b1; rq_byte = 1'b1; rq_a = ea; rq_d = {tb[7:0], tb[7:0]};
                        if (bdone) sub <= 5'd3;
                    end
                    5'd3: begin     // RH1 = xlt
                        w_en = 1'b1; w_sz = 2'd0; w_n = 4'd1; w_lo = {24'b0, tb[7:0]};
                        if (tst) begin fl_en = 1'b1; fl_v[F_Z] = (tb[7:0] == 8'h0); end
                        sub <= 5'd4;
                    end
                    5'd4: begin
                        w_en = 1'b1; w_n = n2; w_lo = {16'b0, dec ? (R[n2] - 16'd1) : (R[n2] + 16'd1)};
                        sub <= 5'd5;
                    end
                    default: begin
                        tmp32[15:0] = R[o1n1] - 16'd1;
                        w_en = 1'b1; w_n = o1n1; w_lo = {16'b0, tmp32[15:0]};
                        fl_en = 1'b1; fl_v[F_V] = (tmp32[15:0] == 16'h0);
                        if (tmp32[15:0] != 16'h0 && rep && (!tst || tb[7:0] == 8'h0)) pc <= pc - 16'd4;
                        done = 1'b1;
                    end
                    endcase
                end

                // ---- LDM ----------------------------------------------------------------
                C_LDM: begin
                    case (sub)
                    5'd0: begin
                        ea   <= (c_mode == M_IR) ? R[n2] : (c_mode == M_DA) ? op2 : (op2 + R[n2]);
                        lreg <= o1n1;
                        lcnt <= 4'd0;
                        sub  <= 5'd1;
                    end
                    default: begin
                        rq = 1'b1; rq_a = ea;
                        if (c_var == 4'd0) begin rq_we = 1'b1; rq_d = R[lreg]; end
                        if (bdone) begin
                            if (c_var != 4'd0) begin w_en = 1'b1; w_n = lreg; w_lo = {16'b0, bus_rdata}; end
                            ea   <= ea + 16'd2;
                            lreg <= lreg + 4'd1;
                            lcnt <= lcnt + 4'd1;
                            if (lcnt == o1n3) done = 1'b1;
                        end
                    end
                    endcase
                end

                // ---- I/O ------------------------------------------------------------------
                C_IO: begin : io
                    logic swap_rd, swap_wr, in, sp, incd, incs;
                    in = !n3[1];
                    sp = n3[0];
                    k  = (c_sz == 2'd0) ? 16'd1 : 16'd2;
                    incd = (c_sz != 2'd0) || n3[3] || in || sp;
                    incs = (c_sz != 2'd0) || n3[3] || !in || sp;
                    case (c_var)
                    4'd0, 4'd2: begin       // IN from port op1 / port R(NIB2)
                        rq = 1'b1; rq_io = 1'b1; rq_byte = (c_sz == 2'd0);
                        rq_a = (c_var == 4'd0) ? op1 : R[n2];
                        if (bdone) begin
                            w_en = 1'b1; w_sz = c_sz;
                            w_n  = (c_var == 4'd0) ? n2 : n3;
                            w_lo = (c_sz == 2'd0) ? {24'b0, (rq_a[0] ? bus_rdata[7:0] : bus_rdata[15:8])}
                                                  : {16'b0, (rq_a[0] ? {bus_rdata[7:0], bus_rdata[15:8]} : bus_rdata)};
                            done = 1'b1;
                        end
                    end
                    4'd1, 4'd3: begin       // OUT to port op1 / port R(NIB2)
                        tmp32 = rv32(c_sz, (c_var == 4'd1) ? n2 : n3);
                        rq = 1'b1; rq_io = 1'b1; rq_we = 1'b1; rq_byte = (c_sz == 2'd0);
                        rq_a = (c_var == 4'd1) ? op1 : R[n2];
                        rq_d = (c_sz == 2'd0) ? {tmp32[7:0], tmp32[7:0]}
                                              : (rq_a[0] ? {tmp32[7:0], tmp32[15:8]} : tmp32[15:0]);
                        if (bdone) done = 1'b1;
                    end
                    default: begin          // block forms: src NIB2, cnt OP1 NIB1, dst OP1 NIB2
                        case (sub)
                        5'd0: begin
                            rq = 1'b1; rq_io = in; rq_a = R[n2];
                            // SOUTIB reads a word and sends its low byte
                            rq_byte = (c_sz == 2'd0) && !(!in && sp && !n3[3]);
                            if (bdone) begin
                                if (c_sz == 2'd0)
                                    ta <= {24'b0, (rq_byte ? (rq_a[0] ? bus_rdata[7:0] : bus_rdata[15:8]) : bus_rdata[7:0])};
                                else
                                    ta <= {16'b0, (in && rq_a[0]) ? {bus_rdata[7:0], bus_rdata[15:8]} : bus_rdata};
                                sub <= 5'd1;
                            end
                        end
                        5'd1: begin
                            rq = 1'b1; rq_io = !in; rq_we = 1'b1; rq_byte = (c_sz == 2'd0); rq_a = R[o1n2];
                            rq_d = (c_sz == 2'd0) ? {ta[7:0], ta[7:0]}
                                                  : ((!in && rq_a[0]) ? {ta[7:0], ta[15:8]} : ta[15:0]);
                            if (bdone) sub <= 5'd2;
                        end
                        5'd2: begin
                            if (incd) begin w_en = 1'b1; w_n = o1n2; w_lo = {16'b0, n3[3] ? (R[o1n2] - k) : (R[o1n2] + k)}; end
                            sub <= 5'd3;
                        end
                        5'd3: begin
                            if (incs) begin w_en = 1'b1; w_n = n2; w_lo = {16'b0, n3[3] ? (R[n2] - k) : (R[n2] + k)}; end
                            sub <= 5'd4;
                        end
                        default: begin
                            tmp32[15:0] = R[o1n1] - 16'd1;
                            w_en = 1'b1; w_n = o1n1; w_lo = {16'b0, tmp32[15:0]};
                            fl_en = 1'b1; fl_v[F_V] = (tmp32[15:0] == 16'h0);
                            if (tmp32[15:0] != 16'h0 && o1n3 == 4'h0) pc <= pc - 16'd4;
                            done = 1'b1;
                        end
                        endcase
                    end
                    endcase
                end

                default: done = 1'b1;   // NOP, EPU (checked at decode)
                endcase
            end

            // ---- MULTW / MULTL -----------------------------------------------------------
            S_MUL: begin
                case (iter)
                7'd0: begin
                    m_p <= m_a * m_b;
                    iter <= 7'd1;
                end
                default: begin
                    fl_en = 1'b1;
                    fl_v[F_V] = 1'b0;
                    if (c_sz == 2'd1) begin
                        tmp32 = m_p[31:0];
                        fl_v[F_Z] = (tmp32 == 32'h0);
                        fl_v[F_S] = tmp32[31];
                        fl_v[F_C] = ($signed(tmp32) < -32'sh7fff) || ($signed(tmp32) >= 32'sh7fff);
                        w_en = 1'b1; w_sz = 2'd2; w_n = n3; w_lo = tmp32;
                    end else begin
                        tmp64 = m_p[63:0];
                        fl_v[F_Z] = (tmp64 == 64'h0);
                        fl_v[F_S] = tmp64[63];
                        fl_v[F_C] = ($signed(tmp64) < -64'sh7fffffff) || ($signed(tmp64) >= 64'sh7fffffff);
                        w_en = 1'b1; w_sz = 2'd3; w_n = n3; w_hi = tmp64[63:32]; w_lo = tmp64[31:0];
                    end
                    fin = 1'b1;
                    st <= S_BOUND;
                end
                endcase
            end

            // ---- DIVW / DIVL: restoring division on magnitudes ---------------------------------
            S_DIV: begin : div
                logic [32:0] trial;
                trial = {drem[31:0], dq[63]};
                if (trial >= {1'b0, dvs}) begin
                    drem <= trial - {1'b0, dvs};
                    dq <= {dq[62:0], 1'b1};
                end else begin
                    drem <= trial;
                    dq <= {dq[62:0], 1'b0};
                end
                iter <= iter - 7'd1;
                if (iter == 7'd1) st <= S_DIVFIN;
            end

            S_DIVFIN: begin : divfin
                logic [63:0] q, s, t;
                logic [31:0] rem;
                logic        inr, inr2;
                fl_en = 1'b1;
                fl_v[F_C] = 1'b0; fl_v[F_Z] = 1'b0; fl_v[F_S] = 1'b0; fl_v[F_V] = 1'b0;
                if (dzero) begin
                    fl_v[F_Z] = 1'b1; fl_v[F_V] = 1'b1;
                    w_en = 1'b1; w_sz = (c_sz == 2'd1) ? 2'd2 : 2'd3; w_n = n3; w_hi = ddest[63:32]; w_lo = ddest[31:0];
                end else if (c_sz == 2'd1) begin
                    q   = {32'b0, dq[31:0]};
                    s   = {32'b0, dneg_q ? (32'd0 - q[31:0]) : q[31:0]};
                    rem = dneg_r ? (32'd0 - drem[31:0]) : drem[31:0];
                    inr = ($signed(s[31:0]) >= -32'sh8000) && ($signed(s[31:0]) <= 32'sh7fff);
                    t   = {32'b0, 32'($signed(s[31:0]) >>> 1)};
                    inr2 = ($signed(t[31:0]) >= -32'sh8000) && ($signed(t[31:0]) <= 32'sh7fff);
                    if (inr) begin
                        fl_v[F_Z] = (s[31:0] == 32'h0); fl_v[F_S] = s[15] & (s[31:0] != 32'h0);
                    end else begin
                        fl_v[F_V] = 1'b1;
                        if (inr2) begin
                            s[31:0] = t[31] ? 32'hffff_ffff : 32'h0;
                            fl_v[F_Z] = (s[31:0] == 32'h0); fl_v[F_S] = s[15];
                            fl_v[F_C] = 1'b1;
                        end
                    end
                    w_en = 1'b1; w_sz = 2'd2; w_n = n3; w_lo = {rem[15:0], s[15:0]};
                end else begin
                    q   = dq;
                    s   = dneg_q ? (64'd0 - q) : q;
                    rem = dneg_r ? (32'd0 - drem[31:0]) : drem[31:0];
                    inr = ($signed(s) >= -64'sh8000_0000) && ($signed(s) <= 64'sh7fff_ffff);
                    t   = $signed(s) >>> 1;
                    inr2 = ($signed(t) >= -64'sh8000_0000) && ($signed(t) <= 64'sh7fff_ffff);
                    if (inr) begin
                        fl_v[F_Z] = (s == 64'h0); fl_v[F_S] = s[31] & (s != 64'h0);
                    end else begin
                        fl_v[F_V] = 1'b1;
                        if (inr2) begin
                            s = t[63] ? 64'hffff_ffff_ffff_ffff : 64'h0;
                            fl_v[F_Z] = (s == 64'h0); fl_v[F_S] = s[31];
                            fl_v[F_C] = 1'b1;
                        end
                    end
                    w_en = 1'b1; w_sz = 2'd3; w_n = n3; w_hi = rem; w_lo = s[31:0];
                end
                fin = 1'b1;
                st <= S_BOUND;
            end

            default: st <= S_BOUND;
            endcase

            if (done) begin
                st  <= S_BOUND;
                sub <= 5'd0;
            end
            step_done <= done | fin;
        end

        // ---- one ALU for every instruction that needs one ---------------------------------
        if (au_go) begin
            au = alu(au_op, c_sz, au_d, au_v, fcw[7:0]);
            if (au_wreg) begin w_en = 1'b1; w_sz = c_sz; w_n = au_n; w_lo = au[39:8]; end
            if (au_rqd)  rq_d = (c_sz == 2'd0) ? {au[15:8], au[15:8]} : au[23:8];
            if (au_fl) begin
                fl_en = 1'b1;
                fl_v = au[7:0];
                if (au_zcc) fl_v[F_Z] = ccv(au_cc, au[7:0]);
            end
        end

        // ---- apply: register write port -------------------------------------------------
        w_v = {w_hi, w_lo};
        if (w_en) begin
            case (w_sz)
                2'd0: if (w_n[3]) R[{1'b0, w_n[2:0]}][7:0] <= w_v[7:0];
                      else        R[{1'b0, w_n[2:0]}][15:8] <= w_v[7:0];
                2'd1: R[w_n] <= w_v[15:0];
                2'd2: begin R[{w_n[3:1], 1'b0}] <= w_v[31:16]; R[{w_n[3:1], 1'b1}] <= w_v[15:0]; end
                default: begin
                    R[{w_n[3:2], 2'b00}] <= w_v[63:48]; R[{w_n[3:2], 2'b01}] <= w_v[47:32];
                    R[{w_n[3:2], 2'b10}] <= w_v[31:16]; R[{w_n[3:2], 2'b11}] <= w_v[15:0];
                end
            endcase
        end

        // ---- flags / CHANGE_FCW ----------------------------------------------------------
        if (chg) begin
            if (chg_v[F_SN] != fcw[F_SN]) begin
                R[15] <= nsp;
                nsp <= R[15];
            end
            if (!fcw[F_NVIE] && chg_v[F_NVIE] && nvi_q) i_set[Q_NVI] = 1'b1;
            if (!fcw[F_VIE] && chg_v[F_VIE] && vi_q)   i_set[Q_VI] = 1'b1;
            fcw <= chg_v & 16'h7fff;
        end else if (fl_en) begin
            fcw[7:0] <= fl_v;
        end

        // ---- interrupt request latch -------------------------------------------------------
        irq_req <= (irq_live & ~i_clr) | i_set;

        // ---- cycle credit -------------------------------------------------------------------
        if (!reset) begin : cred
            logic signed [16:0] c;
            c = {credit[15], credit} + {cdelta[15], cdelta};
            if (czero && c > 17'sd0) c = 17'sd0;
            if (cen && c < 17'sd32767) c = c + 17'sd1;
            credit <= c[15:0];
        end

        // ---- bus handshake ----------------------------------------------------------------------
        if (reset) begin
            bus_req <= 1'b0;
        end else if (rq) begin
            if (!bus_req) begin
                bus_req   <= 1'b1;
                bus_we    <= rq_we;
                bus_io    <= rq_io;
                bus_byte  <= rq_byte;
                bus_addr  <= rq_a;
                bus_wdata <= rq_d;
            end else if (bus_ack) begin
                bus_req <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
