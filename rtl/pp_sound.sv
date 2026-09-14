//------------------------------------------------------------------------------
// Pole Position sound board: WSG + engine + the discrete 54xx/52xx circuits.
//
//   speaker  (front) ch0 <- WSG out 0 x 0.80 + routed CHANLs + engine x 0.693
//   speaker  (front) ch1 <- WSG out 1 ...
//   rspeaker (rear)  ch2 <- WSG out 2 ...
//   rspeaker (rear)  ch3 <- WSG out 3 ...
//
// The analog channels (CHANL1..3 from the 54xx, CHANL4 from the 52xx) reach
// the speakers the way the board sends them: a 4051 puts one of them into a
// WSG voice in place of its waveform, and that voice's four volume sections
// scale it (namco.cpp's own header describes this). The game keeps two voices
// on CHANL1 and CHANL2 at full volume, switches both to CHANL4 for speech, and
// never selects CHANL3. The level of a volt of CHANL against a WSG sample code
// is GAIN_ROUTE (tools/sound/gen_coeffs.py).
//
// MAME 0.288 does not model the 4051: it silences the voice and routes all
// four discrete outputs to every speaker at 0.90 regardless of volume, which
// puts the tyre squeal and crash about 20 dB above the rest of the board.
// mame_mix = 1 selects that routing instead, so the benches can still be held
// to MAME's recordings sample for sample.
//
// The cabinet has four speakers and the Pocket has two, so the stereo fold is
// the average of the front and rear of each side: L = (ch0 + ch2)/2,
// R = (ch1 + ch3)/2. That keeps the level of the (identical) engine
// contribution and averages the pans.
//
// Rates: WSG internally 192 kHz decimated to 48 kHz, engine 24 kHz linearly
// interpolated to 48 kHz (MAME runs its stream at 24 kHz), discrete 48 kHz.
// audio_ce pulses once per 48 kHz output sample.
//
// A one-pole DC blocker at ~5 Hz sits on each output: the discrete and engine
// paths carry a standing offset that would otherwise eat headroom and thump on
// mute. MAME's own -wavwrite is taken before its speaker effects, so its
// recordings keep that offset -- comparisons are made DC-removed.
//------------------------------------------------------------------------------
`default_nettype none

module pp_sound (
    input  wire        clk,
    input  wire        reset,

    // Z80 WSG register window (0x83c0-0x83ff)
    input  wire        wsg_we,
    input  wire  [5:0] wsg_addr,
    input  wire  [7:0] wsg_wdata,
    output wire  [7:0] wsg_rdata,      //! combinational
    input  wire        clson,          //! LS259 Q2
    input  wire        mame_mix,       //! 1: discrete straight to every speaker, as MAME

    // engine registers (0xa200 / 0xa300)
    input  wire        engine_lsb_we,
    input  wire        engine_msb_we,
    input  wire  [7:0] engine_data,

    // custom chip outputs
    input  wire  [3:0] n54_o_lo,
    input  wire  [3:0] n54_o_hi,
    input  wire  [3:0] n54_r1,
    input  wire  [3:0] n52_p,

    // ROM image download
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic       audio_ce,       //! 48 kHz

    // the four cabinet speaker channels, for the benches
    output wire signed [15:0] dbg_spk0,
    output wire signed [15:0] dbg_spk1,
    output wire signed [15:0] dbg_spk2,
    output wire signed [15:0] dbg_spk3,
    // raw Q22 block outputs as the mixer sees them, for the benches
    output wire        dbg_sync,       //! the 24 kHz tick: sample boundary
    output wire signed [31:0] dbg_wsg0,
    output wire signed [31:0] dbg_disc,
    output wire signed [31:0] dbg_eng,
    output wire [31:0] dbg_eng_pos,
    output wire [31:0] dbg_eng_step
);
    `include "pp_snd_coeffs.svh"

    localparam logic [17:0] OFS_ENGINE = 18'h24000;   // 16384 bytes
    localparam logic [17:0] OFS_WAVE   = 18'h2F000;   // 256 bytes

    wire dl_engine = dl_we && (dl_addr >= OFS_ENGINE) && (dl_addr < OFS_ENGINE + 18'd16384);
    wire dl_wave   = dl_we && (dl_addr >= OFS_WAVE)   && (dl_addr < OFS_WAVE   + 18'd256);
    wire [17:0] dl_eoff = dl_addr - OFS_ENGINE;

    // ------------------------------------------------------------ rates
    // 49.152 MHz: 48 kHz every 1024 clocks, 192 kHz every 256, 24 kHz every 2048
    logic [10:0] div;
    wire cen_192k = (div[7:0] == 8'd0);
    wire cen_48k  = (div[9:0] == 10'd0);
    wire cen_24k  = (div == 11'd0);
    always_ff @(posedge clk) begin
        if (reset) div <= 11'd0;
        else       div <= div + 11'd1;
    end

    // ------------------------------------------------------------- blocks
    wire signed [31:0] w0, w1, w2, w3;
    wire wsg_valid;
    wire [111:0] route_vol;
    pp_wsg u_wsg (
        .clk(clk), .reset(reset), .cen_192k(cen_192k), .cen_48k(cen_48k),
        .we(wsg_we), .addr(wsg_addr), .wdata(wsg_wdata), .rdata(wsg_rdata),
        .enable(clson),
        .wave_wa(dl_addr[7:0]), .wave_d(dl_data[3:0]), .wave_we(dl_wave),
        .out0(w0), .out1(w1), .out2(w2), .out3(w3), .out_valid(wsg_valid),
        .route_vol(route_vol));

    wire signed [31:0] eng_s;
    wire eng_valid;
    pp_engine u_engine (
        .clk(clk), .reset(reset), .cen_24k(cen_24k),
        .lsb_we(engine_lsb_we), .msb_we(engine_msb_we), .wdata(engine_data),
        .clson(clson),
        .rom_wa(dl_eoff[13:0]), .rom_d(dl_data), .rom_we(dl_engine),
        .out(eng_s), .out_valid(eng_valid),
        .dbg_step(dbg_eng_step), .dbg_pos(dbg_eng_pos), .dbg_x(), .dbg_y());

    wire signed [31:0] disc_s;
    wire signed [31:0] chanl [0:3];
    wire disc_valid;
    pp_discrete u_discrete (
        .clk(clk), .reset(reset), .cen_48k(cen_48k),
        .n54_0(n54_o_lo), .n54_1(n54_o_hi), .n54_2(n54_r1), .n52(n52_p),
        .out(disc_s), .chanl1(chanl[0]), .chanl2(chanl[1]), .chanl3(chanl[2]), .chanl4(chanl[3]),
        .out_valid(disc_valid), .dbg_y());

    // engine 24 kHz -> 48 kHz: linear interpolation between the last two
    logic signed [31:0] eng_prev, eng_cur;
    logic               eng_phase;
    always_ff @(posedge clk) begin
        if (reset) begin
            eng_prev <= 32'sd0; eng_cur <= 32'sd0; eng_phase <= 1'b0;
        end else begin
            if (eng_valid) begin
                eng_prev <= eng_cur;
                eng_cur  <= eng_s;
            end
            // a sample that carries a fresh 24 kHz value uses it directly; the
            // one in between is the midpoint
            if (cen_48k) eng_phase <= cen_24k;
        end
    end
    wire signed [32:0] eng_mid = {eng_prev[31], eng_prev} + {eng_cur[31], eng_cur};
    wire signed [31:0] eng_i   = eng_phase ? eng_cur : 32'(eng_mid >>> 1);

    // --------------------------------------------------------------- mix
    // One multiplier walks every term of an output sample, one step a clock;
    // the product is registered and lands the clock after its step:
    //   0..3    WSG pan k x GAIN_WSG                       -> spk[k]
    //   4       engine x GAIN_ENG                          -> common
    //   5       discrete sum x GAIN_DISC   (MAME mix only) -> common
    //   6..21   CHANL c x volume steps to speaker k        -> rsum[k]
    //   22..25  rsum[k] >>> 8 x GAIN_ROUTE8                -> spk[k]
    localparam logic [4:0] ST_LAST = 5'd25;
    logic [4:0] mix_step, mix_step_d;
    logic       mix_run, mix_v;
    logic [1:0] post;                      // 1: fold, 2: output
    logic signed [31:0] mix_a, mix_b;
    logic signed [63:0] mix_prod;          // registered: multiply gets its own cycle
    wire signed [34:0] mix_term = 35'(mix_prod >>> 30);
    wire signed [39:0] mix_raw  = mix_prod[39:0];   // CHANL (Q26) x at most 120 steps
    logic signed [34:0] spk [0:3];
    logic signed [34:0] common;
    logic signed [39:0] rsum [0:3];

    wire [3:0] ridx   = 4'(mix_step - 5'd6);        // {speaker, channel}
    wire [1:0] rk     = 2'(mix_step - 5'd22);
    wire [3:0] ridx_d = 4'(mix_step_d - 5'd6);
    wire [1:0] rk_d   = 2'(mix_step_d - 5'd22);
    wire [6:0] rvol   = route_vol[7 * ridx +: 7];

    always_comb begin
        if (mix_step <= 5'd3) begin
            case (mix_step[1:0])
                2'd0: mix_a = w0;
                2'd1: mix_a = w1;
                2'd2: mix_a = w2;
                default: mix_a = w3;
            endcase
            mix_b = GAIN_WSG;
        end else if (mix_step == 5'd4) begin
            mix_a = eng_i;
            mix_b = GAIN_ENG;
        end else if (mix_step == 5'd5) begin
            mix_a = disc_s;
            mix_b = mame_mix ? GAIN_DISC : 32'sd0;
        end else if (mix_step <= 5'd21) begin
            mix_a = chanl[ridx[1:0]];
            mix_b = mame_mix ? 32'sd0 : $signed({25'd0, rvol});
        end else begin
            mix_a = 32'(rsum[rk] >>> 8);
            mix_b = GAIN_ROUTE8;
        end
    end

    // DC blocker: y = x - x1 + (1 - 2^-11) * y1, about 3.7 Hz at 48 kHz
    logic signed [34:0] dc_x1_l, dc_x1_r;
    logic signed [38:0] dc_y_l, dc_y_r;

    function automatic signed [15:0] clip16(input signed [38:0] v);
        // Q26 in MAME stream units (1.0 = 32768 in the wav) -> 16-bit
        clip16 = (v >  39'sd67106816) ? 16'sh7fff :
                 (v < -39'sd67108864) ? 16'sh8000 : 16'(v >>> 11);
    endfunction

    wire signed [34:0] sum_l = spk[0] + spk[2];
    wire signed [34:0] sum_r = spk[1] + spk[3];
    wire signed [34:0] fold_l = sum_l >>> 1;
    wire signed [34:0] fold_r = sum_r >>> 1;
    wire signed [38:0] dcy_l_next = 39'(fold_l) - 39'(dc_x1_l) + dc_y_l - (dc_y_l >>> 11);
    wire signed [38:0] dcy_r_next = 39'(fold_r) - 39'(dc_x1_r) + dc_y_r - (dc_y_r >>> 11);

    always_ff @(posedge clk) begin
        audio_ce <= 1'b0;
        if (reset) begin
            mix_run <= 1'b0; mix_step <= 5'd0; mix_step_d <= 5'd0; mix_v <= 1'b0; post <= 2'd0;
            dc_x1_l <= '0; dc_x1_r <= '0; dc_y_l <= '0; dc_y_r <= '0;
            audio_l <= 16'sd0; audio_r <= 16'sd0;
            common <= '0;
            for (int i = 0; i < 4; i++) begin spk[i] <= '0; rsum[i] <= '0; end
        end else begin
            // every block has finished well inside the 1024 clocks of a sample;
            // mix at three quarters so all of them are fresh
            mix_prod   <= mix_a * mix_b;
            mix_step_d <= mix_step;
            mix_v      <= mix_run;
            if (mix_v) begin
                if (mix_step_d <= 5'd3)       spk[mix_step_d[1:0]] <= mix_term;
                else if (mix_step_d <= 5'd5)  common <= common + mix_term;
                else if (mix_step_d <= 5'd21) rsum[ridx_d[3:2]] <= rsum[ridx_d[3:2]] + mix_raw;
                else                          spk[rk_d] <= spk[rk_d] + mix_term;
            end
            if (div[9:0] == 10'd768) begin
                mix_run  <= 1'b1;
                mix_step <= 5'd0;
                common   <= '0;
                for (int i = 0; i < 4; i++) rsum[i] <= '0;
            end else if (mix_run) begin
                if (mix_step == ST_LAST) mix_run <= 1'b0;
                else mix_step <= mix_step + 5'd1;
            end else if (mix_v) begin
                // the last product lands this clock; fold next
                post <= 2'd1;
            end else if (post == 2'd1) begin
                post <= 2'd2;
                for (int i = 0; i < 4; i++) spk[i] <= spk[i] + common;
            end else if (post == 2'd2) begin
                post <= 2'd0;
                dc_x1_l <= fold_l;
                dc_x1_r <= fold_r;
                dc_y_l  <= dcy_l_next;
                dc_y_r  <= dcy_r_next;
                audio_l <= clip16(dcy_l_next);
                audio_r <= clip16(dcy_r_next);
                audio_ce <= 1'b1;
            end
        end
    end

    assign dbg_sync = cen_24k;
    assign dbg_wsg0 = w0;
    assign dbg_disc = disc_s;
    assign dbg_eng  = eng_i;

    // per-speaker-channel taps for the benches: front L/R, rear L/R, exactly
    // the four channels MAME's -wavwrite records
    assign dbg_spk0 = clip16(39'(spk[0]));
    assign dbg_spk1 = clip16(39'(spk[1]));
    assign dbg_spk2 = clip16(39'(spk[2]));
    assign dbg_spk3 = clip16(39'(spk[3]));

endmodule

`default_nettype wire
