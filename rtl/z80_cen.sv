//------------------------------------------------------------------------------
// Z80 with a clock enable: tv80's core (modules/cpu-tv80, Guy Hutchison, MIT)
// under the bus-signal logic of its own tv80s wrapper, with every state change
// qualified by `cen` so the CPU runs at 8 MHz inside the 96 MHz domain.
// tv80s ties the core's enable high; this is tv80s with the enable brought out
// and nothing else changed (T2Write = 1, IOWait = 1, Mode 0).
//------------------------------------------------------------------------------
`default_nettype none

module z80_cen (
    input  logic        clk,
    input  logic        cen,
    input  logic        reset_n,
    input  logic        wait_n,
    input  logic        int_n,
    input  logic        nmi_n,
    output logic        m1_n,
    output logic        mreq_n,
    output logic        iorq_n,
    output logic        rd_n,
    output logic        wr_n,
    output logic [15:0] A,
    input  logic  [7:0] di,
    output logic  [7:0] dout
);
    logic       intcycle_n, no_read, write, iorq;
    logic [7:0] di_reg;
    logic [6:0] mcycle, tstate;

    /* verilator lint_off PINCONNECTEMPTY */
    tv80_core #(.Mode(0), .IOWait(1)) u_core (
        .cen(cen), .m1_n(m1_n), .iorq(iorq), .no_read(no_read), .write(write),
        .rfsh_n(), .halt_n(), .wait_n(wait_n), .int_n(int_n), .nmi_n(nmi_n),
        .reset_n(reset_n), .busrq_n(1'b1), .busak_n(), .clk(clk),
        .IntE(), .stop(), .A(A), .dinst(di), .di(di_reg), .dout(dout),
        .mc(mcycle), .ts(tstate), .intcycle_n(intcycle_n)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_n <= 1'b1; wr_n <= 1'b1; iorq_n <= 1'b1; mreq_n <= 1'b1; di_reg <= 8'd0;
        end else if (cen) begin
            rd_n <= 1'b1; wr_n <= 1'b1; iorq_n <= 1'b1; mreq_n <= 1'b1;
            if (mcycle[0]) begin
                if (tstate[1] || (tstate[2] && !wait_n)) begin
                    rd_n   <= intcycle_n ? 1'b0 : 1'b1;
                    mreq_n <= intcycle_n ? 1'b0 : 1'b1;
                    iorq_n <= intcycle_n;
                end
            end else begin
                if ((tstate[1] || (tstate[2] && !wait_n)) && !no_read && !write) begin
                    rd_n   <= 1'b0;
                    iorq_n <= ~iorq;
                    mreq_n <= iorq;
                end
                if ((tstate[1] || (tstate[2] && !wait_n)) && write) begin
                    wr_n   <= 1'b0;
                    iorq_n <= ~iorq;
                    mreq_n <= iorq;
                end
            end
            if (tstate[2] && wait_n && !write && !no_read) di_reg <= di;
        end
    end
endmodule

`default_nettype wire
