// -----------------------------------------------------------------------------
// tb_pcm_peak.sv
//
// The peak meter (Phase 13): peak_regs_axil (axil_coef_window + pcm_peak) fed
// a stream, read over AXI4-Lite, across two unrelated clocks (aclk 100 MHz,
// mclk ~12.288 MHz). N = 5 channels (not a power of two), TAP 2.
//
// A model keeps its own windows: every beat goes into the model's
// accumulators; at a frame strobe where the DUT's synchronized request is
// pending, the model closes its window (including a beat on that very edge,
// the closing frame's last cycle) and starts a new one at 0. Every read is
// compared, bit for bit and channel by channel, with the model's last closed
// window, so a window that isn't frame-aligned, isn't the same for every
// channel, loses a beat or leaks one into the wrong window shows up.
//
// Checks:
//   - ID, CONFIG {N, TAP, 24, 0}
//   - 40 snapshots at random times (0..3 frames apart, some issued while the
//     previous is still BUSY: queued), random samples with the extremes over-
//     represented, beats with random gaps, and in about a quarter of the
//     frames the last channel's beat on the strobe edge itself
//   - a one-sample transient on one channel: reported by the next snapshot
//     only, and the other channels unaffected
//   - the most negative sample reads as full scale (0x7F_FFFF), no wrap
//   - writes to PEAK[c] are ignored
//   - COMMITS counts every completed snapshot
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pcm_peak;

    localparam int N   = 5;
    localparam int TAP = 2;
    localparam int SW  = 24;
    localparam int CW  = $clog2(N);

    // ----- clocks / resets -----
    logic aclk = 0, mclk = 0;
    always #5      aclk = ~aclk;
    always #40.69  mclk = ~mclk;
    logic aresetn = 0;

    logic frame = 0;
    int   cyc = -1, ctr = 0;
    always @(posedge mclk) begin
        ctr   <= (ctr == 255) ? 0 : ctr + 1;
        frame <= (ctr == 255);
        cyc   <= frame ? 0 : (cyc >= 0 ? cyc + 1 : -1);
    end

    // ----- AXI -----
    logic [11:0] awaddr, araddr;
    logic        awvalid, awready, wvalid, wready, bvalid, bready;
    logic        arvalid, arready, rvalid, rready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;

    // ----- stream -----
    logic          s_valid = 0;
    logic [CW-1:0] s_ch    = '0;
    logic [SW-1:0] s_data  = '0;

    peak_regs_axil #(.N (N), .TAP (TAP), .SW (SW), .ADDR_WIDTH (12)) dut (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata  (wdata),  .s_axi_wstrb   (wstrb),
        .s_axi_wvalid (wvalid), .s_axi_wready  (wready),
        .s_axi_bresp  (bresp),  .s_axi_bvalid  (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata  (rdata),  .s_axi_rresp   (rresp),
        .s_axi_rvalid (rvalid), .s_axi_rready  (rready),
        .mclk (mclk), .frame_i (frame),
        .s_valid (s_valid), .s_ch (s_ch), .s_data (s_data));

    // ----- stimulus modes -----
    typedef enum { RANDOM, QUIET } mode_t;
    mode_t mode = RANDOM;
    int    spike_ch = -1;              // QUIET: one channel gets SPIKE in the next frame
    logic [SW-1:0] spike_val;
    bit    late_ok = 1;                // allow a beat on the strobe edge

    function automatic logic [SW-1:0] rsamp();
        if (mode == QUIET) return SW'($urandom % 512) - 256;          // |x| <= 256
        case ($urandom % 10)
            0: return 24'h7FFFFF;
            1: return 24'h800000;
            2: return 24'h800001;
            3: return 24'h000000;
            4: return SW'($urandom % 5) - 2;
            default: return SW'($urandom);
        endcase
    endfunction

    // One frame's beats, planned in cycle 0: channels in order, random gaps,
    // and sometimes the last channel's beat on the strobe edge (cycle 255).
    int plan_cyc [N];
    logic [SW-1:0] plan_dat [N];
    int next_b = N;

    always @(negedge mclk) begin
        s_valid = 1'b0;
        if (cyc == 0) begin
            int c;
            c = 1 + $urandom % 4;
            for (int k = 0; k < N; k++) begin
                plan_cyc[k] = c;
                plan_dat[k] = rsamp();
                c += 1 + (($urandom % 3 == 0) ? $urandom % 6 : 0);
            end
            if (late_ok && $urandom % 4 == 0) plan_cyc[N-1] = 255;
            if (spike_ch >= 0) begin
                plan_dat[spike_ch] = spike_val;
                spike_ch = -1;
            end
            next_b = 0;
        end
        if (cyc >= 0 && next_b < N && cyc == plan_cyc[next_b]) begin
            s_valid = 1'b1;
            s_ch    = CW'(next_b);
            s_data  = plan_dat[next_b];
            next_b++;
        end
    end

    // ----- the model -----
    logic [SW-1:0] acc_m [N], closed_m [N];
    logic          ack_m = 1'b0;
    int            flips = 0;
    int            errors = 0;

    function automatic logic [SW-1:0] mag(input logic [SW-1:0] x);
        if (x == 24'h800000) return 24'h7FFFFF;
        if (x[SW-1]) return -x;
        return x;
    endfunction

    initial for (int c = 0; c < N; c++) begin acc_m[c] = '0; closed_m[c] = '0; end

    always @(posedge mclk) begin
        if (s_valid && mag(s_data) > acc_m[s_ch]) acc_m[s_ch] = mag(s_data);
        if (frame && dut.u_peak.req_s2 != ack_m) begin
            for (int c = 0; c < N; c++) begin closed_m[c] = acc_m[c]; acc_m[c] = '0; end
            ack_m = dut.u_peak.req_s2;
            flips++;
        end
    end

    // ----- AXI4-Lite BFM (as tb_matrix_regs) -----
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

    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            errors++;
            if (errors < 15) $display("  FAIL %s: got 0x%08h, expected 0x%08h", what, got, exp);
        end
    endtask

    task automatic wait_idle();
        logic [31:0] c;
        int guard = 0;
        do begin axi_read(12'h008, c); guard++; end
        while (c[1:0] != 2'b00 && guard < 2000);
        if (guard >= 2000) begin $display("  FAIL snapshot never completed"); errors++; end
    endtask

    // SNAP, wait, read every channel, compare with the model's closed window
    task automatic snap_and_check(input string tag);
        logic [31:0] r;
        axi_write(12'h008, 32'h1);
        wait_idle();
        for (int c = 0; c < N; c++) begin
            axi_read(12'h100 + 12'(4*c), r);
            check($sformatf("%s ch%0d", tag, c), r, {8'h00, closed_m[c]});
        end
    endtask

    task automatic frames(input int n);
        repeat (n) @(posedge frame);
    endtask

    logic [31:0] r;
    int snaps = 0;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
        $display("=== tb_pcm_peak ===");
        repeat (5) @(posedge aclk);
        aresetn = 1;
        frames(2);

        axi_read(12'h000, r); check("ID", r, 32'h504B_5001);
        axi_read(12'h004, r); check("CONFIG", r, {8'(N), 8'(TAP), 8'(SW), 8'd0});
        axi_read(12'h00C, r); check("COMMITS@reset", r, 0);

        $display("-- 40 snapshots at random times");
        snap_and_check("first"); snaps++;
        for (int n = 0; n < 40; n++) begin
            frames($urandom % 4);
            repeat ($urandom % 3000) @(posedge aclk);       // anywhere in a frame
            snap_and_check($sformatf("snap %0d", n)); snaps++;
        end

        $display("-- back to back: a SNAP while BUSY is queued, and taken");
        begin
            logic [31:0] c0, c1;
            axi_read(12'h00C, c0);
            axi_write(12'h008, 32'h1);
            axi_write(12'h008, 32'h1);         // ~60 ns later: the first can't be done yet
            snaps += 2;
            wait_idle();
            axi_read(12'h00C, c1);
            check("two snapshots from a queued pair", c1 - c0, 2);
        end
        for (int c = 0; c < N; c++) begin
            axi_read(12'h100 + 12'(4*c), r);
            check($sformatf("queued ch%0d", c), r, {8'h00, closed_m[c]});
        end
        frames(1);

        $display("-- a read right after SNAP waits for the snapshot");
        frames(1);
        begin
            int f0;
            f0 = flips;
            axi_write(12'h008, 32'h1);          // no BUSY polling
            snaps++;
            for (int c = 0; c < N; c++) begin
                axi_read(12'h100 + 12'(4*c), r);
                // the read must come back from THIS snapshot's window, not the one before
                check($sformatf("no-wait ch%0d: window closed first", c), flips - f0, 1);
                check($sformatf("no-wait ch%0d", c), r, {8'h00, closed_m[c]});
            end
        end
        frames(1);

        $display("-- a one-sample transient");
        mode = QUIET; late_ok = 0;
        frames(2);
        snap_and_check("quiet"); snaps++;
        @(negedge mclk); wait (cyc > 250);               // plan the spike for the next frame
        spike_ch = 3; spike_val = 24'h600000;
        frames(3);
        snap_and_check("spike"); snaps++;
        check("spike seen", {8'h00, closed_m[3]}, 32'h0060_0000);
        for (int c = 0; c < N; c++)
            if (c != 3 && closed_m[c] > 24'h100) begin errors++; $display("  FAIL ch%0d leaked", c); end
        frames(2);
        snap_and_check("after spike"); snaps++;
        if (closed_m[3] > 24'h100) begin errors++; $display("  FAIL spike reported twice"); end

        $display("-- the most negative sample");
        @(negedge mclk); wait (cyc > 250);
        spike_ch = 1; spike_val = 24'h800000;
        frames(3);
        snap_and_check("min"); snaps++;
        check("min reads full scale", {8'h00, closed_m[1]}, 32'h007F_FFFF);

        $display("-- writes are ignored");
        axi_write(12'h104, 32'h0012_3456);
        axi_read(12'h104, r); check("PEAK[1] after a write", r, {8'h00, closed_m[1]});

        axi_read(12'h00C, r); check("COMMITS", r, 32'(flips));
        $display("  info %0d snapshots requested, %0d windows closed", snaps, flips);
        if (flips < 44) begin errors++; $display("  FAIL too few windows"); end

        mode = RANDOM;
        if (errors == 0) $display("PASS: tb_pcm_peak - all checks passed");
        else             $display("FAIL: tb_pcm_peak - %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: tb_pcm_peak TIMEOUT");
        $finish;
    end
endmodule
