// -----------------------------------------------------------------------------
// tb_media_clock_steer.sv
//
// P9.4b: media_clock_steer (+ media_clock_ctrl_regs), and the whole steering
// chain against the P9.3 meter.
//
// Part 1, the steerer alone (PSCLK 100 MHz, a UG572 handshake model: PSDONE
// one cycle, 12 cycles after PSEN):
//   - protocol: PSEN is one cycle wide and never asserted while a step is in
//     flight (between PSEN and PSDONE); PSINCDEC follows the rate's sign;
//   - rate -> steps: over a long window the completed steps equal
//     |RATE| * cycles / 2^32 (within the backlog, a few steps);
//   - saturation: an impossible rate gives one step per 14 cycles and counts
//     the excess in DROPPED;
//   - MMCM not locked: no PSEN at all.
//   - the window: RATE written over AXI4-Lite reaches the steerer, reads back;
//     ID, CONFIG, VCO_HZ, PS_DIV, the step counters.
//
// Part 2, end to end: an MMCM model whose clk_out1 edges really move by one
// fine-phase step (1 / (1450 MHz * 56) = 12.315 ps) per completed PSEN,
// increment = later; the real media_clock_meter measures that clock against a
// 1PPS from a TSU model ("seconds" scaled to 1 ms, as in tb_media_clock_meter).
// With RATE for 0, +50 and -50 ppm of steps, the meter must see the frequency
// move by -50 and +50 ppm (steps delay the clock: a positive rate slows it)
// within +/-6 ppm: the mean over 40 intervals is exact to +/-1 cycle overall,
// i.e. +/-2 ppm per mean, so +/-4.1 ppm worst for a difference of two).
// -----------------------------------------------------------------------------
`timescale 1ps / 1ps

module tb_media_clock_steer;

    // ----- common: PSCLK / AXI clock 100 MHz -----
    logic psclk = 0;
    always #5000 psclk = ~psclk;

    int errors = 0;
    task automatic fail(input string s);
        errors++;
        if (errors <= 15) $display("[%0t ps] FAIL %s", $time, s);
    endtask

    // rate for a frequency offset in ppm (positive ppm of steps = slower)
    localparam real STEP_S = 1.0 / (1450.0e6 * 56.0);
    function automatic logic [31:0] rate_for_ppm(input real ppm);
        real steps_per_s = ppm * 1.0e-6 / STEP_S;
        return 32'($rtoi(steps_per_s / 100.0e6 * 4294967296.0));
    endfunction

    // =========================================================================
    // Part 1: the steerer + window, with a handshake-only MMCM model
    // =========================================================================
    logic        aresetn = 0;
    logic        locked1 = 0;
    logic        psen1, psincdec1, psdone1 = 0;
    logic [31:0] rate1;
    logic [31:0] inc1, dec1, drop1;
    logic        busy1, lk1;

    // AXI
    logic [11:0] awaddr = 0, araddr = 0;
    logic awvalid = 0, awready, wvalid = 0, wready, bvalid, bready = 0;
    logic arvalid = 0, arready, rvalid, rready = 0;
    logic [31:0] wdata = 0, rdata;
    logic [3:0]  wstrb = 0;
    logic [1:0]  bresp, rresp;

    media_clock_ctrl_regs u_regs (
        .aclk (psclk), .aresetn (aresetn),
        .s_axi_awaddr (awaddr), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wvalid (wvalid),
        .s_axi_wready (wready), .s_axi_bresp (bresp), .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp), .s_axi_rvalid (rvalid),
        .s_axi_rready (rready),
        .rate (rate1), .steps_inc (inc1), .steps_dec (dec1), .dropped (drop1),
        .busy (busy1), .locked (lk1));

    media_clock_steer u_steer1 (
        .psclk (psclk), .rst_n (aresetn), .rate (rate1), .mmcm_locked (locked1),
        .psen (psen1), .psincdec (psincdec1), .psdone (psdone1),
        .steps_inc (inc1), .steps_dec (dec1), .dropped (drop1),
        .busy (busy1), .locked (lk1));

    // handshake model + protocol checks
    int  ps_cnt1 = 0;
    bit  inflight1 = 0;
    always @(posedge psclk) begin
        psdone1 <= 1'b0;
        if (psen1) begin
            if (inflight1) fail("PSEN while a step is in flight");
            if (!locked1)  fail("PSEN while the MMCM is not locked");
            inflight1 = 1;
            ps_cnt1  <= 12;
        end
        if (ps_cnt1 > 0) begin
            ps_cnt1 <= ps_cnt1 - 1;
            if (ps_cnt1 == 1) begin psdone1 <= 1'b1; inflight1 = 0; end
        end
    end
    logic psen1_q = 0;
    always @(posedge psclk) begin
        if (psen1 && psen1_q) fail("PSEN longer than one cycle");
        psen1_q <= psen1;
    end

    task automatic axi_write(input logic [11:0] a, input logic [31:0] d);
        @(posedge psclk);
        awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= 4'hF; wvalid <= 1; bready <= 1;
        do @(posedge psclk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge psclk);
        @(posedge psclk);
        bready <= 0;
    endtask

    task automatic axi_write_strb(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s);
        @(posedge psclk);
        awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= s; wvalid <= 1; bready <= 1;
        do @(posedge psclk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge psclk);
        @(posedge psclk);
        bready <= 0;
    endtask

    task automatic axi_read(input logic [11:0] a, output logic [31:0] d);
        @(posedge psclk);
        araddr <= a; arvalid <= 1; rready <= 1;
        do @(posedge psclk); while (!arready);
        arvalid <= 0;
        while (!rvalid) @(posedge psclk);
        d = rdata;
        @(posedge psclk);
        rready <= 0;
    endtask

    // count steps over a window at a given rate; compare with the expectation
    task automatic run_rate(input string nm, input logic [31:0] r, input int cycles,
                            input real expect_steps, input bit expect_inc);
        logic [31:0] i0, d0, i1, d1;
        real got;
        axi_write(12'h100, r);
        repeat (200) @(posedge psclk);                 // settle
        i0 = inc1; d0 = dec1;
        repeat (cycles) @(posedge psclk);
        i1 = inc1; d1 = dec1;
        got = expect_inc ? real'(i1 - i0) : real'(d1 - d0);
        if ((expect_inc ? (d1 - d0) : (i1 - i0)) != 0)
            fail($sformatf("%s: steps in the wrong direction", nm));
        if (got < expect_steps - 3.0 || got > expect_steps + 3.0)
            fail($sformatf("%s: %.0f steps, expected %.1f", nm, got, expect_steps));
        $display("  %-24s %8.0f steps in %0d cycles (expected %.1f)", nm, got, cycles, expect_steps);
    endtask

    // =========================================================================
    // Part 2: end to end with a phase-moving MMCM model and the meter
    // =========================================================================
    localparam longint SCALE_NS = 1_000_000;          // one "second" = 1 ms
    localparam int     NOMINAL  = 12288;
    localparam real    T_HALF   = 1.0e12 / (2.0 * 12.288135593e6);   // ps, 25*58/118 MHz
    localparam real    STEP_PS  = STEP_S * 1.0e12;                     // 12.315 ps

    logic        locked2 = 0;
    logic        psen2, psincdec2, psdone2 = 0;
    logic [31:0] rate2 = 0;
    logic [31:0] inc2, dec2, drop2;
    logic        busy2, lk2;
    logic        rst2 = 0;

    media_clock_steer u_steer2 (
        .psclk (psclk), .rst_n (rst2), .rate (rate2), .mmcm_locked (locked2),
        .psen (psen2), .psincdec (psincdec2), .psdone (psdone2),
        .steps_inc (inc2), .steps_dec (dec2), .dropped (drop2),
        .busy (busy2), .locked (lk2));

    // MMCM model: each completed step moves every later edge by STEP_PS
    real phase_ps = 0.0;
    int  ps_cnt2 = 0;
    bit  dir2;
    always @(posedge psclk) begin
        psdone2 <= 1'b0;
        if (psen2) begin ps_cnt2 <= 12; dir2 = psincdec2; end
        if (ps_cnt2 > 0) begin
            ps_cnt2 <= ps_cnt2 - 1;
            if (ps_cnt2 == 1) begin
                psdone2 <= 1'b1;
                phase_ps = phase_ps + (dir2 ? STEP_PS : -STEP_PS);
            end
        end
    end

    logic mclk_m = 0;
    initial begin
        automatic longint k = 0;
        real t;
        forever begin
            k++;
            t = k * T_HALF + phase_ps;                 // absolute edge time
            if (t > $realtime) #(t - $realtime);
            mclk_m = ~mclk_m;
        end
    end

    // TSU model + 1PPS (as tb_media_clock_meter)
    logic tsu_clk = 0;
    always #2000 tsu_clk = ~tsu_clk;
    longint ns = 0;
    always @(posedge tsu_clk) begin
        ns = ns + 4;
        if (ns >= SCALE_NS) ns = ns - SCALE_NS;
    end
    wire pps = ~ns[19];

    logic fr = 0; int fcnt = 0;
    always @(posedge mclk_m) begin fcnt <= (fcnt + 1) % 256; fr <= (fcnt == 255); end

    logic [31:0] m_pps, m_last, m_prev, m_frames, m_impl, m_now;
    logic [15:0] m_phase;
    logic        mrst = 0;
    media_clock_meter #(.NOMINAL (NOMINAL), .TOL (NOMINAL / 100)) u_meter (
        .mclk (mclk_m), .rst_n (mrst), .pps_async (pps), .frame_i (fr),
        .pps_count (m_pps), .cyc_last (m_last), .cyc_prev (m_prev),
        .frames_last (m_frames), .phase_last (m_phase),
        .implausible (m_impl), .cyc_now (m_now));

    // mean interval over n new PPS captures
    task automatic measure(input int n, output real mean);
        real sum; sum = 0;
        for (int i = 0; i < n; i++) begin
            int target = m_pps + 1;
            wait (m_pps >= target);
            #1;
            sum += real'(m_last - m_prev);
        end
        mean = sum / n;
    endtask

    // =========================================================================
    initial begin
        logic [31:0] r;
        real m0, mp, mn, ppm_p, ppm_n;

        // ----- Part 1 -----
        $display("--- part 1: steerer + window");
        repeat (10) @(posedge psclk);
        aresetn = 1;

        axi_read(12'h000, r); if (r !== 32'h4D53_5001) fail($sformatf("ID %h", r));
        axi_read(12'h004, r); if (r !== 100_000_000)   fail($sformatf("CONFIG %0d", r));
        axi_read(12'h114, r); if (r !== 1_450_000_000) fail($sformatf("VCO_HZ %0d", r));
        axi_read(12'h118, r); if (r !== 56)            fail($sformatf("PS_DIV %0d", r));

        // generic window: WSTRB per byte, the WRITES counter, RO words not writable
        begin
            logic [31:0] w0, w1;
            axi_read(12'h00C, w0);
            axi_write(12'h100, 32'h1122_3344);
            axi_write_strb(12'h100, 32'hAABB_CCDD, 4'b0101);  // bytes 0 and 2
            axi_read(12'h100, r);
            if (r !== 32'h11BB_33DD) fail($sformatf("WSTRB: RATE %h, want 11BB33DD", r));
            axi_write(12'h114, 32'h0);                           // a RO word
            axi_read(12'h114, r);
            if (r !== 1_450_000_000) fail("a RO word was writable");
            axi_read(12'h00C, w1);
            if (w1 - w0 != 2) fail($sformatf("WRITES +%0d, want +2 (RO writes don't count)", w1 - w0));
        end

        // not locked: a rate must produce nothing
        axi_write(12'h100, 32'h1000_0000);
        repeat (2000) @(posedge psclk);
        if (inc1 != 0 || dec1 != 0) fail("steps while not locked");
        axi_read(12'h110, r); if (r[0] !== 1'b0) fail("FLAGS.locked while unlocked");

        locked1 = 1;
        repeat (10) @(posedge psclk);
        axi_read(12'h110, r); if (r[0] !== 1'b1) fail("FLAGS.locked not set");
        axi_read(12'h100, r); if (r !== 32'h1000_0000) fail("RATE read-back");

        // 1/64 step per cycle -> 1000 steps in 64000 cycles
        run_rate("+1/64 per cycle",  32'h0400_0000, 64000, 1000.0, 1);
        run_rate("-1/64 per cycle", -32'sh0400_0000, 64000, 1000.0, 0);
        // the +50 ppm rate used in part 2: 50 ppm * 81,200 steps/s / 100 MHz
        run_rate("+50 ppm",  rate_for_ppm(50.0), 200000, 50.0e-6 / STEP_S * 200000 / 100.0e6, 1);
        // impossible rate: saturates at one step per 14 cycles, drops the rest
        begin
            logic [31:0] d0;
            d0 = drop1;
            run_rate("saturated (+1/2)", 32'h7FFF_FFFF, 140000, 10000.0, 1);
            if (drop1 == d0) fail("saturation: nothing counted as dropped");
        end
        axi_write(12'h100, 32'h0);
        repeat (5000) @(posedge psclk);                // the saturated backlog drains
        begin
            logic [31:0] i0; i0 = inc1;
            repeat (20000) @(posedge psclk);
            if (inc1 != i0) fail("steps with RATE = 0");
        end
        // unlock mid-stream: PSEN stops at once (the model checks)
        axi_write(12'h100, 32'h0400_0000);
        repeat (1000) @(posedge psclk);
        locked1 = 0;
        repeat (5000) @(posedge psclk);

        // ----- Part 2 -----
        $display("--- part 2: end to end, MMCM phase model + meter");
        rst2 = 1; mrst = 1;
        locked2 = 1;
        begin automatic int t = 3; wait (m_pps >= t); end        // meter settled
        rate2 = 0;              measure(40, m0);
        rate2 = rate_for_ppm(50.0);
        begin automatic int t = m_pps + 2; wait (m_pps >= t); end
        measure(40, mp);
        rate2 = -rate_for_ppm(50.0);
        begin automatic int t = m_pps + 2; wait (m_pps >= t); end
        measure(40, mn);
        ppm_p = (mp / m0 - 1.0) * 1e6;
        ppm_n = (mn / m0 - 1.0) * 1e6;
        $display("  rate 0      : %.3f cycles per scaled second", m0);
        $display("  rate +50 ppm: %.3f  -> %.1f ppm (expected -50)", mp, ppm_p);
        $display("  rate -50 ppm: %.3f  -> %.1f ppm (expected +50)", mn, ppm_n);
        if (ppm_p > -44.0 || ppm_p < -56.0) fail("+50 ppm of steps did not slow mclk by ~50 ppm");
        if (ppm_n <  44.0 || ppm_n >  56.0) fail("-50 ppm of steps did not speed mclk by ~50 ppm");
        if (drop2 != 0) fail("part 2: steps dropped at 50 ppm");

        if (errors == 0) $display("PASS tb_media_clock_steer");
        else             $display("FAIL tb_media_clock_steer - %0d errors", errors);
        $finish;
    end

    initial begin
        #(200 * SCALE_NS * 1000);
        $display("FAIL tb_media_clock_steer: timeout");
        $finish;
    end

endmodule
