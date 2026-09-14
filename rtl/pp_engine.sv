//------------------------------------------------------------------------------
// Pole Position engine sound, from MAME 0.288 polepos_a.cpp.
//
// A 16 KB ROM of engine waveforms is played back at a rate the Z80 sets with
// two registers (0xA200 lsb, 0xA300 msb); the msb also picks one of eight
// 2 KB banks and a volume from the 4066 shunt ladder. Three filter sections
// (two op-amp band-passes and a 950 Hz high-pass) run on the result, each
// clipped to the op-amp rails, and their outputs are summed through
// 4.7k/7.5k/10k into the mixer.
//
// MAME steps this stream at 24 kHz, so the section coefficients (and this
// module) run at 24 kHz too; pp_sound interpolates to 48 kHz.
//
// The phase step is MAME's integer arithmetic, recomputed whenever the
// registers change:
//     clock = 192000 * ((msb+1)*64 + lsb+1) / 4096       (integer)
//     step  = (clock << 12) / 24000                       (integer)
//------------------------------------------------------------------------------
`default_nettype none

module pp_engine (
    input  wire        clk,
    input  wire        reset,
    input  wire        cen_24k,

    input  wire        lsb_we,
    input  wire        msb_we,
    input  wire  [7:0] wdata,
    input  wire        clson,          //! LS259 Q2: low clears both registers

    // ROM download: 16 KB of engine samples
    input  wire [13:0] rom_wa,
    input  wire  [7:0] rom_d,
    input  wire        rom_we,

    output logic signed [31:0] out,    //! Q22 volts, valid with out_valid
    output logic       out_valid,
    output wire [31:0] dbg_step,       //! phase step, for the bench
    output wire [31:0] dbg_pos,
    output wire signed [31:0] dbg_x,
    output wire [95:0] dbg_y
);
    `include "pp_snd_coeffs.svh"

    // ------------------------------------------------------------ registers
    logic [5:0] msb;
    logic [5:0] lsb;        // MAME keeps data & 62, so bit 0 is always 0
    logic       enable;
    logic       recalc;
    logic       clson_d;

    always_ff @(posedge clk) clson_d <= clson;

    always_ff @(posedge clk) begin
        recalc <= 1'b0;
        if (reset) begin
            msb <= 6'd0; lsb <= 6'd0; enable <= 1'b0;
        end else if (clson_d && !clson) begin
            // clson_w(0) writes 0 to both registers, on the transition only:
            // the Z80 can still load them while the latch bit is low
            recalc <= 1'b1;
            msb <= 6'd0; lsb <= 6'd0; enable <= 1'b0;
        end else begin
            if (lsb_we) begin
                lsb    <= {wdata[5:1], 1'b0};
                enable <= wdata[0];
                recalc <= 1'b1;
            end
            if (msb_we) begin
                msb    <= wdata[5:0];
                recalc <= 1'b1;
            end
        end
    end

    // --------------------------------------------------------- phase step
    // clock = (M * 375) / 8 with M = (msb+1)*64 + lsb + 1, then
    // step = (clock * 4096) / 24000 = (clock * 128) / 750, both truncating.
    logic [31:0] step_val;
    logic [31:0] div_num;
    logic [5:0]  div_cnt;
    logic        div_run;
    logic [31:0] div_rem, div_quo;

    wire [12:0] m_calc = ({7'd0, msb} + 13'd1) * 13'd64 + {7'd0, lsb} + 13'd1;
    wire [31:0] clock_calc = ({19'd0, m_calc} * 32'd375) >> 3;

    always_ff @(posedge clk) begin
        if (reset) begin
            step_val <= 32'd0; div_run <= 1'b0; div_cnt <= 6'd0;
            div_num <= 32'd0; div_rem <= 32'd0; div_quo <= 32'd0;
        end else if (recalc) begin
            div_num <= clock_calc << 7;     // clock * 128
            div_rem <= 32'd0;
            div_quo <= 32'd0;
            div_cnt <= 6'd0;
            div_run <= 1'b1;
        end else if (div_run) begin
            // restoring division by 750, one bit per clock
            automatic logic [31:0] rem_next = {div_rem[30:0], div_num[31]};
            div_num <= div_num << 1;
            if (rem_next >= 32'd750) begin
                div_rem <= rem_next - 32'd750;
                div_quo <= {div_quo[30:0], 1'b1};
            end else begin
                div_rem <= rem_next;
                div_quo <= {div_quo[30:0], 1'b0};
            end
            div_cnt <= div_cnt + 6'd1;
            if (div_cnt == 6'd31) begin
                div_run <= 1'b0;
                step_val <= {div_quo[30:0], (rem_next >= 32'd750) ? 1'b1 : 1'b0};
            end
        end
    end

    assign dbg_step = step_val;

    // ------------------------------------------------------------- playback
    logic [31:0] position;
    wire  [2:0]  slot = msb[5:3];
    logic [13:0] rom_ra;
    wire  [7:0]  rom_q;
    pp_sdpram #(.AW(14)) u_rom (
        .clk(clk), .wa(rom_wa), .we(rom_we), .d(rom_d), .ra(rom_ra), .q(rom_q));

    assign rom_ra = {slot, position[22:12]};
    assign dbg_pos = position;
    assign dbg_x = x_val;
    assign dbg_y = bank_y;

    // x = (3.4/255*data - 2) * volume, folded into ka (Q30 per data step) and
    // kb (Q26) per volume slot. Registered in two stages; the operands are
    // stable for hundreds of clocks before a sample starts.
    logic signed [63:0] ka_prod;
    logic signed [31:0] x_val;
    always_ff @(posedge clk) begin
        ka_prod <= ENG_KA[slot] * $signed({1'b0, rom_q});
        x_val   <= 32'((ka_prod >>> 4) + 64'(ENG_KB[slot]));
    end

    // three sections in the shared bank
    logic        bank_start;
    logic [95:0] bank_x;
    wire  [95:0] bank_y;
    wire         bank_busy;
    pp_biquad #(.FIRST(0), .NSEC(3)) u_filt (
        .clk(clk), .reset(reset), .start(bank_start),
        .x_flat(bank_x), .y_flat(bank_y), .busy(bank_busy));

    logic sum_pending;
    logic sample_req;
    logic signed [31:0] y0, y1, y2;
    wire signed [31:0] yv0 = $signed(bank_y[31:0]);
    wire signed [31:0] yv1 = $signed(bank_y[63:32]);
    wire signed [31:0] yv2 = $signed(bank_y[95:64]);

    // i_total = sum(y_i * (R_FILT_TOTAL/2) / R_i), one product per clock
    logic [1:0] mix_step;
    logic       mix_run;
    logic signed [31:0] mix_in;
    logic signed [31:0] mix_w;
    logic signed [63:0] mix_prod;          // registered: multiply gets its own cycle
    logic               mix_v;
    logic signed [34:0] mix_acc;

    always_comb begin
        case (mix_step)
            2'd0: begin mix_in = y0; mix_w = ENG_W[0]; end
            2'd1: begin mix_in = y1; mix_w = ENG_W[1]; end
            default: begin mix_in = y2; mix_w = ENG_W[2]; end
        endcase
        bank_x = {x_val, x_val, x_val};   // all three sections see the same input
    end

    // A register write registered on the same edge as the tick must affect that
    // sample, as MAME's stream update does, so the sample starts one clock
    // after the tick -- still hundreds of clocks before the mixer reads it.
    logic cen_d;
    always_ff @(posedge clk) cen_d <= cen_24k;

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        bank_start <= 1'b0;
        if (reset) begin
            position <= 32'd0;
            sum_pending <= 1'b0;
            sample_req <= 1'b0;
            mix_run <= 1'b0;
            mix_step <= 2'd0;
            mix_acc <= '0;
            mix_v <= 1'b0;
            out <= 32'sd0;
            y0 <= '0; y1 <= '0; y2 <= '0;
        end else begin
            // A write on this edge restarts the step divider; the sample must
            // wait for it, or the phase advances by a half-finished quotient.
            if (cen_d) sample_req <= 1'b1;
            if (sample_req && !recalc && !div_run) begin
                sample_req <= 1'b0;
                if (enable) begin
                    bank_start <= 1'b1;
                    sum_pending <= 1'b1;
                end else begin
                    // MAME returns before stepping anything when disabled
                    out <= 32'sd0;
                    out_valid <= 1'b1;
                end
            end
            // product pipeline: mix_prod lags the operand select by one clock
            mix_prod <= mix_in * mix_w;
            mix_v    <= mix_run;
            if (mix_v) mix_acc <= mix_acc + 35'(mix_prod >>> 30);
            if (sum_pending && !bank_start && !bank_busy) begin
                sum_pending <= 1'b0;
                y0 <= yv0; y1 <= yv1; y2 <= yv2;
                mix_run <= 1'b1;
                mix_step <= 2'd0;
                mix_acc <= '0;
                position <= position + step_val;
            end else if (mix_run) begin
                if (mix_step == 2'd2) mix_run <= 1'b0;
                else mix_step <= mix_step + 2'd1;
            end else if (mix_v) begin
                // last product is being accumulated this clock
                out <= 32'(mix_acc + 35'(mix_prod >>> 30));
                out_valid <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
