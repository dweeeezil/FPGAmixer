// -----------------------------------------------------------------------------
// mixer_core_pkg.sv
//
// The PCM core's chain arithmetic, in one place (Phase 12, decision L4), so the
// core (which runs the chain), the platform layer (which sizes both matrices'
// coefficient stores) and the TBs can't disagree. The per-matrix formulas stay
// in pcm_matrix_pkg; this adds the gain stage and the chain:
//
//   patch2stream -> gain -> matrix 1 -> gain -> matrix 2 -> gain -> stream2patch
//   (input patch)   (in)   N_IN->N_BUS  (bus)  N_BUS->N_OUT (out)  (output patch)
//
// Every block starts on order, not on its producer's timing, so the latencies
// add. Last beat of each stream, cycles after the strobe:
//   inputs (patch2stream) N_IN + IN_PATCH_LAT     (Phase 15: was N_IN, pack2stream)
//   input levels          + GAIN_LAT
//   input matrix (buses)  + matrix_lat_last(N_IN, N_BUS, L1)
//   bus levels            + GAIN_LAT
//   bus matrix (outputs)  + matrix_lat_last(N_BUS, N_OUT, L2)
//   output levels         + GAIN_LAT
//   core D                + OUT_PATCH_LAT (stream2patch; was 1, stream2pack)
// The links take the output on the first strobe after it updates: with
// D <= pcm_matrix_pkg::D_MAX (255) the next one, as before.
//
// ----- The chain may span frames (library foundation, decision LF1) -----
// docs/library_foundation_proposal_2026-10-10.md sec. 2, 10. D is no longer
// bounded by one frame: frames follow each other FRAME cycles apart through
// the whole chain, and each block must be done with frame k before frame k + 1
// needs what frame k still uses (chain_fits):
//   - a matrix's coefficient reads (DEPTH = passes * N_IN cycles from its
//     input's last beat) end before its bank swaps for the next frame, at the
//     next frame's last input beat: DEPTH <= FRAME;
//   - its sample buffer: the next frame's beat for input i overwrites
//     samp[i], so its last read of it, (passes - 1)*N_IN + i + 1 cycles after
//     the last beat, comes no later than that write. The worst case is the
//     next frame's beats packed at one per cycle, so with SPAN_IN = the input
//     stream's last minus first beat: SPAN_IN + (passes - 1)*N_IN + 1 <= FRAME;
//   - D <= D_CAP (8 frames): a sanity bound on a fixed latency.
// The gain stages and converters handle one beat at a time (nothing to
// check). A frame's span stays the producer's: N_IN - 1 from the input
// patch, matrix_lat_last - matrix_lat_first out of a matrix.
//
// chain_l1() / chain_l2() pick the lane counts (= DSP48E2s per matrix),
// LATENCY FIRST (the user, 2026-10-26, Q1): the fewest lanes in total with
// D <= D_MAX (the whole chain inside one frame, as before), ties to the
// smaller D, then to the smaller L1; only when nothing fits a frame, the
// fewest lanes for which chain_fits holds, same ties. 0 when nothing fits at
// all (the core then refuses to elaborate).
// 20 / 20 / 20: L1 = 4, L2 = 4, D = 251 (one lane more, 4 + 5, would give
// 232; the rule spends DSPs only when the frame needs them, as matrix_lanes
// does). 12 / 12 / 12: 1 + 2, D = 254. 28 / 28 / 28: 10 + 10, D = 235.
// (Before Phase 15, with D_MAX 250 and the plain converters: 249, 2 + 2 at
// 181, 233.) Sizes past one frame, e.g. 48 / 48 / 48, now get a multi-frame
// chain instead of none.
// -----------------------------------------------------------------------------
package mixer_core_pkg;

    import pcm_matrix_pkg::*;

    localparam int GAIN_LAT      = 4;  // pcm_gain: output beat, cycles after its input beat
    localparam int IN_PATCH_LAT  = 1;  // pcm_patch2stream: beats in cycles 1+1 .. N+1
    localparam int OUT_PATCH_LAT = 2;  // pcm_stream2patch: output, cycles after the last beat
    localparam int FRAME         = 256;        // cycles per frame (mclk / fs)
    localparam int D_CAP         = 8 * FRAME;  // LF1: the longest chain allowed

    // LF1: whether a matrix keeps up with the frame rate when its input
    // stream's beats span span_in cycles (last minus first). See the header.
    function automatic bit matrix_fits(input int n_in, input int n_out, input int lanes,
                                       input int span_in);
        int p;
        p = matrix_passes(n_out, lanes);
        return (p * n_in <= FRAME) && (span_in + (p - 1) * n_in + 1 <= FRAME);
    endfunction

    // The span (last minus first beat) of a matrix's output stream.
    function automatic int matrix_span_out(input int n_in, input int n_out, input int lanes);
        return matrix_lat_last(n_in, n_out, lanes) - matrix_lat_first(n_in);
    endfunction

    // Last beat of the input channels' stream (the input patch), cycles after the strobe.
    function automatic int chain_in_last(input int n_in);
        return n_in + IN_PATCH_LAT;
    endfunction
    // Last beat of the input matrix's output (the buses), cycles after the strobe.
    function automatic int chain_bus_last(input int n_in, input int n_bus, input int l1);
        return chain_in_last(n_in) + GAIN_LAT + matrix_lat_last(n_in, n_bus, l1);
    endfunction

    // Last beat of the bus matrix's output, cycles after the strobe.
    function automatic int chain_out_last(input int n_in, input int n_bus, input int n_out,
                                          input int l1, input int l2);
        return chain_bus_last(n_in, n_bus, l1) + GAIN_LAT + matrix_lat_last(n_bus, n_out, l2);
    endfunction

    // The core's D: its packed output updates this many cycles after the
    // strobe that captured the frame (may exceed FRAME: LF1).
    function automatic int chain_latency(input int n_in, input int n_bus, input int n_out,
                                         input int l1, input int l2);
        return chain_out_last(n_in, n_bus, n_out, l1, l2) + GAIN_LAT + OUT_PATCH_LAT;
    endfunction

    // LF1: whether the chain keeps up with the frame rate on l1 + l2 lanes.
    function automatic bit chain_fits(input int n_in, input int n_bus, input int n_out,
                                      input int l1, input int l2);
        if (l1 < 1 || l1 > n_in  || l1 > n_bus) return 0;   // pcm_matrix: LANES <= N_IN, N_OUT
        if (l2 < 1 || l2 > n_bus || l2 > n_out) return 0;
        return matrix_fits(n_in, n_bus, l1, n_in - 1)
            && matrix_fits(n_bus, n_out, l2, matrix_span_out(n_in, n_bus, l1))
            && chain_latency(n_in, n_bus, n_out, l1, l2) <= D_CAP;
    endfunction

    // The search behind chain_l1/chain_l2; which = 1 or 2. Pass 0 keeps the
    // chain inside one frame (D <= D_MAX); pass 1, only if pass 0 found
    // nothing, lets it span frames (latency first, the user's Q1).
    function automatic int chain_pick(input int n_in, input int n_bus, input int n_out,
                                      input int which);
        int max1, max2, d, best_d, best1, best2, l2;
        max1 = (n_in  < n_bus) ? n_in  : n_bus;     // pcm_matrix: LANES <= N_IN, N_OUT
        max2 = (n_bus < n_out) ? n_bus : n_out;
        for (int pass = 0; pass < 2; pass++)
            for (int s = 2; s <= max1 + max2; s++) begin
                best_d = D_CAP + 1; best1 = 0; best2 = 0;
                for (int l1 = 1; l1 <= max1; l1++) begin
                    l2 = s - l1;
                    if (l2 >= 1 && l2 <= max2 && chain_fits(n_in, n_bus, n_out, l1, l2)) begin
                        d = chain_latency(n_in, n_bus, n_out, l1, l2);
                        if ((pass == 1 || d <= D_MAX) && d < best_d) begin
                            best_d = d; best1 = l1; best2 = l2;
                        end
                    end
                end
                if (best1 > 0)
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
