//------------------------------------------------------------------------------
// Sequential biquad bank for the Pole Position sound board.
//
// One 27x27 multiplier walks the sections of a filter chain, five products per
// section, so a whole chain costs a handful of clocks out of the 1024 between
// 48 kHz samples.
//
// Two behaviours have to be distinguished, because MAME's two filter families
// differ exactly here:
//
//   * polepos_a.cpp's engine sections clip the value they contribute to the
//     mix but feed the UNCLIPPED result back into the filter state;
//   * the discrete DST_OP_AMP_FILT band-pass sections add vRef, clip to the
//     op-amp rails, and feed the CLIPPED result (minus vRef) back.
//
// CLIP_STATE / CLIP_OUT in pp_snd_coeffs.svh say which section is which.
//
// Fixed point: values Q22 volts, coefficients Q24, both signed 27-bit, so each
// product fits one Cyclone V DSP block.
//------------------------------------------------------------------------------
`default_nettype none

module pp_biquad #(
    parameter int FIRST = 0,        //! index of this chain's first section
    parameter int NSEC  = 3
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,                       //! pulse: run the chain once
    input  wire [NSEC*32-1:0] x_flat,               //! inputs, signed Q22, sampled at start
    output logic [NSEC*32-1:0] y_flat,              //! outputs, signed Q22
    output logic       busy
);
    `include "pp_snd_coeffs.svh"

    // per-section state
    logic signed [31:0] x1 [0:NSEC-1];
    logic signed [31:0] x2 [0:NSEC-1];
    logic signed [31:0] y1 [0:NSEC-1];
    logic signed [31:0] y2 [0:NSEC-1];
    logic signed [31:0] xin [0:NSEC-1];

    localparam int LAST = NSEC - 1;
    localparam int SECW = (NSEC <= 1) ? 1 : $clog2(NSEC);

    logic [SECW-1:0] sec;    // section being processed
    logic [2:0] step;        // 0..4 operand issue, 5..6 pipeline drain, 7 finish
    logic signed [66:0] acc;

    // Three-stage pipeline: operand select, multiply, accumulate. Each stage is
    // its own register so the 32x32 product never shares a cycle with the
    // 67-bit add, and the round/offset/clip of the finished sum gets a cycle
    // of its own.
    logic signed [31:0] op_a, op_b;
    logic               op_v;
    logic signed [63:0] prod_r;
    logic               prod_v;

    wire [2:0] gidx = 3'(FIRST) + 3'(sec);   // index into the generated tables

    // A chained section takes the previous section's fresh output as its input
    // (the 52xx low-pass follows the high-pass inside one 48 kHz step).
    logic signed [31:0] last_y;
    wire signed [31:0] sec_in = CHAIN_MASK[gidx] ? last_y : xin[sec];

    logic signed [31:0] sel_a, sel_b;
    always_comb begin
        case (step)
            3'd0: begin sel_a = sec_in;  sel_b = B0_Q[gidx]; end
            3'd1: begin sel_a = x1[sec]; sel_b = B1_Q[gidx]; end
            3'd2: begin sel_a = x2[sec]; sel_b = B2_Q[gidx]; end
            3'd3: begin sel_a = y1[sec]; sel_b = -A1_Q[gidx]; end
            default: begin sel_a = y2[sec]; sel_b = -A2_Q[gidx]; end
        endcase
    end

    // acc is Q56 (Q26 value x Q30 coefficient); round back to Q26
    wire signed [66:0] acc_rnd  = acc + 67'sd536870912;  // + 0.5 lsb
    wire signed [31:0] y_raw    = acc_rnd[61:30];
    wire signed [31:0] v_out    = y_raw + VREF_S[gidx];
    wire signed [31:0] v_clip   = (v_out > HI_S[gidx]) ? HI_S[gidx] :
                                  (v_out < LO_S[gidx]) ? LO_S[gidx] : v_out;
    wire               do_state = CLIP_STATE[gidx];
    wire               do_out   = CLIP_OUT[gidx];

    integer i;
    always_ff @(posedge clk) begin
        // the multiply and accumulate stages run every clock
        op_a   <= sel_a;
        op_b   <= sel_b;
        op_v   <= busy && (step <= 3'd4);
        prod_r <= op_a * op_b;
        prod_v <= op_v;
        if (prod_v) acc <= acc + {{3{prod_r[63]}}, prod_r};

        if (reset) begin
            busy <= 1'b0;
            sec  <= '0;
            step <= 3'd0;
            acc  <= 67'sd0;
            op_v <= 1'b0;
            prod_v <= 1'b0;
            last_y <= 32'sd0;
            for (i = 0; i < NSEC; i++) begin
                x1[i] <= 32'sd0; x2[i] <= 32'sd0;
                y1[i] <= 32'sd0; y2[i] <= 32'sd0;
                y_flat[i*32 +: 32] <= 32'sd0;
            end
        end else if (start) begin
            for (i = 0; i < NSEC; i++) xin[i] <= $signed(x_flat[i*32 +: 32]);
            busy <= 1'b1;
            sec  <= '0;
            step <= 3'd0;
            acc  <= 67'sd0;
        end else if (busy) begin
            if (step == 3'd7) begin
                // acc holds all five products: finish this section
                x2[sec] <= x1[sec];
                x1[sec] <= sec_in;
                y2[sec] <= y1[sec];
                y1[sec] <= do_state ? (v_clip - VREF_S[gidx]) : y_raw;
                y_flat[sec*32 +: 32] <= do_out ? v_clip : v_out;
                last_y <= do_out ? v_clip : v_out;
                acc  <= 67'sd0;
                step <= 3'd0;
                if (sec == SECW'(LAST)) begin
                    busy <= 1'b0;
                end else begin
                    sec <= sec + SECW'(1);
                end
            end else begin
                step <= step + 3'd1;
            end
        end
    end
endmodule

`default_nettype wire
