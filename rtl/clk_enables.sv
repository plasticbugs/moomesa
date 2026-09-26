//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md section 1).
//
// Every clock on the board is an exact divider of 96 MHz, so these are plain
// counters with no fractional accumulator anywhere:
//
//   cen_phi1 / cen_phi2   fx68k's two phases, alternating: a 16 MHz 68000
//   cen_z80               8 MHz
//   cen_ym / cen_ym2      the YM2151's 4 MHz clock and its half (jt51)
//   cen_snd               48 kHz, one K054539 sample (18.432 MHz / 384)
//   cen_pix               the video dot clock, 96 / 12 = 8 MHz
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic rst,
    // One pulse just after each edge of the platform's video clock, which
    // restarts the dot divider.  Without it the dot enable would sit at
    // whatever phase the reset left it in, and the pixel handed to the video
    // clock could be sampled while it changes (METHODOLOGY section 5.4).
    input  logic pix_sync,
    input  logic pause,     // hold both CPUs and the sound chips; see below
    output logic cen_phi1,
    output logic cen_phi2,
    output logic cen_z80,
    output logic cen_ym,
    output logic cen_ym2,
    output logic cen_snd,
    output logic cen_pix
);
    logic  [5:0] div;       // 0..47: 68000, Z80 and YM2151 all divide this
    logic  [3:0] dpix;      // 0..11
    logic [10:0] dsnd;      // 0..1999

    always_ff @(posedge clk) begin
        if (rst) begin
            div  <= 6'd0;
            dpix <= 4'd0;
            dsnd <= 11'd0;
        end else begin
            if (!pause) begin
                div  <= (div == 6'd47) ? 6'd0 : div + 6'd1;
                dsnd <= (dsnd == 11'd1999) ? 11'd0 : dsnd + 11'd1;
            end
            if (pix_sync)            dpix <= 4'd0;
            else if (dpix == 4'd11)  dpix <= 4'd0;
            else                     dpix <= dpix + 4'd1;
        end
    end

    // Pausing freezes the divider and masks the enables with the same signal,
    // so every count still produces exactly one pulse: nothing is skipped and
    // nothing fires twice, and fx68k's two phases come back in the order they
    // stopped.  The dot divider is separate and keeps running, which is what
    // leaves the picture on the screen behind the Pocket's menu (METHODOLOGY
    // 5.5: the menu-open signal is not a reset).
    //
    // Every enable is a register, decoded from the divider one clock ahead:
    // they fan out to every register of the CPUs, and a decode of a 6-bit
    // counter in front of that fan-out was the machine's slowest path.  A
    // pulse registered just before a pause still fires; the frozen divider
    // then makes no more, so the count-to-pulse rule above holds.
    wire run = !pause;
    wire [2:0] d6  = 3'(div % 6'd6);
    wire [3:0] d12 = 4'(div % 6'd12);
    wire [4:0] d24 = 5'(div % 6'd24);
    always_ff @(posedge clk) begin
        cen_phi1 <= run && (d6 == 3'd5);                    // 96 / 6 = 16 MHz
        cen_phi2 <= run && (d6 == 3'd2);
        cen_z80  <= run && (d12 == 4'd0);                   // 8 MHz
        cen_ym   <= run && (d24 == 5'd4);                   // 4 MHz
        cen_ym2  <= run && (div == 6'd4);                   // 2 MHz
        cen_snd  <= run && (dsnd == 11'd1999);              // 48 kHz
        cen_pix  <= pix_sync || (dpix == 4'd11);            // 8 MHz, on the clock dpix is 0
        if (rst) begin
            cen_phi1 <= 1'b0; cen_phi2 <= 1'b0; cen_z80 <= 1'b0;
            cen_ym <= 1'b0; cen_ym2 <= 1'b0; cen_snd <= 1'b0; cen_pix <= 1'b0;
        end
    end
endmodule

`default_nettype wire
