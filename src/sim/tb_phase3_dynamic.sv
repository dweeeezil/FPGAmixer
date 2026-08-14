// -----------------------------------------------------------------------------
// tb_phase3_dynamic.sv
//
// Dynamic end-to-end test of phase3_top (identity routing, MMCM stubbed).
//
// Unlike tb_phase3_datapath, which holds each input value steady for many
// frames, this drives a DIFFERENT value into every frame and checks the output
// stream sample-by-sample. That's the case a static test can't see: a frame-
// boundary bug (stale sample, dropped/duplicated frame, L/R skew, channel
// swap) only shows up when the value actually changes each frame.
//
// Each input sample is tagged: bits [23:20] carry a channel ID (JA_L=1, JA_R=2,
// JB_L=3, JB_R=4) and bits [11:0] carry a frame counter. With identity routing
// each output must therefore show (a) its OWN channel tag every frame, and
// (b) a frame counter that increments by exactly 1 per captured frame. A wrong
// tag = routing/swap bug; a broken increment = a frame-boundary datapath bug.
//
// Drive timing is the same timing already validated in the fixed unit TBs
// (MSB on the first falling SCLK after the LRCK edge, self-aligning trailing
// zeros), so nothing here is newly hand-rolled.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_phase3_dynamic;

    logic sysclk = 0;
    always #4 sysclk = ~sysclk;

    logic ja_da_sdin, jb_da_sdin;
    logic ja_ad_sdout_r = 0, jb_ad_sdout_r = 0;
    logic ja_da_mclk, ja_da_lrck, ja_da_sclk, ja_ad_mclk, ja_ad_lrck, ja_ad_sclk;
    logic jb_da_mclk, jb_da_lrck, jb_da_sclk, jb_ad_mclk, jb_ad_lrck, jb_ad_sclk;

    phase3_top u_dut (
        .sysclk (sysclk),
        .ja_da_mclk(ja_da_mclk), .ja_da_lrck(ja_da_lrck), .ja_da_sclk(ja_da_sclk), .ja_da_sdin(ja_da_sdin),
        .ja_ad_mclk(ja_ad_mclk), .ja_ad_lrck(ja_ad_lrck), .ja_ad_sclk(ja_ad_sclk), .ja_ad_sdout(ja_ad_sdout_r),
        .jb_da_mclk(jb_da_mclk), .jb_da_lrck(jb_da_lrck), .jb_da_sclk(jb_da_sclk), .jb_da_sdin(jb_da_sdin),
        .jb_ad_mclk(jb_ad_mclk), .jb_ad_lrck(jb_ad_lrck), .jb_ad_sclk(jb_ad_sclk), .jb_ad_sdout(jb_ad_sdout_r)
    );

    wire mclk = u_dut.mclk;
    wire sclk = ja_ad_sclk;
    wire lrck = ja_ad_lrck;

    logic fix_rst_n = 0;

    // ------- Tagging -------
    function automatic logic [23:0] tagval(input logic [3:0] ch, input int f);
        return {ch, 8'h00, f[11:0]};   // [23:20]=chan, [11:0]=frame counter
    endfunction

    // ------- Drive one channel over its half-period (validated timing) -------
    task automatic drive_ja(input logic [23:0] word);
        logic s; s = lrck;
        for (int i = 23; i >= 0; i--) begin @(negedge sclk); ja_ad_sdout_r = word[i]; end
        while (lrck == s) begin @(negedge sclk); ja_ad_sdout_r = 1'b0; end
    endtask
    task automatic drive_jb(input logic [23:0] word);
        logic s; s = lrck;
        for (int i = 23; i >= 0; i--) begin @(negedge sclk); jb_ad_sdout_r = word[i]; end
        while (lrck == s) begin @(negedge sclk); jb_ad_sdout_r = 1'b0; end
    endtask

    // ------- Monitors: recover PCM from the DUT outputs -------
    logic [23:0] mon_ja_l, mon_ja_r, mon_jb_l, mon_jb_r;
    logic        mon_valid_ja, mon_valid_jb;

    i2s_receiver #(.DATA_WIDTH(24)) mon_ja (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (ja_da_sdin),
        .left_data (mon_ja_l), .right_data (mon_ja_r), .sample_valid (mon_valid_ja)
    );
    i2s_receiver #(.DATA_WIDTH(24)) mon_jb (
        .mclk (mclk), .rst_n (fix_rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (jb_da_sdin),
        .left_data (mon_jb_l), .right_data (mon_jb_r), .sample_valid (mon_valid_jb)
    );

    // ------- Drivers: one per Pmod, each owns its frame counter -------
    initial begin
        int f = 0;
        @(posedge fix_rst_n); @(negedge lrck);
        forever begin
            drive_ja(tagval(4'h1, f));   // JA left
            drive_ja(tagval(4'h2, f));   // JA right
            f++;
        end
    end
    initial begin
        int f = 0;
        @(posedge fix_rst_n); @(negedge lrck);
        forever begin
            drive_jb(tagval(4'h3, f));   // JB left
            drive_jb(tagval(4'h4, f));   // JB right
            f++;
        end
    end

    // ------- Checker -------
    localparam int SKIP   = 8;    // let the pipeline fill
    localparam int CHECK  = 24;   // frames to verify
    int errors = 0;

    task automatic tagchk(input string ch, input logic [3:0] got, input logic [3:0] exp);
        if (got !== exp) begin
            $display("  [FAIL] %s tag = %h, expected %h (channel swap / cross-route)", ch, got, exp);
            errors++;
        end
    endtask

    task automatic incchk(input string ch, input logic [11:0] got, input logic [11:0] prev, input bit have_prev);
        logic [11:0] exp;
        if (have_prev) begin
            exp = prev + 12'd1;
            if (got !== exp) begin
                $display("  [FAIL] %s counter = %03h, expected %03h (stale/dropped/dup frame)", ch, got, exp);
                errors++;
            end
        end
    endtask

    initial begin
        logic [11:0] p_jal, p_jar, p_jbl, p_jbr;
        bit have_prev;
        $display("");
        $display("=== tb_phase3_dynamic (identity routing, changing value every frame) ===");

        fix_rst_n = 0;
        wait (u_dut.mmcm_locked === 1'b1);
        repeat (20) @(posedge mclk);
        fix_rst_n = 1;

        have_prev = 0;
        for (int f = 0; f < SKIP + CHECK; f++) begin
            @(posedge mon_valid_ja); #1;
            if (f >= SKIP) begin
                tagchk("JA_L", mon_ja_l[23:20], 4'h1);
                tagchk("JA_R", mon_ja_r[23:20], 4'h2);
                tagchk("JB_L", mon_jb_l[23:20], 4'h3);
                tagchk("JB_R", mon_jb_r[23:20], 4'h4);
                incchk("JA_L", mon_ja_l[11:0], p_jal, have_prev);
                incchk("JA_R", mon_ja_r[11:0], p_jar, have_prev);
                incchk("JB_L", mon_jb_l[11:0], p_jbl, have_prev);
                incchk("JB_R", mon_jb_r[11:0], p_jbr, have_prev);
                p_jal = mon_ja_l[11:0]; p_jar = mon_ja_r[11:0];
                p_jbl = mon_jb_l[11:0]; p_jbr = mon_jb_r[11:0];
                have_prev = 1;
                if (f == SKIP)
                    $display("  locked: JA_L=%06h JA_R=%06h JB_L=%06h JB_R=%06h",
                             mon_ja_l, mon_ja_r, mon_jb_l, mon_jb_r);
            end
        end

        $display("");
        if (errors == 0)
            $display("PASS: tb_phase3_dynamic - %0d frames, tags + counters all correct", CHECK);
        else
            $display("FAIL: tb_phase3_dynamic - %0d error(s)", errors);
        $display("");
        $finish;
    end

    initial begin
        #4ms;
        $display("FAIL: tb_phase3_dynamic TIMEOUT");
        $finish;
    end

endmodule
