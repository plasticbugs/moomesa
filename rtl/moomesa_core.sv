//------------------------------------------------------------------------------
// Wild West C.O.W.-Boys of Moo Mesa (Konami GX151) -- the machine,
// platform-agnostic.  docs/hardware.md is the specification; each block below
// names the section it implements.
//
//   main    fx68k at 16 MHz; ROM through the memory module's cache; work RAM;
//           CONTROL2, the EEPROM, the K053252's interrupt, the K053990
//           protection, the K054321 latches; IRQ4 at vblank and IRQ5 at the
//           end of object DMA (hardware.md 4: the ROM's order, not MAME's)
//   video   rtl/moo_video.sv
//   sound   Z80 at 8 MHz with its ROM bank and RAM, jt51 (YM2151), and
//           rtl/k054539.sv; mixed in stereo with MAME's routing gains and the
//           K054321's volume and per-side enable
//
// The port list is the contract with target/pocket/core_top.sv and the benches
// in sim/: every ROM through target/pocket/moomesa_mem.sv, every RAM inside.
//------------------------------------------------------------------------------
`default_nettype none

module moomesa_core (
    input  logic        clk,            // 96 MHz
    input  logic        rst,
    input  logic        pause,          // freeze the CPUs and sound, keep the picture
    input  logic        pix_sync,       // see clk_enables.sv

    // ---------------- memory, all through target/pocket/moomesa_mem.sv
    output logic        mrom_req,  output logic [19:1] mrom_addr,   // 68000 ROM, image-relative
    input  logic        mrom_ack,  input  logic [15:0] mrom_q,
    output logic        srom_req,  output logic [17:0] srom_addr,   // Z80 ROM
    input  logic        srom_ack,  input  logic  [7:0] srom_q,
    output logic        pcm_req,   output logic [20:0] pcm_addr,    // K054539 samples
    input  logic        pcm_ack,   input  logic  [7:0] pcm_q,
    output logic        tile_req,  output logic [18:0] tile_addr,   // tile ROM, 32-bit rows
    input  logic        tile_ack,  input  logic [31:0] tile_q,
    output logic        spr_req,   output logic [19:0] spr_addr,    // sprite ROM, 64-bit rows
    input  logic        spr_ack,   input  logic [63:0] spr_q,

    // ---------------- the ROM image as it downloads (byte offset in the image)
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,

    // ---------------- the EEPROM's contents, for the save slot
    input  logic  [6:0] nv_addr,
    input  logic        nv_we,
    input  logic  [7:0] nv_din,
    output logic  [7:0] nv_dout,
    output logic        nv_changed,     // the game wrote the EEPROM (pulse)

    // ---------------- inputs, active low as the board reads them
    input  logic  [7:0] p1, p2, p3, p4, // bit 0 left, 1 right, 2 up, 3 down, 4 b1, 5 b2, 7 start
    input  logic  [7:0] in0,            // bit 0-3 coin 1-4, 4-7 service 1-4
    input  logic        test_n,         // service mode switch
    input  logic  [3:0] dsw,            // SW1:1-4 (IN1 bits 4-7)

    // ---------------- video, one pixel per pix_ce in the clk domain
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank,
    output logic        pix_ce, de,

    output logic signed [15:0] snd_l, snd_r,

    // ---------------- bring-up (rtl/dbg_fault.sv, the panel in core_top)
    output logic        dbg_halted,
    output logic [23:1] dbg_addr,
    output logic        dbg_bus, dbg_wait,
    output logic        watchdog_reset,
    output logic  [7:0] dbg_status,     // engine deadlines missed, sound overrun, IRQs seen
    output logic [15:0] dbg_snd_worst,  // K054539: most clocks a sample took (of 2000)
    output logic  [7:0] dbg_snd_reads   //          and most ROM reads
);
    // ------------------------------------------------------------ clocks
    logic cen_phi1, cen_phi2, cen_z80, cen_ym, cen_ym2, cen_snd, cen_pix;
    clk_enables u_cen (
        .clk(clk), .rst(rst), .pause(pause), .pix_sync(pix_sync),
        .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80),
        .cen_ym(cen_ym), .cen_ym2(cen_ym2), .cen_snd(cen_snd), .cen_pix(cen_pix)
    );
    assign pix_ce = cen_pix;

    // ================================================================ 68000
    logic [23:1] eab;
    logic [15:0] cpu_do, cpu_di;
    logic        ASn, UDSn, LDSn, RWn, FC0, FC1, FC2;
    logic        DTACKn, VPAn;
    logic  [2:0] IPLn;
    logic        halted_n;
    /* verilator lint_off PINCONNECTEMPTY */
    fx68k u_68k (
        .clk(clk), .HALTn(1'b1), .extReset(rst), .pwrUp(rst),
        .enPhi1(cen_phi1), .enPhi2(cen_phi2),
        .eRWn(RWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(),
        .FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(), .oRESETn(), .oHALTEDn(halted_n),
        .DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(IPLn[0]), .IPL1n(IPLn[1]), .IPL2n(IPLn[2]),
        .iEdb(cpu_di), .oEdb(cpu_do), .eab(eab)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    assign dbg_halted = !halted_n;
    assign dbg_addr   = eab;
    assign dbg_bus    = !ASn;
    assign dbg_wait   = !ASn && DTACKn;
    assign watchdog_reset = 1'b0;           // CONTROL2 bit 10 is a watchdog MAME ignores; so do we

    // ------------------------------------------------ the shared bus (slave side)
    // Two masters use it: the 68000's cycle below, and the K053990 protection
    // engine, which runs while the 68000 waits on the write that started it.
    logic        s_req, s_rnw, s_ack;
    logic [23:1] s_addr;
    logic  [1:0] s_be;
    logic [15:0] s_d, s_q;

    wire [23:0] sa = {s_addr, 1'b0};
    wire sel_rom  = (sa[23:19] == 5'b00000) || (sa[23:19] == 5'b00010);  // 000000-07FFFF, 100000-17FFFF
    wire sel_wram = (sa[23:16] == 8'h18);
    wire sel_prot = (sa[23:5]  == 19'h06700);    // 0CE000-0CE01F
    wire sel_ccu  = (sa[23:5]  == 19'h06800);    // 0D0000-0D001F
    wire sel_sirq = (sa[23:1]  == 23'h06A000);   // 0D4000
    wire sel_321  = (sa[23:5]  == 19'h06B00);    // 0D6000-0D601F
    wire sel_pin  = (sa[23:2]  == 22'h036800);   // 0DA000-0DA003
    wire sel_in   = (sa[23:2]  == 22'h037000);   // 0DC000-0DC003
    wire sel_ctl  = (sa[23:1]  == 23'h06F000);   // 0DE000
    logic v_cs;

    // work RAM, 32K x 16
    logic [1:0][7:0] wram [32768];
    logic [15:0] wram_q;
    logic        wram_we;
    always_ff @(posedge clk) begin
        if (wram_we) begin
            if (s_be[1]) wram[s_addr[15:1]][1] <= s_d[15:8];
            if (s_be[0]) wram[s_addr[15:1]][0] <= s_d[7:0];
        end
        wram_q <= wram[s_addr[15:1]];
    end

    // CONTROL2 (hardware.md 2.1)
    logic [15:0] ctl2;
    // EEPROM (ER5911, 128 x 8)
    logic eep_do, eep_rdy;

    // K053252: only its interrupt acknowledge is used; registers are kept
    logic [7:0] ccu [16];
    // K054321 (hardware.md 5)
    logic [7:0] latch0, latch1, latch2;
    logic [7:0] k321_active;
    logic [6:0] k321_vol;
    logic       snd_irq_set;
    // K053990 (hardware.md 2.2)
    logic [15:0] prot [16];
    logic        prot_go;

    // video
    logic        v_req, v_ack;
    logic [15:0] v_q;
    logic        vblank_irq, dma_done;

    typedef enum logic [2:0] { S_IDLE, S_WAIT, S_RAM1, S_RAM2, S_ROM, S_VID } sst_t;
    sst_t ss;
    always_ff @(posedge clk) begin
        s_ack <= 1'b0; wram_we <= 1'b0; v_req <= 1'b0; snd_irq_set <= 1'b0; prot_go <= 1'b0;
        case (ss)
            S_IDLE: if (s_req) begin
                if (sel_rom) begin
                    mrom_addr <= {sa[20], s_addr[18:1]};
                    mrom_req <= 1'b1;
                    ss <= S_ROM;
                end else if (sel_wram) begin
                    wram_we <= !s_rnw;
                    ss <= S_RAM1;
                end else if (v_cs) begin
                    v_req <= 1'b1;
                    ss <= S_VID;
                end else begin
                    // the registers: writes land now, reads answer in two clocks
                    s_q <= 16'h0000;
                    if (!s_rnw) begin
                        if (sel_prot) begin
                            if (s_be[1]) prot[s_addr[4:1]][15:8] <= s_d[15:8];
                            if (s_be[0]) prot[s_addr[4:1]][7:0]  <= s_d[7:0];
                            if (s_addr[4:1] == 4'hC) prot_go <= 1'b1;
                        end
                        if (sel_ccu && s_be[0]) ccu[s_addr[4:1]] <= s_d[7:0];
                        if (sel_sirq) snd_irq_set <= 1'b1;
                        if (sel_321 && s_be[0]) case (s_addr[4:1])
                            4'h0: k321_active <= s_d[7:0];
                            4'h2: k321_vol <= 7'd0;
                            4'h3: if (s_d[7:0] != 8'd0 && k321_vol < 7'd64) k321_vol <= k321_vol + 7'd1;
                            4'h6: latch0 <= s_d[7:0];
                            4'h7: latch1 <= s_d[7:0];
                            default: ;
                        endcase
                        if (sel_ctl) begin
                            if (s_be[1]) ctl2[15:8] <= s_d[15:8];
                            if (s_be[0]) ctl2[7:0]  <= s_d[7:0];
                        end
                    end else begin
                        if (sel_321 && s_addr[4:1] == 4'hA) s_q <= {8'h00, latch2};
                        if (sel_pin) s_q <= s_addr[1] ? {p4, p2} : {p3, p1};
                        if (sel_in)  s_q <= s_addr[1] ? {8'h00, dsw, test_n, 1'b0, eep_rdy, eep_do}
                                                      : {8'h00, in0};
                        if (sel_ctl) s_q <= ctl2;
                    end
                    ss <= S_WAIT;
                end
            end
            S_WAIT: begin s_ack <= 1'b1; ss <= S_IDLE; end
            S_RAM1: ss <= S_RAM2;
            S_RAM2: begin s_q <= wram_q; s_ack <= 1'b1; ss <= S_IDLE; end
            S_ROM: if (mrom_ack) begin mrom_req <= 1'b0; s_q <= mrom_q; s_ack <= 1'b1; ss <= S_IDLE; end
            S_VID: if (v_ack) begin s_q <= v_q; s_ack <= 1'b1; ss <= S_IDLE; end
            default: ss <= S_IDLE;
        endcase
        if (rst) begin
            ss <= S_IDLE; mrom_req <= 1'b0; ctl2 <= 16'd0; k321_active <= 8'd0; k321_vol <= 7'd0;
            latch0 <= 8'd0; latch1 <= 8'd0;
            for (int i = 0; i < 16; i++) prot[i] <= 16'd0;
        end
    end

    // ------------------------------------------------ the 68000's cycle
    // A cycle starts when AS falls.  Reads wait for the slave.  A write is
    // made when DS falls (its data is stable by then) and acknowledged at
    // once -- the board adds no wait state, and every bus slave here takes a
    // write within a few clocks, long before the next cycle -- except the
    // write that starts the protection engine with a non-zero length, which
    // is held until the engine is done.  An interrupt acknowledge is
    // autovectored and clears its level (MAME's HOLD_LINE).
    logic as_d, ds_d, in_cyc, wr_pend, dtack, vpa, iack;
    logic irq4, irq5;
    logic p_busy;                           // protection engine running
    logic c_req;                            // 68000 wants the bus
    logic [23:1] c_addr;
    logic  [1:0] c_be;
    logic        c_rnw;
    wire as = !ASn;
    wire ds = !UDSn || !LDSn;
    assign DTACKn = !dtack;
    assign VPAn   = !vpa;

    always_ff @(posedge clk) begin
        as_d <= as; ds_d <= ds;
        c_req <= 1'b0;
        if (!as) begin
            in_cyc <= 1'b0; dtack <= 1'b0; vpa <= 1'b0; wr_pend <= 1'b0;
        end else if (!as_d) begin
            in_cyc <= 1'b1;
            iack <= FC2 && FC1 && FC0;
            if (FC2 && FC1 && FC0) begin
                vpa <= 1'b1;
            end else if (RWn) begin
                c_req <= 1'b1; c_addr <= eab; c_rnw <= 1'b1; c_be <= 2'b11;
            end else begin
                wr_pend <= 1'b1;
            end
        end else if (in_cyc) begin
            if (wr_pend && ds) begin
                wr_pend <= 1'b0;
                c_req <= 1'b1; c_addr <= eab; c_rnw <= 1'b0; c_be <= {!UDSn, !LDSn};
                // the protection trigger (word 0C) with a length waits for the engine
                if (!({eab, 1'b0} == 24'h0CE018 && prot[15] != 16'd0)) dtack <= 1'b1;
            end
            if (s_ack && c_rnw && !p_busy && !iack) begin
                cpu_di <= s_q;
                dtack <= 1'b1;
            end
            if (p_done) dtack <= 1'b1;
        end
        if (rst) begin in_cyc <= 1'b0; dtack <= 1'b0; vpa <= 1'b0; end
    end

    // interrupts: IRQ4 at the first line of vblank (CONTROL2 bit 11), IRQ5 at
    // the end of object DMA (bit 5); each held until acknowledged
    wire [2:0] iack_level = eab[3:1];
    always_ff @(posedge clk) begin
        if (vblank_irq && ctl2[11]) irq4 <= 1'b1;
        if (dma_done && ctl2[5])    irq5 <= 1'b1;
        if (as && !as_d && FC2 && FC1 && FC0) begin
            if (iack_level == 3'd4) irq4 <= 1'b0;
            if (iack_level == 3'd5) irq5 <= 1'b0;
        end
        if (rst) begin irq4 <= 1'b0; irq5 <= 1'b0; end
    end
    assign IPLn = irq5 ? ~3'd5 : irq4 ? ~3'd4 : 3'b111;

    // ------------------------------------------------ K053990 protection
    // moo_prot_w: on a write to word 0C, `length` = word 0F times,
    // dst[i] = src1[i] + 2 * src2[i], through the CPU's address space.
    typedef enum logic [2:0] { P_IDLE, P_RA, P_RB, P_W, P_NEXT } pst_t;
    pst_t ps;
    logic [23:1] pa, pb, pd;
    logic [15:0] plen, pva;
    logic        p_req, p_rnw, p_done;
    logic [23:1] p_addr;
    logic [15:0] p_d;
    assign p_busy = (ps != P_IDLE);
    always_ff @(posedge clk) begin
        p_req <= 1'b0; p_done <= 1'b0;
        case (ps)
            P_IDLE: if (prot_go) begin
                // the trigger write has just landed; its slave cycle ends this
                // clock, so the engine's first request finds the bus free
                if (prot[15] != 16'd0) begin
                    pa <= {prot[1][7:0], prot[0][15:1]};
                    pb <= {prot[3][7:0], prot[2][15:1]};
                    pd <= {prot[5][7:0], prot[4][15:1]};
                    plen <= prot[15];
                    p_req <= 1'b1; p_rnw <= 1'b1; p_addr <= {prot[1][7:0], prot[0][15:1]};
                    ps <= P_RA;
                end
            end
            P_RA: if (s_ack) begin
                pva <= s_q;
                p_req <= 1'b1; p_rnw <= 1'b1; p_addr <= pb;
                ps <= P_RB;
            end
            P_RB: if (s_ack) begin
                p_req <= 1'b1; p_rnw <= 1'b0; p_addr <= pd; p_d <= pva + {s_q[14:0], 1'b0};
                ps <= P_W;
            end
            P_W: if (s_ack) ps <= P_NEXT;
            P_NEXT: begin
                pa <= pa + 23'd1; pb <= pb + 23'd1; pd <= pd + 23'd1;
                plen <= plen - 16'd1;
                if (plen == 16'd1) begin p_done <= 1'b1; ps <= P_IDLE; end
                else begin p_req <= 1'b1; p_rnw <= 1'b1; p_addr <= pa + 23'd1; ps <= P_RA; end
            end
            default: ps <= P_IDLE;
        endcase
        if (rst) ps <= P_IDLE;
    end

    // bus master mux: the engine owns the bus from its trigger to its end
    assign s_req  = p_busy ? p_req  : c_req;
    assign s_addr = p_busy ? p_addr : c_addr;
    assign s_rnw  = p_busy ? p_rnw  : c_rnw;
    assign s_be   = p_busy ? 2'b11  : c_be;
    assign s_d    = p_busy ? p_d    : cpu_do;

    // ------------------------------------------------ EEPROM
    logic [7:0] eep [128];
    logic [6:0] e_addr;
    logic [7:0] e_din, e_q;
    logic       e_we;
    logic       e_dump;
    // the default contents come with the ROM image, at 0xD40000
    wire dl_eep = dl_we && (dl_addr[24:7] == 18'h1A800);
    always_ff @(posedge clk) begin
        if (e_we) eep[e_addr] <= e_din;
        e_q <= eep[e_addr];
    end
    // second port: the download's default contents, the save slot's load
    // and its unload -- one address, so it stays a block RAM port
    wire [6:0] eb_addr = dl_eep ? dl_addr[6:0] : nv_addr;
    always_ff @(posedge clk) begin
        if (dl_eep || nv_we) eep[eb_addr] <= dl_eep ? dl_data : nv_din;
        nv_dout <= eep[eb_addr];
    end
    jt5911 #(.PROG(0)) u_eeprom (
        .rst(rst), .clk(clk),
        .sclk(ctl2[2]), .sdi(ctl2[0]), .sdo(eep_do), .rdy(eep_rdy), .scs(ctl2[1]),
        .mem_addr(e_addr), .mem_din(e_din), .mem_we(e_we), .mem_dout(e_q),
        .dump_clr(1'b0), .dump_flag(e_dump)
    );
    logic e_we_d;
    always_ff @(posedge clk) begin e_we_d <= e_we; nv_changed <= e_we && !e_we_d; end

    // ================================================================ video
    logic [7:0] vstat;
    moo_video u_video (
        .clk(clk), .rst(rst), .cen_pix(cen_pix),
        .cpu_req(v_req), .cpu_addr(s_addr), .cpu_rnw(s_rnw), .cpu_be(s_be), .cpu_d(s_d),
        .cpu_ack(v_ack), .cpu_q(v_q), .cpu_cs(v_cs), .objcha(ctl2[8]),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vblank_irq(vblank_irq), .dma_done(dma_done), .hpos(), .vpos(),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .dbg_list_we(1'b0), .dbg_list_addr(11'd0), .dbg_list_d(16'd0), .dbg_sort(1'b0),
        .dbg_index(), .dbg_alpha(), .dbg_shadow(),
        .spr_worst(), .spr_missed(vstat[0]), .tile_missed(vstat[1]), .tile_busy(),
        .tile_fetches(), .tile_skips(), .unsupported(vstat[2])
    );

    // ================================================================ sound
    logic [15:0] zA;
    logic  [7:0] z_do, z_di;
    logic        z_m1_n, z_mreq_n, z_iorq_n, z_rd_n, z_wr_n, z_wait_n, z_int_n;
    z80_cen u_z80 (
        .clk(clk), .cen(cen_z80), .reset_n(!rst), .wait_n(z_wait_n), .int_n(z_int_n), .nmi_n(1'b1),
        .m1_n(z_m1_n), .mreq_n(z_mreq_n), .iorq_n(z_iorq_n), .rd_n(z_rd_n), .wr_n(z_wr_n),
        .A(zA), .di(z_di), .dout(z_do)
    );
    wire zmem   = !z_mreq_n;
    wire zrd    = zmem && !z_rd_n;
    wire zwr    = zmem && !z_wr_n;
    wire zs_rom = zA < 16'hC000;
    wire zs_ram = (zA[15:13] == 3'b110);                    // C000-DFFF
    wire zs_539 = (zA >= 16'hE000) && (zA <= 16'hE22F);
    wire zs_ym  = (zA[15:1] == 15'h7600);                   // EC00-EC01
    wire zs_321 = (zA[15:2] == 14'h3C00);                   // F000-F003
    wire zs_bnk = (zA == 16'hF800);

    // Z80 interrupt: set by the 68000's write to 0D4000, held until acknowledged
    always_ff @(posedge clk) begin
        if (snd_irq_set) z_int_n <= 1'b0;
        else if (!z_m1_n && !z_iorq_n) z_int_n <= 1'b1;
        if (rst) z_int_n <= 1'b1;
    end

    // ROM (bank at 8000-BFFF), through the memory module; the Z80 waits for it
    logic [3:0] zbank;
    logic       zrom_done;
    logic [7:0] zrom_q;
    always_ff @(posedge clk) begin
        if (!zrd) zrom_done <= 1'b0;
        if (zrd && zs_rom && !zrom_done && !srom_req) begin
            srom_req  <= 1'b1;
            srom_addr <= zA[15] ? {zbank, zA[13:0]} : {3'b000, zA[14:0]};
        end
        if (srom_req && srom_ack) begin srom_req <= 1'b0; zrom_done <= 1'b1; zrom_q <= srom_q; end
        if (zwr && zs_bnk) zbank <= z_do[3:0];
        if (rst) begin srom_req <= 1'b0; zrom_done <= 1'b0; zbank <= 4'd0; end
    end

    // RAM, 8 KB
    logic [7:0] zram [8192];
    logic [7:0] zram_q;
    always_ff @(posedge clk) begin
        if (zwr && zs_ram) zram[zA[12:0]] <= z_do;
        zram_q <= zram[zA[12:0]];
    end

    // K054321, sound side: F000 writes latch 2, F002/F003 read latches 0/1
    always_ff @(posedge clk) begin
        if (zwr && zs_321 && zA[1:0] == 2'd0) latch2 <= z_do;
        if (rst) latch2 <= 8'd0;
    end

    // YM2151
    logic [7:0] ym_do;
    logic signed [15:0] ym_l, ym_r;
    /* verilator lint_off PINCONNECTEMPTY */
    jt51 u_ym (
        .rst(rst), .clk(clk), .cen(cen_ym), .cen_p1(cen_ym2),
        .cs_n(!(zmem && zs_ym)), .wr_n(z_wr_n), .a0(zA[0]), .din(z_do), .dout(ym_do),
        .ct1(), .ct2(), .irq_n(), .sample(), .left(ym_l), .right(ym_r), .xleft(), .xright()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // K054539: one write per Z80 cycle, held off while the chip works out a sample
    logic k_wdone, k_rstart, k_busy, k_rbusy, k_overrun;
    logic [7:0] k_do;
    logic signed [17:0] k_l, k_r;
    wire  k_we = zwr && zs_539 && !k_wdone && !k_busy;
    wire  k_re = zrd && zs_539 && !k_rstart;
    always_ff @(posedge clk) begin
        if (!zwr) k_wdone <= 1'b0; else if (k_we) k_wdone <= 1'b1;
        if (!zrd) k_rstart <= 1'b0; else if (k_re) k_rstart <= 1'b1;
    end
    k054539 u_539 (
        .clk(clk), .rst(rst), .cen_snd(cen_snd),
        .cs(zs_539), .we(k_we), .re(k_re), .addr(zA[9:0]), .din(z_do), .dout(k_do),
        .busy(k_busy), .rd_busy(k_rbusy),
        .rom_req(pcm_req), .rom_addr(pcm_addr), .rom_ack(pcm_ack), .rom_q(pcm_q),
        .out_l(k_l), .out_r(k_r), .overrun(k_overrun),
        .worst(dbg_snd_worst), .worst_reads(dbg_snd_reads)
    );

    assign z_wait_n = !((zrd && zs_rom && !zrom_done) ||
                        (zwr && zs_539 && !k_wdone) ||
                        (zrd && zs_539 && (k_rbusy || !k_rstart)));
    always_comb begin
        z_di = 8'hFF;
        if (zs_rom)      z_di = zrom_q;
        else if (zs_ram) z_di = zram_q;
        else if (zs_539) z_di = k_do;
        else if (zs_ym)  z_di = ym_do;
        else if (zs_321) z_di = (zA[1:0] == 2'd2) ? latch0 : (zA[1:0] == 2'd3) ? latch1 : 8'hFF;
    end

    // ------------------------------------------------ mix (hardware.md 6)
    // speaker left  = (0.30 * YM left  + 0.50 * K054539 right) * K054321 gain
    // speaker right = (0.30 * YM right + 0.50 * K054539 left)  * K054321 gain
    // gain = 2 ^ ((volume - 40) / 10), a side muted when its enable bit is 0
    function automatic [15:0] k321_gain(input [6:0] v);
        logic [15:0] t [65];
        t = '{16'd256, 16'd274, 16'd294, 16'd315, 16'd338, 16'd362, 16'd388, 16'd416, 16'd446, 16'd478,
              16'd512, 16'd549, 16'd588, 16'd630, 16'd676, 16'd724, 16'd776, 16'd832, 16'd891, 16'd955,
              16'd1024, 16'd1097, 16'd1176, 16'd1261, 16'd1351, 16'd1448, 16'd1552, 16'd1663, 16'd1783, 16'd1911,
              16'd2048, 16'd2195, 16'd2353, 16'd2521, 16'd2702, 16'd2896, 16'd3104, 16'd3327, 16'd3566, 16'd3822,
              16'd4096, 16'd4390, 16'd4705, 16'd5043, 16'd5405, 16'd5793, 16'd6208, 16'd6654, 16'd7132, 16'd7643,
              16'd8192, 16'd8780, 16'd9410, 16'd10086, 16'd10809, 16'd11585, 16'd12417, 16'd13308, 16'd14263, 16'd15287,
              16'd16384, 16'd17560, 16'd18820, 16'd20171, 16'd21619};
        k321_gain = (v > 7'd64) ? t[64] : t[v];
    endfunction
    function automatic signed [15:0] clip16(input signed [31:0] v);
        clip16 = (v > 32'sd32767) ? 16'sd32767 : (v < -32'sd32768) ? -16'sd32768 : 16'(v);
    endfunction
    logic signed [31:0] mix_l, mix_r;
    always_ff @(posedge clk) begin
        mix_l <= (32'(ym_l) * 32'sd1229 + 32'(k_r) * 32'sd2048) >>> 12;     // 0.30, 0.50 in Q12
        mix_r <= (32'(ym_r) * 32'sd1229 + 32'(k_l) * 32'sd2048) >>> 12;
        snd_l <= k321_active[1] ? clip16((mix_l * 32'(k321_gain(k321_vol))) >>> 12) : 16'sd0;
        snd_r <= k321_active[0] ? clip16((mix_r * 32'(k321_gain(k321_vol))) >>> 12) : 16'sd0;
    end

    // ------------------------------------------------ bring-up status
    logic seen4, seen5;
    always_ff @(posedge clk) begin
        if (irq4) seen4 <= 1'b1;
        if (irq5) seen5 <= 1'b1;
        if (rst) begin seen4 <= 1'b0; seen5 <= 1'b0; end
    end
    assign vstat[7:3] = 5'd0;
    assign dbg_status = {seen5, seen4, 1'b0, k_overrun, 1'b0, vstat[2:0]};

    wire _unused = &{1'b0, ccu[0], e_dump, iack, ds_d, 1'b0};
endmodule

`default_nettype wire
