// -----------------------------------------------------------------------------
// tb_matrix_regs.sv
//
// Unit test for matrix_regs_axil driving pcm_matrix, across two unrelated
// clocks (aclk 100 MHz, mclk ~12.288 MHz), with a small AXI4-Lite master BFM.
//
// Checks:
//   - ID / CONFIG / unmapped reads
//   - shadow reset = RESET_GAINS (identity), read back sign-extended
//   - shadow writes do NOT reach the matrix until COMMIT
//   - COMMIT applies the whole bank; COMMITS counts; BUSY clears
//   - atomicity: on every mclk edge gains_flat is exactly the old bank or the
//     new bank, never a mix
//   - COMMIT while BUSY is queued and applied with the latest shadow
//   - WSTRB byte-lane writes
//   - end to end: matrix output for a known input under the committed gains
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_matrix_regs;

    localparam int N  = 4;
    localparam int GW = 18;
    localparam int GF = 16;
    localparam int SW = 24;

    localparam logic [GW-1:0] G1  = 18'h10000;  //  1.0
    localparam logic [GW-1:0] GH  = 18'h08000;  //  0.5
    localparam logic [GW-1:0] GN  = 18'h30000;  // -1.0
    localparam logic [GW-1:0] G0  = 18'h00000;

    function automatic logic [N*N*GW-1:0] identity();
        logic [N*N*GW-1:0] g = '0;
        for (int o = 0; o < N; o++) g[(o*N + o)*GW +: GW] = G1;
        return g;
    endfunction
    localparam logic [N*N*GW-1:0] RESET_GAINS = identity();

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

    logic [N*N*GW-1:0] gains;

    matrix_regs_axil #(
        .N_IN (N), .N_OUT (N), .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .ADDR_WIDTH (12),
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
        .mclk (mclk), .mrst_n (mrst_n),
        .gains_flat (gains)
    );

    // ----- Matrix, fed a constant test vector every 8 mclks -----
    logic              sv_in = 0, sv_out;
    logic [N*SW-1:0]   in_flat, out_flat;
    int                mcnt = 0;

    // in0 = 0x100000, in1 = 0x010000, in2 = -0x020000, in3 = 0x001000
    assign in_flat = { 24'h001000, 24'hFE0000, 24'h010000, 24'h100000 };

    always @(posedge mclk) begin
        mcnt  <= mcnt + 1;
        sv_in <= (mcnt % 8 == 0);
    end

    pcm_matrix #(.N_IN (N), .N_OUT (N), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_mtx (
        .mclk (mclk), .rst_n (mrst_n), .sample_valid_i (sv_in),
        .gains_flat (gains), .in_flat (in_flat), .out_flat (out_flat),
        .sample_valid_o (sv_out)
    );

    // ----- Scoreboard -----
    int errors = 0;

    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %s: got 0x%08h, expected 0x%08h", what, got, exp);
            errors++;
        end else
            $display("  ok   %s = 0x%08h", what, got);
    endtask

    // ----- AXI4-Lite master BFM -----
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

    function automatic logic [11:0] gaddr(input int o, input int i);
        return 12'h100 + 12'(4 * (o*N + i));
    endfunction

    task automatic wait_idle();
        logic [31:0] c;
        int guard = 0;
        do begin axi_read(12'h008, c); guard++; end
        while (c[1:0] != 2'b00 && guard < 1000);
        if (guard >= 1000) begin $display("  FAIL commit never completed"); errors++; end
    endtask

    // ----- Atomicity monitor -----
    // Between commits the TB declares which two banks are legal (old, new).
    logic [N*N*GW-1:0] legal_a, legal_b;
    logic              mon_en = 0;
    always @(posedge mclk) if (mon_en) begin
        if (gains !== legal_a && gains !== legal_b) begin
            $display("  FAIL atomicity: gains_flat is neither old nor new bank at %0t", $time);
            errors++;
        end
    end

    // Reference: out[o] = sat(sum in[i]*g[o][i] >>> GF)
    function automatic logic [SW-1:0] ref_out(input logic [N*N*GW-1:0] g, input int o);
        longint acc = 0;
        for (int i = 0; i < N; i++)
            acc += longint'($signed(in_flat[i*SW +: SW])) * longint'($signed(g[(o*N+i)*GW +: GW]));
        acc = acc >>> GF;
        if (acc >  64'sd8388607) acc =  64'sd8388607;   //  2^23 - 1
        if (acc < -64'sd8388608) acc = -64'sd8388608;   // -2^23
        return acc[SW-1:0];
    endfunction

    task automatic check_outputs(input logic [N*N*GW-1:0] g, input string tag);
        // Two frames: one to pick up any bank change, one to be sure.
        repeat (2) @(posedge sv_out);
        @(negedge mclk);
        for (int o = 0; o < N; o++)
            check($sformatf("%s out%0d", tag, o),
                  32'(out_flat[o*SW +: SW]), 32'(ref_out(g, o)));
    endtask

    // ----- Stimulus -----
    logic [31:0] r;
    logic [N*N*GW-1:0] bank1, bank2;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;

        $display("=== tb_matrix_regs ===");
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge mclk);
        mrst_n = 1;

        $display("-- identification");
        axi_read(12'h000, r); check("ID", r, 32'h4D58_5001);
        axi_read(12'h004, r); check("CONFIG", r, 32'h0404_1210);
        axi_read(12'h00C, r); check("COMMITS@reset", r, 0);
        axi_read(12'h0F0, r); check("unmapped", r, 0);

        $display("-- reset bank = identity");
        axi_read(gaddr(0,0), r); check("G[0][0]", r, 32'h0001_0000);
        axi_read(gaddr(0,1), r); check("G[0][1]", r, 0);
        axi_read(gaddr(3,3), r); check("G[3][3]", r, 32'h0001_0000);
        check_outputs(RESET_GAINS, "identity");

        // bank1: out0 = in2, out1 = 0.5 in0 + 0.5 in1, out2 = -in2, out3 = in0+in1+in3
        bank1 = '0;
        bank1[(0*N+2)*GW +: GW] = G1;
        bank1[(1*N+0)*GW +: GW] = GH;
        bank1[(1*N+1)*GW +: GW] = GH;
        bank1[(2*N+2)*GW +: GW] = GN;
        bank1[(3*N+0)*GW +: GW] = G1;
        bank1[(3*N+1)*GW +: GW] = G1;
        bank1[(3*N+3)*GW +: GW] = G1;

        $display("-- shadow writes do not reach the matrix before COMMIT");
        legal_a = RESET_GAINS; legal_b = RESET_GAINS; mon_en = 1;
        for (int k = 0; k < N*N; k++)
            axi_write(12'h100 + 12'(4*k), 32'(signed'(bank1[k*GW +: GW])));
        repeat (20) @(posedge mclk);
        check("gains unchanged", 32'(gains == RESET_GAINS), 1);
        axi_read(gaddr(2,2), r); check("G[2][2] = -1.0 sign-extended", r, 32'hFFFF_0000);

        $display("-- COMMIT applies the bank atomically");
        legal_b = bank1;
        axi_write(12'h008, 32'h1);
        wait_idle();
        repeat (4) @(posedge mclk);
        check("gains == bank1", 32'(gains == bank1), 1);
        axi_read(12'h00C, r); check("COMMITS", r, 1);
        check_outputs(bank1, "bank1");

        $display("-- COMMIT while BUSY is queued, then applied with the latest shadow");
        legal_a = bank1;
        bank2 = bank1;
        bank2[(0*N+2)*GW +: GW] = G0;
        bank2[(0*N+0)*GW +: GW] = GH;
        // Back-to-back: commit, change, commit again before the first lands.
        axi_write(12'h008, 32'h1);                  // re-commit bank1 (no-op data)
        axi_write(gaddr(0,2), 32'h0);
        axi_write(gaddr(0,0), 32'(signed'(GH)));
        legal_b = bank2;
        axi_write(12'h008, 32'h1);
        axi_read(12'h008, r);
        $display("  info CTRL right after 2nd commit = 0x%08h (queued if bit1)", r);
        wait_idle();
        repeat (4) @(posedge mclk);
        check("gains == bank2", 32'(gains == bank2), 1);
        axi_read(12'h00C, r); check("COMMITS", r, 3);
        check_outputs(bank2, "bank2");

        $display("-- WSTRB byte lanes");
        axi_write(gaddr(1,3), 32'h0003_4567, 4'b0001);   // low byte only -> 0x00067
        axi_read(gaddr(1,3), r); check("G[1][3] after lane0", r, 32'h0000_0067);
        axi_write(gaddr(1,3), 32'h0003_4500, 4'b0110);   // lanes 1,2 -> 0x34567 -> sign-ext
        axi_read(gaddr(1,3), r); check("G[1][3] after lanes1-2", r, 32'hFFFF_4567);

        mon_en = 0;
        repeat (10) @(posedge aclk);
        if (errors == 0) $display("PASS: tb_matrix_regs - all checks passed");
        else             $display("FAIL: tb_matrix_regs - %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_matrix_regs TIMEOUT");
        $finish;
    end

endmodule
