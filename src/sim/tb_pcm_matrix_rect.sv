// -----------------------------------------------------------------------------
// tb_pcm_matrix_rect.sv
//
// Non-square pcm_matrix (N_IN != N_OUT). tb_pcm_matrix covers the arithmetic
// corner cases on a 4x4; this checks the indexing when the two sizes differ,
// which is what a bus layer (inputs -> buses -> outputs) will need:
//   dut_a : 3 in -> 5 out  (widening)
//   dut_b : 5 in -> 2 out  (narrowing)
// Each gets random samples and random gains (including negative and > 1.0)
// for many frames, compared against a 64-bit reference model.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pcm_matrix_rect;

    localparam int SW = 24;
    localparam int GW = 18;
    localparam int GF = 16;
    localparam int FRAMES = 200;

    logic mclk = 0;
    always #5 mclk = ~mclk;
    logic rst_n = 0;
    logic sv_i = 0;

    int errors = 0;

    // ----- Generic reference: out[o] = sat(sum_i in[i]*g[o*n_in+i] >>> GF) -----
    function automatic logic [SW-1:0] ref_out(input logic [8*SW-1:0] in_v,
                                              input logic [40*GW-1:0] g_v,
                                              input int n_in, input int o);
        longint acc = 0;
        for (int i = 0; i < n_in; i++)
            acc += longint'($signed(in_v[i*SW +: SW])) *
                   longint'($signed(g_v[(o*n_in + i)*GW +: GW]));
        acc = acc >>> GF;
        if (acc >  64'sd8388607) acc =  64'sd8388607;
        if (acc < -64'sd8388608) acc = -64'sd8388608;
        return acc[SW-1:0];
    endfunction

    // ----- DUT A: 3 -> 5 -----
    localparam int AI = 3, AO = 5;
    logic [AI*SW-1:0]    a_in;
    logic [AO*SW-1:0]    a_out;
    logic [AO*AI*GW-1:0] a_g;
    logic                a_v;
    pcm_matrix #(.N_IN (AI), .N_OUT (AO), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF))
        dut_a (.mclk (mclk), .rst_n (rst_n), .sample_valid_i (sv_i), .gains_flat (a_g),
               .in_flat (a_in), .out_flat (a_out), .sample_valid_o (a_v));

    // ----- DUT B: 5 -> 2 -----
    localparam int BI = 5, BO = 2;
    logic [BI*SW-1:0]    b_in;
    logic [BO*SW-1:0]    b_out;
    logic [BO*BI*GW-1:0] b_g;
    logic                b_v;
    pcm_matrix #(.N_IN (BI), .N_OUT (BO), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF))
        dut_b (.mclk (mclk), .rst_n (rst_n), .sample_valid_i (sv_i), .gains_flat (b_g),
               .in_flat (b_in), .out_flat (b_out), .sample_valid_o (b_v));

    // Random gain in [-2.0, 2.0) with a bias toward small/zero values so that
    // most outputs don't saturate and the indexing is actually visible.
    function automatic logic [GW-1:0] rand_gain();
        case ($urandom % 4)
            0:       return '0;
            1:       return GW'($urandom % (1 << GF));          // [0, 1.0)
            2:       return GW'(-($urandom % (1 << GF)));       // (-1.0, 0]
            default: return GW'($urandom);                      // anywhere
        endcase
    endfunction

    task automatic check(input string tag, input int o,
                         input logic [SW-1:0] got, input logic [SW-1:0] exp);
        if (got !== exp) begin
            if (errors < 10)
                $display("  FAIL %s out%0d: got %06h, ref %06h", tag, o, got, exp);
            errors++;
        end
    endtask

    initial begin
        logic [8*SW-1:0]  in_v;
        logic [40*GW-1:0] g_v;

        $display("=== tb_pcm_matrix_rect ===");
        a_in = '0; b_in = '0; a_g = '0; b_g = '0;
        repeat (3) @(negedge mclk);
        rst_n = 1;

        for (int f = 0; f < FRAMES; f++) begin
            @(negedge mclk);
            for (int k = 0; k < AI;    k++) a_in[k*SW +: SW] = SW'($urandom);
            for (int k = 0; k < BI;    k++) b_in[k*SW +: SW] = SW'($urandom);
            for (int k = 0; k < AO*AI; k++) a_g[k*GW +: GW]  = rand_gain();
            for (int k = 0; k < BO*BI; k++) b_g[k*GW +: GW]  = rand_gain();
            sv_i = 1;
            @(negedge mclk);
            sv_i = 0;

            in_v = '0; g_v = '0;
            in_v[AI*SW-1:0] = a_in; g_v[AO*AI*GW-1:0] = a_g;
            for (int o = 0; o < AO; o++)
                check("3->5", o, a_out[o*SW +: SW], ref_out(in_v, g_v, AI, o));

            in_v = '0; g_v = '0;
            in_v[BI*SW-1:0] = b_in; g_v[BO*BI*GW-1:0] = b_g;
            for (int o = 0; o < BO; o++)
                check("5->2", o, b_out[o*SW +: SW], ref_out(in_v, g_v, BI, o));
        end

        if (errors == 0)
            $display("PASS: tb_pcm_matrix_rect - %0d frames, 3->5 and 5->2 match the reference", FRAMES);
        else
            $display("FAIL: tb_pcm_matrix_rect - %0d mismatch(es)", errors);
        $finish;
    end

endmodule
