// -----------------------------------------------------------------------------
// tb_link_stat_regs.sv
//
// pcm_link_stat_regs = axil_stat_window + coef_bank_handoff used in REVERSE
// (src = mclk, dst = aclk), on unrelated clocks.
//
//   1. Header: ID, CONFIG, CTRL = 0; unmapped reads 0; writes are OKAY and
//      change nothing.
//   2. Atomicity: every counter input changes on EVERY mclk edge, each a
//      different function of one cycle count c. On every aclk edge the
//      AXI-side bank must decode to a single c for all six counters -- a torn
//      snapshot (words from two mclk edges) fails at once.
//   3. SNAPSHOTS advances by one per frame and the counters read over AXI
//      advance with it.
//   4. Watermarks: RX_FILL_LOW/HIGH track the min/max of rx_fill while
//      running, restart when the stream starts again, and FLAGS shows
//      RX_RUNNING.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_link_stat_regs;

    logic aclk = 0, mclk = 0;
    always #5.000  aclk = ~aclk;          // 100 MHz
    always #40.677 mclk = ~mclk;          // 12.2919 MHz
    logic aresetn = 0, mrst_n = 0;

    logic [11:0] awaddr = 0, araddr = 0;
    logic        awvalid = 0, awready, wvalid = 0, wready, bvalid, bready = 0;
    logic        arvalid = 0, arready, rvalid, rready = 0;
    logic [31:0] wdata = 0, rdata;
    logic [3:0]  wstrb = 0;
    logic [1:0]  bresp, rresp;

    // ----- mclk-side stimulus -----
    logic [31:0] c = 0;                   // mclk cycle count
    logic [7:0]  fc = 0;
    logic        frame_i;
    logic [15:0] rx_fill = 16'd20;
    logic        rx_running = 0;

    always_ff @(posedge mclk) if (mrst_n) begin c <= c + 1; fc <= fc + 1; end
    assign frame_i = mrst_n && (fc[3:0] == 4'd0);     // a "frame" every 16 mclks

    // six counters, all moving every edge, each decodable back to c
    function automatic logic [31:0] w(input int k, input logic [31:0] cc);
        return cc * 32'(2*k + 3) + 32'(k * 1000);
    endfunction

    pcm_link_stat_regs #(.N_CH_RX (8), .N_CH_TX (6), .FIFO_WORDS (64)) dut (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid),
        .s_axi_wready (wready), .s_axi_bresp (bresp), .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid),
        .s_axi_rready (rready),
        .mclk (mclk), .mrst_n (mrst_n), .frame_i (frame_i),
        .frames_rx (w(0, c)), .frames_tx (w(1, c)), .underruns (w(2, c)),
        .starved (w(3, c)), .overruns (w(4, c)), .tid_errors (w(5, c)),
        .rx_fill (rx_fill), .rx_running (rx_running)
    );

    int errors = 0;

    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %s: got 0x%08h, expected 0x%08h", what, got, exp);
            errors++;
        end else
            $display("  ok   %s = 0x%08h", what, got);
    endtask

    task automatic axi_write(input logic [11:0] a, input logic [31:0] d);
        @(posedge aclk);
        awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= 4'hF; wvalid <= 1; bready <= 1;
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

    // ----- atomicity monitor on the AXI-side bank -----
    int checked = 0, torn = 0;
    always @(posedge aclk) if (aresetn && dut.dst_bank[10*32 +: 32] != 0) begin
        logic [31:0] c0;
        c0 = (dut.dst_bank[0 +: 32]) / 3;             // w(0, c) = 3c
        for (int k = 0; k < 6; k++)
            if (dut.dst_bank[k*32 +: 32] !== w(k, c0)) begin
                if (torn < 5)
                    $display("  FAIL torn snapshot: word %0d = %0d, word 0 says c = %0d",
                             k, dut.dst_bank[k*32 +: 32], c0);
                torn++;
            end
        checked++;
    end

    logic [31:0] r, r2, s1, s2;

    initial begin
        $display("tb_link_stat_regs");
        #200 aresetn = 1; mrst_n = 1;
        repeat (200) @(posedge mclk);

        $display("-- header");
        axi_read(12'h000, r); check("ID", r, 32'h4C4B_5001);
        axi_read(12'h004, r); check("CONFIG (tx 6, rx 8, fifo 64)", r, 32'h0608_0040);
        axi_read(12'h008, r); check("CTRL", r, 32'h0);
        axi_read(12'h200, r); check("unmapped", r, 32'h0);
        axi_read(12'h118, r); check("RX_FILL", r, 32'd20);
        axi_write(12'h118, 32'hDEAD_BEEF);
        axi_write(12'h000, 32'h1234_5678);
        axi_read(12'h000, r); check("ID after writes", r, 32'h4C4B_5001);
        axi_read(12'h118, r); check("RX_FILL after write", r, 32'd20);

        $display("-- snapshots advance, counters live");
        axi_read(12'h00C, s1); axi_read(12'h100, r);
        repeat (160) @(posedge mclk);             // 10 frames
        axi_read(12'h00C, s2); axi_read(12'h100, r2);
        if (!(s2 - s1 >= 9 && s2 - s1 <= 11)) begin
            $display("  FAIL SNAPSHOTS advanced %0d in 10 frames", s2 - s1); errors++;
        end else $display("  ok   SNAPSHOTS +%0d in 10 frames", s2 - s1);
        if (!(r2 > r)) begin $display("  FAIL FRAMES_RX did not advance"); errors++; end
        else $display("  ok   FRAMES_RX advanced");

        $display("-- watermarks");
        axi_read(12'h11C, r); check("RX_FILL_LOW before running", r, 32'hFFFF);
        axi_read(12'h124, r); check("FLAGS not running", r, 32'h0);
        @(posedge mclk) rx_running <= 1; rx_fill <= 16'd30;
        repeat (40) @(posedge mclk);
        @(posedge mclk) rx_fill <= 16'd12;         // dip
        repeat (40) @(posedge mclk);
        @(posedge mclk) rx_fill <= 16'd50;         // peak
        repeat (40) @(posedge mclk);
        @(posedge mclk) rx_fill <= 16'd31;
        repeat (40) @(posedge mclk);
        axi_read(12'h11C, r); check("RX_FILL_LOW", r, 32'd12);
        axi_read(12'h120, r); check("RX_FILL_HIGH", r, 32'd50);
        axi_read(12'h124, r); check("FLAGS running", r, 32'h1);
        // stop, then restart: the marks restart from the new level
        @(posedge mclk) rx_running <= 0; rx_fill <= 16'd0;
        repeat (40) @(posedge mclk);
        @(posedge mclk) rx_running <= 1; rx_fill <= 16'd25;
        repeat (40) @(posedge mclk);
        axi_read(12'h11C, r); check("RX_FILL_LOW after restart", r, 32'd25);
        axi_read(12'h120, r); check("RX_FILL_HIGH after restart", r, 32'd25);

        $display("-- atomicity: %0d AXI-side banks checked, %0d torn", checked, torn);
        if (checked < 1000) begin $display("  FAIL too few banks checked"); errors++; end
        errors += torn;

        if (errors == 0) $display("PASS tb_link_stat_regs");
        else             $display("FAIL tb_link_stat_regs: %0d error(s)", errors);
        $finish;
    end

endmodule
