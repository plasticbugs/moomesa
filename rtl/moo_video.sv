//------------------------------------------------------------------------------
// Moo Mesa's video board: raster, the chips' CPU windows, their RAMs, and the
// three engines (moo_tiles, moo_sprites, moo_mixer).
//
// Raster (docs/core-design.md 1): 512 x 264 dots at 8 MHz, MAME's bitmap
// coordinates, so the visible window is x 40..423, y 16..239 and line and
// dot numbers mean the same here as in tools/moo_render.py.  The engines build
// line y+1 while line y is shown, into the half (y+1) & 1 of each line buffer.
//
// CPU side: one request at a time (`cpu_req` a pulse, `cpu_ack` a pulse with
// the read data), addresses as the 68000 sees them (docs/hardware.md 2):
//   0C0000 VACSET (w)  0C2000 K053246 (w)  0C4000 sprite ROM read (r)
//   0CA000 K054338 (w) 0CC000 K053251 (w)  0D8000 VSCCS (w)
//   190000 sprite RAM  1A0000 tile RAM window (mirror 1A2000)
//   1B0000 tile ROM read  1C0000 palette
// `cpu_cs` says whether an address is ours; unmapped writes are dropped.
//------------------------------------------------------------------------------
`default_nettype none

module moo_video (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen_pix,

    // CPU
    input  logic        cpu_req,
    input  logic [23:1] cpu_addr,
    input  logic        cpu_rnw,
    input  logic  [1:0] cpu_be,         // {UDS, LDS}, active high
    input  logic [15:0] cpu_d,
    output logic        cpu_ack,
    output logic [15:0] cpu_q,
    output logic        cpu_cs,
    input  logic        objcha,         // CONTROL2 bit 8: sprite ROM readable

    // the ROM image as it downloads (byte offset in the image), for the
    // blank-tile table
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,

    // ROM
    output logic        tile_req,
    output logic [18:0] tile_addr,
    input  logic        tile_ack,
    input  logic [31:0] tile_q,
    output logic        spr_req,
    output logic [19:0] spr_addr,
    input  logic        spr_ack,
    input  logic [63:0] spr_q,

    // timing and interrupts
    output logic        vblank_irq,     // pulse at the first line of vblank
    output logic        dma_done,       // pulse at the end of an object DMA
    output logic  [8:0] hpos,
    output logic  [8:0] vpos,

    // picture, one dot late against hpos/vpos
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de,

    // bench back doors and statistics
    input  logic        dbg_list_we,
    input  logic [10:0] dbg_list_addr,
    input  logic [15:0] dbg_list_d,
    input  logic        dbg_sort,
    output logic [10:0] dbg_index,
    output logic        dbg_alpha, dbg_shadow,
    output logic [15:0] spr_worst,
    output logic        spr_missed,
    output logic        tile_missed,
    output logic        tile_busy,
    output logic  [7:0] tile_fetches,   // tile-ROM fetches / skips on the last line built
    output logic  [7:0] tile_skips,
    output logic        unsupported
);
    // ------------------------------------------------------------ raster
    always_ff @(posedge clk) begin
        if (rst) begin hpos <= 9'd0; vpos <= 9'd0; end
        else if (cen_pix) begin
            hpos <= hpos + 9'd1;
            if (hpos == 9'd511) vpos <= (vpos == 9'd263) ? 9'd0 : vpos + 9'd1;
        end
    end
    wire vis_x = (hpos >= 9'd40) && (hpos <= 9'd423);
    wire vis_y = (vpos >= 9'd16) && (vpos <= 9'd239);
    // syncs from the CCU as the game programs it (hardware.md 7.1): HFP 33,
    // HSW 40, VFP 17, VSW 8, placed after the visible window
    always_ff @(posedge clk) begin
        if (cen_pix) begin
            hblank <= !vis_x;
            vblank <= !vis_y;
            de     <= vis_x && vis_y;
            hsync  <= (hpos >= 9'd457) && (hpos < 9'd497);
            vsync  <= (vpos >= 9'd257);
        end
    end
    wire line_start = cen_pix && (hpos == 9'd0);
    wire [8:0] nline = (vpos == 9'd263) ? 9'd0 : vpos + 9'd1;
    wire render = line_start && (nline >= 9'd16) && (nline <= 9'd239);
    assign vblank_irq = line_start && (vpos == 9'd240);

    // ------------------------------------------------------------ registers
    logic [15:0] vac [32];
    logic [15:0] vsc [4];

    // ------------------------------------------------------------ CPU decode
    wire [23:0] a = {cpu_addr, 1'b0};
    wire cs_vac  = (a[23:6]  == 18'h03000);          // 0C0000-0C003F
    wire cs_246  = (a[23:3]  == 21'h018400);         // 0C2000-0C2007
    wire cs_246r = (a[23:1]  == 23'h062000);         // 0C4000-0C4001
    wire cs_338  = (a[23:5]  == 19'h06500);          // 0CA000-0CA01F
    wire cs_251  = (a[23:5]  == 19'h06600);          // 0CC000-0CC01F
    wire cs_vsc  = (a[23:3]  == 21'h01B000);         // 0D8000-0D8007
    wire cs_spr  = (a[23:16] == 8'h19);              // 190000-19FFFF
    wire cs_vram = (a[23:14] == 10'h068);            // 1A0000-1A3FFF
    wire cs_trom = (a[23:13] == 11'h0D8);            // 1B0000-1B1FFF
    wire cs_pal  = (a[23:13] == 11'h0E0);            // 1C0000-1C1FFF
    assign cpu_cs = cs_vac | cs_246 | cs_246r | cs_338 | cs_251 | cs_vsc |
                    cs_spr | cs_vram | cs_trom | cs_pal;

    // tile RAM window: MAME page ((b >> 1) & 0xC) | (b & 3) of VACSET 32,
    // physical page = row bit 0, column bit 0 (docs/core-design.md 2)
    wire [15:0] rbank = vac[25];
    wire  [3:0] cpage = {rbank[4:3], rbank[1:0]};
    wire [12:0] cv_entry = {cpage[2], cpage[0], a[12:2]};
    wire        cv_half  = a[1];                     // 0: attribute word, 1: code word

    // ------------------------------------------------------------ tile RAM
    logic [3:0][7:0] vram [8192];
    logic [31:0] vq_cpu, vq_eng;
    logic [12:0] ve_addr;
    logic        v_we;
    // byte enables: the attribute word is bytes 3:2, the code word 1:0
    wire [3:0] v_be = cv_half ? {2'b00, cpu_be} : {cpu_be, 2'b00};
    always_ff @(posedge clk) begin
        if (v_we) begin
            if (v_be[3]) vram[cv_entry][3] <= cpu_d[15:8];
            if (v_be[2]) vram[cv_entry][2] <= cpu_d[7:0];
            if (v_be[1]) vram[cv_entry][1] <= cpu_d[15:8];
            if (v_be[0]) vram[cv_entry][0] <= cpu_d[7:0];
        end
        vq_cpu <= vram[cv_entry];
    end
    always_ff @(posedge clk) vq_eng <= vram[ve_addr];

    // ------------------------------------------------------------ sprite RAM
    logic [1:0][7:0] sram [32768];
    logic [15:0] sq_cpu, sq_dma;
    logic [14:0] sd_addr;
    logic        s_we;
    always_ff @(posedge clk) begin
        if (s_we) begin
            if (cpu_be[1]) sram[a[15:1]][1] <= cpu_d[15:8];
            if (cpu_be[0]) sram[a[15:1]][0] <= cpu_d[7:0];
        end
        sq_cpu <= sram[a[15:1]];
    end
    always_ff @(posedge clk) sq_dma <= sram[sd_addr];

    // ------------------------------------------------------------ engines
    logic [3:0][7:0] tlb [1024];        // tile line buffer {buf, x} -> 4 layers
    logic        tl_we;
    logic [11:0] tl_waddr;
    logic  [7:0] tl_wd;
    logic  [9:0] tl_raddr;
    logic [31:0] tl_q;
    always_ff @(posedge clk) begin
        if (tl_we) tlb[{tl_waddr[11], tl_waddr[8:0]}][tl_waddr[10:9]] <= tl_wd;
        tl_q <= tlb[tl_raddr];
    end

    // ------------------------------------------------------------ blank tiles
    // One bit per tile code, set when all 32 bytes of the tile are zero, so
    // the engine can skip its fetch.  Built from the download: each tile's
    // bytes ORed together as they pass (idempotent, so the loader's held
    // strobe cannot miscount it), the bit written at its last byte.
    logic        blank [65536];
    logic [15:0] bl_addr;
    logic        bl_q;
    logic  [7:0] bl_acc;
    wire         dl_tile = dl_we && (dl_addr[24:21] == 4'b0100);    // 0x800000-0x9FFFFF
    always_ff @(posedge clk) begin
        if (dl_tile) begin
            bl_acc <= (dl_addr[4:0] == 5'd0) ? dl_data : (bl_acc | dl_data);
            if (dl_addr[4:0] == 5'd31) blank[dl_addr[20:5]] <= ((bl_acc | dl_data) == 8'd0);
        end
        bl_q <= blank[bl_addr];
    end

    logic       t_busy, t_unsup;
    logic [3:0] t_valid;
    logic [3:0] lvalid [2];
    logic       t_req;
    logic [18:0] t_addr;
    logic       t_ack;
    logic       rbuf;                    // half being built
    moo_tiles u_tiles (
        .clk(clk), .rst(rst),
        .start(render), .line(nline), .buf_sel(nline[0]), .busy(t_busy),
        .layer_valid(t_valid), .unsupported(t_unsup),
        .regs(vac),
        .vr_addr(ve_addr), .vr_q(vq_eng),
        .bl_addr(bl_addr), .bl_q(bl_q), .n_fetch(tile_fetches), .n_skip(tile_skips),
        .rom_req(t_req), .rom_addr(t_addr), .rom_ack(t_ack), .rom_q(tile_q),
        .lb_we(tl_we), .lb_addr(tl_waddr), .lb_d(tl_wd)
    );
    // the layers the engine built are recorded for its half when it finishes
    logic t_busy_d;
    always_ff @(posedge clk) begin
        t_busy_d <= t_busy;
        if (render) rbuf <= nline[0];
        if (t_busy_d && !t_busy) lvalid[rbuf] <= t_valid;
        if (render && t_busy) tile_missed <= 1'b1;
        if (rst) begin tile_missed <= 1'b0; lvalid[0] <= 4'd0; lvalid[1] <= 4'd0; end
    end

    logic [7:0] k246 [8];
    logic [6:0] scb;
    logic [5:0] lp0, lp1, lp2;
    logic       s_rreq, s_rack;
    logic [19:0] s_raddr;
    logic       mx_buf, mx_claim, mx_shadow;
    logic [8:0] mx_x;
    logic [12:0] mx_cdata;
    logic [3:0] mx_sdata;
    logic       w246;
    logic [2:0] w246_a;
    logic [7:0] w246_d;
    moo_sprites u_spr (
        .clk(clk), .rst(rst),
        .reg_we(w246), .reg_addr(w246_a), .reg_d(w246_d), .k246(k246),
        .colorbase(scb), .lp0(lp0), .lp1(lp1), .lp2(lp2),
        .vblank_start(vblank_irq), .dma_done(dma_done), .dma_busy(),
        .sr_addr(sd_addr), .sr_q(sq_dma),
        .start(render), .line(nline), .buf_sel(nline[0]), .busy(),
        .rom_req(s_rreq), .rom_addr(s_raddr), .rom_ack(s_rack), .rom_q(spr_q),
        .mx_buf(mx_buf), .mx_x(mx_x), .mx_claim(mx_claim), .mx_cdata(mx_cdata),
        .mx_shadow(mx_shadow), .mx_sdata(mx_sdata),
        .dbg_we(dbg_list_we), .dbg_addr(dbg_list_addr), .dbg_d(dbg_list_d), .dbg_sort(dbg_sort),
        .worst_line(spr_worst), .missed(spr_missed)
    );

    logic        w251, w338, wpal;
    logic [15:0] pal_q;
    moo_mixer u_mix (
        .clk(clk), .rst(rst), .cen_pix(cen_pix),
        .hpos(hpos), .lbuf(vpos[0]), .visible(vis_x && vis_y),
        .k251_we(w251), .k251_addr(a[4:1]), .k251_d(cpu_d[5:0]),
        .spr_colorbase(scb), .lp0(lp0), .lp1(lp1), .lp2(lp2),
        .k338_we(w338), .k338_addr(a[4:1]), .k338_d(cpu_d), .k338_be(cpu_be),
        .pal_we(wpal), .pal_addr(a[12:1]), .pal_d(cpu_d), .pal_be(cpu_be), .pal_q(pal_q),
        .tl_addr(tl_raddr), .tl_q(tl_q), .tl_valid(lvalid[vpos[0]]),
        .sp_buf(mx_buf), .sp_x(mx_x), .sp_claim(mx_claim), .sp_cdata(mx_cdata),
        .sp_shadow(mx_shadow), .sp_sdata(mx_sdata),
        .rgb(rgb), .dbg_index(dbg_index), .dbg_alpha(dbg_alpha), .dbg_shadow(dbg_shadow)
    );

    assign unsupported = t_unsup;
    assign tile_busy = t_busy;

    // ------------------------------------------------------------ ROM ports
    // Each is shared by an engine and the CPU's read-back window; the owner
    // is latched at grant and the answer goes where the latch says (5.17).
    logic c_trq, c_srq;                 // CPU wants a tile / sprite ROM word
    logic [18:0] c_taddr;
    logic [19:0] c_saddr;
    logic t_own_cpu, s_own_cpu, t_busy_port, s_busy_port;
    always_ff @(posedge clk) begin
        if (!t_busy_port) begin
            if (c_trq)      begin t_own_cpu <= 1'b1; t_busy_port <= 1'b1; end
            else if (t_req) begin t_own_cpu <= 1'b0; t_busy_port <= 1'b1; end
        end else if (tile_ack) t_busy_port <= 1'b0;
        if (!s_busy_port) begin
            if (c_srq)       begin s_own_cpu <= 1'b1; s_busy_port <= 1'b1; end
            else if (s_rreq) begin s_own_cpu <= 1'b0; s_busy_port <= 1'b1; end
        end else if (spr_ack) s_busy_port <= 1'b0;
        if (rst) begin t_busy_port <= 1'b0; s_busy_port <= 1'b0; end
    end
    assign tile_req  = t_busy_port && (t_own_cpu ? c_trq : t_req);
    assign tile_addr = t_own_cpu ? c_taddr : t_addr;
    assign t_ack     = tile_ack && t_busy_port && !t_own_cpu;
    assign spr_req   = s_busy_port && (s_own_cpu ? c_srq : s_rreq);
    assign spr_addr  = s_own_cpu ? c_saddr : s_raddr;
    assign s_rack    = spr_ack && s_busy_port && !s_own_cpu;

    // ------------------------------------------------------------ CPU cycle
    typedef enum logic [2:0] { C_IDLE, C_RAM1, C_RAM2, C_TROM, C_SROM } cst_t;
    cst_t cs;
    logic [2:0] rsel;                   // which RAM answers a read
    always_ff @(posedge clk) begin
        cpu_ack <= 1'b0;
        v_we <= 1'b0; s_we <= 1'b0; w246 <= 1'b0; w251 <= 1'b0; w338 <= 1'b0; wpal <= 1'b0;
        case (cs)
            C_IDLE: if (cpu_req) begin
                if (!cpu_rnw) begin
                    // writes land now; the ack follows
                    if (cs_vac) begin
                        if (cpu_be[1]) vac[a[5:1]][15:8] <= cpu_d[15:8];
                        if (cpu_be[0]) vac[a[5:1]][7:0]  <= cpu_d[7:0];
                    end
                    if (cs_vsc) begin
                        if (cpu_be[1]) vsc[a[2:1]][15:8] <= cpu_d[15:8];
                        if (cpu_be[0]) vsc[a[2:1]][7:0]  <= cpu_d[7:0];
                    end
                    if (cs_246) begin
                        // a byte-wide chip on the word bus: the even byte is D15-8
                        w246 <= 1'b1;
                        w246_a <= {a[2:1], !cpu_be[1]};
                        w246_d <= cpu_be[1] ? cpu_d[15:8] : cpu_d[7:0];
                        if (cpu_be[1] && cpu_be[0]) pend246 <= 1'b1;
                    end
                    w251 <= cs_251 && cpu_be[0];
                    w338 <= cs_338;
                    wpal <= cs_pal;
                    v_we <= cs_vram;
                    s_we <= cs_spr;
                    cs <= C_RAM2;
                end else begin
                    rsel <= cs_vram ? 3'd1 : cs_spr ? 3'd2 : cs_pal ? 3'd3 : 3'd0;
                    if (cs_trom) begin
                        // rom_word_r: bank VACSET 34 (| 36 << 16) mod 256 banks of 8 KB
                        c_taddr <= {vac[26][7:0], a[12:2]};
                        c_trq <= 1'b1;
                        cs <= C_TROM;
                    end else if (cs_246r && objcha) begin
                        // byte (reg6 << 17 | reg7 << 9 | reg4 << 1 | sel): 64-bit row
                        // {reg6[5:0], reg7, reg4[7:2]}, byte {reg4[1:0], sel}
                        c_saddr <= {k246[6][5:0], k246[7], k246[4][7:2]};
                        c_srq <= 1'b1;
                        cs <= C_SROM;
                    end else cs <= C_RAM1;
                end
            end
            C_RAM1: cs <= C_RAM2;
            C_RAM2: begin
                if (pend246) begin
                    pend246 <= 1'b0; w246 <= 1'b1; w246_a <= {a[2:1], 1'b1}; w246_d <= cpu_d[7:0];
                end
                case (rsel)
                    3'd1: cpu_q <= cv_half ? vq_cpu[15:0] : vq_cpu[31:16];
                    3'd2: cpu_q <= sq_cpu;
                    3'd3: cpu_q <= pal_q;
                    default: cpu_q <= 16'h0000;
                endcase
                cpu_ack <= 1'b1; rsel <= 3'd0;
                cs <= C_IDLE;
            end
            C_TROM: if (tile_ack && t_own_cpu) begin
                c_trq <= 1'b0;
                cpu_q <= a[1] ? tile_q[15:0] : tile_q[31:16];
                cpu_ack <= 1'b1; cs <= C_IDLE;
            end
            C_SROM: if (spr_ack && s_own_cpu) begin
                // k053246_r: the even byte (D15-8) is sel 1, the odd sel 0
                c_srq <= 1'b0;
                cpu_q <= {spr_q[63 - 8 * int'({k246[4][1:0], 1'b1}) -: 8],
                          spr_q[63 - 8 * int'({k246[4][1:0], 1'b0}) -: 8]};
                cpu_ack <= 1'b1; cs <= C_IDLE;
            end
            default: cs <= C_IDLE;
        endcase
        if (rst) begin cs <= C_IDLE; c_trq <= 1'b0; c_srq <= 1'b0; pend246 <= 1'b0; end
    end
    logic pend246;
    wire _unused = &{1'b0, vsc[0], t_busy, 1'b0};
endmodule

`default_nettype wire
