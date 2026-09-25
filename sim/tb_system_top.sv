// Whole-machine bench, through the Pocket's real memory glue: moomesa_core
// against moomesa_mem, sdram_ctrl and sram_port, with behavioural chips beyond
// the pins and the ROM image sent in through the download port at the APF
// loader's rate.
//
// This is the bench two shipped cores did without, and both paid for it: a
// whole-machine bench that answers the CPUs from plain arrays never exercises
// the memory controller, its arbiter, the refresh, or the download path that
// fills it, and all three faults that blacked out their first hardware runs
// lived there (METHODOLOGY section 5.16).  It is slower than an ideal-memory
// bench.  Keep both: this one is the gate before a flash.
//
// The C++ side is sim/tb_system.cpp.  With the skeleton core it draws the test
// pattern; once there is a machine it runs the game, and the same driver
// dumps frames and counts watchdogs either way.
`default_nettype none

module tb_system_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,

    // the ROM image, a byte at a time in the order the MRA builds it
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,

    input  logic  [7:0] p1, p2, p3, p4, in0,
    input  logic        test_n,
    input  logic  [3:0] dsw,

    output logic [23:0] rgb,
    output logic        de, pix_ce, vblank, hblank, hsync, vsync,
    output logic signed [15:0] snd_l, snd_r,
    output logic        dbg_halted, watchdog_reset,
    output logic  [7:0] dbg_status,
    output logic [15:0] mrom_misses,
    output logic        mem_ready
);
    logic        mrom_req, mrom_ack;  logic [19:1] mrom_addr;  logic [15:0] mrom_q;
    logic        srom_req, srom_ack;  logic [17:0] srom_addr;  logic  [7:0] srom_q;
    logic        pcm_req,  pcm_ack;   logic [20:0] pcm_addr;   logic  [7:0] pcm_q;
    logic        tile_req, tile_ack;  logic [18:0] tile_addr;  logic [31:0] tile_q;
    logic        spr_req,  spr_ack;   logic [19:0] spr_addr;   logic [63:0] spr_q;
    logic        vram_ack;  logic [15:0] vram_q;

    wire [15:0] dram_dq;  wire [12:0] dram_a;  wire [1:0] dram_ba;
    wire        dram_dqml, dram_dqmh, dram_clk, dram_cke;
    wire        dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
    wire [16:0] sram_a;   wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    // The SDRAM's power-up sequence has to finish before the loader's first
    // byte, exactly as it does on the Pocket, so it is counted out from the
    // driver's first reset rather than tied to it.
    logic [7:0] por;
    logic       seen_reset;
    always_ff @(posedge clk) begin
        if (reset && !seen_reset) begin seen_reset <= 1'b1; por <= '0; end
        else if (!(&por)) por <= por + 8'd1;
    end
    wire mem_init = !seen_reset || !(&por);

    moomesa_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(mem_init), .ready(mem_ready),
        .rd_late(1'b1), .burst_slow(1'b0), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(reset),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .vram_req(1'b0), .vram_we(1'b0), .vram_addr(15'd0),
        .vram_din(16'd0), .vram_ben(2'b00), .vram_ack(vram_ack), .vram_q(vram_q),
        .mrom_misses(mrom_misses),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba),
        .SDRAM_DQML(dram_dqml), .SDRAM_DQMH(dram_dqmh),
        .SDRAM_nCS(dram_cs_n), .SDRAM_nWE(dram_we_n),
        .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba),
        .dqml(dram_dqml), .dqmh(dram_dqmh), .cs_n(dram_cs_n),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n), .cke(dram_cke)
    );
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n),
                     .we_n(sram_we_n), .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    moomesa_core u_core (
        .clk(clk), .rst(reset | ~mem_ready), .pause(pause), .pix_sync(1'b0),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .tile_req(tile_req), .tile_addr(tile_addr), .tile_ack(tile_ack), .tile_q(tile_q),
        .spr_req(spr_req), .spr_addr(spr_addr), .spr_ack(spr_ack), .spr_q(spr_q),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data),
        .nv_addr(7'd0), .nv_we(1'b0), .nv_din(8'd0), .nv_dout(), .nv_changed(),
        .p1(p1), .p2(p2), .p3(p3), .p4(p4), .in0(in0), .test_n(test_n), .dsw(dsw),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .pix_ce(pix_ce), .de(de), .snd_l(snd_l), .snd_r(snd_r),
        .dbg_halted(dbg_halted), .dbg_addr(f_addr), .dbg_bus(f_bus), .dbg_wait(),
        .watchdog_reset(watchdog_reset),
        .dbg_status(dbg_status), .dbg_snd_worst(), .dbg_snd_reads()
    );

    // The hardware's own first-fault capture, run here so it is proven quiet
    // on a healthy boot before it is trusted on a sick one, and so a bench
    // failure says WHERE (METHODOLOGY section 5.21).
    logic [23:1] f_addr;  logic f_bus, f_hit, f_hit_d, f_rst;
    logic  [7:0] f_vec, f_n;  logic [23:0] f_pc0, f_pc1, f_io;
    always_ff @(posedge clk) f_rst <= reset | ~mem_ready;
    dbg_fault u_fault (
        .clk(clk), .rst(f_rst), .addr(f_addr), .bus(f_bus),
        .hit(f_hit), .vec(f_vec), .pc0(f_pc0), .pc1(f_pc1), .io(f_io), .faults(f_n)
    );
    always_ff @(posedge clk) begin
        f_hit_d <= f_hit;
        if (f_hit && !f_hit_d)
            $display("FAULT CAPTURE: vector %02x, pc0 %06x, pc1 %06x, io %06x",
                     f_vec, f_pc0, f_pc1, f_io);
    end
endmodule

`default_nettype wire
