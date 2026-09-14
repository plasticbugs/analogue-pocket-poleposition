//------------------------------------------------------------------------------
// The discrete circuits on the Pole Position sound board, from the
// polepos_discrete netlist in MAME 0.288's polepos_a.cpp.
//
//   CHANL1..3  the 54xx's three 4-bit outputs, each through an R1 ladder DAC
//              and an op-amp multiple-feedback band-pass, then referred to vRef
//   CHANL4     the 52xx's 4-bit DAC, high-passed at 100 Hz, low-passed at
//              1200 Hz, halved and clamped to the op-amp's swing
//
// Every DAC-plus-input-network is a pure function of the 4-bit code, so the
// generator folds it into a 16-entry table and no multiplier is needed here.
// All five filter sections run in one pp_biquad chain at 48 kHz.
//------------------------------------------------------------------------------
`default_nettype none

module pp_discrete (
    input  wire        clk,
    input  wire        reset,
    input  wire        cen_48k,

    input  wire  [3:0] n54_0,          //! NAMCO_54XX_0_DATA (O low nibble)
    input  wire  [3:0] n54_1,          //! NAMCO_54XX_1_DATA (O high nibble)
    input  wire  [3:0] n54_2,          //! NAMCO_54XX_2_DATA (R1 write)
    input  wire  [3:0] n52,            //! NAMCO_52XX_P_DATA

    output logic signed [31:0] out,    //! Q26: sum of the four channel nodes
    output logic signed [31:0] chanl1, //! Q26: the four channel nodes, valid with out
    output logic signed [31:0] chanl2,
    output logic signed [31:0] chanl3,
    output logic signed [31:0] chanl4,
    output logic       out_valid,
    output wire [159:0] dbg_y          //! the five raw section outputs
);
    `include "pp_snd_coeffs.svh"

    logic         start;
    logic [159:0] x_flat;              // 5 sections
    wire  [159:0] y_flat;
    wire          busy;

    pp_biquad #(.FIRST(3), .NSEC(5)) u_filt (
        .clk(clk), .reset(reset), .start(start),
        .x_flat(x_flat), .y_flat(y_flat), .busy(busy));

    // CHANL1 <- 54xx_2, CHANL2 <- 54xx_1, CHANL3 <- 54xx_0
    always_comb begin
        x_flat = {D52_X[n52],          // section 7 (chained: input ignored)
                  D52_X[n52],          // section 6, 52xx high-pass
                  D54_X2[n54_0],       // section 5, CHANL3
                  D54_X1[n54_1],       // section 4, CHANL2
                  D54_X0[n54_2]};      // section 3, CHANL1
    end

    assign dbg_y = y_flat;

    wire signed [31:0] y1 = $signed(y_flat[31:0])   - VREF_Q;
    wire signed [31:0] y2 = $signed(y_flat[63:32])  - VREF_Q;
    wire signed [31:0] y3 = $signed(y_flat[95:64])  - VREF_Q;
    wire signed [31:0] y4raw = $signed(y_flat[159:128]) >>> 1;   // DISCRETE_GAIN 0.5
    wire signed [31:0] y4 = (y4raw < 32'sd0)     ? 32'sd0 :
                            (y4raw > CLAMP52_HI) ? CLAMP52_HI : y4raw;

    logic pending;
    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        start <= 1'b0;
        if (reset) begin
            pending <= 1'b0;
            out <= 32'sd0;
            chanl1 <= 32'sd0; chanl2 <= 32'sd0; chanl3 <= 32'sd0; chanl4 <= 32'sd0;
        end else begin
            if (cen_48k) begin
                start <= 1'b1;
                pending <= 1'b1;
            end else if (pending && !start && !busy) begin
                pending <= 1'b0;
                out <= y1 + y2 + y3 + y4;
                chanl1 <= y1; chanl2 <= y2; chanl3 <= y3; chanl4 <= y4;
                out_valid <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
