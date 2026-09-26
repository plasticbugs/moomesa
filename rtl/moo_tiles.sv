//------------------------------------------------------------------------------
// K054156/K054157 tilemap line engine (docs/hardware.md 7.2, the reference is
// tools/moo_render.py draw_layer).
//
// On `start` it builds one line (bitmap y = `line`) of all four layers into
// the line buffer half `buf`: for each layer, the 49 tiles that cover the 384
// visible dots, each a tile-RAM entry read and one 32-bit tile-ROM row fetched
// through the tile port, written out as {colour[3:0], pen[3:0]} per dot at
// bitmap x 40..423.  The mixer turns those into palette indices.
//
// What it models, as the game programs the chip: single-page layers (the page
// grid position from VACSET 10-1E, the later layer winning a shared page), x/y
// scroll with MAME's per-layer offsets, line scroll (mode 0) and row scroll
// (mode 2) from the table at page VACSET 30 + layer * 0x400 words, the FBIT
// field of VACSET 06 and the per-layer flip mask of VACSET 02.  Not modelled
// (never programmed by the game; `unsupported` goes high if they are): screen
// flip, multi-page layers, scroll mode 1.
//------------------------------------------------------------------------------
`default_nettype none

module moo_tiles (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,          // pulse: build `line` into half `buf`
    input  logic  [8:0] line,
    input  logic        buf_sel,
    output logic        busy,
    output logic  [3:0] layer_valid,    // for the line just built
    output logic        unsupported,

    input  logic [15:0] regs [32],      // VACSET, word-indexed

    // tile RAM, second port: {attr[15:0], code[15:0]}, one clock latency
    output logic [12:0] vr_addr,
    input  logic [31:0] vr_q,

    // blank-tile table: bit set when all 32 bytes of the tile are zero.  The
    // address is the code straight off the tile RAM, so the answer is there
    // the clock after an entry is decoded
    output logic [15:0] bl_addr,
    input  logic        bl_q,

    // statistics: tile-ROM fetches and skips on the last line
    output logic  [7:0] n_fetch,
    output logic  [7:0] n_skip,

    // tile ROM rows
    output logic        rom_req,
    output logic [18:0] rom_addr,
    input  logic        rom_ack,
    input  logic [31:0] rom_q,

    // line buffer: {buf, layer, x} <- {mix code, colour, pen}
    output logic        lb_we,
    output logic [11:0] lb_addr,
    output logic  [9:0] lb_d
);
    // ------------------------------------------------ per-layer set-up
    logic [1:0] L;
    wire  [1:0] lx = regs[{3'b011, L}][4:3];
    wire  [1:0] ly = regs[{3'b010, L}][4:3];
    wire  [3:0] page = {ly, lx};
    // physical page of a MAME page: row bit 0 and column bit 0 (docs/core-design.md 2)
    function automatic [1:0] phys(input [3:0] p); phys = {p[2], p[0]}; endfunction

    // the later layer wins a shared page (update_page_layout)
    logic owned;
    always_comb begin
        owned = 1'b1;
        for (int k = 0; k < 4; k++)
            if (k > int'(L) && {regs[8 + k][4:3], regs[12 + k][4:3]} == page) owned = 1'b0;
    end
    wire multi = (regs[{3'b011, L}][1:0] != 2'd0) || (regs[{3'b010, L}][1:0] != 2'd0);
    wire [1:0] smode = 2'(regs[5] >> {L, 1'b0});

    // FBIT decoding (get_tile_info k056832_shiftmasks)
    wire [1:0] fbits = regs[3][7:6];
    function automatic [5:0] tcolor(input [15:0] attr, input [1:0] fb);
        case (fb)
            2'd0: tcolor = attr[5:0];
            2'd1: tcolor = {attr[7:6], attr[3:0]};
            2'd2: tcolor = {attr[7:4], attr[1:0]};
            default: tcolor = attr[7:2];
        endcase
    endfunction
    function automatic [1:0] tflip(input [15:0] attr, input [1:0] fb);
        case (fb)
            2'd0: tflip = attr[7:6];
            2'd1: tflip = attr[5:4];
            2'd2: tflip = attr[3:2];
            default: tflip = attr[1:0];
        endcase
    endfunction

    // per-layer x offsets from VIDEO_START(moo): -1, +3, +5, +7 subtracted
    function automatic [15:0] loff(input [1:0] l);
        case (l)
            2'd0: loff = 16'hFFFF;
            2'd1: loff = 16'd3;
            2'd2: loff = 16'd5;
            default: loff = 16'd7;
        endcase
    endfunction

    // ------------------------------------------------ state
    // Per tile: read its tile-RAM entry (E0/E1), then look the code up in the
    // blank table (E2) while the entry is decoded; then either fetch the row
    // (F), or reuse the last one fetched when the code and row are the same,
    // or skip the fetch for a blank tile.  The next tile's entry read overlaps
    // the fetch.  Every tile ends as 8 dots handed to the writer.
    typedef enum logic [3:0] {
        T_IDLE, T_LAYER, T_SCRL, T_SCRLW, T_SETUP, T_E0, T_E1, T_E2, T_F, T_HAND, T_NEXT
    } st_t;
    st_t st;
    logic  [8:0] y;
    logic        bsel;
    logic [15:0] sxv;          // x scroll value for this line
    logic  [8:0] xs;           // source x of screen x 40
    logic  [7:0] srow;         // source line
    logic  [5:0] k;            // tile being decoded 0..48
    logic  [1:0] fl;
    logic  [3:0] col4;
    logic  [1:0] mix2;
    logic [18:0] want;         // {code, row} of the tile being decoded
    logic        blank, reuse;
    logic [18:0] last;         // {code, row} of the row held in rom_q
    logic        last_v;
    logic        unsup;
    logic  [7:0] nf, ns;
    logic [31:0] lastq;        // the row last fetched: rom_q may be the CPU's by now
    assign bl_addr = vr_q[15:0];

    // writer: 8 dots of one tile
    logic        w_busy;
    logic  [2:0] w_i;
    logic  [8:0] w_x;          // screen x of dot 0 (may be < 40)
    logic [31:0] w_pens;       // 8 pens, dot 0 in [31:28]
    logic  [3:0] w_col;
    logic  [1:0] w_mix;        // the colour's two low bits: the K054338 mix code
    logic  [1:0] w_L;

    wire  [15:0] dy   = regs[{3'b100, L}];
    wire  [15:0] ey   = dy + {7'd0, y};                  // source line for the scroll table
    wire   [8:0] etab = (smode == 2'd0) ? ey[8:0] : {ey[8:3], 3'b000};
    wire   [3:0] sbank = {regs[24][4:3], regs[24][1:0]};
    wire   [1:0] flm   = 2'(regs[1] >> {L, 1'b0});

    // pens of a 32-bit row in dot order (charlayout4: nibbles 2,3,0,1,6,7,4,5)
    function automatic [31:0] order(input [31:0] q, input fx);
        logic [3:0] p [8];
        p[0] = q[23:20]; p[1] = q[19:16]; p[2] = q[31:28]; p[3] = q[27:24];
        p[4] = q[7:4];   p[5] = q[3:0];   p[6] = q[15:12]; p[7] = q[11:8];
        if (!fx) order = {p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]};
        else     order = {p[7], p[6], p[5], p[4], p[3], p[2], p[1], p[0]};
    endfunction

    assign busy = (st != T_IDLE);
    assign unsupported = unsup;
    assign n_fetch = nf;
    assign n_skip  = ns;

    always_ff @(posedge clk) begin
        lb_we <= 1'b0;
        // ---- writer
        if (w_busy) begin
            if ((w_x + {6'd0, w_i}) >= 9'd40 && (w_x + {6'd0, w_i}) <= 9'd423) begin
                lb_we   <= 1'b1;
                lb_addr <= {bsel, w_L, w_x + {6'd0, w_i}};
                lb_d    <= {w_mix, w_col, w_pens[31:28]};
            end
            w_pens <= {w_pens[27:0], 4'd0};
            w_i    <= w_i + 3'd1;
            if (w_i == 3'd7) w_busy <= 1'b0;
        end

        case (st)
            T_IDLE: if (start) begin
                y <= line; bsel <= buf_sel; L <= 2'd0;
                layer_valid <= 4'd0; nf <= 8'd0; ns <= 8'd0;
                st <= T_LAYER;
            end
            T_LAYER: begin
                last_v <= 1'b0;
                if (!owned) st <= T_NEXT;
                else if (multi || smode == 2'd1 || regs[0][5:4] != 2'd0) begin
                    unsup <= 1'b1; st <= T_NEXT;
                end else begin
                    layer_valid[L] <= 1'b1;
                    if (smode == 2'd3) begin sxv <= regs[{3'b101, L}]; st <= T_SETUP; end
                    else begin
                        // table entry e: word (L << 10) + (e * 2 & 0x3FF) + 1 of the
                        // scroll page, i.e. the code half of entry (L << 9) + e
                        vr_addr <= {phys(sbank), L, etab};
                        st <= T_SCRL;
                    end
                end
            end
            T_SCRL:  st <= T_SCRLW;
            T_SCRLW: begin sxv <= vr_q[15:0]; st <= T_SETUP; end
            T_SETUP: begin
                xs   <= 9'(sxv - loff(L) + 16'd40);
                srow <= 8'(y + dy[7:0]);
                k    <= 6'd0;
                st   <= T_E0;
            end
            T_E0: begin
                vr_addr <= {phys(page), srow[7:3], 6'(xs[8:3] + k)};
                st <= T_E1;
            end
            T_E1: st <= T_E2;
            T_E2: begin
                // vr_q is the entry: decode it, and ask the blank table
                logic [1:0] f;
                logic [5:0] tc;
                f = tflip(vr_q[31:16], fbits) & flm;
                tc = tcolor(vr_q[31:16], fbits);
                fl   <= f;
                col4 <= tc[5:2];
                mix2 <= tc[1:0];
                want <= {vr_q[15:0], f[1] ? ~srow[2:0] : srow[2:0]};
                st <= T_F;
                reuse <= last_v && (last == {vr_q[15:0], f[1] ? ~srow[2:0] : srow[2:0]});
                blank <= 1'b0;
            end
            T_F: begin
                // bl_q answers this clock; fetch unless blank or already held
                if (!rom_req) begin
                    if (bl_q) begin blank <= 1'b1; ns <= ns + 8'd1; st <= T_HAND; end
                    else if (reuse) begin ns <= ns + 8'd1; st <= T_HAND; end
                    else begin rom_addr <= want; rom_req <= 1'b1; nf <= nf + 8'd1; end
                end else if (rom_ack) begin
                    rom_req <= 1'b0;
                    last <= want; last_v <= 1'b1; lastq <= rom_q;
                    st <= T_HAND;
                end
            end
            T_HAND: if (!w_busy) begin
                w_busy <= 1'b1; w_i <= 3'd0; w_L <= L; w_col <= col4; w_mix <= mix2;
                w_pens <= blank ? 32'd0 : order(lastq, fl[0]);
                w_x    <= 9'd40 + {k, 3'b000} - {6'd0, xs[2:0]};
                k      <= k + 6'd1;
                if (k == 6'd48) st <= T_NEXT;
                else begin
                    // the next entry read starts now, alongside the writer
                    vr_addr <= {phys(page), srow[7:3], 6'(xs[8:3] + k + 6'd1)};
                    st <= T_E1;
                end
            end
            T_NEXT: if (!w_busy) begin
                if (L == 2'd3) st <= T_IDLE;
                else begin L <= L + 2'd1; st <= T_LAYER; end
            end
            default: st <= T_IDLE;
        endcase
        if (rst) begin
            st <= T_IDLE; rom_req <= 1'b0; w_busy <= 1'b0; unsup <= 1'b0; layer_valid <= 4'd0; last_v <= 1'b0;
        end
    end
endmodule

`default_nettype wire
