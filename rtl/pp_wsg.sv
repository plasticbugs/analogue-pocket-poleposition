//------------------------------------------------------------------------------
// Namco Pole Position WSG: 8 wavetable voices, four outputs (front L/R, rear
// L/R), semantics from MAME 0.288 namco.cpp polepos_wsg_device.
//
// The chip's stream runs at 4x its 48 kHz clock, i.e. 192 kHz internally, with
// 17 fractional bits of phase; one voice is summed per two clocks, so a whole
// 192 kHz tick costs 16 of the 256 clocks available.
//
// Two details from MAME that are easy to miss and audible if missed:
//   * a voice whose four volumes are all zero does not advance its phase,
//     because MAME only steps the counter inside namco_update_one;
//   * sound_enable (LS259 Q2) low freezes everything, output included.
//
// A voice with bit 3 of register ch*4+0x23 set plays no waveform: on the board
// a 4051 hands its four volume sections one of the analog channels instead
// (CHANL1..4 for bits 1:0 = 0..3, from the 54xx and 52xx). The analog side
// lives in pp_sound; this module reports, per speaker and per channel, the sum
// of the volume steps the selected voices give it (route_vol), refreshed every
// 192 kHz tick. MAME silences such a voice and mixes the discrete outputs
// straight to the speakers instead.
//
// The 192 kHz sum is decimated to 48 kHz with a 32-tap FIR rather than
// point-sampled, so nothing above 24 kHz folds back into the band. The four
// channels share one multiplier: 128 products out of the 1024 clocks in a
// 48 kHz sample.
//------------------------------------------------------------------------------
`default_nettype none

module pp_wsg (
    input  wire        clk,
    input  wire        reset,
    input  wire        cen_192k,        //! internal stream rate
    input  wire        cen_48k,         //! output rate, aligned with cen_192k

    // Z80 register window
    input  wire        we,
    input  wire  [5:0] addr,
    input  wire  [7:0] wdata,
    output wire  [7:0] rdata,           //! combinational read of the register file
    input  wire        enable,          //! sound_enable_w

    // waveform PROM download
    input  wire  [7:0] wave_wa,
    input  wire  [3:0] wave_d,
    input  wire        wave_we,

    output logic signed [31:0] out0,    //! Q22, front left, valid with out_valid
    output logic signed [31:0] out1,    //! front right
    output logic signed [31:0] out2,    //! rear left
    output logic signed [31:0] out3,    //! rear right
    output logic       out_valid,
    //! volume steps routed to each analog channel: {speaker, channel} at bit
    //! 7*(4*speaker + channel), speakers 0..3 = front L/R, rear L/R
    output logic [111:0] route_vol
);
    `include "pp_snd_coeffs.svh"

    // ------------------------------------------------------------- registers
    logic [7:0] regs [0:63] /* verilator public_flat_rw */;
    always_ff @(posedge clk) begin
        if (we) regs[addr] <= wdata;
    end
    assign rdata = regs[addr];

    // ------------------------------------------------------------ waveforms
    logic [7:0] wave_ra;
    wire  [3:0] wave_q;
    pp_sdpram #(.AW(8), .DW(4)) u_wave (
        .clk(clk), .wa(wave_wa), .we(wave_we), .d(wave_d), .ra(wave_ra), .q(wave_q));

    // -------------------------------------------------------- voice engine
    logic [21:0] counter [0:7];
    logic  [2:0] voice;
    logic        phase;      // 0 = address, 1 = accumulate
    logic        running;

    wire [7:0] r0  = regs[{1'b0, voice, 2'b00}];      // ch*4 + 0: frequency low
    wire [7:0] r1  = regs[{1'b0, voice, 2'b01}];      // frequency high
    wire [7:0] r2  = regs[{1'b0, voice, 2'b10}];      // rear right volume
    wire [7:0] r3  = regs[{1'b0, voice, 2'b11}];      // front volumes
    wire [7:0] r23 = regs[{1'b1, voice, 2'b11}];      // ch*4 + 0x23

    wire        selected = r23[3];                    // 54xx/52xx on this voice
    wire  [3:0] v0 = selected ? 4'd0 : r3[7:4];
    wire  [3:0] v1 = selected ? 4'd0 : r3[3:0];
    wire  [3:0] v2 = selected ? 4'd0 : r23[7:4];
    wire  [3:0] v3 = selected ? 4'd0 : r2[7:4];
    wire        any_vol = (v0 | v1 | v2 | v3) != 4'd0;
    wire [15:0] freq = {r1, r0};

    assign wave_ra = {r23[2:0], counter[voice][21:17]};

    wire signed [4:0] wsample = $signed({1'b0, wave_q}) - 5'sd8;
    logic signed [13:0] acc0, acc1, acc2, acc3;
    logic signed [13:0] sum0, sum1, sum2, sum3;   // this tick's 192 kHz sums

    function automatic signed [13:0] vmul(input signed [4:0] w, input [3:0] v);
        vmul = 14'($signed(w) * $signed({1'b0, v}));
    endfunction

    logic tick_done;

    // per {speaker, channel}: up to 8 voices x 15 steps
    logic [6:0] racc [0:15];
    wire  [1:0] rch = r23[1:0];

    always_ff @(posedge clk) begin
        tick_done <= 1'b0;
        if (reset) begin
            voice <= 3'd0; phase <= 1'b0; running <= 1'b0;
            acc0 <= '0; acc1 <= '0; acc2 <= '0; acc3 <= '0;
            sum0 <= '0; sum1 <= '0; sum2 <= '0; sum3 <= '0;
            for (int i = 0; i < 8; i++) counter[i] <= 22'd0;
            for (int i = 0; i < 16; i++) racc[i] <= 7'd0;
            route_vol <= '0;
        end else begin
            if (cen_192k) begin
                running <= 1'b1;
                voice <= 3'd0;
                phase <= 1'b0;
                acc0 <= '0; acc1 <= '0; acc2 <= '0; acc3 <= '0;
                // the last tick's walk is complete
                for (int i = 0; i < 16; i++) begin
                    route_vol[7*i +: 7] <= racc[i];
                    racc[i] <= 7'd0;
                end
            end else if (running) begin
                if (!phase) begin
                    phase <= 1'b1;
                end else begin
                    phase <= 1'b0;
                    if (enable) begin
                        acc0 <= acc0 + vmul(wsample, v0);
                        acc1 <= acc1 + vmul(wsample, v1);
                        acc2 <= acc2 + vmul(wsample, v2);
                        acc3 <= acc3 + vmul(wsample, v3);
                        if (any_vol) counter[voice] <= counter[voice] + {6'd0, freq};
                        if (selected) begin
                            racc[{2'd0, rch}] <= racc[{2'd0, rch}] + {3'd0, r3[7:4]};
                            racc[{2'd1, rch}] <= racc[{2'd1, rch}] + {3'd0, r3[3:0]};
                            racc[{2'd2, rch}] <= racc[{2'd2, rch}] + {3'd0, r23[7:4]};
                            racc[{2'd3, rch}] <= racc[{2'd3, rch}] + {3'd0, r2[7:4]};
                        end
                    end
                    if (voice == 3'd7) begin
                        running <= 1'b0;
                        tick_done <= 1'b1;
                        sum0 <= enable ? (acc0 + vmul(wsample, v0)) : 14'sd0;
                        sum1 <= enable ? (acc1 + vmul(wsample, v1)) : 14'sd0;
                        sum2 <= enable ? (acc2 + vmul(wsample, v2)) : 14'sd0;
                        sum3 <= enable ? (acc3 + vmul(wsample, v3)) : 14'sd0;
                    end else begin
                        voice <= voice + 3'd1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------- decimation 192 -> 48
    // History of the raw 192 kHz sums: 4 channels x 32 samples. The FIR walks
    // them two clocks per tap (address, accumulate) -- 256 clocks of the 1024
    // in a 48 kHz sample, so there is no need to pipeline it.
    logic [6:0] hist_wa, hist_ra;
    logic       hist_we;
    logic signed [13:0] hist_d;
    wire  [13:0] hist_q;
    pp_sdpram #(.AW(7), .DW(14)) u_hist (
        .clk(clk), .wa(hist_wa), .we(hist_we), .d(hist_d), .ra(hist_ra), .q(hist_q));

    logic [4:0] wp;                 // slot written next = oldest sample
    logic [1:0] wr_ch;
    logic       wr_run;
    logic       fir_pending, fir_run, fir_phase;
    logic [1:0] fir_ch;
    logic [4:0] fir_tap;
    logic signed [40:0] fir_acc;
    logic signed [31:0] fir_out [0:3];

    wire signed [17:0] tap_coef = FIR_Q[fir_tap];
    wire signed [31:0] fir_prod = $signed(hist_q) * tap_coef;

    always_comb begin
        hist_we = wr_run;
        hist_wa = {wr_ch, wp};
        case (wr_ch)
            2'd0: hist_d = sum0;
            2'd1: hist_d = sum1;
            2'd2: hist_d = sum2;
            default: hist_d = sum3;
        endcase
        hist_ra = {fir_ch, wp + fir_tap};
    end

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        if (reset) begin
            wp <= 5'd0; wr_ch <= 2'd0; wr_run <= 1'b0;
            fir_pending <= 1'b0; fir_run <= 1'b0; fir_phase <= 1'b0;
            fir_ch <= 2'd0; fir_tap <= 5'd0; fir_acc <= '0;
            out0 <= '0; out1 <= '0; out2 <= '0; out3 <= '0;
            for (int i = 0; i < 4; i++) fir_out[i] <= 32'sd0;
        end else begin
            if (cen_48k) fir_pending <= 1'b1;

            // store this tick's four sums, one per clock
            if (tick_done) begin
                wr_run <= 1'b1;
                wr_ch  <= 2'd0;
            end else if (wr_run) begin
                if (wr_ch == 2'd3) begin
                    wr_run <= 1'b0;
                    wp <= wp + 5'd1;
                    if (fir_pending) begin
                        fir_pending <= 1'b0;
                        fir_run   <= 1'b1;
                        fir_phase <= 1'b0;
                        fir_ch    <= 2'd0;
                        fir_tap   <= 5'd0;
                        fir_acc   <= '0;
                    end
                end else begin
                    wr_ch <= wr_ch + 2'd1;
                end
            end

            if (fir_run) begin
                fir_phase <= ~fir_phase;
                if (fir_phase) begin        // hist_q holds hist[fir_ch][wp+fir_tap]
                    if (fir_tap == 5'd31) begin
                        automatic logic signed [40:0] total = fir_acc + 41'(fir_prod);
                        // Q16 in MIX_RES units is exactly Q26 volts-equivalent
                        fir_out[fir_ch] <= 32'(total);
                        fir_acc <= '0;
                        fir_tap <= 5'd0;
                        if (fir_ch == 2'd3) begin
                            fir_run <= 1'b0;
                            out0 <= fir_out[0];
                            out1 <= fir_out[1];
                            out2 <= fir_out[2];
                            out3 <= 32'(total);
                            out_valid <= 1'b1;
                        end else begin
                            fir_ch <= fir_ch + 2'd1;
                        end
                    end else begin
                        fir_acc <= fir_acc + 41'(fir_prod);
                        fir_tap <= fir_tap + 5'd1;
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
