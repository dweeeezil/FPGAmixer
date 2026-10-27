// -----------------------------------------------------------------------------
// tb_mixer_core_pkg.sv
//
// The chain arithmetic (mixer_core_pkg, Phase 12) against values computed
// independently (a Python model of pcm_matrix_pkg's formulas and the chooser
// rule, phase12_status_2026-10-04.md step 1): lane counts and D for the sizes
// the project uses or may grow to, the "nothing fits" cases, and one chain
// latency off the chooser's path. Elaboration-time functions only; the cycle
// accuracy of the formulas themselves is checked by the core TB (step 2).
// LF1 (2026-10-26): the chooser's fallback to chains that span frames, and
// matrix_fits / chain_fits at their edges.
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

    task automatic expect_fits(input string what, input bit got, input bit want);
        if (got != want) begin
            errors++;
            $display("  %s: fits %0d, expected %0d", what, got, want);
        end
    endtask

    initial begin
        // Phase 15: the patch converters (+1 in, +1 out) and D_MAX 255
        expect_chain(20, 20, 20,  4,  4, 251);   // today's core (L2: N_BUS = N_OUT)
        expect_chain(12, 12, 12,  1,  2, 254);   // one DSP fewer than with D_MAX 250
        expect_chain(28, 28, 28, 10, 10, 235);   // Phase 11 growth
        expect_chain(40, 40, 40, 20, 28, 255);   // exactly D_MAX
        expect_chain(35, 35, 35, 15, 18, 255);   // exactly D_MAX
        // LF1 (2026-10-26): past one frame the chooser falls back to a chain
        // that spans frames (were "nothing fits"); values from an independent
        // Python model of the formulas and the latency-first rule
        expect_chain(48, 48, 48, 12, 16, 435);
        expect_chain(64, 64, 64, 22, 32, 459);
        expect_chain(96, 96, 96, 48, 48, 599);
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
        // LF1: the occupancy rule at its edges, and whole chains
        if (FRAME != 256 || D_CAP != 2048) begin
            errors++;
            $display("  FRAME = %0d, D_CAP = %0d, expected 256, 2048", FRAME, D_CAP);
        end
        expect_fits("matrix 16x16, 1 lane, span 15", matrix_fits(16, 16, 1, 15), 1);  // 256 + 256: both at the edge
        expect_fits("matrix 16x16, 1 lane, span 16", matrix_fits(16, 16, 1, 16), 0);  // samples: 257
        expect_fits("matrix 32->16, 2 lanes",        matrix_fits(32, 16, 2, 0),  1);  // depth 256
        expect_fits("matrix 32->17, 2 lanes",        matrix_fits(32, 17, 2, 0),  0);  // depth 288
        expect_fits("chain 16/16/16, 2 + 2",  chain_fits(16, 16, 16, 2, 2), 1);       // D 299: the TB's long chain
        expect_fits("chain 16/16/16, 1 + 1",  chain_fits(16, 16, 16, 1, 1), 0);
        expect_fits("chain 20/20/20, 2 + 2",  chain_fits(20, 20, 20, 2, 2), 0);
        expect_fits("chain 12/12/12, 1 + 1",  chain_fits(12, 12, 12, 1, 1), 0);
        expect_fits("chain 20/20/20, 4 + 4",  chain_fits(20, 20, 20, 4, 4), 1);
        expect_fits("chain 7/5/3, lanes 0",   chain_fits(7, 5, 3, 0, 1), 0);
        expect_fits("chain 7/5/3, L2 > N_OUT", chain_fits(7, 5, 3, 1, 4), 0);
        if (chain_latency(16, 16, 16, 2, 2) != 299) begin
            errors++;
            $display("  chain_latency(16,16,16,2,2) = %0d, expected 299", chain_latency(16, 16, 16, 2, 2));
        end
        if (errors == 0) $display("PASS: tb_mixer_core_pkg");
        else             $display("FAIL: tb_mixer_core_pkg - %0d errors", errors);
        $finish;
    end
endmodule
