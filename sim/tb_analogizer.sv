// The Analogizer path on its own: target/pocket/pocket_analogizer.sv with the
// vendored adapter module behind it, driven the way core_top drives it -- this
// core's raster (512 x 264 dots, 384 x 224 visible, one dot per 12 clocks of
// 96 MHz), the 48 MHz Analogizer clock in phase with it, and the settings file
// written over the bridge as the Pocket writes analogizer.bin.  The raster
// is set at the top of the module: change it with the core's.  It reads the
// cartridge pins as the ADV7123 would and checks:
//
//   idle    no file: every cartridge pin as on a core without an Analogizer,
//           and the controller words pass through
//   RGBS    every visible pixel of a frame reaches the DAC pins, in order,
//           as its top six bits per channel; csync once a line, hsync-long
//   SVGA    the scandoubler: twice the lines per frame, at half the period
//   YPbPr, Y/C  run without an unknown on any pin (no reference to compare)
//   SNAC    each assignment puts pads where AnalogizerConfigurator says
//   blank   "blank the Pocket screen" reaches pocket_off
//
// sim/run_analogizer.sh builds and runs it.
`timescale 1ps/1ps
`default_nettype none

module tb_analogizer;
    // ------------------------------------------- the core's raster: SET THESE
    // to the core's (its video module, and core_top's pocket_analogizer
    // parameters).  This core: moo_video.sv, 8 MHz dots from 96 MHz.
    localparam int DIV    = 12;           // system clocks a dot
    localparam int HTOTAL = 512, VTOTAL = 264;
    localparam int X0 = 40,  X1 = 423;    // visible dots, inclusive
    localparam int Y0 = 16,  Y1 = 239;    // visible lines, inclusive
    localparam int HS0 = 457, HS1 = 497;  // hsync [HS0, HS1)
    localparam int VS0 = 257, VS1 = 264;  // vsync [VS0, VS1)
    localparam int CLK_HZ = 48_000_000;   // the Analogizer's clock: clk_sys / 2
    localparam int W = X1 - X0 + 1, H = Y1 - Y0 + 1;
    localparam int APD = DIV / 2;         // Analogizer clocks a dot
    localparam int FRAME = HTOTAL * VTOTAL * APD;

    // ------------------------------------------------------------- clocks
    logic clk_src = 1'b0, clk = 1'b0, clk_74a = 1'b0;
    always #5208 clk_src = ~clk_src;      // 96 MHz (10.416 ns)
    always #10416 clk = ~clk;             // 48 MHz, edges on clk_src's
    always #6734 clk_74a = ~clk_74a;      // 74.25 MHz, unrelated

    // ------------------------------------------------- the core's raster
    int         div = 0;
    logic [9:0] hpos = 10'd0, vpos = 10'd0;
    logic       pix_ce = 1'b0;
    logic       hs, vs, hb, vb;
    logic [23:0] rgb;
    always_ff @(posedge clk_src) begin
        div    <= (div == DIV - 1) ? 0 : div + 1;
        pix_ce <= (div == DIV - 1);
        if (pix_ce) begin
            if (hpos == 10'(HTOTAL - 1)) begin
                hpos <= 10'd0;
                vpos <= (vpos == 10'(VTOTAL - 1)) ? 10'd0 : vpos + 10'd1;
            end else hpos <= hpos + 10'd1;
        end
    end
    wire vis_x = (hpos >= 10'(X0)) && (hpos <= 10'(X1));
    wire vis_y = (vpos >= 10'(Y0)) && (vpos <= 10'(Y1));
    // a colour every dot can be told apart by: x in red and blue, y in green
    function automatic [23:0] colour(input [9:0] x, input [9:0] y);
        colour = {x[7:0], y[7:0], ~x[7:0] ^ {y[1:0], 6'd0}};
    endfunction
    always_ff @(posedge clk_src) if (pix_ce) begin
        hb  <= !vis_x;  vb <= !vis_y;
        hs  <= (hpos >= 10'(HS0)) && (hpos < 10'(HS1));
        vs  <= (vpos >= 10'(VS0)) && (vpos < 10'(VS1));
        rgb <= (vis_x && vis_y) ? colour(hpos, vpos) : 24'h0;
    end

    // ------------------------------------------------------------- bridge
    logic [31:0] bridge_addr = 32'h0, bridge_wr_data = 32'h0;
    logic        bridge_wr = 1'b0, bridge_rd = 1'b0;
    wire  [31:0] bridge_rd_data;
    // analogizer.bin is the setting word little-endian; the Pocket hands a
    // file over big-endian (bridge_endian_little = 0 in core_top)
    task automatic write_settings(input [31:0] v);
        @(posedge clk_74a);
        bridge_addr    <= 32'hF7000000;
        bridge_wr_data <= {v[7:0], v[15:8], v[23:16], v[31:24]};
        bridge_wr      <= 1'b1;
        @(posedge clk_74a);
        bridge_wr      <= 1'b0;
        repeat (200) @(posedge clk);         // into the Analogizer's domain and back
    endtask
    function automatic [31:0] settings(input ena, input [4:0] snac, input [3:0] assign_,
                                       input [3:0] video, input blank);
        settings = {16'h0, 1'b0, blank, video, assign_, ena, snac};
    endfunction

    // --------------------------------------------------------- controllers
    logic [31:0] cont1_key = 32'h1000_0001, cont2_key = 32'h2000_0002;
    logic [31:0] cont3_key = 32'h3000_0004, cont4_key = 32'h4000_0008;
    wire  [31:0] key1, key2, key3, key4;
    wire         ena, pocket_off;

    // ----------------------------------------------------------- cartridge
    wire [7:0] bank3, bank2, bank1;
    wire [7:4] bank0;
    wire       pin30, pin31;
    wire       bank3_dir, bank2_dir, bank1_dir, bank0_dir, pin30_dir, pin31_dir, pin30_pwroff;

    logic rst = 1'b1;

    pocket_analogizer #(.CLK_HZ(CLK_HZ), .LINE_LEN(HTOTAL)) dut (
        .clk_74a(clk_74a), .clk(clk), .rst(rst),
        .clk_src(clk_src), .src_pix_ce(pix_ce), .src_rgb(rgb),
        .src_hs(hs), .src_vs(vs), .src_hb(hb), .src_vb(vb),
        .bridge_endian_little(1'b0), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .cont1_key(cont1_key), .cont2_key(cont2_key), .cont3_key(cont3_key), .cont4_key(cont4_key),
        .key1(key1), .key2(key2), .key3(key3), .key4(key4),
        .ena(ena), .pocket_off(pocket_off), .ps2_code_new(), .ps2_code(),
        .cart_tran_bank2(bank2), .cart_tran_bank2_dir(bank2_dir),
        .cart_tran_bank3(bank3), .cart_tran_bank3_dir(bank3_dir),
        .cart_tran_bank1(bank1), .cart_tran_bank1_dir(bank1_dir),
        .cart_tran_bank0(bank0), .cart_tran_bank0_dir(bank0_dir),
        .cart_tran_pin30(pin30), .cart_tran_pin30_dir(pin30_dir),
        .cart_pin30_pwroff_reset(pin30_pwroff),
        .cart_tran_pin31(pin31), .cart_tran_pin31_dir(pin31_dir)
    );

    // the DAC's view of the pins (openFPGA_Pocket_Analogizer.v, end)
    wire [5:0] dac_r = bank3[7:2], dac_g = bank2[5:0];
    wire [5:0] dac_b = {bank1[4:0], bank2[7]};
    wire       dac_hs = bank3[1], dac_vs = bank3[0], dac_blank_n = bank2[6];

    int errors = 0;
    task automatic fail(input string what);
        $display("FAIL: %s", what);
        errors++;
    endtask

    // wait for the start of a frame as the core makes it
    task automatic frame_start();
        @(posedge clk_src iff (pix_ce && hpos == 10'(HTOTAL - 1) && vpos == 10'(VTOTAL - 1)));
    endtask

    // ------------------------------------------------------------- checks
    // RGBS: collect the visible pixels as the DAC samples them (on clk) and
    // compare them, in order, with the frame the core drew
    task automatic check_rgbs();
        int n, bad, line_px, lines, cs_lo, cs_runs, cs_bad;
        logic [17:0] want, got, prev;
        logic        was_blank, cs_prev;
        int          x, y, run;
        // the expected stream: visible dots in raster order
        logic [17:0] exp_q[$];
        for (y = Y0; y <= Y1; y++)
            for (x = X0; x <= X1; x++) begin
                logic [23:0] c = colour(10'(x), 10'(y));
                exp_q.push_back({c[23:18], c[15:10], c[7:2]});
            end
        frame_start();
        repeat (2000) @(posedge clk);       // the pipeline's own latency, well inside vblank
        n = 0; bad = 0; run = 0; prev = 18'h3ffff; line_px = 0; lines = 0;
        was_blank = 1'b1; cs_prev = 1'b1; cs_lo = 0; cs_runs = 0; cs_bad = 0;
        // one frame of the Analogizer's clock
        repeat (FRAME) begin
            @(negedge clk);
            if (dac_blank_n) begin
                got = {dac_r, dac_g, dac_b};
                // a dot is held APD clocks: take it once, on its first
                if (was_blank || run == APD) begin
                    if (n < exp_q.size()) begin
                        if (got !== exp_q[n]) begin
                            if (bad < 5) $display("  dot %0d (line %0d, x %0d): got %05h want %05h",
                                                  n, n / W, n % W, got, exp_q[n]);
                            bad++;
                        end
                    end
                    n++; run = 1; line_px++;
                end else run++;
            end else if (!was_blank) begin
                if (line_px != W) cs_bad++;
                line_px = 0; lines++; run = 0;
            end
            was_blank = !dac_blank_n;
            // csync: active low, the hsync's length on a line outside vsync
            if (!dac_hs) cs_lo++;
            else if (!cs_prev) begin
                if (cs_lo == (HS1 - HS0) * APD) cs_runs++;
                cs_lo = 0;
            end
            cs_prev = dac_hs;
        end
        $display("RGBS: %0d visible dots in %0d lines, %0d differ; %0d short lines; %0d csync pulses of %0d dots",
                 n, lines, bad, cs_bad, cs_runs, HS1 - HS0);
        if (n != W * H) fail("RGBS: wrong number of visible dots");
        if (lines != H) fail("RGBS: wrong number of visible lines");
        if (bad != 0) fail("RGBS: pixels differ from what the core drew");
        if (cs_bad != 0) fail("RGBS: a line without every visible dot");
        if (cs_runs < VTOTAL - (VS1 - VS0) - 2) fail("RGBS: csync not one hsync-long pulse a line");
        if (dac_vs !== 1'b1) fail("RGBS: VGA vsync pin not high");
    endtask

    // the scandoubler: hsync pulses between two like vsync edges, and the
    // line period (either polarity: only like edges are compared)
    task automatic check_svga();
        int hs_n, period, last, t;
        logic hs_p, vs_p, vs_edge;
        frame_start();
        repeat (2000) @(posedge clk);
        vs_p = dac_vs;
        @(negedge clk iff dac_vs !== vs_p);
        vs_edge = dac_vs; vs_p = dac_vs; hs_p = dac_hs;
        hs_n = 0; last = 0; period = 0; t = 0;
        while (t < 2 * FRAME) begin
            @(negedge clk); t++;
            if (!hs_p && dac_hs) begin hs_n++; period = t - last; last = t; end
            hs_p = dac_hs;
            if (dac_vs !== vs_p && dac_vs === vs_edge) break;
            vs_p = dac_vs;
        end
        $display("SVGA: %0d hsync pulses in a frame of %0d clocks, line period %0d clocks", hs_n, t, period);
        if (hs_n != 2 * VTOTAL) fail("SVGA: not twice the core's lines");
        if (period * 2 != HTOTAL * APD) fail("SVGA: line period is not half the core's");
        if (t != FRAME) fail("SVGA: frame period is not the core's");
    endtask

    // no unknown on any output pin for a whole frame
    task automatic check_known(input string mode);
        int unk = 0, changes = 0;
        logic [17:0] prev = '0;
        frame_start();
        repeat (2000) @(posedge clk);
        repeat (FRAME) begin
            @(negedge clk);
            if ($isunknown({bank3, bank2, bank1[5:0]})) unk++;
            if ({dac_r, dac_g, dac_b} != prev) changes++;
            prev = {dac_r, dac_g, dac_b};
        end
        $display("%s: %0d clocks with an unknown pin, %0d colour changes", mode, unk, changes);
        if (unk != 0) fail({mode, ": unknown on the pins"});
        if (changes < 1000) fail({mode, ": the picture does not move"});
    endtask

    task automatic check_idle();
        if (bank3_dir !== 1'b0 || bank2_dir !== 1'b0 || bank1_dir !== 1'b0)
            fail("idle: a video bank is driven");
        if (bank0 !== 4'hf || bank0_dir !== 1'b1) fail("idle: bank0 not 4'hf, out");
        if (pin30_dir !== 1'b0 || pin31_dir !== 1'b0 || pin30_pwroff !== 1'b0)
            fail("idle: pin30/31 not as an unused port");
        // (the banks' own values are not checked: the simulator resolves a
        // released inout to 0, and with the translators set to input the
        // FPGA side drives nothing onto the port whatever it holds)
        if (key1 !== cont1_key || key2 !== cont2_key || key3 !== cont3_key || key4 !== cont4_key)
            fail("idle: controller words do not pass through");
        if (ena !== 1'b0 || pocket_off !== 1'b0) fail("idle: enabled with no file");
    endtask

    // SNAC: the pads, forced at the adapter module's outputs (the serial
    // protocols are the adapter's and are not this bench's business)
    task automatic check_snac();
        logic [15:0] s1 = 16'h8011, s2 = 16'h4022, s3 = 16'h0044, s4 = 16'h0088;
        force dut.p1_btn = s1; force dut.p2_btn = s2;
        force dut.p3_btn = s3; force dut.p4_btn = s4;
        force dut.p1_joy = 32'h0000_7F7F; force dut.p2_joy = 32'h0000_7F7F;
        // type 1 (DB15), each assignment
        for (int a = 0; a <= 5; a++) begin
            logic [15:0] w1, w2, w3, w4;
            write_settings(settings(1'b1, 5'h01, 4'(a), 4'h0, 1'b0));
            repeat (10) @(posedge clk_74a);
            case (a)
                0: {w1, w2, w3, w4} = {s1, cont1_key[15:0], cont3_key[15:0], cont4_key[15:0]};
                1: {w1, w2, w3, w4} = {cont1_key[15:0], s1, cont3_key[15:0], cont4_key[15:0]};
                2: {w1, w2, w3, w4} = {s1, s2, cont3_key[15:0], cont4_key[15:0]};
                3: {w1, w2, w3, w4} = {s2, s1, cont3_key[15:0], cont4_key[15:0]};
                4: {w1, w2, w3, w4} = {cont1_key[15:0], cont2_key[15:0], s1, s2};
                default: {w1, w2, w3, w4} = {s1, s2, s3, s4};
            endcase
            if ({key1[15:0], key2[15:0], key3[15:0], key4[15:0]} !== {w1, w2, w3, w4}) begin
                $display("  assignment %0d: got %04h %04h %04h %04h want %04h %04h %04h %04h", a,
                         key1[15:0], key2[15:0], key3[15:0], key4[15:0], w1, w2, w3, w4);
                fail("SNAC: assignment maps the pads wrongly");
            end
        end
        // a PlayStation pad in analog mode: the left stick is the d-pad
        force dut.p1_joy = 32'h0000_FF10;     // Y full down, X full left
        write_settings(settings(1'b1, 5'h13, 4'd0, 4'h0, 1'b0));
        repeat (10) @(posedge clk_74a);
        if (key1[3:0] !== 4'b0110) fail("SNAC: analog stick is not down+left");
        // SNAC type none: pass-through even when enabled
        write_settings(settings(1'b1, 5'h00, 4'd2, 4'h0, 1'b0));
        repeat (10) @(posedge clk_74a);
        if (key1 !== cont1_key || key2 !== cont2_key) fail("SNAC: type none does not pass through");
        release dut.p1_btn; release dut.p2_btn; release dut.p3_btn; release dut.p4_btn;
        release dut.p1_joy; release dut.p2_joy;
        $display("SNAC: assignments 0-5, analog stick, none: checked");
    endtask

    initial begin
        repeat (50) @(posedge clk);
        check_idle();
        rst = 1'b0;
        repeat (50) @(posedge clk);
        check_idle();                         // out of reset, still no file
        $display("idle: checked");

        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h0, 1'b0));   // RGBS
        if (ena !== 1'b1) fail("enable bit not seen");
        if (bank3_dir !== 1'b1 || bank2_dir !== 1'b1 || bank1_dir !== 1'b1) fail("RGBS: video banks not driven");
        check_rgbs();

        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h5, 1'b0));   // SC 0% RGBHV
        check_svga();
        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h2, 1'b0));   // YPbPr
        check_known("YPbPr");
        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h3, 1'b0));   // Y/C NTSC
        check_known("Y/C NTSC");
        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h4, 1'b0));   // Y/C PAL
        check_known("Y/C PAL");

        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h0, 1'b1));
        if (pocket_off !== 1'b1) fail("blank: pocket_off not set");
        write_settings(settings(1'b0, 5'h00, 4'd0, 4'h0, 1'b1));
        if (pocket_off !== 1'b0) fail("blank: pocket_off set with the Analogizer off");
        repeat (10) @(posedge clk);
        check_idle();
        $display("blank, and off again: checked");

        check_snac();

        if (errors == 0) $display("PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
