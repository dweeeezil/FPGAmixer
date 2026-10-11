// -----------------------------------------------------------------------------
// pcm_matrix_pkg.sv
//
// The time-shared pcm_matrix's schedule arithmetic, in one place, so the
// platform layer (which sizes the coefficient store) and the matrix (which
// runs the schedule) can't disagree. See pcm_matrix.sv for the schedule and
// phase9_status_2026-09-26.md 5.1 for the derivation.
//
//   passes(L)  = ceil(N_OUT / L)          each lane computes one output per pass
//   lat_first  = N_IN + 5                 first output beat, cycles after the
//                                         last INPUT beat
//   lat_last   = passes*N_IN + 5 + l_last last output beat, same reference;
//                                         l_last = lane of output N_OUT-1
//   core D     = LAST_IN + lat_last + 1   packed output update, with
//                                         pcm_pack2stream (LAST_IN = N_IN) in
//                                         front and pcm_stream2pack (+1) behind
//
// matrix_lanes() picks the smallest lane count (= DSP48E2s) with D <= D_MAX.
// D_MAX = 255 since Phase 15 (decision CS11): the only consumers of the
// core's output are the pcm_links, which capture tx_flat on the next strobe
// edge (edge 256 of the frame), so an output that updates on edge 255 or
// earlier is taken with its own frame. (It was 250 while i2s_port, the Pmods'
// front door, sampled its pair on edge 254; they went in Phase 11 H.3.)
// docs/architecture_modules.md 2.1.
// -----------------------------------------------------------------------------
package pcm_matrix_pkg;

    localparam int D_MAX    = 255;
    localparam int PIPE     = 5;     // sample/coef read, A/B, M, P, saturate
    localparam int MAX_N_IN = 127;   // the exact sum fits the DSP's 48-bit P

    function automatic int matrix_passes(input int n_out, input int lanes);
        return (n_out + lanes - 1) / lanes;
    endfunction

    // Last output beat, cycles after the last input beat.
    function automatic int matrix_lat_last(input int n_in, input int n_out, input int lanes);
        int p;
        p = matrix_passes(n_out, lanes);
        return p*n_in + PIPE + ((n_out - 1) - (p - 1)*lanes);
    endfunction

    // First output beat, cycles after the last input beat.
    function automatic int matrix_lat_first(input int n_in);
        return n_in + PIPE;
    endfunction

    // The core's latency D (cycles after the strobe) with the boundary
    // converters around the matrix.
    function automatic int core_latency(input int n_in, input int n_out, input int lanes);
        return n_in + matrix_lat_last(n_in, n_out, lanes) + 1;
    endfunction

    // Smallest lane count meeting D_MAX; 0 if none does (the matrix then
    // refuses to elaborate). Lanes can't exceed N_IN (output beats would
    // collide) or N_OUT.
    function automatic int matrix_lanes(input int n_in, input int n_out);
        for (int l = 1; l <= n_out && l <= n_in; l++)
            if (core_latency(n_in, n_out, l) <= D_MAX)
                return l;
        return 0;
    endfunction

endpackage
