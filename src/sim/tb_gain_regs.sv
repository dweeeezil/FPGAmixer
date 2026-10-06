// -----------------------------------------------------------------------------
// tb_gain_regs.sv
//
// Unit test for gain_regs_axil (Phase 12) driving a pcm_gain between the
// stream converters, across two unrelated clocks (aclk 100 MHz, mclk
// ~12.288 MHz), with the AXI4-Lite master BFM of tb_matrix_regs. N = 5
// channels (not a power of two), TAP = 2 (output levels).
//
// Checks:
//   - ID / CONFIG (N, TAP, width, frac) / COMMITS / unmapped reads
//   - shadow reset = RESET_GAINS (unity), read back; output = input
//   - shadow writes do NOT reach the gain stage until COMMIT
//   - COMMIT applies the whole bank; COMMITS counts; -1.0 reads back
//     sign-extended
//   - atomicity: every frame, the gains the stage actually READ through its
//     coefficient port (rebuilt from the read port) are exactly the old bank
//     or the new bank, never a mix, over 20 back-to-back bank changes
//   - end to end: the converters' packed output = sat(in * gain) per channel
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_gain_regs;
    import mixer_core_pkg::*;

    localparam int N   = 5;
    localparam int TAP = 2;
    localparam int GW  = 18;
    localparam int GF  = 16;
    localparam int SW  = 24;
    localparam int CW  = $clog2(N);

    localparam logic [GW-1:0] G1 = 18'h10000;   //  1.0
    localparam logic [GW-1:0] GH = 18'h08000;   //  0.5
    localparam logic [GW-1:0] GN = 18'h30000;   // -1.0
    localparam logic [GW-1:0] G0 = 18'h00000;
    localparam logic [GW-1:0] GB = 18'h1C000;   //  1.75

    function automatic logic [N*GW-1:0] unity();
        logic [N*GW-1:0] g;
        for (int c = 0; c < N; c++) g[c*GW +: GW] = G1;
        return g;
    endfunction
    localparam logic [N*GW-1:0] RESET_GAINS = unity();

    // ----- Clocks / resets -----
    logic aclk = 0, mclk = 0;
    always #5      aclk = ~aclk;         // 100 MHz
    always #40.69  mclk = ~mclk;         // ~12.288 MHz, unrelated phase
    logic aresetn = 0, mrst_n = 0;

    // ----- AXI signals -----
    logic [11:0] awaddr, araddr;
    logic        awvalid, awready, wvalid, wready, bvalid, bready;
    logic        arvalid, arready, rvalid, rready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;

    logic [CW-1:0] coef_addr;
    logic [GW-1:0] coef_data;
    logic          frame = 0;

    gain_regs_axil #(
        .N (N), .TAP (TAP), .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .ADDR_WIDTH (12),
        .RESET_GAINS (RESET_GAINS)
    ) dut (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata  (wdata),  .s_axi_wstrb   (wstrb),
        .s_axi_wvalid (wvalid), .s_axi_wready  (wready),
        .s_axi_bresp  (bresp),  .s_axi_bvalid  (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata  (rdata),  .s_axi_rresp   (rresp),
        .s_axi_rvalid (rvalid), .s_axi_rready  (rready),
        .mclk (mclk), .frame_i (frame),
        .coef_addr (coef_addr), .coef_data (coef_data)
    );

    // ----- pack -> pcm_gain -> pack, one frame every 256 mclks -----
    logic [N*SW-1:0] in_flat, out_flat;
    logic            a_valid, b_valid, sv_out, s_err;
    logic [CW-1:0]   a_ch, b_ch;
    logic [SW-1:0]   a_data, b_data;
    int              mcnt = 0;

    // full scale, small, negative, mid, and one that 1.75 saturates
    assign in_flat = { 24'h600000, 24'h000123, 24'hF00000, 24'h7FFFFF, 24'h123456 };

    always @(posedge mclk) begin
        mcnt  <= mcnt + 1;
        frame <= (mcnt % 256 == 0);
    end

    pcm_pack2stream #(.N (N), .SW (SW)) u_in (
        .mclk (mclk), .rst_n (mrst_n), .frame_i (frame), .in_flat (in_flat),
        .s_valid (a_valid), .s_ch (a_ch), .s_data (a_data));
    pcm_gain #(.N (N), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_gain (
        .mclk (mclk), .rst_n (mrst_n),
        .in_valid (a_valid), .in_ch (a_ch), .in_data (a_data),
        .coef_addr (coef_addr), .coef_data (coef_data),
        .out_valid (b_valid), .out_ch (b_ch), .out_data (b_data));
    pcm_stream2pack #(.N (N), .SW (SW)) u_out (
        .mclk (mclk), .rst_n (mrst_n), .frame_i (frame),
        .s_valid (b_valid), .s_ch (b_ch), .s_data (b_data),
        .out_flat (out_flat), .valid_o (sv_out), .err_o (s_err));

    // ----- The bank the stage actually read, rebuilt per frame -----
    // The read for a beat's channel is issued in the beat's cycle and
    // returns in the next.
    logic [N*GW-1:0] gains = '0, rebuild = '0;
    logic            rd_q = 0, frame_done = 0;
    logic [CW-1:0]   ch_q;
    always @(posedge mclk) begin
        frame_done = 0;
        if (rd_q) begin
            rebuild[int'(ch_q)*GW +: GW] = coef_data;
            if (int'(ch_q) == N-1) begin gains = rebuild; frame_done = 1; end
        end
        rd_q <= a_valid;
        ch_q <= a_ch;
    end

    // ----- Scoreboard -----
    int errors = 0;
    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %s: got 0x%08h, expected 0x%08h", what, got, exp);
            errors++;
        end else
            $display("  ok   %s = 0x%08h", what, got);
    endtask

    // ----- AXI4-Lite master BFM (as tb_matrix_regs) -----
    task automatic axi_write(input logic [11:0] a, input logic [31:0] d,
                             input logic [3:0] s = 4'hF);
        @(posedge aclk);
        awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= s; wvalid <= 1; bready <= 1;
        do @(posedge aclk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge aclk);
        if (bresp !== 2'b00) begin $display("  FAIL bresp=%b", bresp); errors++; end
        @(posedge aclk);
        bready <= 0;
    endtask

    task automatic axi_read(input logic [11:0] a, output logic [31:0] d);
        @(posedge aclk);
        araddr <= a; arvalid <= 1; rready <= 1;
        do @(posedge aclk); while (!arready);
        arvalid <= 0;
        while (!rvalid) @(posedge aclk);
        d = rdata;
        @(posedge aclk);
        rready <= 0;
    endtask

    function automatic logic [11:0] gaddr(input int c);
        return 12'h100 + 12'(4 * c);
    endfunction

    task automatic wait_idle();
        logic [31:0] c;
        int guard = 0;
        do begin axi_read(12'h008, c); guard++; end
        while (c[1:0] != 2'b00 && guard < 1000);
        if (guard >= 1000) begin $display("  FAIL commit never completed"); errors++; end
    endtask

    task automatic write_bank(input logic [N*GW-1:0] g);
        for (int c = 0; c < N; c++) axi_write(gaddr(c), 32'(signed'(g[c*GW +: GW])));
    endtask

    // ----- Atomicity monitor: each frame's bank is one of the two legal ones -----
    logic [N*GW-1:0] legal_a, legal_b;
    logic            mon_en = 0;
    int              mon_frames = 0;
    always @(posedge mclk) if (mon_en && frame_done) begin
        mon_frames++;
        if (gains !== legal_a && gains !== legal_b) begin
            $display("  FAIL atomicity: the bank read in a frame is neither old nor new at %0t", $time);
            errors++;
        end
    end

    function automatic logic [SW-1:0] ref_out(input logic [N*GW-1:0] g, input int c);
        longint acc;
        acc = longint'($signed(in_flat[c*SW +: SW])) * longint'($signed(g[c*GW +: GW]));
        acc = acc >>> GF;
        if (acc >  64'sd8388607) acc =  64'sd8388607;
        if (acc < -64'sd8388608) acc = -64'sd8388608;
        return acc[SW-1:0];
    endfunction

    task automatic check_outputs(input logic [N*GW-1:0] g, input string tag);
        repeat (2) @(posedge sv_out);
        @(negedge mclk);
        for (int c = 0; c < N; c++)
            check($sformatf("%s out%0d", tag, c), 32'(out_flat[c*SW +: SW]), 32'(ref_out(g, c)));
    endtask

    // ----- Stimulus -----
    logic [31:0] r;
    logic [N*GW-1:0] bank1, prev, nbank;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;

        $display("=== tb_gain_regs ===");
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge mclk);
        mrst_n = 1;

        $display("-- identification");
        axi_read(12'h000, r); check("ID", r, 32'h474E_5001);
        axi_read(12'h004, r); check("CONFIG", r, {8'(N), 8'(TAP), 8'(GW), 8'(GF)});
        axi_read(12'h00C, r); check("COMMITS@reset", r, 0);
        axi_read(12'h0F0, r); check("unmapped", r, 0);

        $display("-- reset bank = unity");
        for (int c = 0; c < N; c++) begin
            axi_read(gaddr(c), r); check($sformatf("GAIN[%0d]", c), r, 32'h0001_0000);
        end
        check_outputs(RESET_GAINS, "unity");
        for (int c = 0; c < N; c++)
            check($sformatf("unity out%0d = in", c), 32'(out_flat[c*SW +: SW]), 32'(in_flat[c*SW +: SW]));

        bank1 = {GB, G0, GN, GH, GB};     // ch4 .. ch0

        $display("-- shadow writes do not reach the stage before COMMIT");
        legal_a = RESET_GAINS; legal_b = RESET_GAINS; mon_en = 1;
        write_bank(bank1);
        repeat (3) @(posedge sv_out);
        check("gains unchanged", 32'(gains == RESET_GAINS), 1);
        axi_read(gaddr(2), r); check("GAIN[2] = -1.0 sign-extended", r, 32'hFFFF_0000);

        $display("-- COMMIT applies the bank");
        legal_b = bank1;
        axi_write(12'h008, 32'h1);
        wait_idle();
        @(posedge sv_out);
        check("gains == bank1", 32'(gains == bank1), 1);
        axi_read(12'h00C, r); check("COMMITS", r, 1);
        check_outputs(bank1, "bank1");

        $display("-- 20 bank changes, each frame old or new");
        prev = bank1;
        for (int n = 0; n < 20; n++) begin
            for (int c = 0; c < N; c++) nbank[c*GW +: GW] = GW'($urandom);
            write_bank(nbank);
            legal_a = prev; legal_b = nbank;
            axi_write(12'h008, 32'h1);
            wait_idle();
            repeat (2) @(posedge sv_out);
            prev = nbank;
        end
        check("gains == last bank", 32'(gains == prev), 1);
        axi_read(12'h00C, r); check("COMMITS", r, 21);
        check_outputs(prev, "last bank");
        $display("  info %0d frames checked for atomicity", mon_frames);
        if (mon_frames < 40) begin $display("  FAIL too few frames monitored"); errors++; end

        mon_en = 0;
        repeat (10) @(posedge aclk);
        if (errors == 0) $display("PASS: tb_gain_regs - all checks passed");
        else             $display("FAIL: tb_gain_regs - %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_gain_regs TIMEOUT");
        $finish;
    end

endmodule
