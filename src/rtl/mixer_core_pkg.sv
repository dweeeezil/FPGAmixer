// -----------------------------------------------------------------------------
// mixer_core_pkg.sv
//
// The PCM core's chain arithmetic, in one place (Phase 12, decision L4), so the
// core (which runs the chain), the platform layer (which sizes both matrices'
// coefficient stores) and the TBs can't disagree. The per-matrix formulas stay
// in pcm_matrix_pkg; this adds the gain stage and the chain:
//
//   pack2stream -> gain -> matrix 1 -> gain -> matrix 2 -> gain -> stream2pack
//                  (in)   N_IN->N_BUS  (bus)  N_BUS->N_OUT (out)
//
// Every block starts on order, not on its producer's timing, so the latencies
// add. Last beat of each stream, cycles after the strobe:
//   inputs (pack2stream)  N_IN
//   input levels          + GAIN_LAT
//   input matrix (buses)  + matrix_lat_last(N_IN, N_BUS, L1)
//   bus levels            + GAIN_LAT
//   bus matrix (outputs)  + matrix_lat_last(N_BUS, N_OUT, L2)
//   output levels         + GAIN_LAT
//   core D                + 1 (stream2pack)
// D <= pcm_matrix_pkg::D_MAX (250): the whole chain stays inside the frame,
// with the same latency to the links as the single matrix had.
//
// chain_l1() / chain_l2() pick the lane counts (= DSP48E2s per matrix): the
// fewest lanes in total with D <= D_MAX, ties to the smaller D, then to the
// smaller L1. 0 when nothing fits (the core then refuses to elaborate).
// 20 / 20 / 20: L1 = 4, L2 = 4, D = 249 (one lane more, 4 + 5, would give
// 230; the rule spends DSPs only when the frame needs them, as matrix_lanes
// does). 12 / 12 / 12: 2 + 2, D = 181. 28 / 28 / 28: 10 + 10, D = 233.
// -----------------------------------------------------------------------------
package mixer_core_pkg;

    import pcm_matrix_pkg::*;

    localparam int GAIN_LAT = 4;    // pcm_gain: output beat, cycles after its input beat

    // Last beat of the input matrix's output (the buses), cycles after the strobe.
    function automatic int chain_bus_last(input int n_in, input int n_bus, input int l1);
        return n_in + GAIN_LAT + matrix_lat_last(n_in, n_bus, l1);
    endfunction

    // Last beat of the bus matrix's output, cycles after the strobe.
    function automatic int chain_out_last(input int n_in, input int n_bus, input int n_out,
                                          input int l1, input int l2);
        return chain_bus_last(n_in, n_bus, l1) + GAIN_LAT + matrix_lat_last(n_bus, n_out, l2);
    endfunction

    // The core's D: its packed output updates this many cycles after the strobe.
    function automatic int chain_latency(input int n_in, input int n_bus, input int n_out,
                                         input int l1, input int l2);
        return chain_out_last(n_in, n_bus, n_out, l1, l2) + GAIN_LAT + 1;
    endfunction

    // The search behind chain_l1/chain_l2; which = 1 or 2.
    function automatic int chain_pick(input int n_in, input int n_bus, input int n_out,
                                      input int which);
        int max1, max2, d, best_d, best1, best2, l2;
        max1 = (n_in  < n_bus) ? n_in  : n_bus;     // pcm_matrix: LANES <= N_IN, N_OUT
        max2 = (n_bus < n_out) ? n_bus : n_out;
        for (int s = 2; s <= max1 + max2; s++) begin
            best_d = D_MAX + 1; best1 = 0; best2 = 0;
            for (int l1 = 1; l1 <= max1; l1++) begin
                l2 = s - l1;
                if (l2 >= 1 && l2 <= max2) begin
                    d = chain_latency(n_in, n_bus, n_out, l1, l2);
                    if (d < best_d) begin
                        best_d = d; best1 = l1; best2 = l2;
                    end
                end
            end
            if (best_d <= D_MAX)
                return (which == 1) ? best1 : best2;
        end
        return 0;
    endfunction

    function automatic int chain_l1(input int n_in, input int n_bus, input int n_out);
        return chain_pick(n_in, n_bus, n_out, 1);
    endfunction

    function automatic int chain_l2(input int n_in, input int n_bus, input int n_out);
        return chain_pick(n_in, n_bus, n_out, 2);
    endfunction

endpackage
