//------------------------------------------------------------------------------
// Frozen-state video bench top: pp_video plus behavioural models of the four
// video RAMs, with the same registered-read timing as the block RAMs in the
// real design. The C++ driver pokes a state dump in through tb_poke().
//------------------------------------------------------------------------------
`default_nettype none

module tb_video_top (
    input  wire        clk,
    input  wire        reset,
    input  wire [17:0] dl_addr,
    input  wire  [7:0] dl_data,
    input  wire        dl_we,
    input  wire [15:0] hscroll,
    input  wire [15:0] vscroll,
    input  wire        chacl,
    output wire  [7:0] red,
    output wire  [7:0] green,
    output wire  [7:0] blue,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    output wire  [8:0] hcount,
    output wire  [8:0] vcount,
    output wire        cen_pix,
    output wire        dbg_overrun,
    output wire [11:0] dbg_line_clocks
);
    logic [2:0] div = 3'd0;
    always_ff @(posedge clk) div <= div + 3'd1;
    assign cen_pix = (div == 3'd7);

    logic [15:0] view_mem   [0:2047];
    logic [15:0] alpha_mem  [0:1023];
    logic [15:0] road_mem   [0:1023];
    logic [15:0] sprite_mem [0:2047];

    export "DPI-C" function tb_poke;
    function void tb_poke(input int region, input int addr, input int val);
        case (region)
            0: view_mem[addr]   = val[15:0];
            1: alpha_mem[addr]  = val[15:0];
            2: road_mem[addr]   = val[15:0];
            default: sprite_mem[addr] = val[15:0];
        endcase
    endfunction

    wire [10:0] view_addr, sprite_addr;
    wire  [9:0] alpha_addr, road_addr;
    logic [15:0] view_q, alpha_q, road_q, sprite_q;
    always_ff @(posedge clk) begin
        view_q   <= view_mem[view_addr];
        alpha_q  <= alpha_mem[alpha_addr];
        road_q   <= road_mem[road_addr];
        sprite_q <= sprite_mem[sprite_addr];
    end

    wire line_tick, hblank, vblank;

    pp_video u_video (
        .clk(clk), .reset(reset), .cen_pix(cen_pix),
        .hcount(hcount), .vcount(vcount), .line_tick(line_tick),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .hscroll(hscroll), .vscroll(vscroll), .chacl(chacl),
        .view_addr(view_addr), .view_q(view_q),
        .alpha_addr(alpha_addr), .alpha_q(alpha_q),
        .road_addr(road_addr), .road_q(road_q),
        .sprite_addr(sprite_addr), .sprite_q(sprite_q),
        .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .dbg_overrun(dbg_overrun), .dbg_line_clocks(dbg_line_clocks)
    );
endmodule

`default_nettype wire
