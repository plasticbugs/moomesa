//------------------------------------------------------------------------------
// K053246/K053247 sprites (docs/hardware.md 7.4; the reference is
// tools/moo_render.py draw_sprites and blit).
//
// Three jobs:
//
//   DMA   at vblank, when K053246 reg 5 bit 4 is set: walk the 256 sprite-RAM
//         entries at a 0x80-word stride, copy each active one (word 0 bit 15)
//         into the chip's list, packed to the front, and clear word 0 of the
//         rest (moo.cpp object_dma).  `dma_done` pulses at the end.
//   SORT  after the DMA (or at vblank if there was none): MAME's exchange
//         sort of the active entries by z-code, done literally, because the
//         order it leaves equal z-codes in decides which sprite claims a
//         pixel.  Drawing is from the end of that list (nearest first).
//   LINE  on `start`, draw every sprite that crosses bitmap line `line` into
//         the line buffer half `buf_sel`: cell rows fetched through the sprite
//         port, stretched with MAME's drawgfxzoom stepping, and written with
//         PIXEL_OP_REMAP_TRANSTABLE32_PRIORITY's rule -- the first opaque pen
//         claims the pixel whether or not it will show; a shadow pen marks an
//         unclaimed, unshadowed pixel.  Whether each shows is the mixer's
//         decision (it knows the layers under it).
//
// Claim and shadow flags are flops, so a pixel is written every clock and a
// half is cleared in one.  The sprite data behind them is block RAM:
//   claim  {palette index[10:0], class[1:0]}   class: which sorted layers hide it
//   shadow {preset[1:0], class[1:0]}
//
// Deviation from MAME, on a path the game was never seen to use (no shadow in
// 20 minutes of census): MAME skips a shadow pen whose priority mask fails and
// lets a farther shadow sprite shade the pixel instead; here the first shadow
// pen always marks it and the mask is applied at mix time.
//------------------------------------------------------------------------------
`default_nettype none

module moo_sprites (
    input  logic        clk,
    input  logic        rst,

    // K053246 registers, byte-wide (0C2000-0C2007)
    input  logic        reg_we,
    input  logic  [2:0] reg_addr,
    input  logic  [7:0] reg_d,
    output logic  [7:0] k246 [8],

    // from the K053251 (static in this game, but read live)
    input  logic  [6:0] colorbase,      // CI0 palette base, in 16-colour units
    input  logic  [5:0] lp0, lp1, lp2,  // sorted layer priorities, back to front

    input  logic        vblank_start,   // pulse
    output logic        dma_done,       // pulse, end of an object DMA
    output logic        dma_busy,

    // sprite RAM, second port (CPU view, 32K words), one clock latency
    output logic [14:0] sr_addr,
    input  logic [15:0] sr_q,

    // line engine
    input  logic        start,
    input  logic  [8:0] line,
    input  logic        buf_sel,
    output logic        busy,

    // sprite ROM rows
    output logic        rom_req,
    output logic [19:0] rom_addr,
    input  logic        rom_ack,
    input  logic [63:0] rom_q,

    // mixer read port: half `mx_buf`, bitmap x `mx_x`; data one clock later
    input  logic        mx_buf,
    input  logic  [8:0] mx_x,
    output logic        mx_claim,
    output logic [12:0] mx_cdata,
    output logic        mx_shadow,
    output logic  [3:0] mx_sdata,

    // bench back door into the list (word address {entry, word})
    input  logic        dbg_we,
    input  logic [10:0] dbg_addr,
    input  logic [15:0] dbg_d,
    input  logic        dbg_sort,       // pulse: sort without a DMA

    // statistics
    output logic [15:0] worst_line,     // most clocks a line took, saturating
    output logic        missed          // a line was not finished in time (sticky)
);
    // ------------------------------------------------------------ registers
    always_ff @(posedge clk) begin
        if (rst) for (int i = 0; i < 8; i++) k246[i] <= 8'd0;
        else if (reg_we) k246[reg_addr] <= reg_d;
    end

    // ------------------------------------------------------------ list RAM
    // eight banks of 256 x 16, one per word of an entry, read all at once
    logic [15:0] lst [8][256];
    logic  [7:0] l_raddr;
    logic [15:0] l_q [8];
    logic        l_we;
    logic  [2:0] l_wbank;
    logic  [7:0] l_waddr;
    logic [15:0] l_wd;
    always_ff @(posedge clk) begin
        for (int b = 0; b < 8; b++) begin
            l_q[b] <= lst[b][l_raddr];
            if (dbg_we && dbg_addr[2:0] == 3'(b)) lst[b][dbg_addr[10:3]] <= dbg_d;
            else if (l_we && l_wbank == 3'(b)) lst[b][l_waddr] <= l_wd;
        end
    end

    // sorted list: {entry, z}
    logic [15:0] srt [256];
    logic  [7:0] s_raddr, s_waddr;
    logic [15:0] s_q, s_wd;
    logic        s_we;
    always_ff @(posedge clk) begin
        s_q <= srt[s_raddr];
        if (s_we) srt[s_waddr] <= s_wd;
    end

    // ------------------------------------------------------------ tables
    // zoom = (0x400000 + z/2) / z, 0x800000 for z = 0 (draw_single_sprite_gxcore)
    logic [23:0] ztab [1024];
    // 16.16 source step for a destination size w: (16 << 16) / w (drawgfxzoom_core)
    logic [20:0] rtab [2048];
    initial begin
        ztab[0] = 24'h800000;
        for (int z = 1; z < 1024; z++) ztab[z] = 24'((32'h400000 + (z >> 1)) / z);
        rtab[0] = 21'd0;
        for (int w = 1; w < 2048; w++) rtab[w] = 21'((32'd16 << 16) / w);
    end
    logic  [9:0] z_a0, z_a1;
    logic [23:0] z_q0, z_q1;
    logic [10:0] r_a;
    logic [20:0] r_q;
    always_ff @(posedge clk) begin
        z_q0 <= ztab[z_a0];
        z_q1 <= ztab[z_a1];
        r_q  <= rtab[r_a];
    end

    // ------------------------------------------------------------ DMA and sort
    typedef enum logic [3:0] {
        V_IDLE, V_DMA_RD, V_DMA_W0, V_DMA_CP, V_DMA_CLR,
        V_SCAN, V_SCANW, V_SCANC, V_SO_Y, V_SO_YW, V_SO_YQ, V_SO_X, V_SO_XW, V_SO_XC, V_SO_WY
    } vst_t;
    vst_t vs;
    logic  [7:0] v_lraddr, v_sraddr, e_lraddr, e_sraddr;
    assign l_raddr = (vs != V_IDLE) ? v_lraddr : e_lraddr;
    assign s_raddr = (vs != V_IDLE) ? v_sraddr : e_sraddr;
    logic  [8:0] d_src, d_dst;          // 0..256
    logic  [3:0] d_w;
    logic  [8:0] n_act;                 // active entries in the sorted list
    logic  [8:0] so_y, so_x, sc_i;
    logic [15:0] so_cur;                // {entry, z} held for position y

    assign dma_busy = (vs != V_IDLE);

    always_ff @(posedge clk) begin
        l_we     <= 1'b0;
        s_we     <= 1'b0;
        dma_done <= 1'b0;
        case (vs)
            V_IDLE: begin
                if (vblank_start && k246[5][4]) begin d_src <= 9'd0; d_dst <= 9'd0; vs <= V_DMA_RD; end
                else if (vblank_start || dbg_sort) begin sc_i <= 9'd0; n_act <= 9'd0; vs <= V_SCAN; end
            end
            // ---- object DMA
            V_DMA_RD: begin
                if (d_src == 9'd256) begin
                    if (d_dst == 9'd256) begin dma_done <= 1'b1; sc_i <= 9'd0; n_act <= 9'd0; vs <= V_SCAN; end
                    else vs <= V_DMA_CLR;
                end else begin
                    sr_addr <= {d_src[7:0], 7'd0};
                    d_w <= 4'd0;
                    vs <= V_DMA_W0;
                end
            end
            V_DMA_W0: vs <= V_DMA_CP;       // read in flight
            V_DMA_CP: begin
                // sr_q is word d_w of source entry d_src
                if (d_w == 4'd0 && !sr_q[15]) begin d_src <= d_src + 9'd1; vs <= V_DMA_RD; end
                else begin
                    l_we <= 1'b1; l_wbank <= d_w[2:0]; l_waddr <= d_dst[7:0]; l_wd <= sr_q;
                    if (d_w == 4'd7) begin
                        d_dst <= d_dst + 9'd1; d_src <= d_src + 9'd1; vs <= V_DMA_RD;
                    end else begin
                        d_w <= d_w + 4'd1;
                        sr_addr <= {d_src[7:0], 4'd0, 3'(d_w + 4'd1)};
                        vs <= V_DMA_W0;
                    end
                end
            end
            V_DMA_CLR: begin                // word 0 of every entry not filled
                l_we <= 1'b1; l_wbank <= 3'd0; l_waddr <= d_dst[7:0]; l_wd <= 16'd0;
                d_dst <= d_dst + 9'd1;
                if (d_dst == 9'd255) begin dma_done <= 1'b1; sc_i <= 9'd0; n_act <= 9'd0; vs <= V_SCAN; end
            end
            // ---- collect the active entries, in list order
            V_SCAN: begin
                if (sc_i == 9'd256) begin so_y <= 9'd0; vs <= V_SO_Y; end
                else begin v_lraddr <= sc_i[7:0]; vs <= V_SCANW; end
            end
            V_SCANW: vs <= V_SCANC;
            V_SCANC: begin
                if (l_q[0][15]) begin
                    s_we <= 1'b1; s_waddr <= n_act[7:0]; s_wd <= {sc_i[7:0], l_q[0][7:0]};
                    n_act <= n_act + 9'd1;
                end
                sc_i <= sc_i + 9'd1;
                vs <= V_SCAN;
            end
            // ---- the exchange sort (k053247_sprites_draw_common):
            //   for y: cur = lst[y]
            //     for x > y: if z(cur) <= z(lst[x]): lst[x] = cur; cur = lst[x]
            //     lst[y] = cur
            V_SO_Y: begin
                if (n_act < 9'd2 || so_y >= n_act - 9'd1) vs <= V_IDLE;
                else begin v_sraddr <= so_y[7:0]; vs <= V_SO_YW; end
            end
            V_SO_YW: vs <= V_SO_YQ;
            V_SO_YQ: begin so_cur <= s_q; so_x <= so_y + 9'd1; vs <= V_SO_X; end
            V_SO_X: begin v_sraddr <= so_x[7:0]; vs <= V_SO_XW; end
            V_SO_XW: vs <= V_SO_XC;
            V_SO_XC: begin
                if (so_cur[7:0] <= s_q[7:0]) begin
                    s_we <= 1'b1; s_waddr <= so_x[7:0]; s_wd <= so_cur;
                    so_cur <= s_q;
                end
                if (so_x == n_act - 9'd1) vs <= V_SO_WY;
                else begin so_x <= so_x + 9'd1; vs <= V_SO_X; end
            end
            V_SO_WY: begin
                s_we <= 1'b1; s_waddr <= so_y[7:0]; s_wd <= so_cur;
                so_y <= so_y + 9'd1;
                vs <= V_SO_Y;
            end
            default: vs <= V_IDLE;
        endcase
        if (rst) begin vs <= V_IDLE; n_act <= 9'd0; end
    end


    // ------------------------------------------------------------ line engine
    typedef enum logic [4:0] {
        E_IDLE, E_NEXT, E_S1, E_S2, E_L1, E_L2, E_Z1, E_G1, E_G2, E_V,
        E_R0, E_R1, E_R2, E_R3, E_C0, E_C1, E_C2, E_PIX, E_NX
    } est_t;
    est_t es;
    logic  [8:0] Y;
    logic        eb;
    logic  [8:0] ei;                          // sprites done this line
    logic [15:0] w0, w1, w6;
    logic  [9:0] wx, wy;
    logic [23:0] zx, zy;
    logic        nozoom;
    logic signed [16:0] ox, oy;
    logic  [2:0] xa, ya;
    logic  [1:0] wl, hl;
    logic  [3:0] k, cx;                       // cell row, cell column
    logic [26:0] accy, accx;
    logic signed [16:0] top, nxt;
    logic [11:0] dsth, m;
    logic  [5:0] ty;
    logic        fy, dbl, pass;
    logic  [3:0] row_a, row_b;
    logic signed [16:0] sx;
    logic [11:0] zw;
    logic        fx;
    logic  [5:0] tx;
    logic [20:0] dx;
    logic signed [33:0] acc, step;
    logic signed [16:0] pi, pi1;              // pixel index range within the cell
    logic [63:0] rowd;
    logic  [1:0] cls;
    logic  [6:0] pbase;
    logic        shd_on;
    logic  [1:0] preset;
    logic [15:0] cyc;

    logic [511:0] claim0, claim1, shd0, shd1;
    logic [12:0] cbuf [1024];
    logic  [3:0] sbuf [1024];
    logic        c_we, sh_we;
    logic  [9:0] c_wa;
    logic [12:0] c_wd;
    logic  [3:0] sh_wd;

    assign busy = (es != E_IDLE);

    localparam int XOFF [8] = '{0, 1, 4, 5, 16, 17, 20, 21};
    localparam int YOFF [8] = '{0, 2, 8, 10, 32, 34, 40, 42};
    function automatic [5:0] xoff(input [2:0] i); xoff = 6'(XOFF[i]); endfunction
    function automatic [5:0] yoff(input [2:0] i); yoff = 6'(YOFF[i]); endfunction

    // pen of source column c of a 64-bit row (spritelayout nibbles
    // 2,3,0,1,6,7,4,5, 10,11,8,9,14,15,12,13; nibble n is q[63-4n -: 4])
    function automatic [3:0] spen(input [63:0] q, input [3:0] c);
        logic [3:0] n;
        n = {c[3:2], ~c[1], c[0]};
        spen = q[63 - 4 * int'(n) -: 4];
    endfunction

    wire signed [16:0] offx = 17'($signed(16'({k246[0], k246[1]})));
    wire signed [16:0] offy = 17'($signed(16'({k246[2], k246[3]})));
    wire  [5:0] pri = w6[9:4];
    wire  [3:0] pen = spen(rowd, 4'(acc >>> 16));
    wire signed [16:0] X = sx + pi;
    wire  [8:0] Xu = X[8:0];
    wire        claimed  = eb ? claim1[Xu] : claim0[Xu];
    wire        shadowed = eb ? shd1[Xu]   : shd0[Xu];

    always_ff @(posedge clk) begin
        c_we  <= 1'b0;
        sh_we <= 1'b0;
        if (es != E_IDLE && cyc != 16'hFFFF) cyc <= cyc + 16'd1;
        case (es)
            E_IDLE: if (start) begin
                Y <= line; eb <= buf_sel; ei <= 9'd0; cyc <= 16'd0;
                if (buf_sel) begin claim1 <= '0; shd1 <= '0; end
                else         begin claim0 <= '0; shd0 <= '0; end
                es <= E_NEXT;
            end
            E_NEXT: begin
                if (ei >= n_act) es <= E_IDLE;
                else begin e_sraddr <= 8'(n_act - 9'd1 - ei); es <= E_S1; end
            end
            E_S1: es <= E_S2;
            E_S2: begin e_lraddr <= s_q[15:8]; es <= E_L1; end
            E_L1: es <= E_L2;
            E_L2: begin
                w0 <= l_q[0]; w1 <= l_q[1]; w6 <= l_q[6];
                wy <= l_q[2][9:0]; wx <= l_q[3][9:0];
                z_a0 <= l_q[4][9:0];
                z_a1 <= l_q[0][14] ? l_q[4][9:0] : l_q[5][9:0];
                nozoom <= (l_q[4][9:0] == 10'h40) && ((l_q[0][14] ? l_q[4][9:0] : l_q[5][9:0]) == 10'h40);
                es <= E_Z1;
            end
            E_Z1: es <= E_G1;
            E_G1: begin
                zy <= z_q0; zx <= z_q1;
                xa <= {w1[4], w1[2], w1[0]}; ya <= {w1[5], w1[3], w1[1]};
                wl <= w0[9:8]; hl <= w0[11:10];
                // wrap and global offsets: ox = (x - offx) & 1023, oy = (-y - offy) & 1023,
                // wrapped at 1024-384 and 1024-512, then the chip's dx/dy (-47, +23)
                begin
                    logic [9:0] ox1, oy1;
                    ox1 = 10'(17'(wx) - offx);
                    oy1 = 10'(17'sd0 - 17'(wy) - offy);
                    ox <= (ox1 >= 10'd640 ? 17'(ox1) - 17'sd1024 : 17'(ox1)) - 17'sd47;
                    oy <= (oy1 >= 10'd512 ? 17'(oy1) - 17'sd1024 : 17'(oy1)) - 17'sd23;
                end
                begin
                    logic [2:0] pc;
                    pc = (pri <= lp2) ? 3'd0 : (pri <= lp1) ? 3'd1 : (pri <= lp0) ? 3'd2 : 3'd3;
                    cls <= pc[1:0];
                end
                pbase  <= colorbase | {2'b00, w6[4:0]};
                shd_on <= (w6[11:10] != 2'd0);
                preset <= w6[11:10] - 2'd1;
                es <= E_G2;
            end
            E_G2: begin
                // the coordinates are the sprite's centre
                ox <= ox - 17'(({3'd0, zx} << wl) >> 13);
                oy <= oy - 17'(({3'd0, zy} << hl) >> 13);
                k <= 4'd0; accy <= 27'd0;
                es <= E_V;
            end
            E_V: begin
                // row k spans [oy + (zy*k + 0x800) >> 12, oy + (zy*(k+1) + 0x800) >> 12)
                logic signed [16:0] t0, t1;
                t0 = oy + 17'((accy + 27'h800) >> 12);
                t1 = oy + 17'((accy + 27'(zy) + 27'h800) >> 12);
                if (k == 4'd0 && $signed({8'd0, Y}) < t0) es <= E_NX;       // above the sprite
                else if ($signed({8'd0, Y}) < t1) begin
                    top <= t0; nxt <= t1; es <= E_R0;
                end else if (k == 4'((1 << hl) - 1)) es <= E_NX;             // below it
                else begin k <= k + 4'd1; accy <= accy + 27'(zy); end
            end
            E_R0: begin
                logic [3:0] h;
                logic mir;
                h = 4'(1 << hl);
                mir = w6[15];
                dsth <= 12'(nxt - top);
                m    <= 12'($signed({8'd0, Y}) - top);
                if (mir) begin
                    if ((!w0[13]) ^ ({k, 1'b0} >= {1'b0, h})) begin ty <= yoff(3'(h - 4'd1 - k + 4'(ya))); fy <= 1'b1; end
                    else begin ty <= yoff(3'(k + 4'(ya))); fy <= 1'b0; end
                end else begin
                    ty <= yoff(3'(w0[13] ? (h - 4'd1 - k + 4'(ya)) : (k + 4'(ya))));
                    fy <= w0[13];
                end
                dbl <= mir && (hl == 2'd0);                 // "Simpsons shadows": each cell twice
                r_a <= (12'(nxt - top) > 12'd2047) ? 11'd2047 : 11'(nxt - top);
                es <= E_R1;
            end
            E_R1: es <= E_R2;
            E_R2: begin
                // source row = (m * dy) >> 16, or (dsth - 1 - m) * dy >> 16 flipped
                logic [32:0] pa, pb;
                pa = 33'(m) * 33'(r_q);
                pb = 33'(12'(dsth - 12'd1 - m)) * 33'(r_q);
                row_a <= fy ? pb[19:16] : pa[19:16];
                row_b <= fy ? pa[19:16] : pb[19:16];      // the second blit's, y-flipped
                cx <= 4'd0; accx <= 27'd0; pass <= 1'b0;
                es <= E_C0;
            end
            E_C0: begin
                logic signed [16:0] s0, s1;
                logic [3:0] w;
                logic mirx, flx;
                w = 4'(1 << wl);
                mirx = w6[14];
                flx = w0[12] && !mirx;                      // mirror x overrides flip x
                s0 = ox + 17'((accx + 27'h800) >> 12);
                s1 = ox + 17'((accx + 27'(zx) + 27'h800) >> 12);
                sx <= s0;
                zw <= 12'(s1 - s0);
                if (mirx) begin
                    if ((!flx) ^ ({cx, 1'b0} < {1'b0, w})) begin tx <= xoff(3'(w - 4'd1 - cx + 4'(xa))); fx <= 1'b1; end
                    else begin tx <= xoff(3'(cx + 4'(xa))); fx <= 1'b0; end
                end else begin
                    tx <= xoff(3'(flx ? (w - 4'd1 - cx + 4'(xa)) : (cx + 4'(xa))));
                    fx <= flx;
                end
                r_a <= (12'(s1 - s0) > 12'd2047) ? 11'd2047 : 11'(s1 - s0);
                // culled (empty, or wholly outside x 40..423): on to the next cell
                if (s1 <= s0 || s0 > 17'sd423 || s1 - 17'sd1 < 17'sd40) es <= E_R3;
                else es <= E_C1;
            end
            E_C1: begin
                rom_addr <= {w1[15:6], 6'(tx + ty), pass ? row_b : row_a};
                rom_req  <= 1'b1;
                pi  <= (sx < 17'sd40) ? 17'sd40 - sx : 17'sd0;
                pi1 <= (sx + 17'(zw) - 17'sd1 > 17'sd423) ? 17'sd423 - sx : 17'(zw) - 17'sd1;
                es <= E_C2;
            end
            E_C2: begin
                // r_q is dx; the fetch is in flight
                dx <= r_q;
                acc  <= fx ? 34'(34'(zw - 12'd1) - 34'(pi)) * 34'(r_q) : 34'(pi) * 34'(r_q);
                step <= fx ? (34'sd0 - 34'(r_q)) : 34'(r_q);
                if (rom_ack) begin rom_req <= 1'b0; rowd <= rom_q; es <= E_PIX; end
                else es <= E_C2;
            end
            E_PIX: begin
                if (pen != 4'd0) begin
                    if (pen != 4'd15 || !shd_on) begin
                        if (!claimed) begin
                            if (eb) claim1[Xu] <= 1'b1; else claim0[Xu] <= 1'b1;
                            c_we <= 1'b1; c_wa <= {eb, Xu};
                            c_wd <= {{pbase, 4'b0000} + {7'd0, pen}, cls};
                        end
                    end else if (!claimed && !shadowed) begin
                        if (eb) shd1[Xu] <= 1'b1; else shd0[Xu] <= 1'b1;
                        sh_we <= 1'b1; c_wa <= {eb, Xu}; sh_wd <= {preset, cls};
                    end
                end
                acc <= acc + step;
                pi  <= pi + 17'sd1;
                if (pi == pi1) es <= E_R3;
            end
            E_R3: begin
                // next blit of this cell, or the next cell
                if (dbl && !pass) begin pass <= 1'b1; es <= E_C0; end
                else begin
                    pass <= 1'b0;
                    if (cx == 4'((1 << wl) - 1)) es <= E_NX;
                    else begin cx <= cx + 4'd1; accx <= accx + 27'(zx); es <= E_C0; end
                end
            end
            E_NX: begin ei <= ei + 9'd1; es <= E_NEXT; end
            default: es <= E_IDLE;
        endcase
        if (start && es != E_IDLE) missed <= 1'b1;
        if (es != E_IDLE && (es == E_NEXT && ei >= n_act) && cyc > worst_line) worst_line <= cyc;
        if (rst) begin es <= E_IDLE; rom_req <= 1'b0; missed <= 1'b0; worst_line <= 16'd0; end
    end

    // line buffer data: engine writes, mixer reads
    always_ff @(posedge clk) begin
        if (c_we)  cbuf[c_wa] <= c_wd;
        if (sh_we) sbuf[c_wa] <= sh_wd;
        mx_cdata <= cbuf[{mx_buf, mx_x}];
        mx_sdata <= sbuf[{mx_buf, mx_x}];
        mx_claim  <= mx_buf ? claim1[mx_x] : claim0[mx_x];
        mx_shadow <= mx_buf ? shd1[mx_x]   : shd0[mx_x];
    end
endmodule

`default_nettype wire
