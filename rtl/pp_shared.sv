//------------------------------------------------------------------------------
// The four video memories shared by the Z80, both Z8002s and the video board:
//
//   region 0  sprite  0x800 words  Z8002 0x8000-0x8FFF  Z80 0x4000-0x47FF
//   region 1  road    0x400 words  Z8002 0x9000-0x97FF  Z80 0x4800-0x4BFF
//   region 2  alpha   0x400 words  Z8002 0x9800-0x9FFF  Z80 0x4C00-0x4FFF
//   region 3  view    0x800 words  Z8002 0xA000-0xAFFF  Z80 0x5000-0x57FF
//
// Each is a 16-bit true dual-port block RAM. Port A belongs to the video board
// (read only, one address per clock, data the clock after). Port B is shared
// by the three CPUs through a one-request-per-clock arbiter: the Z80 first,
// the two Z8002s alternating. A grant on clock N drives the memory on clock N
// and acknowledges on clock N+1 with the read data; a master is never granted
// on the clock its acknowledge is being delivered, so it sees exactly one
// acknowledge per request.
//
// Byte lanes: lane 1 is the high byte (even Z8002 address), lane 0 the low
// byte (odd address, and the only byte the Z80 can see) -- MAME's big-endian
// 16-bit shares with the Z80 reading `word & 0xff`.
//------------------------------------------------------------------------------
`default_nettype none

module pp_shared (
    input  wire         clk,

    // ---- video port (A): read only --------------------------------------
    input  wire  [10:0] vid_sprite_addr,
    output logic [15:0] vid_sprite_q,
    input  wire   [9:0] vid_road_addr,
    output logic [15:0] vid_road_q,
    input  wire   [9:0] vid_alpha_addr,
    output logic [15:0] vid_alpha_q,
    input  wire  [10:0] vid_view_addr,
    output logic [15:0] vid_view_q,

    // ---- CPU requests (port B): 0 = Z80, 1 = Z8002 #1, 2 = Z8002 #2 --------
    input  wire   [2:0] req,
    input  wire   [1:0] region [3],
    input  wire  [10:0] addr   [3],     //! word address within the region
    input  wire   [2:0] we,
    input  wire   [1:0] be     [3],     //! {high, low} byte lanes for writes
    input  wire  [15:0] wdata  [3],
    output logic  [2:0] ack,            //! one clock, read data valid with it
    output logic [15:0] rdata
);

    // ------------------------------------------------------------ arbiter
    logic       g_v;            // a grant is in flight (ack next clock)
    logic [1:0] g_m;            // its master
    logic [1:0] g_r;            // its region
    logic       last_sub;       // which Z8002 was served last

    wire [2:0] eligible = req & ~((g_v ? (3'b001 << g_m) : 3'b000));
    logic       sel_v;
    logic [1:0] sel_m;
    always_comb begin
        sel_v = 1'b1;
        if      (eligible[0])                  sel_m = 2'd0;
        else if (eligible[1] && eligible[2])   sel_m = last_sub ? 2'd1 : 2'd2;
        else if (eligible[1])                  sel_m = 2'd1;
        else if (eligible[2])                  sel_m = 2'd2;
        else begin sel_m = 2'd0; sel_v = 1'b0; end
    end

    wire  [1:0] sel_region = region[sel_m];
    wire [10:0] sel_addr   = addr[sel_m];
    wire        sel_we     = we[sel_m];
    wire  [1:0] sel_be     = be[sel_m];
    wire [15:0] sel_wdata  = wdata[sel_m];

    always_ff @(posedge clk) begin
        g_v <= sel_v;
        g_m <= sel_m;
        g_r <= sel_region;
        if (sel_v && sel_m != 2'd0) last_sub <= (sel_m == 2'd2);
    end

    // ------------------------------------------------------------ memories
    wire [1:0] cpu_be = sel_be & {2{sel_v && sel_we}};
    logic [15:0] sprite_bq, road_bq, alpha_bq, view_bq;

    pp_dpram16 #(.AW(11)) u_sprite (.clk(clk),
        .a_addr(vid_sprite_addr), .a_q(vid_sprite_q),
        .b_addr(sel_addr),      .b_be(cpu_be & {2{sel_region == 2'd0}}), .b_d(sel_wdata), .b_q(sprite_bq));
    pp_dpram16 #(.AW(10)) u_road (.clk(clk),
        .a_addr(vid_road_addr),   .a_q(vid_road_q),
        .b_addr(sel_addr[9:0]), .b_be(cpu_be & {2{sel_region == 2'd1}}), .b_d(sel_wdata), .b_q(road_bq));
    pp_dpram16 #(.AW(10)) u_alpha (.clk(clk),
        .a_addr(vid_alpha_addr),  .a_q(vid_alpha_q),
        .b_addr(sel_addr[9:0]), .b_be(cpu_be & {2{sel_region == 2'd2}}), .b_d(sel_wdata), .b_q(alpha_bq));
    pp_dpram16 #(.AW(11)) u_view (.clk(clk),
        .a_addr(vid_view_addr),   .a_q(vid_view_q),
        .b_addr(sel_addr),      .b_be(cpu_be & {2{sel_region == 2'd3}}), .b_d(sel_wdata), .b_q(view_bq));

    always_comb begin
        case (g_r)
            2'd0:    rdata = sprite_bq;
            2'd1:    rdata = road_bq;
            2'd2:    rdata = alpha_bq;
            default: rdata = view_bq;
        endcase
        ack = g_v ? (3'b001 << g_m) : 3'b000;
    end

endmodule


//! 16-bit true dual port RAM with byte lanes on port B; port A is read only.
//! 2D-packed data so Quartus infers byte enables instead of registers.
module pp_dpram16 #(parameter AW = 10) (
    input  wire            clk,
    input  wire   [AW-1:0] a_addr,
    output logic    [15:0] a_q,
    input  wire   [AW-1:0] b_addr,
    input  wire      [1:0] b_be,
    input  wire     [15:0] b_d,
    output logic    [15:0] b_q
);
    logic [1:0][7:0] mem [0:(1<<AW)-1] /* verilator public_flat_rw */;
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        a_q <= mem[a_addr];
        if (b_be[0]) mem[b_addr][0] <= b_d[7:0];
        if (b_be[1]) mem[b_addr][1] <= b_d[15:8];
        b_q <= mem[b_addr];
    end
endmodule

`default_nettype wire
