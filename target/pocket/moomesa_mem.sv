//------------------------------------------------------------------------------
// The Pocket's memories behind the core's ports (docs/core-design.md section 2).
//
// SDRAM holds the ROM image only; every RAM of the board is block RAM inside
// the core.  The image is laid out exactly as moomesa.mra builds it, so the
// SDRAM word address of an image byte is its offset divided by two:
//
//   word 0x000000   sprite ROM   8 MB   64-bit rows, 4-word bursts   (spr)
//   word 0x400000   tile ROM     2 MB   32-bit rows, 2-word bursts   (tile)
//   word 0x500000   PCM samples  2 MB   bytes, single words          (pcm)
//   word 0x600000   68000 ROM    1 MB   16-bit, through a cache      (mrom)
//   word 0x680000   Z80 ROM    256 KB   bytes, single words          (srom)
//   word 0x6A0000   EEPROM     128 B    taken off the download by core_top
//
// The image arrives from the Pocket as a byte stream and is written into
// SDRAM a word at a time through the same controller the core reads it back
// through.
//
// Client conventions (all ports): `req` is a level held until `ack`; `ack` is
// a one-clock pulse with the data; the client drops `req` for at least one
// clock before its next request.  A request counts once: each port keeps a
// `served` flag, set by its ack and cleared when req drops, so a req still
// high on the clock after its ack is never mistaken for a new one.
//
// The SRAM port is kept for core_top's power-on self-test and nothing else:
// the game has no RAM there.
//------------------------------------------------------------------------------
`default_nettype none

module moomesa_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase shifted, drives the pin
    input  logic        init,           // hold to (re)initialise the SDRAM
    output logic        ready,

    input  logic        rd_late,        // SDRAM diagnostics, from the Pocket menu
    input  logic        burst_slow,
    input  logic        sram_slow,
    input  logic        sram_slow_wr,

    // the ROM image arriving from the Pocket
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_active,

    // core ports
    input  logic        mrom_req,  input  logic [19:1] mrom_addr,   // 68000, image-relative
    output logic        mrom_ack,  output logic [15:0] mrom_q,

    input  logic        srom_req,  input  logic [17:0] srom_addr,   // Z80
    output logic        srom_ack,  output logic  [7:0] srom_q,

    input  logic        pcm_req,   input  logic [20:0] pcm_addr,    // K054539
    output logic        pcm_ack,   output logic  [7:0] pcm_q,

    input  logic        tile_req,  input  logic [18:0] tile_addr,   // 32-bit row index
    output logic        tile_ack,  output logic [31:0] tile_q,

    input  logic        spr_req,   input  logic [19:0] spr_addr,    // 64-bit row index
    output logic        spr_ack,   output logic [63:0] spr_q,

    input  logic        vram_req,  input  logic        vram_we,     // self-test only
    input  logic [14:0] vram_addr, input  logic [15:0] vram_din,
    input  logic  [1:0] vram_ben,
    output logic        vram_ack,  output logic [15:0] vram_q,

    // statistics for the bring-up panel: 68000 cache misses (saturating)
    output logic [15:0] mrom_misses,

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // SRAM pins
    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    // Where each region starts, as an SDRAM word address.  Every base is a
    // multiple of its region's size, so the offsets go in with an OR.
    localparam logic [24:1] SPR_W  = 24'h000000;
    localparam logic [24:1] TILE_W = 24'h400000;
    localparam logic [24:1] PCM_W  = 24'h500000;
    localparam logic [24:1] PROG_W = 24'h600000;
    localparam logic [24:1] SND_W  = 24'h680000;

    // ------------------------------------------------------------ download
    // A byte at a time from the Pocket, paired into a 16-bit word because the
    // image is big-endian throughout.  The loader cannot be told to wait --
    // it sends a byte every eight clocks whatever the SDRAM is doing -- so
    // the words go into a FIFO deep enough to ride out a refresh or a row
    // change, and each byte is taken once, on the rising edge of the strobe
    // the Pocket holds for several clocks (METHODOLOGY 5.8, 5.16).
    localparam int DLQ = 64;
    logic [39:0] dlq [DLQ];             // {word address [24:1], data [15:0]}
    logic  [6:0] dlq_wp, dlq_rp;
    logic  [7:0] dl_hi;
    logic        dl_we_d;
    wire         dlq_empty = (dlq_wp == dlq_rp);
    wire  [39:0] dlq_head  = dlq[dlq_rp[5:0]];
    wire         nb        = dl_we && !dl_we_d;   // one byte, once

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        if (init) begin
            dlq_wp <= '0;
            dlq_rp <= '0;
        end else begin
            if (nb) begin
                if (!dl_addr[0]) dl_hi <= dl_data;
                else begin
                    dlq[dlq_wp[5:0]] <= {dl_addr[24:1], dl_hi, dl_data};
                    dlq_wp <= dlq_wp + 7'd1;
                end
            end
            if (!dlq_empty && dl_ack) dlq_rp <= dlq_rp + 7'd1;
        end
    end

    // ---------------------------------------------------- random clients
    // 0 download (writes), 1 Z80, 2 K054539.  The controller serves them
    // round-robin and lets one in between burst chunks.
    localparam int NCLI = 3;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;

    wire dl_ack = c_ack[0];
    assign c_addr[0]  = dlq_head[39:16];
    assign c_req[0]   = !dlq_empty;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = dlq_head[15:0];
    assign c_be[0]    = 2'b11;

    // the Z80 and the K054539 read bytes; the SDRAM holds them two to a
    // word, high byte first
    logic srom_served, pcm_served;
    assign c_addr[1]  = SND_W | {7'd0, srom_addr[17:1]};
    assign c_req[1]   = srom_req && !srom_served;
    assign c_we[1]    = 1'b0;
    assign c_wdata[1] = 16'd0;
    assign c_be[1]    = 2'b11;
    assign c_addr[2]  = PCM_W | {4'd0, pcm_addr[20:1]};
    assign c_req[2]   = pcm_req && !pcm_served;
    assign c_we[2]    = 1'b0;
    assign c_wdata[2] = 16'd0;
    assign c_be[2]    = 2'b11;
    always_ff @(posedge clk) begin
        srom_ack <= c_ack[1];
        pcm_ack  <= c_ack[2];
        if (c_ack[1]) srom_q <= srom_addr[0] ? rdata[7:0] : rdata[15:8];
        if (c_ack[2]) pcm_q  <= pcm_addr[0]  ? rdata[7:0] : rdata[15:8];
        if (!srom_req) srom_served <= 1'b0; else if (c_ack[1]) srom_served <= 1'b1;
        if (!pcm_req)  pcm_served  <= 1'b0; else if (c_ack[2]) pcm_served  <= 1'b1;
        if (init) begin srom_served <= 1'b0; pcm_served <= 1'b0; end
    end

    // ------------------------------------------------------ 68000 cache
    // Direct-mapped, 512 lines of 4 words (4 KB), filled by a 4-word burst.
    // The ROM is read-only, so a line can never go stale; every line is
    // invalidated while the image downloads.  A hit answers in 3 clocks, a
    // miss when its line is in.
    //   mrom_addr[19:1]: word [2:1], line index [11:3], tag [19:12]
    logic [15:0] cdata [2048];
    logic  [7:0] ctag  [512];
    logic [511:0] cvalid;
    logic [15:0] cdata_q;
    logic  [7:0] ctag_q;
    logic [19:1] m_a;
    logic        m_served, m_fill_start, m_filling, m_have;
    logic [15:0] m_word;
    typedef enum logic [2:0] { MC_IDLE, MC_LOOK, MC_CMP, MC_FILL, MC_DONE } mc_t;
    mc_t mc;

    // burst port results routed to the cache (declared with the arbiter below)
    logic        b_wr, b_done;
    logic  [9:0] b_idx;
    logic [15:0] b_data;
    typedef enum logic [2:0] { B_IDLE, B_CACHE, B_TILE, B_SPR, B_GAP } bown_t;
    bown_t bown;

    always_ff @(posedge clk) begin
        cdata_q <= cdata[{m_a[11:3], m_a[2:1]}];
        ctag_q  <= ctag[m_a[11:3]];
        if (bown == B_CACHE && b_wr) cdata[{m_a[11:3], b_idx[1:0]}] <= b_data;
        if (mc == MC_DONE && m_filling) ctag[m_a[11:3]] <= m_a[19:12];
    end

    always_ff @(posedge clk) begin
        mrom_ack <= 1'b0;
        if (!mrom_req) m_served <= 1'b0;
        case (mc)
            MC_IDLE: if (mrom_req && !m_served) begin m_a <= mrom_addr; mc <= MC_LOOK; end
            MC_LOOK: mc <= MC_CMP;                         // BRAM read in flight
            MC_CMP: begin
                if (cvalid[m_a[11:3]] && ctag_q == m_a[19:12]) begin
                    mrom_q <= cdata_q; mrom_ack <= 1'b1; m_served <= 1'b1;
                    m_filling <= 1'b0;
                    mc <= MC_IDLE;
                end else begin
                    m_fill_start <= 1'b1; m_filling <= 1'b1; m_have <= 1'b0;
                    if (mrom_misses != 16'hffff) mrom_misses <= mrom_misses + 16'd1;
                    mc <= MC_FILL;
                end
            end
            MC_FILL: begin
                if (bown == B_CACHE) m_fill_start <= 1'b0;
                if (bown == B_CACHE && b_wr && b_idx[1:0] == m_a[2:1]) begin m_word <= b_data; m_have <= 1'b1; end
                if (bown == B_CACHE && b_done) mc <= MC_DONE;
            end
            MC_DONE: begin
                cvalid[m_a[11:3]] <= 1'b1;
                mrom_q <= m_word; mrom_ack <= 1'b1; m_served <= 1'b1;
                m_filling <= 1'b0;
                mc <= MC_IDLE;
            end
            default: mc <= MC_IDLE;
        endcase
        if (init || dl_active) begin
            cvalid <= '0;
            if (init) begin mc <= MC_IDLE; m_served <= 1'b0; m_fill_start <= 1'b0; m_filling <= 1'b0; end
        end
        if (init && !dl_active) mrom_misses <= '0;
    end
    wire _unused_have = m_have;

    // ------------------------------------------------------ the burst port
    // Three users: the 68000 cache (4 words), the tile fetch (2) and the
    // sprite fetch (4).  The owner is latched at grant and every result is
    // routed by that latch, never by who is asking when it lands
    // (METHODOLOGY 5.17).  Priority at grant: the 68000, whose every miss
    // stalls the game; then the tile fetch, whose line has the earlier
    // deadline; then sprites.  The controller wants b_req low for a clock
    // between bursts (B_GAP).
    logic [15:0] t_w0, s_w0, s_w1, s_w2;
    logic        tile_served, spr_served;
    wire tile_want  = tile_req && !tile_served;
    wire spr_want   = spr_req  && !spr_served;
    wire cache_want = m_fill_start;

    always_ff @(posedge clk) begin
        if (init) bown <= B_IDLE;
        else case (bown)
            B_IDLE: if (cache_want) bown <= B_CACHE;
                    else if (tile_want) bown <= B_TILE;
                    else if (spr_want)  bown <= B_SPR;
            B_CACHE, B_TILE, B_SPR: if (b_done) bown <= B_GAP;
            default: bown <= B_IDLE;
        endcase
    end

    logic        b_req_m;
    logic [24:1] b_addr_m;
    logic  [9:0] b_len_m;
    always_comb begin
        b_req_m  = (bown == B_CACHE) || (bown == B_TILE) || (bown == B_SPR);
        case (bown)
            B_CACHE: begin b_addr_m = PROG_W | {5'd0, m_a[19:3], 2'b00}; b_len_m = 10'd4; end
            B_TILE:  begin b_addr_m = TILE_W | {4'd0, tile_addr, 1'b0};  b_len_m = 10'd2; end
            default: begin b_addr_m = SPR_W  | {2'd0, spr_addr, 2'b00};  b_len_m = 10'd4; end
        endcase
    end

    always_ff @(posedge clk) begin
        tile_ack <= 1'b0;
        spr_ack  <= 1'b0;
        if (b_wr && bown == B_TILE) begin
            if (b_idx[0] == 1'b0) t_w0 <= b_data;
            else begin tile_q <= {t_w0, b_data}; tile_ack <= 1'b1; end
        end
        if (b_wr && bown == B_SPR) begin
            case (b_idx[1:0])
                2'd0: s_w0 <= b_data;
                2'd1: s_w1 <= b_data;
                2'd2: s_w2 <= b_data;
                default: begin spr_q <= {s_w0, s_w1, s_w2, b_data}; spr_ack <= 1'b1; end
            endcase
        end
        if (!tile_req) tile_served <= 1'b0; else if (tile_ack) tile_served <= 1'b1;
        if (!spr_req)  spr_served  <= 1'b0; else if (spr_ack)  spr_served  <= 1'b1;
        if (init) begin tile_served <= 1'b0; spr_served <= 1'b0; end
    end

    // ------------------------------------------------------------- SDRAM
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(b_addr_m), .b_len(b_len_m),
        .b_req(b_req_m), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx()
    );

    // -------------------------------------------------------------- SRAM
    sram_port u_sram (
        .clk(clk), .reset(init), .slow(sram_slow), .slow_wr(sram_slow_wr),
        .req(vram_req && !dl_active), .we(vram_we), .addr({1'b0, vram_addr}),
        .be(vram_ben), .wdata(vram_din), .ack(vram_ack), .q(vram_q),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );
endmodule

`default_nettype wire
