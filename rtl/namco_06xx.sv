//------------------------------------------------------------------------------
// Namco 06xx: the Z80's interface to up to four Namco 5xXX customs.
//
// Semantics are MAME 0.288 src/mame/namco/namco06.cpp:
//
// * control register: bits 3:0 chip selects, bit 4 read(1)/write(0), bits 7:5
//   clock divider (0 stops the clock).
// * The clock is a timer running at twice the divided rate. It is aligned to the
//   48 kHz base clock (MASTER/8/64): after a control write with a non-zero
//   divider the first edge is the next base tick strictly after the write, then
//   one edge every 2^(n-1) base ticks (n = control[7:5]).
// * On every edge the timer state toggles. On the "true" half the rw line of
//   every chip is set to control[4]; NMI is asserted on the true half unless
//   the read stretch is pending (the first NMI after a read-mode control write is
//   suppressed to give the chip a cycle to answer); chip selects follow
//   control[i] && state.
// * Reads of the data port AND together the selected chips (0xff if none) and
//   return 0 in write mode. Writes go to every selected chip, and are ignored in
//   read mode.
//------------------------------------------------------------------------------
`default_nettype none

module namco_06xx (
    input  wire         clk,
    input  wire         reset,
    input  wire         cen_base,       // 48 kHz base clock tick

    // Z80 side
    input  wire         data_wr,        // 1-cycle strobe: write to the data port
    input  wire         ctrl_wr,        // 1-cycle strobe: write to the control port
    input  wire  [7:0]  din,
    output logic [7:0]  data_q,         // what a data port read returns now
    output logic [7:0]  ctrl_q,         // what a control port read returns now
    output logic        nmi = 1'b0,     // level, active high

    // customs side
    output logic [3:0]  chip_sel = '0,  // levels, active high (-> MCU IRQ lines)
    output logic        rw = 1'b0,      // level, 1 = read (driven on the true half)
    output logic [3:0]  chip_wr = '0,   // 1-cycle write strobes
    output logic [7:0]  chip_wdata = '0,
    input  wire  [31:0] chip_rdata      // {chip3, chip2, chip1, chip0}; 0xff if unbound
);

    logic [7:0] control      = '0;
    logic       timer_state  = 1'b0;
    logic       read_stretch = 1'b0;
    logic       running      = 1'b0;
    logic [6:0] period       = 7'd1;    // base ticks per timer edge
    logic [6:0] count        = 7'd0;    // base ticks until the next edge

    assign ctrl_q = control;

    always_comb begin
        data_q = 8'hff;
        for (int i = 0; i < 4; i++)
            if (control[i]) data_q = data_q & chip_rdata[i*8 +: 8];
        if (!control[4]) data_q = 8'h00;
    end

    always_ff @(posedge clk) begin
        chip_wr <= '0;
        if (reset) begin
            control <= '0;
            timer_state <= 1'b0;
            read_stretch <= 1'b0;
            running <= 1'b0;
            count <= '0;
            nmi <= 1'b0;
            chip_sel <= '0;
        end else begin
            // timer edge on this base tick (a control write in the same cycle
            // re-arms instead: its first edge is the next tick)
            if (cen_base && running && !ctrl_wr) begin
                if (count == 7'd1) begin
                    count <= period;
                    timer_state <= ~timer_state;
                    if (!timer_state) rw <= control[4];
                    nmi <= !timer_state && !read_stretch;
                    read_stretch <= 1'b0;
                    chip_sel <= control[3:0] & {4{~timer_state}};
                end else begin
                    count <= count - 7'd1;
                end
            end

            if (ctrl_wr) begin
                control <= din;
                if (din[7:5] == 3'd0) begin
                    running <= 1'b0;
                    timer_state <= 1'b0;
                    nmi <= 1'b0;
                    chip_sel <= '0;
                end else begin
                    if (din[4]) begin
                        nmi <= 1'b0;
                        read_stretch <= 1'b1;
                    end else begin
                        read_stretch <= 1'b0;
                    end
                    running <= 1'b1;
                    count <= 7'd1;
                    period <= 7'd1 << (din[7:5] - 3'd1);
                end
            end

            if (data_wr && !control[4]) begin
                chip_wr <= control[3:0];
                chip_wdata <= din;
            end
        end
    end

endmodule

`default_nettype wire
