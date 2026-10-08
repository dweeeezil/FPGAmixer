// -----------------------------------------------------------------------------
// tb_mixer_core_pkg.sv
//
// The chain arithmetic (mixer_core_pkg, Phase 12) against values computed
// independently (a Python model of pcm_matrix_pkg's formulas and the chooser
// rule, phase12_status_2026-10-04.md step 1): lane counts and D for the sizes
// the project uses or may grow to, the "nothing fits" cases, and one chain
// latency off the chooser's path. Elaboration-time functions only; the cycle
// accuracy of the formulas themselves is checked by the core TB (step 2).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_mixer_core_pkg;
    import pcm_matrix_pkg::*;
    import mixer_core_pkg::*;

    int errors = 0;

    task automatic expect_chain(input int ni, input int nb, input int no,
                                input int l1, input int l2, input int d);
        int g1, g2, gd;
        g1 = chain_l1(ni, nb, no);
        g2 = chain_l2(ni, nb, no);
        gd = (g1 > 0 && g2 > 0) ? chain_latency(ni, nb, no, g1, g2) : 0;
        if (g1 != l1 || g2 != l2 || gd != d) begin
            errors++;
            $display("  %0d/%0d/%0d: lanes %0d + %0d, D = %0d; expected %0d + %0d, D = %0d",
                     ni, nb, no, g1, g2, gd, l1, l2, d);
        end else
            $display("  %2d/%2d/%2d: lanes %2d + %2d, D = %0d", ni, nb, no, g1, g2, gd);
    endtask

    initial begin
        // Phase 15: the patch converters (+1 in, +1 out) and D_MAX 255
        expect_chain(20, 20, 20,  4,  4, 251);   // today's core (L2: N_BUS = N_OUT)
        expect_chain(12, 12, 12,  1,  2, 254);   // one DSP fewer than with D_MAX 250
        expect_chain(28, 28, 28, 10, 10, 235);   // Phase 11 growth
        expect_chain(40, 40, 40, 20, 28, 255);   // exactly D_MAX
        expect_chain(35, 35, 35, 15, 18, 255);   // exactly D_MAX
        expect_chain(48, 48, 48,  0,  0,   0);   // nothing fits
        expect_chain(64, 64, 64,  0,  0,   0);
        expect_chain(20,  8, 20,  2,  2, 207);   // other bus counts
        expect_chain(20, 16, 20,  4,  3, 241);
        expect_chain( 7,  5,  3,  1,  1,  82);
        expect_chain( 1,  1,  1,  1,  1,  28);
        if (D_MAX != 255) begin
            errors++;
            $display("  D_MAX = %0d, expected 255", D_MAX);
        end
        if (chain_latency(20, 20, 20, 4, 5) != 232) begin
            errors++;
            $display("  chain_latency(20,20,20,4,5) = %0d, expected 232",
                     chain_latency(20, 20, 20, 4, 5));
        end
        if (chain_bus_last(20, 20, 4) != 20 + 1 + GAIN_LAT + matrix_lat_last(20, 20, 4)) begin
            errors++;
            $display("  chain_bus_last(20,20,4) = %0d", chain_bus_last(20, 20, 4));
        end
        if (errors == 0) $display("PASS: tb_mixer_core_pkg");
        else             $display("FAIL: tb_mixer_core_pkg - %0d errors", errors);
        $finish;
    end
endmodule
