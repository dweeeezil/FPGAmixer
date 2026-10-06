// -----------------------------------------------------------------------------
// tb_media_clock_meter.sv
//
// P9.3: media_clock_meter + media_clock_stat_regs on unrelated clocks.
//
// The reference is a model of the GEM TSU: a 250 MHz clock (4 ns period)
// adding 4 to a nanosecond counter that wraps at one "second", with the 1PPS
// taken as the inverse of the counter's MSB, as fpgamixer_top does with
// tsu_timer_cnt[45]. To keep the run short a "second" is SCALE = 1 ms of TSU
// time, so NOMINAL = 12288 mclk cycles and the plausibility window is
// +/-1000 ppm = +/-12 cycles.
//
//   meter A: mclk_a = 12.29166 MHz, +296 ppm (near the board's +324 ppm;
//            the ps timescale sets the exact value)
//   meter B: mclk_b = 12.28803 MHz, +2.5 ppm (as near 12.288 MHz as 1 ps
//            steps allow)
// Both see the same PPS and have their own 256-cycle frame strobes.
//
// Checks, per meter:
//   - every interval (cyc_last - cyc_prev) is floor or ceil of the exact
//     expectation, and the mean over the run is within 0.1 cycle of it (so the
//     ppm computed in software is right to ~0.01 ppm per this model);
//   - phase_last advances by the interval mod 256 each second, and
//     frames_last by the number of strobes in between (the two captures agree);
//   - implausible: 0 during steady running; exactly +1 for a PHC step
//     (+300 us of TSU time) and exactly +1 for a two-second PPS dropout;
//   - the status window (meter A, through AXI4-Lite): ID, CONFIG, and the
//     words equal the meter's outputs once a snapshot has passed.
// -----------------------------------------------------------------------------
`timescale 1ps / 1ps

module tb_media_clock_meter;

    localparam longint SCALE_NS = 1_000_000;          // one "second" of TSU time
    localparam int     NOMINAL  = 12288;              // 12.288 MHz * 1 ms
    localparam int     TOL      = 12;                 // ~1000 ppm
    localparam int     MSB      = 19;                 // 2^19 ns = 524 us < 1 ms

    // ----- clocks (ps) -----
    logic tsu_clk = 0, mclk_a = 0, mclk_b = 0, aclk = 0;
    always #2000   tsu_clk = ~tsu_clk;                // 250 MHz
    always #40678  mclk_a  = ~mclk_a;                 // 12.29184 MHz  (81.356 ns)
    always #40690  mclk_b  = ~mclk_b;                 // 12.28802 MHz  (81.380 ns)
    always #5000   aclk    = ~aclk;                   // 100 MHz
    // exact expectations per "second" from the half-periods above
    localparam real EXP_A = 1.0e9 / (2.0 * 40678.0);  // cycles per 1e6 ns
    localparam real EXP_B = 1.0e9 / (2.0 * 40690.0);

    // ----- TSU model -----
    longint ns = 0;
    bit     tsu_run = 1;
    always @(posedge tsu_clk) if (tsu_run) begin
        ns = ns + 4;
        if (ns >= SCALE_NS) ns = ns - SCALE_NS;
    end
    wire pps = ~ns[MSB];          // rises when ns wraps to 0

    // ----- DUTs -----
    logic rst_n = 0;
    logic fr_a = 0, fr_b = 0;
    int   fa = 0, fb = 0;
    always @(posedge mclk_a) begin fa <= (fa + 1) % 256; fr_a <= (fa == 255); end
    always @(posedge mclk_b) begin fb <= (fb + 1) % 256; fr_b <= (fb == 255); end

    logic [31:0] a_pps, a_last, a_prev, a_frames, a_impl, a_now;
    logic [15:0] a_phase;
    logic [31:0] b_pps, b_last, b_prev, b_frames, b_impl, b_now;
    logic [15:0] b_phase;

    media_clock_meter #(.NOMINAL (NOMINAL), .TOL (TOL)) u_a (
        .mclk (mclk_a), .rst_n (rst_n), .pps_async (pps), .frame_i (fr_a),
        .pps_count (a_pps), .cyc_last (a_last), .cyc_prev (a_prev),
        .frames_last (a_frames), .phase_last (a_phase),
        .implausible (a_impl), .cyc_now (a_now));

    media_clock_meter #(.NOMINAL (NOMINAL), .TOL (TOL)) u_b (
        .mclk (mclk_b), .rst_n (rst_n), .pps_async (pps), .frame_i (fr_b),
        .pps_count (b_pps), .cyc_last (b_last), .cyc_prev (b_prev),
        .frames_last (b_frames), .phase_last (b_phase),
        .implausible (b_impl), .cyc_now (b_now));

    // ----- status window on meter A -----
    logic aresetn = 0;
    logic [11:0] araddr = 0, awaddr = 0;
    logic arvalid = 0, arready, rvalid, rready = 0, awvalid = 0, awready;
    logic wvalid = 0, wready, bvalid, bready = 0;
    logic [31:0] rdata, wdata = 0;
    logic [3:0]  wstrb = 0;
    logic [1:0]  rresp, bresp;

    media_clock_stat_regs #(.NOMINAL (NOMINAL)) u_regs (
        .aclk (aclk), .aresetn (aresetn),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid),
        .s_axi_wready (wready), .s_axi_bresp (bresp), .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid),
        .s_axi_rready (rready),
        .mclk (mclk_a), .mrst_n (rst_n), .frame_i (fr_a),
        .pps_count (a_pps), .cyc_last (a_last), .cyc_prev (a_prev),
        .frames_last (a_frames), .phase_last (a_phase),
        .implausible (a_impl), .cyc_now (a_now));

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

    int errors = 0;
    task automatic fail(input string s);
        errors++;
        if (errors <= 15) $display("[%0t ps] FAIL %s", $time, s);
    endtask

    // ----- per-interval checks (on each new capture) -----
    int     n_a = 0, n_b = 0;
    real    sum_a = 0, sum_b = 0;
    bit     steady = 0;          // only steady intervals enter the statistics
    logic [31:0] pa_frames; logic [15:0] pa_phase; int pa_pps = 0;

    task automatic check_interval(input string nm, input real expv,
                                  input logic [31:0] last, input logic [31:0] prev,
                                  inout int n, inout real sum);
        int d, lo, hi;
        d  = int'(last - prev);
        lo = $rtoi(expv);
        hi = lo + 1;
        if (d != lo && d != hi)
            fail($sformatf("%s interval %0d, expected %0d or %0d", nm, d, lo, hi));
        n++; sum += d;
    endtask

    always @(posedge mclk_a) if (steady && a_pps != pa_pps) begin
        #1;
        if (pa_pps != 0 && a_pps == pa_pps + 1) begin
            automatic int d = int'(a_last - a_prev);
            check_interval("A", EXP_A, a_last, a_prev, n_a, sum_a);
            // the two captures must agree: frames advanced by the strobes in
            // the interval, phase by the remainder
            if (int'(a_frames - pa_frames) * 256 + int'(a_phase) - int'(pa_phase) != d)
                fail($sformatf("A: frames %0d, phase %0d -> %0d disagree with interval %0d",
                               int'(a_frames - pa_frames), pa_phase, a_phase, d));
        end
        pa_pps = a_pps; pa_frames = a_frames; pa_phase = a_phase;
    end

    int pb_pps = 0;
    always @(posedge mclk_b) if (steady && b_pps != pb_pps) begin
        #1;
        if (pb_pps != 0 && b_pps == pb_pps + 1)
            check_interval("B", EXP_B, b_last, b_prev, n_b, sum_b);
        pb_pps = b_pps;
    end

    task automatic wait_pps(input int k);
        int t = a_pps + k;
        wait (a_pps >= t);
    endtask

    // ----- run -----
    initial begin
        logic [31:0] r, impl0;
        repeat (20) @(posedge aclk);
        aresetn = 1;
        rst_n = 1;

        // settle: first edges carry no interval
        wait_pps(2);
        if (a_impl != 0 || b_impl != 0) fail("implausible at start-up");
        pa_pps = a_pps; pb_pps = b_pps;
        pa_frames = a_frames; pa_phase = a_phase;
        steady = 1;
        wait_pps(40);
        steady = 0;
        if (a_impl != 0 || b_impl != 0) fail($sformatf("implausible in steady run: A %0d B %0d", a_impl, b_impl));

        // status window: header and words vs the meter (after a snapshot)
        repeat (600) @(posedge mclk_a);
        axi_read(12'h000, r); if (r !== 32'h4D43_5001) fail($sformatf("ID %h", r));
        axi_read(12'h004, r); if (r !== NOMINAL)       fail($sformatf("CONFIG %0d", r));
        axi_read(12'h100, r); if (r !== a_pps)    fail($sformatf("PPS_COUNT %0d vs %0d", r, a_pps));
        axi_read(12'h104, r); if (r !== a_last)   fail("CYC_AT_PPS");
        axi_read(12'h108, r); if (r !== a_prev)   fail("CYC_AT_PREV");
        axi_read(12'h10C, r); if (r !== a_frames) fail("FRAMES_AT_PPS");
        axi_read(12'h110, r); if (r !== {16'b0, a_phase}) fail("PHASE_AT_PPS");
        axi_read(12'h114, r); if (r !== a_impl)   fail("IMPLAUSIBLE");
        axi_read(12'h118, r); if (r === 32'h0 || r > a_now) fail("CYC_NOW");

        // a PHC step: +300 us of TSU time -> exactly one implausible interval
        impl0 = a_impl;
        wait_pps(1);
        repeat (1000) @(posedge tsu_clk);
        @(negedge tsu_clk) ns = ns + 300_000;
        wait_pps(3);
        if (a_impl != impl0 + 1) fail($sformatf("PHC step: implausible +%0d, want +1", a_impl - impl0));

        // a dropout: the PPS stops for two "seconds" -> exactly one
        // Forced low from 60 % into a "second" (the PPS is low there anyway,
        // since ns > 2^MSB) and released at the same point two seconds later,
        // so the release makes no edge of its own: the next edge is the real
        // one, three seconds after the last.
        impl0 = a_impl;
        wait_pps(1);
        repeat (150_000) @(posedge tsu_clk);
        force u_a.pps_async = 1'b0;
        #(2 * SCALE_NS * 1000);
        release u_a.pps_async;
        wait_pps(3);
        if (a_impl != impl0 + 1) fail($sformatf("dropout: implausible +%0d, want +1", a_impl - impl0));

        $display("meter A: %0d intervals, mean %.3f cycles, expected %.3f (%.1f ppm vs nominal)",
                 n_a, sum_a / n_a, EXP_A, (sum_a / n_a / NOMINAL - 1.0) * 1e6);
        $display("meter B: %0d intervals, mean %.3f cycles, expected %.3f (%.1f ppm vs nominal)",
                 n_b, sum_b / n_b, EXP_B, (sum_b / n_b / NOMINAL - 1.0) * 1e6);
        if (n_a < 30 || n_b < 30) fail("too few intervals checked");
        if ((sum_a / n_a - EXP_A) > 0.1 || (EXP_A - sum_a / n_a) > 0.1) fail("A: mean off");
        if ((sum_b / n_b - EXP_B) > 0.1 || (EXP_B - sum_b / n_b) > 0.1) fail("B: mean off");

        if (errors == 0) $display("PASS tb_media_clock_meter");
        else             $display("FAIL tb_media_clock_meter - %0d errors", errors);
        $finish;
    end

    initial begin
        #(200 * SCALE_NS * 1000);
        $display("FAIL tb_media_clock_meter: timeout");
        $finish;
    end

endmodule
