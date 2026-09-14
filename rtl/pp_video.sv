//------------------------------------------------------------------------------
// Pole Position video board.
//
// Semantics are MAME 0.288's polepos_v.cpp, as transcribed and proven
// pixel-identical in tools/ppvideo.py -- read that file alongside this one.
//
// Raster: 6.144 MHz dot clock, 384 x 264, visible x 0..255, y 16..239.
// hcount/vcount are MAME's hpos/vpos directly.
//
// Every visible line is built during the line before it into a 256-entry line
// buffer, one buffer per line parity so the line being shown is never the one
// being written:
//
//   1. base layer: background tiles above row 128, the road below it;
//   2. alpha layer, into its own buffer, in parallel with (1);
//   3. the 64 zoomed sprites in table order, over the base buffer.
//
// The display merges alpha over base and looks up the palette PROMs. A line
// has 384 dots x 8 clocks = 3072 clocks; the worst line measured in real play
// needs about 1,900 (tools/sprite_load.py). dbg_overrun latches if a line ever
// fails to finish.
//
// Memory timing: every BRAM read address is driven combinationally from the
// current pipeline stage, so the data arrives on the next clock alongside that
// stage's registers.
//------------------------------------------------------------------------------
`default_nettype none

module pp_video (
    input  wire        clk,             //! 49.152 MHz
    input  wire        reset,
    input  wire        cen_pix,         //! 6.144 MHz dot enable

    // ---- raster -------------------------------------------------------------
    output logic [8:0] hcount,
    output logic [8:0] vcount,
    output wire        line_tick,       //! last dot of a line: vcount advances next
    output logic [7:0] red,
    output logic [7:0] green,
    output logic [7:0] blue,
    output logic       hsync,
    output logic       vsync,
    output logic       hblank,
    output logic       vblank,
    output logic       de,

    // ---- scroll and control, from the CPU boards ----------------------------
    input  wire [15:0] hscroll,         //! VHP
    input  wire [15:0] vscroll,         //! RVP
    input  wire        chacl,           //! latch bit 7

    // ---- video memories: registered reads, data the clock after addr --------
    output logic [10:0] view_addr,      //! 0x800 words, background uses 0x000-0x3ff
    input  wire  [15:0] view_q,
    output logic  [9:0] alpha_addr,     //! 0x400 words
    input  wire  [15:0] alpha_q,
    output logic  [9:0] road_addr,      //! 0x400 words
    input  wire  [15:0] road_q,
    output logic [10:0] sprite_addr,    //! 0x800 words, sprites use 0x380-0x3ff, 0x780-0x7ff
    input  wire  [15:0] sprite_q,

    // ---- ROM image download ---------------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- diagnostics --------------------------------------------------------
    output logic       dbg_overrun,
    output logic [11:0] dbg_line_clocks //! worst line build time seen
);

    // ======================================================== ROMs and PROMs
    localparam logic [17:0] OFS_CHARS = 18'h0B000, OFS_TILES = 18'h0C000,
                            OFS_SPR_SA = 18'h0D000, OFS_SPR_SB = 18'h0F000,
                            OFS_SPR_BA = 18'h11000, OFS_SPR_BB = 18'h17000,
                            OFS_ROAD0 = 18'h1D000, OFS_ROAD1 = 18'h1F000,
                            OFS_ROAD2 = 18'h21000, OFS_SCALE = 18'h22000,
                            OFS_RED   = 18'h2E000, OFS_GREEN = 18'h2E100,
                            OFS_BLUE  = 18'h2E200, OFS_ALPHA = 18'h2E300,
                            OFS_BG    = 18'h2E400, OFS_VPL   = 18'h2E500,
                            OFS_VPM   = 18'h2E600, OFS_VPH   = 18'h2E700,
                            OFS_ROADC = 18'h2E800, OFS_SPRC  = 18'h2EC00;

    function automatic logic in_rng(input logic [17:0] a, input logic [17:0] base, input int len);
        in_rng = (a >= base) && (a < base + 18'(len));
    endfunction

    wire [17:0] dl_chars = dl_addr - OFS_CHARS, dl_tiles = dl_addr - OFS_TILES;
    wire [17:0] dl_spr_sa = dl_addr - OFS_SPR_SA, dl_spr_sb = dl_addr - OFS_SPR_SB;
    wire [17:0] dl_spr_ba = dl_addr - OFS_SPR_BA, dl_spr_bb = dl_addr - OFS_SPR_BB;
    wire [17:0] dl_road0 = dl_addr - OFS_ROAD0, dl_road1 = dl_addr - OFS_ROAD1;
    wire [17:0] dl_road2 = dl_addr - OFS_ROAD2, dl_scale = dl_addr - OFS_SCALE;

    // characters and tiles (2 bpp, 16 bytes each)
    logic [11:0] chars_ra, tiles_ra;
    wire  [7:0]  chars_q, tiles_q;
    pp_sdpram #(.AW(12)) u_chars (.clk(clk), .wa(dl_chars[11:0]), .we(dl_we && in_rng(dl_addr, OFS_CHARS, 4096)),
        .d(dl_data), .ra(chars_ra), .q(chars_q));
    pp_sdpram #(.AW(12)) u_tiles (.clk(clk), .wa(dl_tiles[11:0]), .we(dl_we && in_rng(dl_addr, OFS_TILES, 4096)),
        .d(dl_data), .ra(tiles_ra), .q(tiles_q));

    // sprites: planes 0+1 (A) and planes 2+3 (B) read in parallel
    logic [12:0] spr_s_ra;
    logic [14:0] spr_b_ra;
    wire  [7:0]  spr_sa_q, spr_sb_q, spr_ba_q, spr_bb_q;
    pp_sdpram #(.AW(13)) u_spr_sa (.clk(clk), .wa(dl_spr_sa[12:0]), .we(dl_we && in_rng(dl_addr, OFS_SPR_SA, 8192)),
        .d(dl_data), .ra(spr_s_ra), .q(spr_sa_q));
    pp_sdpram #(.AW(13)) u_spr_sb (.clk(clk), .wa(dl_spr_sb[12:0]), .we(dl_we && in_rng(dl_addr, OFS_SPR_SB, 8192)),
        .d(dl_data), .ra(spr_s_ra), .q(spr_sb_q));
    pp_sdpram #(.AW(15), .DEPTH(24576)) u_spr_ba (.clk(clk), .wa(dl_spr_ba[14:0]), .we(dl_we && in_rng(dl_addr, OFS_SPR_BA, 24576)),
        .d(dl_data), .ra(spr_b_ra), .q(spr_ba_q));
    pp_sdpram #(.AW(15), .DEPTH(24576)) u_spr_bb (.clk(clk), .wa(dl_spr_bb[14:0]), .we(dl_we && in_rng(dl_addr, OFS_SPR_BB, 24576)),
        .d(dl_data), .ra(spr_b_ra), .q(spr_bb_q));

    // road: control, bits 1, bits 2
    logic [12:0] road01_ra;
    logic [11:0] road2_ra;
    wire  [7:0]  road0_q, road1_q, road2_q;
    pp_sdpram #(.AW(13)) u_road0 (.clk(clk), .wa(dl_road0[12:0]), .we(dl_we && in_rng(dl_addr, OFS_ROAD0, 8192)),
        .d(dl_data), .ra(road01_ra), .q(road0_q));
    pp_sdpram #(.AW(13)) u_road1 (.clk(clk), .wa(dl_road1[12:0]), .we(dl_we && in_rng(dl_addr, OFS_ROAD1, 8192)),
        .d(dl_data), .ra(road01_ra), .q(road1_q));
    pp_sdpram #(.AW(12)) u_road2 (.clk(clk), .wa(dl_road2[11:0]), .we(dl_we && in_rng(dl_addr, OFS_ROAD2, 4096)),
        .d(dl_data), .ra(road2_ra), .q(road2_q));

    // vertical sprite scaling
    logic [11:0] scale_ra;
    wire  [7:0]  scale_q;
    pp_sdpram #(.AW(12)) u_scale (.clk(clk), .wa(dl_scale[11:0]), .we(dl_we && in_rng(dl_addr, OFS_SCALE, 4096)),
        .d(dl_data), .ra(scale_ra), .q(scale_q));

    // 4-bit PROMs
    logic [6:0] pal_ra;
    wire  [3:0] red_q, green_q, blue_q;
    pp_sdpram #(.AW(7), .DW(4)) u_red   (.clk(clk), .wa(dl_addr[6:0]), .we(dl_we && in_rng(dl_addr, OFS_RED, 128)),
        .d(dl_data[3:0]), .ra(pal_ra), .q(red_q));
    pp_sdpram #(.AW(7), .DW(4)) u_green (.clk(clk), .wa(dl_addr[6:0]), .we(dl_we && in_rng(dl_addr, OFS_GREEN, 128)),
        .d(dl_data[3:0]), .ra(pal_ra), .q(green_q));
    pp_sdpram #(.AW(7), .DW(4)) u_blue  (.clk(clk), .wa(dl_addr[6:0]), .we(dl_we && in_rng(dl_addr, OFS_BLUE, 128)),
        .d(dl_data[3:0]), .ra(pal_ra), .q(blue_q));

    logic [7:0] alphac_ra, bgc_ra, vpos_ra;
    wire  [3:0] alphac_q, bgc_q, vpl_q, vpm_q, vph_q;
    pp_sdpram #(.AW(8), .DW(4)) u_alphac (.clk(clk), .wa(dl_addr[7:0]), .we(dl_we && in_rng(dl_addr, OFS_ALPHA, 256)),
        .d(dl_data[3:0]), .ra(alphac_ra), .q(alphac_q));
    pp_sdpram #(.AW(8), .DW(4)) u_bgc    (.clk(clk), .wa(dl_addr[7:0]), .we(dl_we && in_rng(dl_addr, OFS_BG, 256)),
        .d(dl_data[3:0]), .ra(bgc_ra), .q(bgc_q));
    pp_sdpram #(.AW(8), .DW(4)) u_vpl    (.clk(clk), .wa(dl_addr[7:0]), .we(dl_we && in_rng(dl_addr, OFS_VPL, 256)),
        .d(dl_data[3:0]), .ra(vpos_ra), .q(vpl_q));
    pp_sdpram #(.AW(8), .DW(4)) u_vpm    (.clk(clk), .wa(dl_addr[7:0]), .we(dl_we && in_rng(dl_addr, OFS_VPM, 256)),
        .d(dl_data[3:0]), .ra(vpos_ra), .q(vpm_q));
    pp_sdpram #(.AW(8), .DW(4)) u_vph    (.clk(clk), .wa(dl_addr[7:0]), .we(dl_we && in_rng(dl_addr, OFS_VPH, 256)),
        .d(dl_data[3:0]), .ra(vpos_ra), .q(vph_q));

    logic [9:0] roadc_ra, sprc_ra;
    wire  [3:0] roadc_q, sprc_q;
    pp_sdpram #(.AW(10), .DW(4)) u_roadc (.clk(clk), .wa(dl_addr[9:0]), .we(dl_we && in_rng(dl_addr, OFS_ROADC, 1024)),
        .d(dl_data[3:0]), .ra(roadc_ra), .q(roadc_q));
    pp_sdpram #(.AW(10), .DW(4)) u_sprc  (.clk(clk), .wa(dl_addr[9:0]), .we(dl_we && in_rng(dl_addr, OFS_SPRC, 1024)),
        .d(dl_data[3:0]), .ra(sprc_ra), .q(sprc_q));

    // ============================================================ raster
    localparam logic [8:0] HLAST = 9'd383, VLAST = 9'd263;
    localparam logic [8:0] HS_BEG = 9'd288, HS_END = 9'd320;
    localparam logic [8:0] VS_BEG = 9'd248, VS_END = 9'd251;

    // The raster leaves reset at the top of vblank, row 240, which is where
    // MAME's screen is at time zero: its frame_done runs at N x 264 lines and
    // the 64V IRQ handlers run at 88 and 216 lines into each period (measured).
    // Starting at row 0 instead puts every raster event 24 lines early
    // relative to the CPUs.
    always_ff @(posedge clk) begin
        if (reset) begin
            hcount <= 9'd0;
            vcount <= 9'd240;
        end else if (cen_pix) begin
            if (hcount == HLAST) begin
                hcount <= 9'd0;
                vcount <= (vcount == VLAST) ? 9'd0 : vcount + 9'd1;
            end else begin
                hcount <= hcount + 9'd1;
            end
        end
    end

    assign line_tick = cen_pix && (hcount == HLAST);

    // ====================================================== line buffers
    // base: 7-bit palette index. alpha: {opaque, 7-bit index}.
    // address {parity, x}
    logic       base_we, alpha_we;
    logic [8:0] base_wa, alpha_wa;
    logic [6:0] base_d;
    logic [7:0] alpha_d;
    wire  [8:0] disp_ra = {vcount[0], hcount[7:0]};
    wire  [6:0] base_dq;
    wire  [7:0] alpha_dq;
    pp_sdpram #(.AW(9), .DW(7)) u_lb_base  (.clk(clk), .wa(base_wa),  .we(base_we),  .d(base_d),
        .ra(disp_ra), .q(base_dq));
    pp_sdpram #(.AW(9), .DW(8)) u_lb_alpha (.clk(clk), .wa(alpha_wa), .we(alpha_we), .d(alpha_d),
        .ra(disp_ra), .q(alpha_dq));

    // ===================================================== line renderer
    // Started on the last dot of line V; builds line V+2 during line V+1.
    wire [8:0] tgt_next = (vcount >= 9'd262) ? vcount - 9'd262 : vcount + 9'd2;
    wire       tgt_vis  = (tgt_next >= 9'd16) && (tgt_next < 9'd240);

    logic [7:0]  ly;            // target line (bitmap row, 16..239)
    logic        lpar;          // its parity = line buffer select
    logic [8:0]  l_hscroll;
    logic [15:0] l_vscroll;
    logic        l_chacl;
    logic        busy;
    logic [11:0] line_clocks;

    // --------------------------------------------------------- alpha pass
    logic       a_run;
    logic [8:0] a_x;            // 0..255 while running
    logic       a1_v, a2_v, a3_v;
    logic [7:0] a1_x, a2_x, a3_x;
    logic [1:0] a2_k;
    logic [5:0] a2_color;
    logic       a2_hi, a3_hi;

    always_comb begin
        alpha_addr = {ly[7:3], a_x[7:3]};
        // stage 1: alpha word -> character ROM
        chars_ra   = {alpha_q[7:0], a1_x[2], ly[2:0]};
        // stage 2: character pixel -> colour PROM
        alphac_ra  = {a2_color, chars_q[3'd7 - {1'b0, a2_k}], chars_q[3'd3 - {1'b0, a2_k}]};
    end

    always_ff @(posedge clk) begin
        if (reset || !a_run) begin
            a1_v <= 1'b0; a2_v <= 1'b0; a3_v <= 1'b0;
        end else begin
            a1_v <= !a_x[8];
            a1_x <= a_x[7:0];
            a2_v <= a1_v; a2_x <= a1_x; a2_k <= a1_x[1:0];
            a2_color <= l_chacl ? alpha_q[13:8] : 6'd0;
            a2_hi <= ly[7];
            a3_v <= a2_v; a3_x <= a2_x; a3_hi <= a2_hi;
        end
    end

    always_comb begin
        alpha_we = a_run && a3_v;
        alpha_wa = {lpar, a3_x};
        alpha_d  = (alphac_q == 4'd15) ? 8'h00 : {1'b1, (a3_hi ? 3'b110 : 3'b010), alphac_q};
    end

    // ---------------------------------------------------------- main FSM
    typedef enum logic [4:0] {
        S_IDLE,
        S_BG,
        S_RD0, S_RD1, S_RD2, S_RD3, S_RCH, S_RPX, S_RFL,
        S_SP0, S_SP1, S_SP2, S_SP3, S_SP4, S_SP5, S_SST, S_SFL,
        S_DONE
    } st_t;
    st_t st;

    // background pipeline
    logic [8:0] b_x;
    logic       b1_v, b2_v, b3_v;
    logic [7:0] b1_x, b2_x, b3_x;
    logic [2:0] b1_px;
    logic [1:0] b2_k;
    logic [5:0] b2_color;

    // road
    logic [3:0]  r_pal;
    logic [2:0]  r_xscroll;
    logic [10:0] r_xo;
    logic [8:0]  r_k;           // position in the generated scanline
    logic [3:0]  r_i;           // 8..1
    logic [7:0]  r_val;
    logic        r_carin;
    logic        r1_v;
    logic [7:0]  r1_x;

    // sprites
    logic [5:0]  s_i;
    logic [15:0] s_yw, s_z0;
    logic [5:0]  s_dyr;
    logic        s_hi;
    logic [9:0]  s_xx;
    logic [6:0]  s_siz;
    logic [5:0]  s_sizex, s_color;
    logic [4:0]  s_dy;
    logic [6:0]  s_step;
    logic        t1_v, t2_v;
    logic [7:0]  t1_x, t2_x;
    logic [1:0]  t1_k;
    logic        t1_zero;       // big sprite codes 96..127: MAME's empty region

    wire        s_big    = s_z0[15];
    wire [5:0]  s_sizey  = s_z0[13:8];
    wire [6:0]  s_code   = s_z0[6:0];
    wire        s_flipx  = s_z0[7];
    wire [4:0]  s_col    = s_step[5:1] ^ (s_flipx ? (s_big ? 5'h1f : 5'h0f) : 5'h00);
    wire [6:0]  s_nsteps = s_big ? 7'd64 : 7'd32;

    // background source column, scroll mod 512
    wire [8:0]  b_sx     = b_x + l_hscroll;

    // hit test for the word pair just read: y = (Y - sy) mod 512, sy = 513 - p
    wire [8:0]  s_p      = s_yw[8:0];
    wire [8:0]  s_dyr_w  = {1'b0, ly} + s_p - 9'd1;

    // road pixel. MAME walks i = 8..1 with BIT(bits, i): bit 8 of a byte is 0.
    wire [8:0]  r_b1     = {1'b0, road1_q};
    wire [8:0]  r_b2     = {1'b0, road2_q};
    wire [1:0]  r_bits   = {r_b2[r_i], r_b1[r_i]};
    wire [2:0]  r_step   = {1'b0, r_bits} + ((!r_carin && r_bits != 2'd0) ? 3'd1 : 3'd0);
    wire [7:0]  r_valnow = (r_i == 4'd8) ? {2'b00, road0_q[5:0]} : r_val;
    wire        r_blank  = r_xo[9];     // the 0x200 bit disables the road ROMs
    wire [5:0]  r_pix    = r_blank ? 6'd0 : r_valnow[5:0];
    wire [8:0]  r_xout   = r_k - {6'd0, r_xscroll};

    // yoffs = ((vpos + RVP) >> 3) & 0x1ff
    wire [16:0] r_ysum   = {5'd0, vph_q, vpm_q, vpl_q} + {1'b0, l_vscroll};

    // sprite pen from the two planes
    wire [3:0]  t_pen    = t1_zero ? 4'd0 :
                           {spr_a_q[3'd7 - {1'b0, t1_k}], spr_a_q[3'd3 - {1'b0, t1_k}],
                            spr_b_q[3'd7 - {1'b0, t1_k}], spr_b_q[3'd3 - {1'b0, t1_k}]};
    logic        t_big;
    wire  [7:0]  spr_a_q = t_big ? spr_ba_q : spr_sa_q;
    wire  [7:0]  spr_b_q = t_big ? spr_bb_q : spr_sb_q;

    always_comb begin
        // background
        view_addr = {1'b0, b_sx[8:3], ly[6:3]};
        tiles_ra  = {view_q[7:0], b1_px[2], ly[2:0]};
        bgc_ra    = {b2_color, tiles_q[3'd7 - {1'b0, b2_k}], tiles_q[3'd3 - {1'b0, b2_k}]};

        // road
        vpos_ra   = ly;
        road_addr = 10'd0;
        case (st)
            S_RD1:   road_addr = {1'b0, r_ysum[11:3]};
            default: road_addr = 10'h380 + {3'd0, ly[6:0]};
        endcase
        road01_ra = {ly[6:0], r_xo[8:3]};
        road2_ra  = {road01_ra[12] | road01_ra[11], road01_ra[10:0]};
        roadc_ra  = {r_pal, r_pix};

        // sprites
        sprite_addr = 11'h380 + {4'd0, s_i, 1'b0};
        case (st)
            S_SP1: sprite_addr = 11'h780 + {4'd0, s_i, 1'b0};
            S_SP2: sprite_addr = 11'h381 + {4'd0, s_i, 1'b0};
            S_SP3: sprite_addr = 11'h781 + {4'd0, s_i, 1'b0};
            default: ;
        endcase
        scale_ra = {s_dyr, s_sizey};
        spr_b_ra = {s_code[6:0], s_dy[4:0], s_col[4:2]};
        spr_s_ra = {s_code[6:0], s_dy[3:0], s_col[3:2]};
        sprc_ra  = {s_color, t_pen};
    end

    // base line buffer writes
    always_comb begin
        base_we = 1'b0;
        base_wa = {lpar, b3_x};
        base_d  = {3'b000, bgc_q};
        if (st == S_BG && b3_v) begin
            base_we = 1'b1;
        end else if ((st == S_RPX || st == S_RCH || st == S_RFL) && r1_v) begin
            base_we = 1'b1;
            base_wa = {lpar, r1_x};
            base_d  = {3'b100, roadc_q};
        end else if ((st == S_SST || st == S_SFL) && t2_v && sprc_q != 4'd15) begin
            base_we = 1'b1;
            base_wa = {lpar, t2_x};
            base_d  = {(s_hi ? 3'b101 : 3'b001), sprc_q};
        end
    end

    wire start = line_tick && tgt_vis;

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE;
            busy <= 1'b0;
            a_run <= 1'b0;
            dbg_overrun <= 1'b0;
            dbg_line_clocks <= 12'd0;
            b1_v <= 1'b0; b2_v <= 1'b0; b3_v <= 1'b0;
            r1_v <= 1'b0; t1_v <= 1'b0; t2_v <= 1'b0;
        end else begin
            // pipelines advance every clock
            b2_v <= b1_v; b2_x <= b1_x; b2_k <= b1_px[1:0]; b2_color <= view_q[13:8];
            b3_v <= b2_v; b3_x <= b2_x;
            t2_v <= t1_v; t2_x <= t1_x;

            if (busy) line_clocks <= line_clocks + 12'd1;

            // alpha pass counter
            if (a_run) begin
                if (a_x[8] && !a1_v && !a2_v && !a3_v) a_run <= 1'b0;
                else if (!a_x[8]) a_x <= a_x + 9'd1;
            end

            if (start) begin
                if (busy) dbg_overrun <= 1'b1;
                busy <= 1'b1;
                line_clocks <= 12'd0;
                ly <= tgt_next[7:0];
                lpar <= tgt_next[0];
                l_hscroll <= hscroll[8:0];
                l_vscroll <= vscroll;
                l_chacl <= chacl;
                a_run <= 1'b1;
                a_x <= 9'd0;
                b_x <= 9'd0;
                b1_v <= 1'b0;
                r1_v <= 1'b0;
                t1_v <= 1'b0;
                st <= (tgt_next < 9'd128) ? S_BG : S_RD0;
            end else begin
                case (st)
                S_IDLE: ;

                // ---------------------------------------------- background
                S_BG: begin
                    b1_v  <= !b_x[8];
                    b1_x  <= b_x[7:0];
                    b1_px <= b_sx[2:0];
                    if (!b_x[8]) b_x <= b_x + 9'd1;
                    else if (!b1_v && !b2_v && !b3_v) begin
                        s_i <= 6'd0;
                        st <= S_SP0;
                    end
                end

                // ---------------------------------------------------- road
                S_RD0: st <= S_RD1;                     // vpos PROMs read
                S_RD1: st <= S_RD2;                     // road RAM[yoffs] read
                S_RD2: begin                            // road RAM[0x380+y] read
                    r_pal <= road_q[3:0];
                    st <= S_RD3;
                end
                S_RD3: begin
                    r_xscroll <= road_q[2:0];
                    r_xo <= {1'b0, road_q[9:3], 3'b000};
                    r_k <= 9'd0;
                    st <= S_RCH;
                end
                S_RCH: begin                            // chunk ROMs read
                    r_i <= 4'd8;
                    r1_v <= 1'b0;
                    st <= S_RPX;
                end
                S_RPX: begin
                    if (r_i == 4'd8) r_carin <= road0_q[7];
                    // i == 8 adds BIT(bits, 8) = 0, so carin is not needed yet
                    r_val <= r_valnow + ((r_i == 4'd8) ? 8'd0 : {5'd0, r_step});
                    r1_v  <= (r_k >= {6'd0, r_xscroll}) && (r_xout < 9'd256);
                    r1_x  <= r_xout[7:0];
                    r_k   <= r_k + 9'd1;
                    if (r_i == 4'd1) begin
                        r_xo <= r_xo + 11'd8;
                        st <= (r_k + 9'd1 >= 9'd256 + {6'd0, r_xscroll}) ? S_RFL : S_RCH;
                    end
                    r_i <= r_i - 4'd1;
                end
                S_RFL: begin
                    r1_v <= 1'b0;
                    s_i <= 6'd0;
                    st <= S_SP0;
                end

                // ------------------------------------------------- sprites
                S_SP0: st <= S_SP1;                     // posi Y read
                S_SP1: begin                            // size/data word 0 read
                    s_yw <= sprite_q;
                    st <= S_SP2;
                end
                S_SP2: begin
                    s_z0 <= sprite_q;
                    s_dyr <= s_dyr_w[5:0];
                    s_hi <= (s_p <= 9'd385);
                    if (s_dyr_w[8:6] == 3'd0 && s_dyr_w[5:0] <= sprite_q[13:8]) begin
                        st <= S_SP3;
                    end else if (s_i == 6'd63) begin
                        st <= S_DONE;
                    end else begin
                        s_i <= s_i + 6'd1;
                        st <= S_SP0;
                    end
                end
                S_SP3: begin                            // posi X read
                    s_xx <= sprite_q[9:0] - 10'd60;
                    st <= S_SP4;
                end
                S_SP4: begin                            // size/data word 1 read, scale read
                    s_color <= sprite_q[5:0];
                    s_sizex <= sprite_q[13:8];
                    st <= S_SP5;
                end
                S_SP5: begin
                    s_dy <= s_big ? scale_q[4:0] : {1'b0, scale_q[4:1]};
                    s_siz <= 7'd0;
                    s_step <= 7'd0;
                    t_big <= s_big;
                    st <= S_SST;
                end
                S_SST: begin
                    t1_v    <= (s_xx < 10'd256);
                    t1_x    <= s_xx[7:0];
                    t1_k    <= s_col[1:0];
                    t1_zero <= s_big && (s_code >= 7'd96);
                    if (s_siz + 7'd1 + {1'b0, s_sizex} >= 7'd64) begin
                        s_siz <= s_siz + 7'd1 + {1'b0, s_sizex} - 7'd64;
                        s_xx <= s_xx + 10'd1;
                    end else begin
                        s_siz <= s_siz + 7'd1 + {1'b0, s_sizex};
                    end
                    s_step <= s_step + 7'd1;
                    if (s_step + 7'd1 == s_nsteps) st <= S_SFL;
                end
                S_SFL: begin
                    t1_v <= 1'b0;
                    if (!t1_v && !t2_v) begin
                        if (s_i == 6'd63) st <= S_DONE;
                        else begin
                            s_i <= s_i + 6'd1;
                            st <= S_SP0;
                        end
                    end
                end

                S_DONE: begin
                    if (!a_run) begin
                        busy <= 1'b0;
                        st <= S_IDLE;
                        if (line_clocks > dbg_line_clocks) dbg_line_clocks <= line_clocks;
                    end
                end
                default: st <= S_IDLE;
                endcase
            end
        end
    end

    // ============================================================= display
    logic       d1;                         // clock after the dot tick
    logic       px_de, px_hs, px_vs, px_hb, px_vb;
    logic [6:0] px_idx;

    wire h_vis = (hcount < 9'd256);
    wire v_vis = (vcount >= 9'd16) && (vcount < 9'd240);

    always_ff @(posedge clk) begin
        d1 <= cen_pix;
        if (cen_pix) begin
            px_de <= h_vis && v_vis;
            px_hs <= (hcount >= HS_BEG) && (hcount < HS_END);
            px_vs <= (vcount >= VS_BEG) && (vcount < VS_END);
            px_hb <= !h_vis;
            px_vb <= !v_vis;
        end
        if (d1) px_idx <= alpha_dq[7] ? alpha_dq[6:0] : base_dq;
    end

    assign pal_ra = px_idx;

    function automatic [7:0] gun(input [3:0] v);
        gun = (v[0] ? 8'h0e : 8'h00) + (v[1] ? 8'h1f : 8'h00)
            + (v[2] ? 8'h43 : 8'h00) + (v[3] ? 8'h8f : 8'h00);
    endfunction

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            red    <= px_de ? gun(red_q)   : 8'h00;
            green  <= px_de ? gun(green_q) : 8'h00;
            blue   <= px_de ? gun(blue_q)  : 8'h00;
            de     <= px_de;
            hsync  <= px_hs;
            vsync  <= px_vs;
            hblank <= px_hb;
            vblank <= px_vb;
        end
    end

endmodule

`default_nettype wire
