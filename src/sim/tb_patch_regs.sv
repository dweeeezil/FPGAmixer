// -----------------------------------------------------------------------------
// tb_patch_regs.sv
//
// Unit test for patch_regs_axil (Phase 15): two windows, the input patch
// (DIR 0, sources) and the output patch (DIR 1, destinations), driving
// pcm_patch2stream -> pcm_stream2patch across two unrelated clocks (aclk
// 100 MHz, mclk ~12.288 MHz), with the AXI4-Lite master BFM of
// tb_gain_regs (one bus; address bit 12 selects the window). N = 5 channels,
// P = 6 ports in and out (3-bit entries: 6 = 0b110 has its top bit set).
//
// Checks:
//   - ID / CONFIG (N, P, DIR, entry width) / COMMITS / unmapped reads, both
//   - reset tables: the input window's RESET_TABLE (here identity) read
//     back; the output window's (all None) leaves every port silent
//   - shadow writes do NOT reach the converters until COMMIT
//   - entries read back ZERO-extended (6 reads 0x6, not 0xFFFF_FFFE);
//     WSTRB: a write with byte 0 disabled changes nothing
//   - COMMIT applies the whole table; COMMITS counts
//   - atomicity: every frame, the source table the converter actually READ
//     (rebuilt from the read port) is exactly the old or the new table, over
//     20 back-to-back changes
//   - end to end: the output ports = the model of both tables
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_patch_regs;

    localparam int N  = 5;
    localparam int P  = 6;
    localparam int PW = 3;
    localparam int SW = 24;
    localparam int CW = $clog2(N);

    typedef logic [N*PW-1:0] tab_t;

    function automatic tab_t identity();
        tab_t t;
        for (int c = 0; c < N; c++) t[c*PW +: PW] = PW'(c + 1);
        return t;
    endfunction
    localparam tab_t IN_RESET = identity();

    // ----- Clocks / resets -----
    logic aclk = 0, mclk = 0;
    always #5      aclk = ~aclk;         // 100 MHz
    always #40.69  mclk = ~mclk;         // ~12.288 MHz, unrelated phase
    logic aresetn = 0, mrst_n = 0;

    // ----- AXI: one master, two windows (address bit 12) -----
    logic [12:0] awaddr, araddr;
    logic        awvalid, wvalid, bready, arvalid, rready;
    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        awready [2], wready [2], bvalid [2], arready [2], rvalid [2];
    logic [1:0]  bresp [2], rresp [2];
    logic [31:0] rdata [2];
    wire         aw_w = awaddr[12], ar_w = araddr[12];

    logic [CW-1:0] in_addr, out_addr;
    logic [PW-1:0] in_data, out_data;
    logic [PW-1:0] cdata [2];
    logic          frame = 0;

    for (genvar w = 0; w < 2; w++) begin : g_win
        patch_regs_axil #(
            .N (N), .P (P), .DIR (w), .ADDR_WIDTH (12),
            .RESET_TABLE ((w == 0) ? IN_RESET : tab_t'(0))
        ) dut (
            .aclk (aclk), .aresetn (aresetn),
            .s_axi_awaddr (awaddr[11:0]), .s_axi_awvalid (awvalid && (aw_w == w)),
            .s_axi_awready (awready[w]),
            .s_axi_wdata  (wdata),  .s_axi_wstrb (wstrb),
            .s_axi_wvalid (wvalid && (aw_w == w)), .s_axi_wready (wready[w]),
            .s_axi_bresp  (bresp[w]), .s_axi_bvalid (bvalid[w]), .s_axi_bready (bready),
            .s_axi_araddr (araddr[11:0]), .s_axi_arvalid (arvalid && (ar_w == w)),
            .s_axi_arready (arready[w]),
            .s_axi_rdata  (rdata[w]), .s_axi_rresp (rresp[w]),
            .s_axi_rvalid (rvalid[w]), .s_axi_rready (rready),
            .mclk (mclk), .frame_i (frame),
            .coef_addr ((w == 0) ? in_addr : out_addr),
            .coef_data (cdata[w])
        );
    end
    assign in_data  = cdata[0];
    assign out_data = cdata[1];

    // ----- ports -> input patch -> output patch -> ports, one frame every 256 mclks -----
    logic [P*SW-1:0] in_flat, out_flat;
    logic            s_valid, sv_out, s_err;
    logic [CW-1:0]   s_ch;
    logic [SW-1:0]   s_data;
    int              mcnt = 0;

    initial for (int p = 0; p < P; p++) in_flat[p*SW +: SW] = SW'(24'h100000 * (p + 1) + p);

    always @(posedge mclk) begin
        mcnt  <= mcnt + 1;
        frame <= (mcnt % 256 == 0);
    end

    pcm_patch2stream #(.P (P), .N (N), .SW (SW)) u_in (
        .mclk (mclk), .rst_n (mrst_n), .frame_i (frame), .in_flat (in_flat),
        .coef_addr (in_addr), .coef_data (in_data),
        .s_valid (s_valid), .s_ch (s_ch), .s_data (s_data));
    pcm_stream2patch #(.N (N), .P (P), .SW (SW)) u_out (
        .mclk (mclk), .rst_n (mrst_n), .frame_i (frame),
        .s_valid (s_valid), .s_ch (s_ch), .s_data (s_data),
        .coef_addr (out_addr), .coef_data (out_data),
        .out_flat (out_flat), .valid_o (sv_out), .err_o (s_err));

    // ----- The source table the converter actually read, rebuilt per frame -----
    // pcm_patch2stream issues read k in cycle k; in the next cycle its v1/c1
    // say which channel's entry is on the read port.
    tab_t srcs = '0, rebuild = '0;
    logic frame_done = 0;
    always @(posedge mclk) begin
        frame_done = 0;
        if (u_in.v1) begin
            rebuild[int'(u_in.c1)*PW +: PW] = in_data;
            if (int'(u_in.c1) == N-1) begin srcs = rebuild; frame_done = 1; end
        end
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

    // ----- AXI4-Lite master BFM -----
    task automatic axi_write(input int w, input logic [11:0] a, input logic [31:0] d,
                             input logic [3:0] s = 4'hF);
        @(posedge aclk);
        awaddr <= {w[0], a}; awvalid <= 1; wdata <= d; wstrb <= s; wvalid <= 1; bready <= 1;
        do @(posedge aclk); while (!(awready[w] && wready[w]));
        awvalid <= 0; wvalid <= 0;
        while (!bvalid[w]) @(posedge aclk);
        if (bresp[w] !== 2'b00) begin $display("  FAIL bresp=%b", bresp[w]); errors++; end
        @(posedge aclk);
        bready <= 0;
    endtask

    task automatic axi_read(input int w, input logic [11:0] a, output logic [31:0] d);
        @(posedge aclk);
        araddr <= {w[0], a}; arvalid <= 1; rready <= 1;
        do @(posedge aclk); while (!arready[w]);
        arvalid <= 0;
        while (!rvalid[w]) @(posedge aclk);
        d = rdata[w];
        @(posedge aclk);
        rready <= 0;
    endtask

    function automatic logic [11:0] eaddr(input int c);
        return 12'h100 + 12'(4 * c);
    endfunction

    task automatic wait_idle(input int w);
        logic [31:0] c;
        int guard = 0;
        do begin axi_read(w, 12'h008, c); guard++; end
        while (c[1:0] != 2'b00 && guard < 1000);
        if (guard >= 1000) begin $display("  FAIL commit never completed"); errors++; end
    endtask

    task automatic write_table(input int w, input tab_t t);
        for (int c = 0; c < N; c++) axi_write(w, eaddr(c), 32'(t[c*PW +: PW]));
    endtask

    // ----- Atomicity monitor: each frame's source table is one of the two legal ones -----
    tab_t legal_a, legal_b;
    logic mon_en = 0;
    int   mon_frames = 0;
    always @(posedge mclk) if (mon_en && frame_done) begin
        mon_frames++;
        if (srcs !== legal_a && srcs !== legal_b) begin
            $display("  FAIL atomicity: the table read in a frame is neither old nor new at %0t", $time);
            errors++;
        end
    end

    // ----- the model -----
    function automatic logic [P*SW-1:0] model(input tab_t s, input tab_t d);
        logic [P*SW-1:0] o;
        int sv, dv;
        o = '0;
        for (int c = 0; c < N; c++) begin
            sv = int'(s[c*PW +: PW]);
            dv = int'(d[c*PW +: PW]);
            if (dv >= 1 && dv <= P)
                o[(dv-1)*SW +: SW] = (sv >= 1 && sv <= P) ? in_flat[(sv-1)*SW +: SW] : '0;
        end
        return o;
    endfunction

    task automatic check_outputs(input tab_t s, input tab_t d, input string tag);
        logic [P*SW-1:0] want;
        repeat (2) @(posedge sv_out);
        @(negedge mclk);
        want = model(s, d);
        for (int p = 0; p < P; p++)
            check($sformatf("%s port%0d", tag, p), 32'(out_flat[p*SW +: SW]), 32'(want[p*SW +: SW]));
    endtask

    // ----- Stimulus -----
    logic [31:0] r;
    tab_t src1, dst1, prev, nt;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;

        $display("=== tb_patch_regs ===");
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge mclk);
        mrst_n = 1;

        $display("-- identification");
        for (int w = 0; w < 2; w++) begin
            axi_read(w, 12'h000, r); check($sformatf("ID[%0d]", w), r, 32'h5054_5001);
            axi_read(w, 12'h004, r); check($sformatf("CONFIG[%0d]", w), r, {8'(N), 8'(P), 8'(w), 8'(PW)});
            axi_read(w, 12'h00C, r); check($sformatf("COMMITS@reset[%0d]", w), r, 0);
            axi_read(w, 12'h0F0, r); check($sformatf("unmapped[%0d]", w), r, 0);
        end

        $display("-- reset tables: input identity, output all None (silent)");
        for (int c = 0; c < N; c++) begin
            axi_read(0, eaddr(c), r); check($sformatf("SRC[%0d]", c), r, c + 1);
            axi_read(1, eaddr(c), r); check($sformatf("DST[%0d]", c), r, 0);
        end
        check_outputs(IN_RESET, '0, "reset");
        check("reset: all ports silent", 32'(out_flat == '0), 1);

        // sources: c0 <- p5 (6, top bit set), c1 <- None, c2 <- p0, c3 <- p5, c4 <- p2
        src1 = {3'd3, 3'd6, 3'd1, 3'd0, 3'd6};
        // destinations: c0 -> p1, c1 -> p0 (a None source: silence), c2 -> p5,
        //               c3 -> None, c4 -> p3; p2 and p4 unnamed
        dst1 = {3'd4, 3'd0, 3'd6, 3'd1, 3'd2};

        $display("-- shadow writes do not reach the converters before COMMIT");
        legal_a = IN_RESET; legal_b = IN_RESET; mon_en = 1;
        write_table(0, src1);
        write_table(1, dst1);
        repeat (3) @(posedge sv_out);
        check("sources unchanged", 32'(srcs == IN_RESET), 1);
        check("ports still silent", 32'(out_flat == '0), 1);
        axi_read(0, eaddr(0), r); check("SRC[0] = 6 zero-extended", r, 32'h0000_0006);
        axi_read(1, eaddr(2), r); check("DST[2] = 6 zero-extended", r, 32'h0000_0006);
        axi_write(0, eaddr(1), 32'h0000_0005, 4'b1110);   // byte 0 disabled
        axi_read(0, eaddr(1), r); check("WSTRB: SRC[1] unchanged", r, 0);

        $display("-- COMMIT applies both tables");
        legal_b = src1;
        axi_write(0, 12'h008, 32'h1);
        axi_write(1, 12'h008, 32'h1);
        wait_idle(0); wait_idle(1);
        @(posedge sv_out);
        check("sources == src1", 32'(srcs == src1), 1);
        axi_read(0, 12'h00C, r); check("COMMITS[0]", r, 1);
        axi_read(1, 12'h00C, r); check("COMMITS[1]", r, 1);
        check_outputs(src1, dst1, "tables 1");

        $display("-- 20 source tables, each frame old or new");
        prev = src1;
        for (int n = 0; n < 20; n++) begin
            for (int c = 0; c < N; c++) nt[c*PW +: PW] = PW'($urandom % (P + 1));
            write_table(0, nt);
            legal_a = prev; legal_b = nt;
            axi_write(0, 12'h008, 32'h1);
            wait_idle(0);
            repeat (2) @(posedge sv_out);
            prev = nt;
        end
        check("sources == last table", 32'(srcs == prev), 1);
        axi_read(0, 12'h00C, r); check("COMMITS[0]", r, 21);
        check_outputs(prev, dst1, "last table");
        $display("  info %0d frames checked for atomicity", mon_frames);
        if (mon_frames < 40) begin $display("  FAIL too few frames monitored"); errors++; end
        if (s_err) begin $display("  FAIL err_o"); errors++; end

        mon_en = 0;
        repeat (10) @(posedge aclk);
        if (errors == 0) $display("PASS: tb_patch_regs - all checks passed");
        else             $display("FAIL: tb_patch_regs - %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: tb_patch_regs TIMEOUT");
        $finish;
    end

endmodule
