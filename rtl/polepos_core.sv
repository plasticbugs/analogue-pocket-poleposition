//------------------------------------------------------------------------------
// Pole Position (Namco, 1982): the whole machine.
//
// CPU board: Z80 @ 3.072 MHz (I/O, sound, game supervision), two Z8002s @
// 3.072 MHz (game logic, road and sprite tables), Namco 06xx bridging the Z80
// to four MB88xx custom MCUs (51xx I/O and coins, 52xx voice samples, 53xx
// steering and DIPs, 54xx explosion noise), an LS259 control latch, an ADC0804
// reading the pedals, and a watchdog.
//
// Video board: background tilemap, road generator, 64 zoomed sprites, alpha
// text layer -- rtl/pp_video.sv. Sound: 8-voice WSG, engine sample player and
// the discrete filters behind the 52xx/54xx -- rtl/pp_sound.sv.
//
// Memory maps are polepos.cpp's, transcribed at the decode below. Everything
// is block RAM: every access is single cycle and there is nothing to arbitrate
// except the four video memories the three CPUs and the video board share
// (rtl/pp_shared.sv).
//
// Clocking: one 49.152 MHz clock, 2x the board's 24.576 MHz crystal, with
// enables for every rate the board derives from it (docs/interfaces.md).
//------------------------------------------------------------------------------
`default_nettype none

module polepos_core (
    input  wire        clk,             //! 49.152 MHz
    input  wire        reset,
    input  wire        pause,

    // ---- controls ---------------------------------------------------------
    input  wire  [7:0] in0,             //! active low: 7 service mode, 6 service,
                                        //! 5 coin2, 4 coin1, 1 gear (0 = HI); bit 2 is
                                        //! the program-controlled start, driven here
    input  wire  [7:0] dswa,
    input  wire  [7:0] dswb,
    input  wire  [7:0] steer_pos,       //! wheel position, wraps (MAME's STEER dial)
    input  wire  [7:0] accel,           //! pedals: 0x00 up .. 0x90 floored
    input  wire  [7:0] brake,
    input  wire        mame_mix,        //! 1: MAME's discrete routing (benches); 0: the board's

    // ---- ROM image download ----------------------------------------------
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,

    // ---- video -------------------------------------------------------------
    output wire  [7:0] red,
    output wire  [7:0] green,
    output wire  [7:0] blue,
    output wire        hsync,
    output wire        vsync,
    output wire        hblank,
    output wire        vblank,
    output wire        de,
    output wire        cen_pix,

    // ---- audio -------------------------------------------------------------
    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r,
    output wire        audio_ce,

    // ---- diagnostics --------------------------------------------------------
    output wire        dbg_vid_overrun,
    output logic       dbg_watchdog,    //! sticky: the watchdog fired
    output wire [15:0] dbg_z80_pc,
    output wire [15:0] dbg_sub1_pc,
    output wire [15:0] dbg_sub2_pc,
    output wire  [7:0] dbg_latch,
    output wire        dbg_frame        //! one clock at the start of row 240: MAME's frame_done
);

    // ============================================================ clocking
    // 49.152 MHz / 8 = dot clock, / 16 = CPU clock, / 1024 = 06xx base clock,
    // / 192 = MCU instruction rate (1.536 MHz / 6), / 128 = ADC clock.
    logic [9:0] div;
    logic [7:0] mcu_div;
    logic [6:0] adc_div;            // 7 bits: wraps every 128 clocks = 384 kHz
    always_ff @(posedge clk) begin
        if (reset) begin
            div <= 10'd0; mcu_div <= 8'd0; adc_div <= 7'd0;
        end else begin
            div <= div + 10'd1;
            mcu_div <= (mcu_div == 8'd191) ? 8'd0 : mcu_div + 8'd1;
            adc_div <= adc_div + 7'd1;
        end
    end
    wire run      = !pause && !dl_we;
    assign cen_pix = (div[2:0] == 3'd7);
    wire cen_cpu  = (div[3:0] == 4'd15) && run;
    wire cen_06xx = (div == 10'd1023) && run;
    wire cen_mcu  = (mcu_div == 8'd191) && run;
    wire cen_adc  = (adc_div == 7'd127) && run;

    // ============================================================ watchdog
    // 16 vblanks without a kick (any write to 0xA100) resets the board.
    logic       mreset;             // machine reset: external or watchdog
    logic [7:0] wdog_hold;
    logic [4:0] wdog;
    logic       wdog_kick;
    logic       vblank_start;

    always_ff @(posedge clk) begin
        if (reset) begin
            wdog <= 5'd0; wdog_hold <= 8'd0; dbg_watchdog <= 1'b0;
        end else begin
            if (wdog_hold != 8'd0) wdog_hold <= wdog_hold - 8'd1;
            if (wdog_kick) wdog <= 5'd0;
            else if (vblank_start && run) begin
                if (wdog == 5'd15) begin
                    wdog <= 5'd0;
                    wdog_hold <= 8'hff;
                    dbg_watchdog <= 1'b1;
                end else wdog <= wdog + 5'd1;
            end
        end
    end
    assign mreset = reset || (wdog_hold != 8'd0);

    // ============================================================== raster
    wire [8:0] hcount, vcount;
    wire       line_tick;
    wire       line_start = cen_pix && (hcount == 9'd0);   // MAME's scanline timer
    // The raster comes out of reset already at row 240 (see pp_video), so the
    // very first dot is not a vblank start: nothing happens there in MAME.
    logic raster_run;
    always_ff @(posedge clk) begin
        if (reset) raster_run <= 1'b0;
        else if (cen_pix) raster_run <= 1'b1;
    end
    assign vblank_start = line_start && (vcount == 9'd240) && raster_run;
    // MAME's frame_done runs at vblank start, N x 264 lines from power-on
    assign dbg_frame    = vblank_start;
    wire       vblank_lvl = (vcount >= 9'd240) || (vcount < 9'd16);

    // ============================================================ LS259 8E
    //  0 IRQON   Z80 IRQ enable / acknowledge
    //  1 IOSEL   run the 5xXX customs (0 = held in reset)
    //  2 CLSON   sound enable
    //  3 GASEL   ADC input: 1 accelerator, 0 brake
    //  4 RESB    run Z8002 #1
    //  5 RESA    run Z8002 #2
    //  6 SB0     start (goes to the 51xx as IN0 bit 2)
    //  7 CHACL   alpha layer full colour and code MSB
    logic [7:0] latch;
    assign dbg_latch = latch;

    // ================================================================= Z80
    wire        z80_reset = mreset;
    wire [15:0] cpu_a;
    wire  [7:0] cpu_do;
    logic [7:0] cpu_di;
    wire        cpu_mreq_n, cpu_iorq_n, cpu_rd_n, cpu_wr_n, cpu_m1_n, cpu_rfsh_n;
    logic       irq_req;
    wire        nmi;

    tv80s_cen u_z80 (
        .reset_n (~z80_reset),
        .clk     (clk),
        .cen     (cen_cpu),
        .wait_n  (1'b1),
        .int_n   (~irq_req),
        .nmi_n   (~nmi),
        .busrq_n (1'b1),
        .m1_n    (cpu_m1_n),
        .mreq_n  (cpu_mreq_n),
        .iorq_n  (cpu_iorq_n),
        .rd_n    (cpu_rd_n),
        .wr_n    (cpu_wr_n),
        .rfsh_n  (cpu_rfsh_n),
        .halt_n  (),
        .busak_n (),
        .A       (cpu_a),
        .di      (cpu_di),
        .dout    (cpu_do)
    );
    assign dbg_z80_pc = cpu_a;

    wire mem    = ~cpu_mreq_n && cpu_rfsh_n;
    wire mem_rd = mem && ~cpu_rd_n;
    wire mem_wr = mem && ~cpu_wr_n;
    wire io_rd  = ~cpu_iorq_n && cpu_m1_n && ~cpu_rd_n;
    wire io_wr  = ~cpu_iorq_n && ~cpu_wr_n;
    logic mem_wr_q, io_rd_q, io_wr_q;
    always_ff @(posedge clk) begin
        mem_wr_q <= mem_wr; io_rd_q <= io_rd; io_wr_q <= io_wr;
    end
    wire wr_edge   = mem_wr && !mem_wr_q;     // one pulse per Z80 write
    wire iord_edge = io_rd && !io_rd_q;
    wire iowr_edge = io_wr && !io_wr_q;

    // decode (polepos.cpp z80_map)
    wire sel_rom   = (cpu_a[15:12] < 4'd3);                        // 0000-2FFF
    wire sel_nvram = (cpu_a[15:12] == 4'd3);                       // 3000-37FF, mirror 0800
    wire sel_shr   = (cpu_a[15:13] == 3'b010) && !(cpu_a[12] && cpu_a[11]);  // 4000-57FF
    wire sel_sram  = (cpu_a[15:12] == 4'h8) && (cpu_a[9:6] != 4'hf); // 8000-83BF, mirror 0C00
    wire sel_wsg   = (cpu_a[15:12] == 4'h8) && (cpu_a[9:6] == 4'hf); // 83C0-83FF, mirror 0C00
    wire sel_06d   = (cpu_a[15:12] == 4'h9) && !cpu_a[8];           // 9000, mirror 0EFF
    wire sel_06c   = (cpu_a[15:12] == 4'h9) &&  cpu_a[8];           // 9100, mirror 0EFF
    wire sel_a0    = (cpu_a[15:12] == 4'ha) && (cpu_a[9:8] == 2'd0); // READY / latch
    wire sel_a1    = (cpu_a[15:12] == 4'ha) && (cpu_a[9:8] == 2'd1); // watchdog
    wire sel_a2    = (cpu_a[15:12] == 4'ha) && (cpu_a[9:8] == 2'd2); // engine lsb
    wire sel_a3    = (cpu_a[15:12] == 4'ha) && (cpu_a[9:8] == 2'd3); // engine msb

    assign wdog_kick = (wr_edge && sel_a1) || dl_we;

    // program ROM
    wire [7:0] rom_q;
    pp_sdpram #(.AW(14), .DEPTH(12288)) u_rom (
        .clk(clk), .wa(dl_addr[13:0]), .we(dl_we && (dl_addr < 18'h03000)), .d(dl_data),
        .ra(cpu_a[13:0]), .q(rom_q));

    // battery-backed RAM, 2K, all ones from the factory
    wire [7:0] nvram_q;
    pp_nvram u_nvram (.clk(clk), .addr(cpu_a[10:0]), .we(mem_wr && sel_nvram), .d(cpu_do), .q(nvram_q));

    // sound work RAM, 960 bytes used of 1K
    wire [7:0] sram_q;
    pp_sdpram #(.AW(10)) u_sram (
        .clk(clk), .wa(cpu_a[9:0]), .we(mem_wr && sel_sram), .d(cpu_do),
        .ra(cpu_a[9:0]), .q(sram_q));

    // ---- Z80 access to the shared video memories ------------------------
    // The Z80 sees the low byte only. A read is requested once per rd cycle,
    // as soon as the strobe appears, and lands long before tv80 samples it.
    logic       z80_rd_pend, z80_rd_done, z80_wr_pend, z80_wr_done;
    logic [7:0] z80_shr_q;
    wire  [2:0] shr_ack;
    wire [15:0] shr_rdata;
    wire        z80_shr_rd = mem_rd && sel_shr;
    wire        z80_shr_wr = mem_wr && sel_shr;

    always_ff @(posedge clk) begin
        if (z80_reset) begin
            z80_rd_pend <= 1'b0; z80_rd_done <= 1'b0;
            z80_wr_pend <= 1'b0; z80_wr_done <= 1'b0;
        end else begin
            if (!z80_shr_rd) begin z80_rd_done <= 1'b0; z80_rd_pend <= 1'b0; end
            else if (!z80_rd_done && !z80_rd_pend) z80_rd_pend <= 1'b1;
            if (!z80_shr_wr) begin z80_wr_done <= 1'b0; z80_wr_pend <= 1'b0; end
            else if (!z80_wr_done && !z80_wr_pend) z80_wr_pend <= 1'b1;
            if (shr_ack[0]) begin
                if (z80_rd_pend) begin z80_rd_pend <= 1'b0; z80_rd_done <= 1'b1; z80_shr_q <= shr_rdata[7:0]; end
                if (z80_wr_pend) begin z80_wr_pend <= 1'b0; z80_wr_done <= 1'b1; end
            end
        end
    end

    // region and word address from a Z80 address
    function automatic logic [1:0] z80_region(input logic [15:0] a);
        z80_region = a[12] ? 2'd3 : (a[11] ? (a[10] ? 2'd2 : 2'd1) : 2'd0);
    endfunction

    // ---- READY and the ADC --------------------------------------------------
    logic       adc_intr;
    logic [7:0] adc_result, adc_busy;
    // READY bit 1 is 128V: bitmap rows 128 and up (vcount is MAME's vpos)
    wire        vpos_hi = (vcount >= 9'd128);

    // ADC0804 @ 384 kHz: 74 clocks per conversion, INTR set when done and
    // cleared by a read (RD strobed) or a write (which also starts one).
    always_ff @(posedge clk) begin
        if (mreset) begin
            adc_intr <= 1'b0; adc_busy <= 8'd0; adc_result <= 8'd0;
        end else begin
            if (iowr_edge) begin
                adc_intr <= 1'b0;
                if (adc_busy == 8'd0) adc_busy <= 8'd74;
            end
            if (iord_edge) adc_intr <= 1'b0;
            if (cen_adc && adc_busy != 8'd0) begin
                adc_busy <= adc_busy - 8'd1;
                if (adc_busy == 8'd1) begin
                    adc_result <= latch[3] ? accel : brake;
                    adc_intr <= 1'b1;
                end
            end
        end
    end

    // ---- Z80 read mux --------------------------------------------------------
    wire [7:0] wsg_rdata, n06_data_rdata, n06_ctrl_rdata;
    always_comb begin
        cpu_di = 8'hff;
        if (!cpu_iorq_n)      cpu_di = cpu_m1_n ? adc_result : 8'hff;   // IN A,(0) / IM1 ack
        else if (sel_rom)     cpu_di = rom_q;
        else if (sel_nvram)   cpu_di = nvram_q;
        else if (sel_shr)     cpu_di = z80_shr_q;
        else if (sel_sram)    cpu_di = sram_q;
        else if (sel_wsg)     cpu_di = wsg_rdata;
        else if (sel_06d)     cpu_di = n06_data_rdata;
        else if (sel_06c)     cpu_di = n06_ctrl_rdata;
        // READY: bit 3 is the ADC's /INTR pin, low once a conversion is done
        // (MAME: if (!intr_r()) ret ^= 0x08; the ROM at 0x0206 waits for 0)
        else if (sel_a0)      cpu_di = {4'hf, ~adc_intr, 1'b1, ~vpos_hi, 1'b1};
    end

    // ---- control latch -------------------------------------------------------
    always_ff @(posedge clk) begin
        if (mreset) latch <= 8'h00;
        else if (wr_edge && sel_a0) latch[cpu_a[2:0]] <= cpu_do[0];
    end

    // ---- Z80 IRQ: 64V, at scanlines 64 and 192 while IRQON; IRQON low clears
    always_ff @(posedge clk) begin
        if (z80_reset)      irq_req <= 1'b0;
        else if (!latch[0]) irq_req <= 1'b0;
        else if (line_start && (vcount == 9'd64 || vcount == 9'd192)) irq_req <= 1'b1;
    end

    // =============================================================== Z8002s
    // Both run the same memory map; only the ROM and the NVI acknowledge
    // register are private. Shared RAM goes through the arbiter, everything
    // else is answered locally the clock after the request.
    logic [15:0] hscroll, vscroll;
    logic        sub_irq_mask;          // one register, both CPUs write it (MAME)
    logic  [1:0] nvi_line;
    logic  [1:0] nvi_evt;               // one pulse per MAME set_input_line call
    logic  [1:0] sub_reset;
    assign sub_reset = {mreset || !latch[5], mreset || !latch[4]};

    wire         sub_req   [2], sub_we [2], sub_io [2], sub_byte [2];
    logic        sub_ack   [2];
    wire  [15:0] sub_addr  [2], sub_wdata [2];
    logic [15:0] sub_rdata [2];
    wire  [15:0] sub_pc    [2];
    logic        loc_ack   [2];
    logic [15:0] loc_rdata [2];
    wire         sub_shared [2];
    wire  [15:0] rom_e_q [2], rom_o_q [2];

    localparam logic [17:0] OFS_SUB_ROM [2] = '{18'h03000, 18'h07000};

    genvar i;
    generate for (i = 0; i < 2; i++) begin : g_sub
        z8002 u_cpu (
            .clk(clk), .reset(sub_reset[i]), .cen(cen_cpu),
            .nmi(1'b0), .nvi(nvi_line[i]), .vi(1'b0), .nvi_evt(nvi_evt[i]), .vi_evt(1'b0),
            .bus_req(sub_req[i]), .bus_we(sub_we[i]), .bus_io(sub_io[i]), .bus_byte(sub_byte[i]),
            .bus_addr(sub_addr[i]), .bus_wdata(sub_wdata[i]),
            .bus_ack(sub_ack[i]), .bus_rdata(sub_rdata[i]),
            .dbg_insn(), .dbg_pc(sub_pc[i])
        );

        // even bytes = high half of the word, odd = low half
        wire [17:0] dl_e = dl_addr - OFS_SUB_ROM[i];
        wire [17:0] dl_o = dl_addr - OFS_SUB_ROM[i] - 18'h2000;
        pp_sdpram #(.AW(13)) u_rom_e (.clk(clk), .wa(dl_e[12:0]),
            .we(dl_we && dl_addr >= OFS_SUB_ROM[i] && dl_addr < OFS_SUB_ROM[i] + 18'h2000),
            .d(dl_data), .ra(sub_addr[i][13:1]), .q(rom_e_q[i][7:0]));
        pp_sdpram #(.AW(13)) u_rom_o (.clk(clk), .wa(dl_o[12:0]),
            .we(dl_we && dl_addr >= OFS_SUB_ROM[i] + 18'h2000 && dl_addr < OFS_SUB_ROM[i] + 18'h4000),
            .d(dl_data), .ra(sub_addr[i][13:1]), .q(rom_o_q[i][7:0]));
        assign rom_e_q[i][15:8] = 8'h00;
        assign rom_o_q[i][15:8] = 8'h00;

        assign sub_shared[i] = !sub_io[i] && (sub_addr[i][15:12] >= 4'h8) && (sub_addr[i][15:12] <= 4'ha);

        always_ff @(posedge clk) begin
            if (sub_reset[i]) loc_ack[i] <= 1'b0;
            else loc_ack[i] <= sub_req[i] && !sub_shared[i] && !loc_ack[i];
        end
        always_comb begin
            loc_rdata[i] = 16'h0000;
            if (!sub_io[i] && sub_addr[i][15:14] == 2'b00)
                loc_rdata[i] = {rom_e_q[i][7:0], rom_o_q[i][7:0]};
            sub_ack[i]   = loc_ack[i] | shr_ack[i + 1];
            sub_rdata[i] = shr_ack[i + 1] ? shr_rdata : loc_rdata[i];
        end
    end endgenerate

    assign dbg_sub1_pc = sub_pc[0];
    assign dbg_sub2_pc = sub_pc[1];

    // local writes: NVI enable (6000-7FFF), scroll registers (C000-FFFF).
    // MAME acts on every set_input_line call, not only on level changes, so
    // the CPU gets an event pulse with each assert or clear (docs/z8002.md 3).
    always_ff @(posedge clk) begin
        nvi_evt <= 2'b00;
        if (mreset) begin
            hscroll <= 16'd0; vscroll <= 16'd0;
            sub_irq_mask <= 1'b0; nvi_line <= 2'b00;
        end else begin
            for (int k = 0; k < 2; k++) begin
                if (loc_ack[k] && sub_we[k] && !sub_io[k]) begin
                    if (sub_addr[k][15:13] == 3'b011) begin
                        sub_irq_mask <= sub_wdata[k][0];
                        if (!sub_wdata[k][0]) begin nvi_line[k] <= 1'b0; nvi_evt[k] <= 1'b1; end
                    end
                    if (sub_addr[k][15:14] == 2'b11) begin
                        // COMBINE_DATA: a byte write touches its own lane only
                        if (sub_addr[k][10:8] == 3'd0) begin
                            if (!sub_byte[k] || !sub_addr[k][0]) hscroll[15:8] <= sub_wdata[k][15:8];
                            if (!sub_byte[k] ||  sub_addr[k][0]) hscroll[7:0]  <= sub_wdata[k][7:0];
                        end
                        if (sub_addr[k][10:8] == 3'd1) begin
                            if (!sub_byte[k] || !sub_addr[k][0]) vscroll[15:8] <= sub_wdata[k][15:8];
                            if (!sub_byte[k] ||  sub_addr[k][0]) vscroll[7:0]  <= sub_wdata[k][7:0];
                        end
                    end
                end
            end
            if (vblank_start && sub_irq_mask) begin nvi_line <= 2'b11; nvi_evt <= 2'b11; end
            if (sub_reset[0]) nvi_line[0] <= 1'b0;
            if (sub_reset[1]) nvi_line[1] <= 1'b0;
        end
    end

    // ======================================================= shared memory
    wire  [10:0] vid_sprite_addr, vid_view_addr;
    wire   [9:0] vid_road_addr, vid_alpha_addr;
    wire  [15:0] vid_sprite_q, vid_road_q, vid_alpha_q, vid_view_q;

    logic  [2:0] shr_req, shr_we;
    logic  [1:0] shr_region [3], shr_be [3];
    logic [10:0] shr_addr [3];
    logic [15:0] shr_wdata [3];

    always_comb begin
        // Z80: low byte only
        shr_req[0]    = z80_rd_pend || z80_wr_pend;
        shr_we[0]     = z80_wr_pend && !z80_rd_pend;
        shr_region[0] = z80_region(cpu_a);
        shr_addr[0]   = cpu_a[10:0];
        shr_be[0]     = 2'b01;
        shr_wdata[0]  = {8'h00, cpu_do};
        for (int k = 0; k < 2; k++) begin
            shr_req[k + 1]    = sub_req[k] && sub_shared[k];
            shr_we[k + 1]     = sub_we[k];
            shr_region[k + 1] = (sub_addr[k][15:12] == 4'h8) ? 2'd0 :
                                (sub_addr[k][15:12] == 4'ha) ? 2'd3 :
                                (sub_addr[k][11] ? 2'd2 : 2'd1);
            shr_addr[k + 1]   = sub_addr[k][11:1];
            shr_be[k + 1]     = sub_byte[k] ? (sub_addr[k][0] ? 2'b01 : 2'b10) : 2'b11;
            shr_wdata[k + 1]  = sub_wdata[k];
        end
    end

    pp_shared u_shared (
        .clk(clk),
        .vid_sprite_addr(vid_sprite_addr), .vid_sprite_q(vid_sprite_q),
        .vid_road_addr(vid_road_addr),     .vid_road_q(vid_road_q),
        .vid_alpha_addr(vid_alpha_addr),   .vid_alpha_q(vid_alpha_q),
        .vid_view_addr(vid_view_addr),     .vid_view_q(vid_view_q),
        .req(shr_req), .region(shr_region), .addr(shr_addr), .we(shr_we), .be(shr_be), .wdata(shr_wdata),
        .ack(shr_ack), .rdata(shr_rdata)
    );

    // ================================================================ video
    pp_video u_video (
        .clk(clk), .reset(reset), .cen_pix(cen_pix),
        .hcount(hcount), .vcount(vcount), .line_tick(line_tick),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .hscroll(hscroll), .vscroll(vscroll), .chacl(latch[7]),
        .view_addr(vid_view_addr),     .view_q(vid_view_q),
        .alpha_addr(vid_alpha_addr),   .alpha_q(vid_alpha_q),
        .road_addr(vid_road_addr),     .road_q(vid_road_q),
        .sprite_addr(vid_sprite_addr), .sprite_q(vid_sprite_q),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .dbg_overrun(dbg_vid_overrun), .dbg_line_clocks()
    );

    // ======================================================= 06xx + customs
    wire  [7:0] in0_eff = {in0[7:3], latch[6], in0[1:0]};
    wire  [3:0] n52_p, n54_o_lo, n54_o_hi, n54_r1;
    wire [15:0] smp_addr;
    wire  [7:0] smp_data;
    // 52xx voice ROM: MAME's region is 0x8000 long with three 8K chips loaded
    // and the empty fourth socket zero-filled (checked in MAME), so the memory
    // is the full 32K and the top 8K is simply never written.
    pp_sdpram #(.AW(15)) u_voice (
        .clk(clk), .wa(dl_addr[14:0]),
        .we(dl_we && dl_addr >= 18'h28000 && dl_addr < 18'h2E000),
        .d(dl_data), .ra(smp_addr[14:0]), .q(smp_data));

    namco_customs u_customs (
        .clk(clk), .reset(mreset), .cen_mcu(cen_mcu), .cen_06xx(cen_06xx),
        .dl_addr(dl_addr[11:0]), .dl_data(dl_data),
        .dl_we(dl_we && dl_addr >= 18'h23000 && dl_addr < 18'h24000),
        .data_wr(wr_edge && sel_06d), .ctrl_wr(wr_edge && sel_06c), .z80_din(cpu_do),
        .data_q(n06_data_rdata), .ctrl_q(n06_ctrl_rdata), .nmi(nmi),
        .iosel(latch[1]), .vblank(vblank_lvl),
        .in0(in0_eff), .dswa(dswa), .dswb(dswb), .steer_pos(steer_pos),
        .n51_p(), .coin_counter(), .lockout(),
        .smp_addr(smp_addr), .smp_data(smp_data),
        .n52_p(n52_p), .n54_o_lo(n54_o_lo), .n54_o_hi(n54_o_hi), .n54_r1(n54_r1),
        .dbg_pc()
    );

    // ================================================================ sound
    pp_sound u_sound (
        .clk(clk), .reset(mreset),
        .wsg_we(wr_edge && sel_wsg), .wsg_addr(cpu_a[5:0]), .wsg_wdata(cpu_do), .wsg_rdata(wsg_rdata),
        .clson(latch[2]), .mame_mix(mame_mix),
        .engine_lsb_we(wr_edge && sel_a2), .engine_msb_we(wr_edge && sel_a3), .engine_data(cpu_do),
        .n54_o_lo(n54_o_lo), .n54_o_hi(n54_o_hi), .n54_r1(n54_r1), .n52_p(n52_p),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .audio_l(audio_l), .audio_r(audio_r), .audio_ce(audio_ce),
        .dbg_spk0(), .dbg_spk1(), .dbg_spk2(), .dbg_spk3(), .dbg_sync(),
        .dbg_wsg0(), .dbg_disc(), .dbg_eng(), .dbg_eng_pos(), .dbg_eng_step()
    );

endmodule


//! 2K battery-backed RAM. The board ships with it all ones (MAME
//! nvram_device::DEFAULT_ALL_1); the game initialises it on first boot.
module pp_nvram (
    input  wire        clk,
    input  wire [10:0] addr,
    input  wire        we,
    input  wire  [7:0] d,
    output logic [7:0] q
);
    logic [7:0] mem [0:2047] /* verilator public_flat_rw */;
    initial mem = '{default: '1};
    always_ff @(posedge clk) begin
        if (we) mem[addr] <= d;
        q <= mem[addr];
    end
endmodule

`default_nettype wire
