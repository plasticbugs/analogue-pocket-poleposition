// Bench top for the cabinet filter: the platform's preset table feeding its
// audio filter chain, clocked directly at the Pocket's 12.288 MHz audio MCLK.
`default_nettype none
module tb_cabfilter_top (
    input  wire        clk,
    input  wire        reset,
    input  wire  [3:0] afilter_sw,
    input  wire [15:0] core_l,
    output wire [15:0] audio_l,
    output wire [15:0] audio_r
);
    wire [31:0] rate; wire [39:0] cx; wire [7:0] cx0, cx1, cx2; wire [23:0] cy0, cy1, cy2;
    arcade_filters u_tab (.clk(clk), .afilter_sw(afilter_sw), .flt_rate(rate), .cx(cx),
        .cx0(cx0), .cx1(cx1), .cx2(cx2), .cy0(cy0), .cy1(cy1), .cy2(cy2));
    audio_filters u_flt (.clk(clk), .reset(reset), .flt_rate(rate), .cx(cx), .cx0(cx0), .cx1(cx1),
        .cx2(cx2), .cy0(cy0), .cy1(cy1), .cy2(cy2), .att(5'd0), .is_signed(1'b1), .mix(2'd0),
        .core_l(core_l), .core_r(core_l), .audio_l(audio_l), .audio_r(audio_r));
endmodule
`default_nettype wire
