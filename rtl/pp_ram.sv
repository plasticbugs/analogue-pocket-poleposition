//------------------------------------------------------------------------------
// Block RAM primitives for the Pole Position core.
//
// The whole 188 KB romset and all work RAM live in block RAM, so
// every access is single cycle. Reads are registered:
// drive the address on cycle N, the data is valid on cycle N+1.
//------------------------------------------------------------------------------
`default_nettype none

//! One write port, one read port. Read-during-write to the same address
//! returns the old contents, which is what Quartus infers for this style.
//! DEPTH lets a memory hold fewer than 2^AW words, so a 24K ROM does not
//! cost a 32K block.
module pp_sdpram #(parameter AW = 8, parameter DW = 8, parameter DEPTH = 1 << AW) (
    input  wire           clk,
    input  wire  [AW-1:0] wa,
    input  wire           we,
    input  wire  [DW-1:0] d,
    input  wire  [AW-1:0] ra,
    output logic [DW-1:0] q
);
    logic [DW-1:0] mem [0:DEPTH-1] /* verilator public_flat_rw */;
    // Assignment pattern rather than a for loop: Quartus caps constant loops
    // at 5000 iterations, and the largest memory here is 24576 bytes.
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule

//! True dual port: two independent read/write ports on one array.
module pp_dpram #(parameter AW = 10, parameter DW = 8) (
    input  wire           clk,
    input  wire  [AW-1:0] a_addr,
    input  wire           a_we,
    input  wire  [DW-1:0] a_d,
    output logic [DW-1:0] a_q,
    input  wire  [AW-1:0] b_addr,
    input  wire           b_we,
    input  wire  [DW-1:0] b_d,
    output logic [DW-1:0] b_q
);
    logic [DW-1:0] mem [0:(1<<AW)-1] /* verilator public_flat_rw */;
    // Assignment pattern rather than a for loop: Quartus caps constant loops
    // at 5000 iterations, and the largest memory here is 24576 bytes.
    initial mem = '{default: '0};
    always_ff @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_d;
        a_q <= mem[a_addr];
        if (b_we) mem[b_addr] <= b_d;
        b_q <= mem[b_addr];
    end
endmodule

`default_nettype wire
