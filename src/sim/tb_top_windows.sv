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
//   - each window drives ITS block: with the core's input forced to known
//     samples, one change per window, chosen so that a swapped or misrouted
//     window gives a different output:
//       input level  ch0 = 0.5
//       input matrix bus2 <- in2 at 0.25 (instead of 1.0)
//       bus level    ch0 = 0.5
//       bus matrix   out1 <- bus0 at 1.0, out0 <- bus0 off
//       output level ch1 = 0.5
//     expected: out0 = 0; out1 = (in0/4 + in1) / 2 (bus0 = in0/2/2 joins
//     bus1 = in1, which still feeds out1 at 1.0, then the output level);
//     out2 = in2 / 4; every other output = its input.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_top_windows;

    localparam int N  = 20;
    localparam int SW = 24;

    logic sysclk = 0;
    always #4 sysclk = ~sysclk;

    logic jb_da_mclk, jb_da_lrck, jb_da_sclk, jb_da_sdin, jb_ad_mclk, jb_ad_lrck, jb_ad_sclk;
    logic jc_da_mclk, jc_da_lrck, jc_da_sclk, jc_da_sdin, jc_ad_mclk, jc_ad_lrck, jc_ad_sclk;

    fpgamixer_top u_dut (
        .sysclk (sysclk),
        .jb_da_mclk (jb_da_mclk), .jb_da_lrck (jb_da_lrck), .jb_da_sclk (jb_da_sclk), .jb_da_sdin (jb_da_sdin),
        .jb_ad_mclk (jb_ad_mclk), .jb_ad_lrck (jb_ad_lrck), .jb_ad_sclk (jb_ad_sclk), .jb_ad_sdout (1'b0),
        .jc_da_mclk (jc_da_mclk), .jc_da_lrck (jc_da_lrck), .jc_da_sclk (jc_da_sclk), .jc_da_sdin (jc_da_sdin),
        .jc_ad_mclk (jc_ad_mclk), .jc_ad_lrck (jc_ad_lrck), .jc_ad_sclk (jc_ad_sclk), .jc_ad_sdout (1'b0)
    );

    // ----- known core inputs: in[k] = (k + 1) * 0x010000 -----
    logic [N*SW-1:0] stim;
    initial begin
        for (int k = 0; k < N; k++) stim[k*SW +: SW] = SW'((k + 1) * 32'h010000);
        stim[0 +: SW] = 24'h400000;          // in0: big enough that /8 is exact
        force u_dut.core_in = stim;
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
    string name [5] = '{"input matrix", "bus matrix", "input levels", "bus levels", "output levels"};

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

        $display("-- reset state: identity and unity, output = input");
        repeat (3) @(posedge u_dut.u_core.valid_o);
        @(negedge u_dut.mclk);
        for (int k = 0; k < N; k++)
            check($sformatf("reset out%0d", k), 32'(u_dut.core_out[k*SW +: SW]), 32'(stim[k*SW +: SW]));

        $display("-- one change per window");
        wr(INLVL,  lv(0), 32'h0000_8000);           // in0 x 0.5
        wr(CTRL,   mx(2, 2), 32'h0000_4000);        // bus2 <- in2 x 0.25
        wr(BUSLVL, lv(0), 32'h0000_8000);           // bus0 x 0.5
        wr(BUSMX,  mx(0, 0), 32'h0);                // out0 <- bus0 off
        wr(BUSMX,  mx(1, 0), 32'h0001_0000);        // out1 <- bus0 x 1.0
        wr(OUTLVL, lv(1), 32'h0000_8000);           // out1 x 0.5
        commit(INLVL); commit(CTRL); commit(BUSLVL); commit(BUSMX); commit(OUTLVL);

        for (int k = 0; k < N; k++) exp_out[k] = stim[k*SW +: SW];
        exp_out[0] = 0;
        exp_out[1] = SW'((32'h400000 / 4 + 32'h020000) / 2);   // (in0/2/2 + in1) / 2
        exp_out[2] = SW'(32'h030000 / 4);

        repeat (3) @(posedge u_dut.u_core.valid_o);
        @(negedge u_dut.mclk);
        for (int k = 0; k < N; k++)
            check($sformatf("out%0d", k), 32'(u_dut.core_out[k*SW +: SW]), 32'(exp_out[k]));

        $display("-- the GAIN registers read back");
        rd(INLVL,  lv(0), r);     check("input level 0",  r, 32'h0000_8000);
        rd(BUSMX,  mx(1, 0), r);  check("bus matrix 1<-0", r, 32'h0001_0000);
        rd(OUTLVL, lv(1), r);     check("output level 1", r, 32'h0000_8000);

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
