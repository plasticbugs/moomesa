//------------------------------------------------------------------------------
// Konami 054539 PCM sound chip, written from MAME's model
// (ref/mame/k054539.cpp, sound_stream_update and write/read), which is the
// oracle the sound is compared against (docs/hardware.md 6).
//
// At each 48 kHz sample tick (18.432 MHz / 384) the eight channels are worked
// out one after another, each exactly as MAME steps it: 8-bit PCM, 16-bit PCM
// or 4-bit DPCM, forward or reversed, with the loop and end markers, the
// reverb send into a 0x2000-word ring in the chip's RAM, and the channel's
// position written back to its registers.  The sample ROM is read a byte at a
// time through the `rom` port.  Volume and pan use MAME's tables in Q16
// (tools/gen_k054539_tables.py).
//
// Registers live in block RAM except what the per-sample pass changes or
// needs every time (key-on bits 22C, control 22F, the channel positions and
// their key-on latches), which are flops.  The core holds a Z80 write off
// while `busy`, so that, as in MAME, every write lands between two samples,
// and holds a 22D read until `rd_busy` falls.
//
// Not modelled: the timer (22F bit 5; not connected on this board), the
// analogue input pan (13F), DJ Main's alternate register behaviours.
//------------------------------------------------------------------------------
`default_nettype none

module k054539 (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_snd,        // 48 kHz

    // Z80 side: `we`/`re` one pulse per access; dout valid with re + 1
    input  logic        cs,
    input  logic        we,
    input  logic        re,
    input  logic  [9:0] addr,
    input  logic  [7:0] din,
    output logic  [7:0] dout,
    output logic        busy,           // the per-sample pass: hold writes off
    output logic        rd_busy,        // a 22D read is waiting for its byte

    // sample ROM (2 MB)
    output logic        rom_req,
    output logic [20:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,

    // MAME's lval / rval in sample units (before the board's routing gains)
    output logic signed [17:0] out_l,
    output logic signed [17:0] out_r,
    output logic        overrun,        // a tick arrived with the pass still running (sticky)
    output logic [15:0] worst,          // most clocks a pass took (saturating)
    output logic  [7:0] worst_reads     // most ROM reads a pass made (saturating)
);
    `include "k054539_tables.svh"

    // ------------------------------------------------------------ registers
    logic  [7:0] regs [1024];           // 000-22F; the flops below shadow some
    logic  [9:0] ra;                    // engine read address
    logic  [7:0] rq, zq;
    always_ff @(posedge clk) begin
        if (z_we_ram) regs[addr] <= din;
        zq <= regs[addr];
        rq <= regs[ra];
    end
    logic  [7:0] r22c, r22f, romsel;
    logic [16:0] cur_ptr;
    logic [23:0] pos   [8];             // channel position registers 0C-0E
    logic [23:0] plat  [8];             // their key-on latches
    wire         regupdate = !r22f[7];
    wire         latch     = r22f[0];   // UPDATE_AT_KEYON, MAME's default

    // ------------------------------------------------------------ reverb RAM
    // 32 KB, little-endian words: word i = {byte 2i+1, byte 2i}.  One port:
    // the pass owns it while `busy`; the Z80's byte accesses (a boot-time
    // test through 22D) happen only between passes.
    logic [1:0][7:0] ram [16384];
    logic [13:0] rw_a;
    logic [15:0] rw_q, rw_d;
    logic        rw_we;
    logic [14:0] cb_a;                  // CPU byte address
    logic        cb_we;
    logic  [7:0] cb_d, cb_q;
    wire  [13:0] ram_a  = busy ? rw_a : cb_a[14:1];
    wire   [1:0] ram_be = rw_we ? 2'b11 : (cb_we ? (cb_a[0] ? 2'b10 : 2'b01) : 2'b00);
    wire  [15:0] ram_d  = rw_we ? rw_d : {cb_d, cb_d};
    always_ff @(posedge clk) begin
        if (ram_be[1]) ram[ram_a][1] <= ram_d[15:8];
        if (ram_be[0]) ram[ram_a][0] <= ram_d[7:0];
        rw_q <= ram[ram_a];
    end
    assign cb_q = cb_a[0] ? rw_q[15:8] : rw_q[7:0];
    wire [14:0] ptr_ram = {cur_ptr[16], cur_ptr[13:0]};   // (ptr & 0x3FFF) | (ptr & 0x10000) >> 2

    // ------------------------------------------------------------ Z80 side
    logic z_we_ram;
    logic z_rd_pend, z_rd_rom;          // 22D read waiting for ROM
    logic [7:0] z_rd_data;
    logic       z_rd_sel;               // 0: register / flop, 1: z_rd_data
    logic [9:0] z_ra;
    assign rd_busy = z_rd_pend;

    logic [2:0] wch;
    logic [4:0] wreg;
    always_comb begin
        wch  = addr[7:5];
        wreg = addr[4:0];
    end
    wire is_posreg = (addr < 10'h100) && (wreg >= 5'hC) && (wreg <= 5'hE);
    wire [1:0] posb = 2'(wreg - 5'hC);

    // engine interface for keyoff and position write-back
    logic       e_keyoff;
    logic [2:0] e_ch;
    logic       e_posw;
    logic [23:0] e_pos;

    always_ff @(posedge clk) begin
        z_we_ram <= 1'b0;
        cb_we    <= 1'b0;
        if (zr_done) begin z_rd_data <= zr_byte; z_rd_pend <= 1'b0; end
        if (e_keyoff && regupdate) r22c[e_ch] <= 1'b0;
        if (e_posw && regupdate) pos[e_ch] <= e_pos;
        if (we && cs && !busy) begin
            if (latch && is_posreg)
                plat[wch][8 * posb +: 8] <= din;
            else begin
                z_we_ram <= 1'b1;
                if (is_posreg) pos[wch][8 * posb +: 8] <= din;
                case (addr)
                    10'h214: for (int c = 0; c < 8; c++) if (din[c]) begin
                        if (latch) pos[c] <= plat[c];
                        if (regupdate) r22c[c] <= 1'b1;
                    end
                    10'h215: for (int c = 0; c < 8; c++) if (din[c] && regupdate) r22c[c] <= 1'b0;
                    10'h22C: r22c <= din;
                    10'h22D: begin
                        if (romsel == 8'h80) begin cb_a <= ptr_ram; cb_d <= din; cb_we <= 1'b1; end
                        cur_ptr <= cur_ptr + 17'd1;
                    end
                    10'h22E: begin romsel <= din; cur_ptr <= 17'd0; end
                    10'h22F: r22f <= din;
                    default: ;
                endcase
            end
        end
        // reads: 22D steps the read-back pointer; everything else is a register
        if (re && cs) begin
            z_ra <= addr;
            z_rd_sel <= 1'b0;
            if (addr == 10'h22D) begin
                z_rd_sel <= 1'b1;
                if (!r22f[4]) z_rd_data <= 8'd0;
                else if (romsel == 8'h80) begin
                    cb_a <= ptr_ram; z_rd_pend <= 1'b1; z_rd_rom <= 1'b0;
                    cur_ptr <= cur_ptr + 17'd1;
                end else begin
                    z_rd_pend <= 1'b1; z_rd_rom <= 1'b1;
                    cur_ptr <= cur_ptr + 17'd1;
                end
            end
        end
        if (rst) begin
            r22c <= 8'd0; r22f <= 8'd0; romsel <= 8'd0; cur_ptr <= 17'd0; z_rd_pend <= 1'b0;
        end
    end
    always_comb begin
        if (z_rd_sel)                                             dout = z_rd_data;
        else if (z_ra == 10'h22C)                                 dout = r22c;
        else if (z_ra == 10'h22F)                                 dout = r22f;
        else if (z_ra < 10'h100 && z_ra[4:0] >= 5'hC && z_ra[4:0] <= 5'hE)
                                                                  dout = pos[z_ra[7:5]][8 * (z_ra[4:0] - 5'hC) +: 8];
        else                                                      dout = zq;
    end

    // ------------------------------------------------------------ the pass
    typedef enum logic [4:0] {
        P_IDLE, P_RV0, P_RV1, P_RV2, P_CH, P_RD, P_RDW, P_SETUP, P_STEP, P_FETCH, P_FWAIT,
        P_BYTE, P_ENDCHK, P_DONE, P_REVR, P_REVW, P_NEXT, P_OUT, P_ZROM, P_ZRAM
    } pst_t;
    pst_t ps;
    logic  [2:0] ch;
    logic  [3:0] ri;                    // register fetch index
    logic  [7:0] cr [16];               // this channel's registers as fetched
    logic [12:0] rvpos;
    logic signed [39:0] lacc, racc;
    // per-channel state (MAME's struct channel)
    logic signed [31:0] c_pos [8];
    logic signed [31:0] c_frac [8];
    logic signed [15:0] c_val [8], c_pval [8];
    // working copy
    logic signed [31:0] wpos, wfrac, delta, fdelta, pdelta;
    logic signed [15:0] wval, wpval;
    logic  [1:0] typ;
    logic        lpf, reloaded, second;
    logic  [7:0] b0;
    logic [23:0] lpos;
    logic [16:0] lg, rg;
    logic [15:0] rbg;
    logic [12:0] widx;

    // gains: voltab * pantab >> 16, voltab[vol + rvol, capped] / 2
    function automatic [3:0] panidx(input [7:0] p);
        if (p >= 8'h81 && p <= 8'h8F)      panidx = 4'(p - 8'h81);
        else if (p >= 8'h11 && p <= 8'h1F) panidx = 4'(p - 8'h11);
        else                               panidx = 4'd7;
    endfunction

    // the byte (or word) just read, as MAME's cur_val
    logic signed [15:0] dpcm_step;
    always_comb begin
        case (wpos[0] ? b0[7:4] : b0[3:0])
            4'd0: dpcm_step = 16'sd0;      4'd1: dpcm_step = 16'sd256;
            4'd2: dpcm_step = 16'sd512;    4'd3: dpcm_step = 16'sd1024;
            4'd4: dpcm_step = 16'sd2048;   4'd5: dpcm_step = 16'sd4096;
            4'd6: dpcm_step = 16'sd8192;   4'd7: dpcm_step = 16'sd16384;
            4'd8: dpcm_step = 16'sd0;      4'd9: dpcm_step = -16'sd16384;
            4'd10: dpcm_step = -16'sd8192; 4'd11: dpcm_step = -16'sd4096;
            4'd12: dpcm_step = -16'sd2048; 4'd13: dpcm_step = -16'sd1024;
            4'd14: dpcm_step = -16'sd512;  default: dpcm_step = -16'sd256;
        endcase
    end

    always_ff @(posedge clk) begin
        rw_we <= 1'b0;
        zr_done <= 1'b0;
        e_keyoff <= 1'b0;
        e_posw <= 1'b0;
        // a tick that finds the chip busy with a read-back waits for it; one
        // that finds a pass still running is a pass missed (MAME never misses)
        if (cen_snd && busy) overrun <= 1'b1;
        if (busy && pcyc != 16'hFFFF) pcyc <= pcyc + 16'd1;
        if (rom_req && rom_ack && busy && preads != 8'hFF) preads <= preads + 8'd1;
        case (ps)
            P_IDLE: begin
                if (z_rd_pend && z_rd_rom && !zr_done) begin
                    rom_addr <= 21'({romsel, 17'd0} + {4'd0, cur_ptr - 17'd1});
                    rom_req <= 1'b1; ps <= P_ZROM;
                end else if (z_rd_pend && !zr_done) ps <= P_ZRAM;
                else if (tick && !r22f[0]) tick <= 1'b0;
                else if (tick) begin
                    tick <= 1'b0;
                    busy <= 1'b1; pcyc <= 16'd0; preads <= 8'd0;
                    rw_a <= {1'b0, rvpos};
                    ps <= P_RV0;
                end
            end
            P_ZROM: if (rom_ack) begin
                rom_req <= 1'b0; zr_done <= 1'b1; zr_byte <= rom_q; ps <= P_IDLE;
            end
            P_ZRAM: begin zr_done <= 1'b1; zr_byte <= cb_q; ps <= P_IDLE; end
            // ---- reverb tap: lval = rval = rbase[pos]; rbase[pos] = 0
            P_RV0: ps <= P_RV1;
            P_RV1: begin
                lacc <= 40'($signed(rw_q)) <<< 16;
                racc <= 40'($signed(rw_q)) <<< 16;
                rw_d <= 16'd0; rw_we <= 1'b1;
                ch <= 3'd0;
                ps <= P_CH;
            end
            // ---- channel ch
            P_CH: begin
                if (!r22c[ch]) ps <= P_NEXT;
                else begin ri <= 4'd0; ra <= {2'b00, ch, 5'd0}; ps <= P_RD; end
            end
            P_RD: begin
                // fetch 00-0A of the channel and its two bytes at 200 + 2 ch
                ps <= P_RDW;
            end
            P_RDW: begin
                cr[ri] <= rq;
                ri <= ri + 4'd1;
                if (ri == 4'd12) ps <= P_SETUP;
                else begin
                    ra <= (ri + 4'd1 < 4'd11) ? {2'b00, ch, 5'(ri + 4'd1)}
                                              : {6'b100000, ch, 1'(ri + 4'd1 - 4'd11)};
                    ps <= P_RD;
                end
            end
            P_SETUP: begin
                logic [7:0] vol, bval;
                logic [3:0] p;
                logic [13:0] rd;
                logic signed [31:0] d;
                vol = cr[3];
                bval = (9'(cr[3]) + 9'(cr[4]) > 9'd255) ? 8'd255 : 8'(cr[3] + cr[4]);
                p = panidx(cr[5]);
                lg  <= 17'((33'(k539_vol(vol)) * 33'(k539_pan(p))) >> 16);
                rg  <= 17'((33'(k539_vol(vol)) * 33'(k539_pan(4'd14 - p))) >> 16);
                rbg <= k539_vol(bval) >> 1;
                rd = 14'(({cr[7], cr[6]} >> 3) + {3'd0, rvpos});
                widx <= 13'(rd + {1'b0, rvpos});
                typ <= cr[11][3:2];
                lpf <= cr[12][0];
                lpos <= {cr[10], cr[9], cr[8]};
                d = 32'({8'd0, cr[2], cr[1], cr[0]});
                if (cr[11][5]) begin delta <= -d; fdelta <= 32'sh10000; pdelta <= -32'sd1; end
                else begin delta <= d; fdelta <= -32'sh10000; pdelta <= 32'sd1; end
                // a changed position register restarts the channel's state
                if (32'(pos[ch]) != c_pos[ch]) begin
                    wpos <= 32'(pos[ch]); wfrac <= 32'sd0; wval <= 16'sd0; wpval <= 16'sd0;
                end else begin
                    wpos <= c_pos[ch]; wfrac <= c_frac[ch]; wval <= c_val[ch]; wpval <= c_pval[ch];
                end
                ps <= P_STEP;
                second <= 1'b0;
            end
            P_STEP: begin
                // first entry: advance the fraction by delta (DPCM works in nibbles)
                if (!second) begin
                    second <= 1'b1;
                    if (typ == 2'd2) begin
                        logic signed [31:0] f2, p2;
                        p2 = wpos <<< 1; f2 = wfrac <<< 1;
                        if (f2[16]) begin f2 = f2 & 32'shFFFF; p2 = p2 | 32'sd1; end
                        wpos <= p2; wfrac <= f2 + delta;
                    end else if (typ == 2'd3) ps <= P_DONE;          // unknown type: nothing
                    else wfrac <= wfrac + delta;
                end else if ((wfrac & ~32'shFFFF) != 0) begin
                    // one step of `while (cur_pfrac & ~0xffff)`
                    wfrac <= wfrac + fdelta;
                    wpos  <= wpos + ((typ == 2'd1) ? (pdelta <<< 1) : pdelta);
                    wpval <= wval;
                    reloaded <= 1'b0;
                    ps <= P_FETCH;
                end else ps <= P_DONE;
            end
            P_FETCH: begin
                rom_addr <= (typ == 2'd2) ? 21'(wpos >>> 1) : 21'(wpos);
                rom_req <= 1'b1;
                ps <= P_FWAIT;
            end
            P_FWAIT: if (rom_ack) begin
                rom_req <= 1'b0;
                b0 <= rom_q;
                ps <= P_BYTE;
            end
            P_BYTE: begin
                // 16-bit: the high byte follows the low one
                if (typ == 2'd1 && !second_byte) begin
                    second_byte <= 1'b1; lo_byte <= b0;
                    rom_addr <= 21'(wpos + 32'sd1); rom_req <= 1'b1;
                    ps <= P_FWAIT;
                end else begin
                    second_byte <= 1'b0;
                    ps <= P_ENDCHK;
                end
            end
            P_ENDCHK: begin
                logic endm;
                endm = (typ == 2'd0) ? (b0 == 8'h80) :
                       (typ == 2'd1) ? ({b0, lo_byte} == 16'h8000) : (b0 == 8'h88);
                if (endm && lpf && !reloaded) begin
                    // loop: back to the loop address and read again
                    reloaded <= 1'b1;
                    wpos <= (typ == 2'd2) ? 32'({lpos, 1'b0}) : 32'(lpos);
                    ps <= P_FETCH;
                end else if (endm) begin
                    e_keyoff <= 1'b1; e_ch <= ch;
                    wval <= 16'sd0;
                    ps <= P_DONE;                                    // break
                end else begin
                    case (typ)
                        2'd0: wval <= {b0, 8'd0};
                        2'd1: wval <= {b0, lo_byte};
                        default: begin
                            logic signed [16:0] v;
                            v = 17'(wpval) + 17'(dpcm_step);
                            wval <= (v < -17'sd32768) ? -16'sd32768 : (v > 17'sd32767) ? 16'sd32767 : 16'(v);
                        end
                    endcase
                    ps <= P_STEP;
                end
            end
            P_DONE: begin
                logic signed [31:0] fp, pp;
                fp = wfrac; pp = wpos;
                if (typ == 2'd2) begin
                    fp = fp >>> 1;
                    if (pp[0]) fp = fp | 32'sh8000;
                    pp = pp >>> 1;
                end
                lacc <= lacc + 40'(wval) * 40'($signed({1'b0, lg}));
                racc <= racc + 40'(wval) * 40'($signed({1'b0, rg}));
                c_pos[ch] <= pp; c_frac[ch] <= fp; c_val[ch] <= wval; c_pval[ch] <= wpval;
                e_posw <= 1'b1; e_ch <= ch; e_pos <= 24'(pp);
                rw_a <= {1'b0, widx};
                ps <= P_REVR;
            end
            P_REVR: ps <= P_REVW;
            P_REVW: begin
                // rbase[...] += int16(cur_val * rbvol), truncated toward zero
                logic signed [33:0] pr;
                logic signed [15:0] add;
                pr = 34'(wval) * 34'($signed({1'b0, rbg}));
                add = (pr < 0) ? (16'd0 - 16'((34'sd0 - pr) >>> 16)) : 16'(pr >>> 16);
                rw_d <= rw_q + add; rw_we <= 1'b1;
                ps <= P_NEXT;
            end
            P_NEXT: begin
                if (ch == 3'd7) ps <= P_OUT;
                else begin ch <= ch + 3'd1; ps <= P_CH; end
            end
            P_OUT: begin
                out_l <= 18'(lacc >>> 16);
                out_r <= 18'(racc >>> 16);
                rvpos <= rvpos + 13'd1;
                busy <= 1'b0;
                if (pcyc > worst) worst <= pcyc;
                if (preads > worst_reads) worst_reads <= preads;
                ps <= P_IDLE;
            end
            default: ps <= P_IDLE;
        endcase
        if (cen_snd) tick <= 1'b1;      // after the state machine, so a new tick is never lost
        if (rst) begin
            ps <= P_IDLE; busy <= 1'b0; rom_req <= 1'b0; rvpos <= 13'd0; overrun <= 1'b0;
            worst <= 16'd0; worst_reads <= 8'd0; tick <= 1'b0;
            out_l <= 18'sd0; out_r <= 18'sd0; second_byte <= 1'b0;
            for (int c = 0; c < 8; c++) begin c_pos[c] <= 32'sd0; c_frac[c] <= 32'sd0; c_val[c] <= 16'sd0; c_pval[c] <= 16'sd0; end
        end
    end
    logic       second_byte;
    logic [7:0] lo_byte;
    logic       zr_done;
    logic        tick;
    logic [15:0] pcyc;
    logic  [7:0] preads;
    logic [7:0] zr_byte;
endmodule

`default_nettype wire
