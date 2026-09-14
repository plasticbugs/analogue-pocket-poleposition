//------------------------------------------------------------------------------
// Pole Position's steering wheel from a D-pad or an analog stick.
//
// The wheel is an optical encoder: the 53xx consumes one count of movement per
// poll, so what steers the car is how fast the wheel turns, not where it is.
// This keeps a free-running 8-bit position, like MAME's dial, and turns it
// once a frame:
//
//   D-pad   b counts a frame, 2b once the direction has been held 32 frames
//           (about half a second) -- Medium (b = 2) is the feel the core
//           shipped with
//   stick   in proportion to deflection past the framework's dead zone, up to
//           2b counts a frame at full lock, carrying fractions of a count
//           between frames so a light touch still turns the wheel slowly
//
// Sensitivity picks b: Low 1, Medium 2, High 3. The menu stores Medium as 0,
// so the core steers at Medium before the Pocket has written its settings.
//
// The framework reports a stick past its dead zone as a D-pad press
// (stick_active) and folds that into its merged directions, so the stick path
// takes over whenever a stick is off centre; either stick steers, whichever is
// further over.
//------------------------------------------------------------------------------
`default_nettype none

module pp_steer (
    input  wire       clk,
    input  wire       reset,
    input  wire       frame_tick,
    input  wire [1:0] sens,           // menu: 0 Medium, 1 Low, 2 (or 3) High
    input  wire       left,           // digital directions
    input  wire       right,
    input  wire       stick_active,   // a stick is past the dead zone
    input  wire [7:0] stick_lx,       // 0x80 centre, larger = right
    input  wire [7:0] stick_rx,
    output logic [7:0] pos
);
    localparam [6:0] DEADZONE = 7'd16;           // the framework's 0x10

    // ---- per-clock pipeline: everything the frame update needs, from flops
    wire [2:0] b = (sens == 2'd0) ? 3'd2 : (sens == 2'd1) ? 3'd1 : 3'd3;

    function automatic [7:0] mag(input [7:0] v);   // |v - 0x80|, 0..128
        mag = v[7] ? (v - 8'h80) : (8'h80 - v);
    endfunction

    logic [7:0]  ml, mr, m;
    logic        m_right;
    logic [6:0]  eff;                               // deflection past the dead zone, 0..111
    logic [10:0] add;                               // 1/256 counts per frame, up to 1540
    always_ff @(posedge clk) begin
        ml <= mag(stick_lx);
        mr <= mag(stick_rx);
        m       <= (ml >= mr) ? ml : mr;
        m_right <= (ml >= mr) ? stick_lx[7] : stick_rx[7];
        eff <= (m > {1'b0, DEADZONE}) ? ((m > 8'd127) ? 7'd111 : 7'(m - {1'b0, DEADZONE})) : 7'd0;
        // eff / 111 of 2b counts, in 1/256ths: eff * b * 256 * 2 / 111 ~ eff * b * 37 / 8
        add <= 11'((14'(eff) * 14'(b) * 14'd37) >> 3);
    end

    logic [5:0] held;
    logic [7:0] frac;
    wire  [8:0] sum = {1'b0, frac} + {1'b0, add[7:0]};
    wire  [2:0] whole = 3'(add[10:8]) + 3'(sum[8]);  // counts this frame, up to 6

    always_ff @(posedge clk) begin
        if (reset) begin
            pos <= 8'd0; held <= 6'd0; frac <= 8'd0;
        end else if (frame_tick) begin
            if (stick_active) begin
                held <= 6'd0;
                frac <= sum[7:0];
                pos  <= m_right ? pos + 8'(whole) : pos - 8'(whole);
            end else if (left ^ right) begin
                frac <= 8'd0;
                if (!(&held)) held <= held + 6'd1;
                pos <= right ? pos + (held[5] ? 8'({b, 1'b0}) : 8'(b))
                             : pos - (held[5] ? 8'({b, 1'b0}) : 8'(b));
            end else begin
                held <= 6'd0; frac <= 8'd0;
            end
        end
    end
endmodule

`default_nettype wire
