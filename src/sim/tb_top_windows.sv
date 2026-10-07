// -----------------------------------------------------------------------------
// tb_top_windows.sv
//
// Phase 12 step 3: the platform layer's register-window wiring, in the real
// fpgamixer_top compiled as a PS build (INCLUDE_PS; no links, no media clock,
// as phase5), with the block design replaced by ps_sys_wrapper_stub (five
// AXI4-Lite master BFMs) and the MMCM by clk_wiz_audio_stub.
//
// Checks:
//   - each window answers on its own port with its own ID and CONFIG:
//     input matrix and bus matrix (0x4D58_5001, 20 x 20), input / bus /
//     output levels (0x474E_5001, N = 20, TAP 0 / 1 / 2);
//   - the reset state: identity and unity, except the USB-host channels 0..3
//     whose input matrix starts all off (Phase 11, H5);
//   - each window drives ITS block: with the core's input forced to known
//     samples, one change per window (on channels B = 4 .. 6, which start at
//     identity), chosen so that a swapped or misrouted window gives a
//     different output:
//       input level  ch B = 0.5
//       input matrix bus B+2 <- in B+2 at 0.25 (instead of 1.0)
//       bus level    ch B = 0.5
//       bus matrix   out B+1 <- bus B at 1.0, out B <- bus B off
//       output level ch B+1 = 0.5
//     expected: out B = 0; out B+1 = (in B/4 + in B+1) / 2; out B+2 =
//     in B+2 / 4; outputs 0..3 silent; every other output = its input;
//   - Phase 13: each meter reads its own zone.
// Phase 11: fpgamixer_top has no Pmod pins any more (decision P1).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_top_windows;

    localparam int N  = 20;
    localparam int SW = 24;
    localparam int NH = 4;     // the USB-host channels 0..3: input matrix off at reset (H5)
    localparam int B  = 4;     // the first channel of the per-window test (an identity one)

    logic sysclk = 0;
    always #4 sysclk = ~sysclk;

    fpgamixer_top u_dut (.sysclk (sysclk));     // Phase 11: no Pmod pins any more

    // ----- known core inputs: in[k] = (k + 1) * 0x010000 -----
    // Driven at the LINKS' wires, per the channel map (Phase 11): core 0..3 =
    // link #3 ch 0..3, 4..11 = link #1, 12..19 = link #2. Link #3's ch 4..7
    // carry a marker that must never reach the core.
    localparam logic [SW-1:0] MARK = 24'h5A5A5A;
    logic [N*SW-1:0] stim;
    logic [8*SW-1:0] l1, l2, l3;
    initial begin
        for (int k = 0; k < N; k++) stim[k*SW +: SW] = SW'((k + 1) * 32'h010000);
        stim[B*SW +: SW] = 24'h400000;       // in B: big enough that /8 is exact
        for (int c = 0; c < 8; c++) begin
            l3[c*SW +: SW] = c < NH ? stim[c*SW +: SW] : MARK;
            l1[c*SW +: SW] = stim[(4 + c)*SW +: SW];
            l2[c*SW +: SW] = stim[(12 + c)*SW +: SW];
        end
        force u_dut.link3_rx = l3;
        force u_dut.link_rx  = l1;
        force u_dut.link2_rx = l2;
    end

    // ----- the frame strobe: exactly one per 256 mclk cycles (2.1) -----
    int since = -1, frame_errors = 0, strobes = 0;
    always @(posedge u_dut.mclk) begin
        if (u_dut.frame) begin
            if (since >= 0 && since != 256) frame_errors++;
            since = 1;
            strobes++;
        end else if (since >= 0)
            since++;
    end

    int errors = 0;
    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("  FAIL %s: got 0x%08h, expected 0x%08h", what, got, exp);
            errors++;
        end else
            $display("  ok   %s = 0x%08h", what, got);
    endtask

    localparam int CTRL = 0, BUSMX = 1, INLVL = 2, BUSLVL = 3, OUTLVL = 4;
    localparam int INMTR = 5, BUSMTR = 6, OUTMTR = 7;                    // Phase 13
    string name [8] = '{"input matrix", "bus matrix", "input levels", "bus levels", "output levels",
                        "input meter", "bus meter", "output meter"};

    function automatic logic [31:0] mag(input logic [SW-1:0] x);       // as pcm_peak
        if (x == 24'h800000) return 32'h7F_FFFF;
        return x[SW-1] ? 32'(-x) & 32'hFF_FFFF : 32'(x);
    endfunction

    // SNAP a meter, wait, and check every channel against `want`
    task automatic check_meter(input int m, input logic [SW-1:0] want [N], input string tag);
        logic [31:0] r;
        commit(m);                                   // CTRL bit0 = SNAP
        for (int c = 0; c < N; c++) begin
            rd(m, lv(c), r);
            check($sformatf("%s %s ch%0d", name[m], tag, c), r, mag(want[c]));
        end
    endtask

    task automatic wr(input int m, input logic [31:0] a, input logic [31:0] d);
        u_dut.u_ps.axi_write(m, a, d);
    endtask
    task automatic rd(input int m, input logic [31:0] a, output logic [31:0] d);
        u_dut.u_ps.axi_read(m, a, d);
    endtask
    task automatic commit(input int m);
        logic [31:0] c;
        int guard = 0;
        wr(m, 32'h008, 32'h1);
        do begin rd(m, 32'h008, c); guard++; end while (c[1:0] != 2'b00 && guard < 2000);
        if (guard >= 2000) begin $display("  FAIL %s: commit never completed", name[m]); errors++; end
    endtask

    function automatic logic [31:0] mx(input int dst, input int src);   // matrix GAIN address
        return 32'h100 + 32'(4 * (dst*N + src));
    endfunction
    function automatic logic [31:0] lv(input int c);                     // level GAIN address
        return 32'h100 + 32'(4 * c);
    endfunction

    logic [31:0] r;
    logic [SW-1:0] exp_out [N];

    initial begin
        $display("=== tb_top_windows ===");
        wait (u_dut.mmcm_locked === 1'b1);
        wait (u_dut.u_ps.ctrl_aresetn === 1'b1);
        repeat (20) @(posedge u_dut.mclk);

        $display("-- each window: ID and CONFIG");
        rd(CTRL,   32'h000, r); check("input matrix ID",      r, 32'h4D58_5001);
        rd(CTRL,   32'h004, r); check("input matrix CONFIG",  r, 32'h1414_1210);
        rd(BUSMX,  32'h000, r); check("bus matrix ID",        r, 32'h4D58_5001);
        rd(BUSMX,  32'h004, r); check("bus matrix CONFIG",    r, 32'h1414_1210);
        rd(INLVL,  32'h000, r); check("input levels ID",      r, 32'h474E_5001);
        rd(INLVL,  32'h004, r); check("input levels CONFIG",  r, 32'h1400_1210);
        rd(BUSLVL, 32'h000, r); check("bus levels ID",        r, 32'h474E_5001);
        rd(BUSLVL, 32'h004, r); check("bus levels CONFIG",    r, 32'h1401_1210);
        rd(OUTLVL, 32'h000, r); check("output levels ID",     r, 32'h474E_5001);
        rd(OUTLVL, 32'h004, r); check("output levels CONFIG", r, 32'h1402_1210);
        rd(INMTR,  32'h000, r); check("input meter ID",       r, 32'h504B_5001);
        rd(INMTR,  32'h004, r); check("input meter CONFIG",   r, 32'h1400_1800);
        rd(BUSMTR, 32'h000, r); check("bus meter ID",         r, 32'h504B_5001);
        rd(BUSMTR, 32'h004, r); check("bus meter CONFIG",     r, 32'h1401_1800);
        rd(OUTMTR, 32'h000, r); check("output meter ID",      r, 32'h504B_5001);
        rd(OUTMTR, 32'h004, r); check("output meter CONFIG",  r, 32'h1402_1800);

        $display("-- reset state: identity and unity, output = input; channels 0..3 off (H5)");
        repeat (3) @(posedge u_dut.u_core.valid_o);
        @(negedge u_dut.mclk);
        for (int k = 0; k < N; k++)
            check($sformatf("reset out%0d", k), 32'(u_dut.core_out[k*SW +: SW]),
                  k < NH ? 32'h0 : 32'(stim[k*SW +: SW]));

        $display("-- the channel map (Phase 11): links in -> core in, core out -> links out");
        check("core_in = the links in map order", 32'(u_dut.core_in == stim), 1);
        for (int c = 0; c < 8; c++) begin
            check($sformatf("link #1 out ch%0d", c), 32'(u_dut.link_tx[c*SW +: SW]),
                  32'(u_dut.core_out[(4 + c)*SW +: SW]));
            check($sformatf("link #2 out ch%0d", c), 32'(u_dut.link2_tx[c*SW +: SW]),
                  32'(u_dut.core_out[(12 + c)*SW +: SW]));
            check($sformatf("link #3 out ch%0d", c), 32'(u_dut.link3_tx[c*SW +: SW]),
                  c < NH ? 32'(u_dut.core_out[c*SW +: SW]) : 32'h0);
        end

        $display("-- one change per window (channels B = 4 .. 6)");
        wr(INLVL,  lv(B), 32'h0000_8000);               // in B x 0.5
        wr(CTRL,   mx(B+2, B+2), 32'h0000_4000);        // bus B+2 <- in B+2 x 0.25
        wr(BUSLVL, lv(B), 32'h0000_8000);               // bus B x 0.5
        wr(BUSMX,  mx(B, B), 32'h0);                    // out B <- bus B off
        wr(BUSMX,  mx(B+1, B), 32'h0001_0000);          // out B+1 <- bus B x 1.0
        wr(OUTLVL, lv(B+1), 32'h0000_8000);             // out B+1 x 0.5
        commit(INLVL); commit(CTRL); commit(BUSLVL); commit(BUSMX); commit(OUTLVL);

        for (int k = 0; k < N; k++) exp_out[k] = k < NH ? '0 : stim[k*SW +: SW];
        exp_out[B]   = 0;
        exp_out[B+1] = SW'((32'h400000 / 4 + 32'h060000) / 2);  // (in B/2/2 + in B+1) / 2
        exp_out[B+2] = SW'(32'h070000 / 4);                     // in B+2 / 4

        repeat (3) @(posedge u_dut.u_core.valid_o);
        @(negedge u_dut.mclk);
        for (int k = 0; k < N; k++)
            check($sformatf("out%0d", k), 32'(u_dut.core_out[k*SW +: SW]), 32'(exp_out[k]));

        $display("-- each meter reads its own zone (Phase 13)");
        begin
            logic [SW-1:0] want_in [N], want_bus [N];
            for (int k = 0; k < N; k++) begin
                want_in[k]  = stim[k*SW +: SW];             // input levels: before the matrix
                want_bus[k] = k < NH ? '0 : stim[k*SW +: SW];
            end
            want_in[B]    = 24'h200000;                 // in B x 0.5
            want_bus[B]   = 24'h100000;                 // in B x 0.5, bus B x 0.5
            want_bus[B+2] = 24'h01C000;                 // in B+2 x 0.25
            commit(INMTR); commit(BUSMTR); commit(OUTMTR);   // close the windows from before the changes
            repeat (2) @(posedge u_dut.u_core.valid_o);
            check_meter(INMTR,  want_in,  "post-level");
            check_meter(BUSMTR, want_bus, "post-level");
            check_meter(OUTMTR, exp_out,  "post-level");
        end

        $display("-- the GAIN registers read back");
        rd(INLVL,  lv(B), r);       check("input level B",    r, 32'h0000_8000);
        rd(BUSMX,  mx(B+1, B), r);  check("bus matrix B+1<-B", r, 32'h0001_0000);
        rd(OUTLVL, lv(B+1), r);     check("output level B+1", r, 32'h0000_8000);
        rd(CTRL,   mx(0, 0), r);    check("input matrix 0<-0 off at reset (H5)", r, 32'h0);

        check("frame strobes at 256-cycle spacing", 32'(frame_errors), 0);
        if (strobes < 10) begin $display("  FAIL only %0d frame strobes", strobes); errors++; end
        if (u_dut.u_ps.bus_errors != 0) begin
            $display("  FAIL %0d non-OKAY AXI responses", u_dut.u_ps.bus_errors);
            errors++;
        end
        if (errors == 0) $display("PASS: tb_top_windows - all checks passed");
        else             $display("FAIL: tb_top_windows - %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #10ms;
        $display("FAIL: tb_top_windows TIMEOUT");
        $finish;
    end
endmodule
