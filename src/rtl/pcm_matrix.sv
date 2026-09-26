// -----------------------------------------------------------------------------
// pcm_matrix.sv
//
// N_IN-in / N_OUT-out PCM crosspoint matrix mixer (a PCM core block),
// TIME-SHARED since Phase 9 (P9.A4): LANES multipliers (DSP48E2s) do all
// N_IN x N_OUT multiply-accumulates of a frame one after another, instead of
// one multiplier per crosspoint.
//
//   out[o] = saturate( sum over i of ( in[i] * GAIN[o][i] ) )
//
// Arithmetic (unchanged from the parallel matrix, bit-exact against the same
// reference model): signed SAMPLE_WIDTH samples, signed Q2.16 gains
// (GAIN_WIDTH=18, GAIN_FRAC=16: 0x10000 = 1.0, 0x30000 = -1.0, 0 = mute).
// The exact sum is kept in a 48-bit accumulator (|product| <= 2^40, so up to
// 127 inputs can't overflow it), then >>> GAIN_FRAC (arithmetic, truncating
// toward -inf) and saturated once to SAMPLE_WIDTH.
//
// ----- Ports: the PCM stream contract (docs/architecture_modules.md 2.1) -----
// Input stream: channels 0..N_IN-1, ascending, once per frame. The beat for
// N_IN-1 starts the frame's computation, so the matrix doesn't depend on its
// producer's exact timing, only on order. Output stream: channels
// 0..N_OUT-1, ascending, one beat per cycle except for gaps where a lane is
// idle in the last pass.
//
// Coefficients arrive through a READ PORT (coef_addr -> coef_data one cycle
// later), served by coef_bank_ram or coef_flat_reader with ROW_LEN = N_IN,
// N_ROWS = N_OUT, the same LANES: word t holds, for lane l, the gain of
// output o = (t / N_IN)*LANES + l and input i = t % N_IN. The matrix reads
// words 0 .. passes*N_IN-1 in order, all inside one frame, so each frame
// uses one coefficient bank (the bank swaps only at a frame strobe).
//
// ----- The schedule (phase9_status_2026-09-26.md 5.1) -----
// Lane l computes outputs l, l+LANES, l+2*LANES, ... (one per pass). For each
// output it sweeps inputs 0..N_IN-1, one multiply-accumulate per cycle; the
// accumulator restarts on input 0. All lanes sweep the same input, lane l
// one cycle behind lane l-1, so ONE sample read per cycle serves every lane:
// the sample is handed down the lanes register to register (the DSP48E2
// A-cascade, ACOUT -> ACIN). Each lane's gain is delayed to match. Because
// of the stagger, lane l finishes output o one cycle after lane l-1 finishes
// o-1, and the results leave as an ascending stream, provided LANES <= N_IN.
//
// Per lane:  s (sample)  ->  A   \
//            g (gain)    ->  B   -> M = A*B -> P = (first ? 0 : P) + M
// which Vivado maps onto one DSP48E2 (AREG/BREG, MREG, PREG, the accumulate
// with a dynamic OPMODE). Data registers have no reset, so they pack into the
// DSP; the control flags reset.
//
// ----- Timing (cycles after the last input beat, LAST_IN) -----
//   first output beat : LAT_FIRST = N_IN + 5
//   last output beat  : LAT_LAST  = passes*N_IN + 5 + (lane of output N_OUT-1)
// (pcm_matrix_pkg; the TBs check both to the cycle). With pcm_pack2stream in
// front the core's packed output updates at D = N_IN + LAT_LAST + 1; 12 x 12
// on 1 lane: D = 162.
//
// LANES must be one of the values that keep a frame inside the budget;
// pcm_matrix_pkg::matrix_lanes(N_IN, N_OUT) gives the smallest.
// -----------------------------------------------------------------------------
module pcm_matrix
    import pcm_matrix_pkg::*;
#(
    parameter int N_IN         = 4,
    parameter int N_OUT        = 4,
    parameter int SAMPLE_WIDTH = 24,
    parameter int GAIN_WIDTH   = 18,
    parameter int GAIN_FRAC    = 16,
    parameter int LANES        = matrix_lanes(N_IN, N_OUT),
    localparam int CWI    = (N_IN  > 1) ? $clog2(N_IN)  : 1,
    localparam int CWO    = (N_OUT > 1) ? $clog2(N_OUT) : 1,
    localparam int PASSES = matrix_passes(N_OUT, LANES),
    localparam int DEPTH  = PASSES * N_IN,
    localparam int AW     = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                      mclk,
    input  logic                      rst_n,

    // ----- input stream -----
    input  logic                      in_valid,
    input  logic [CWI-1:0]            in_ch,
    input  logic [SAMPLE_WIDTH-1:0]   in_data,

    // ----- coefficient read port -----
    output logic [AW-1:0]             coef_addr,
    input  logic [LANES*GAIN_WIDTH-1:0] coef_data,

    // ----- output stream -----
    output logic                      out_valid,
    output logic [CWO-1:0]            out_ch,
    output logic [SAMPLE_WIDTH-1:0]   out_data
);

    localparam int SW = SAMPLE_WIDTH;
    localparam int GW = GAIN_WIDTH;
    localparam int PW = 48;                  // DSP48E2 P width
    localparam int JW = (PASSES > 1) ? $clog2(PASSES) : 1;

    localparam int LAT_FIRST = matrix_lat_first(N_IN);
    localparam int LAT_LAST  = matrix_lat_last(N_IN, N_OUT, LANES);

    generate
        if (LANES < 1)
            $error("pcm_matrix: %0d x %0d does not fit the frame budget", N_IN, N_OUT);
        if (LANES > N_IN || LANES > N_OUT)
            $error("pcm_matrix: LANES = %0d must be <= N_IN (%0d) and <= N_OUT (%0d)",
                   LANES, N_IN, N_OUT);
        if (N_IN > MAX_N_IN)
            $error("pcm_matrix: N_IN = %0d > %0d overflows the 48-bit accumulator",
                   N_IN, MAX_N_IN);
        if (SW + GW > 45 || SW > 27 || GW > 18)
            $error("pcm_matrix: %0d x %0d bits is not one DSP48E2 multiply", SW, GW);
    endgenerate

    localparam logic signed [PW-1:0] SAMP_MAX =  (PW'(1) <<< (SW-1)) - 1;
    localparam logic signed [PW-1:0] SAMP_MIN = -(PW'(1) <<< (SW-1));

    // =========================================================================
    // Sample buffer: written by the input stream, read by the schedule
    // =========================================================================
    logic [SW-1:0] samp [N_IN];

    always_ff @(posedge mclk) begin
        if (in_valid && int'(in_ch) < N_IN)
            samp[in_ch] <= in_data;
    end

    // The last input's beat starts the schedule on the same edge that stores
    // it: step 0 (next cycle) reads input 0, and input N_IN-1 isn't read
    // before step N_IN-1.
    wire start = in_valid && (in_ch == CWI'(N_IN - 1));

    // =========================================================================
    // Sequencer: step t = 0 .. DEPTH-1, input i = t % N_IN, pass j = t / N_IN
    // =========================================================================
    logic           run;
    logic [AW-1:0]  t;
    logic [CWI-1:0] i;
    logic [JW-1:0]  j;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            run <= 1'b0; t <= '0; i <= '0; j <= '0;
        end else if (start) begin
            run <= 1'b1; t <= '0; i <= '0; j <= '0;   // a new frame restarts
        end else if (run) begin
            if (t == AW'(DEPTH - 1)) run <= 1'b0;
            t <= t + 1'b1;
            if (i == CWI'(N_IN - 1)) begin
                i <= '0;
                j <= j + 1'b1;
            end else begin
                i <= i + 1'b1;
            end
        end
    end

    assign coef_addr = t;

    // Stage 1: the sample read and the coefficient read (coef_data arrives
    // on this same edge), plus the step's control.
    typedef struct packed {
        logic          v;       // a real step
        logic          first;   // input 0: restart the accumulator
        logic          last;    // input N_IN-1: the sum is complete
        logic [JW-1:0] j;       // pass
    } ctl_t;

    logic [SW-1:0] s_q;
    ctl_t          c_q;

    always_ff @(posedge mclk) s_q <= samp[i];

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) c_q <= '0;
        else begin
            c_q.v     <= run;
            c_q.first <= (i == '0);
            c_q.last  <= (i == CWI'(N_IN - 1));
            c_q.j     <= j;
        end
    end

    // =========================================================================
    // Lanes
    // =========================================================================
    logic [SW-1:0] a_r   [LANES];          // A register (cascade to the next lane)
    ctl_t          ca_r  [LANES];          // control, aligned with A/B
    logic          done  [LANES];          // P holds a finished sum this cycle
    logic [JW-1:0] done_j[LANES];
    logic signed [PW-1:0] p_r [LANES];

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl++) begin : g_lane
            // this lane's gain, delayed gl cycles to meet its sample
            logic [GW-1:0] g_lane;
            if (gl == 0) begin : g_nodly
                assign g_lane = coef_data[0 +: GW];
            end else begin : g_dly
                logic [GW-1:0] sr [gl];
                always_ff @(posedge mclk) begin
                    sr[0] <= coef_data[gl*GW +: GW];
                    for (int d = 1; d < gl; d++) sr[d] <= sr[d-1];
                end
                assign g_lane = sr[gl-1];
            end

            logic [SW-1:0] a_in;
            ctl_t          c_in;
            if (gl == 0) begin : g_head
                assign a_in = s_q;
                assign c_in = c_q;
            end else begin : g_casc
                assign a_in = a_r[gl-1];
                assign c_in = ca_r[gl-1];
            end

            logic signed [GW-1:0]    b_r;
            logic signed [SW+GW-1:0] m_r;
            ctl_t                    cm_r;

            // A/B registers (data: no reset, so they pack into the DSP)
            always_ff @(posedge mclk) begin
                a_r[gl] <= a_in;
                b_r     <= g_lane;
            end
            // M register
            always_ff @(posedge mclk)
                m_r <= $signed(a_r[gl]) * b_r;
            // P register: accumulate, restart on input 0
            always_ff @(posedge mclk)
                p_r[gl] <= (cm_r.first ? PW'(0) : p_r[gl]) + PW'(m_r);

            always_ff @(posedge mclk or negedge rst_n) begin
                if (!rst_n) begin
                    ca_r[gl]   <= '0;
                    cm_r       <= '0;
                    done[gl]   <= 1'b0;
                    done_j[gl] <= '0;
                end else begin
                    ca_r[gl]   <= c_in;
                    cm_r       <= ca_r[gl];
                    done[gl]   <= cm_r.v && cm_r.last;
                    done_j[gl] <= cm_r.j;
                end
            end
        end
    endgenerate

    // =========================================================================
    // Output: at most one lane finishes per cycle (the stagger); descale,
    // saturate, and emit the beat for output o = j*LANES + l.
    // =========================================================================
    always_ff @(posedge mclk or negedge rst_n) begin
        logic signed [PW-1:0] p, scaled;
        int o;
        logic hit;

        if (!rst_n) begin
            out_valid <= 1'b0;
            out_ch    <= '0;
            out_data  <= '0;
        end else begin
            hit = 1'b0; p = '0; o = 0;
            for (int l = 0; l < LANES; l++)
                if (done[l]) begin
                    hit = 1'b1;
                    p   = p_r[l];
                    o   = int'(done_j[l]) * LANES + l;
                end

            out_valid <= hit && (o < N_OUT);     // idle lanes of the last pass
            out_ch    <= CWO'(o);
            scaled = p >>> GAIN_FRAC;
            if (scaled > SAMP_MAX)      out_data <= SAMP_MAX[SW-1:0];
            else if (scaled < SAMP_MIN) out_data <= SAMP_MIN[SW-1:0];
            else                        out_data <= scaled[SW-1:0];
        end
    end

endmodule
