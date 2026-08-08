// -----------------------------------------------------------------------------
// pcm_matrix.sv
//
// Static N-in / N-out PCM crosspoint matrix mixer.
//
//   out[o] = saturate( sum over i of ( in[i] * GAIN[o][i] ) )
//
// Every crosspoint gain is a compile-time constant (Phase 3 has no runtime
// control yet). Samples are signed two's-complement PCM. Gains are signed
// fixed-point in Q(GAIN_WIDTH-GAIN_FRAC . GAIN_FRAC) format, so with the
// defaults (GAIN_WIDTH=18, GAIN_FRAC=16) a gain of 1.0 is 18'sh10000, 0.5 is
// 18'sh08000, -1.0 (phase invert) is 18'sh30000, and 0.0 mutes the crosspoint.
//
// Arithmetic, per output, sized to never overflow before the final saturate:
//   product   = sample (SAMPLE_WIDTH, signed) * gain (GAIN_WIDTH, signed)
//             -> PROD_WIDTH = SAMPLE_WIDTH + GAIN_WIDTH bits
//   accumulate N products
//             -> ACC_WIDTH  = PROD_WIDTH + clog2(N) bits (headroom for the sum)
//   descale   = acc >>> GAIN_FRAC          (arithmetic shift; truncates toward -inf)
//   saturate  = clamp to signed SAMPLE_WIDTH range
//
// Truncation (not rounding) is used for the descale so the result is trivially
// hand-checkable. Rounding is a one-line half-LSB add before the shift and can
// be added later without changing the interface.
//
// The SAMPLE_WIDTH operand + 18-bit gain maps to one DSP48E1 per crosspoint on
// the Zynq-7 (25x18 signed multiplier), so an N=4 matrix infers 16 DSP48s.
//
// PORT FORMAT: samples are carried as flat PACKED vectors (channel c occupies
// bits [c*SAMPLE_WIDTH +: SAMPLE_WIDTH], interpreted signed), not unpacked
// arrays. Packed vectors propagate identically across every simulator and
// synthesizer; unpacked-array *output* ports do not (Icarus, in particular,
// drops them). GAINS are likewise passed flattened, indexed
//   GAIN[o][i] = GAINS_FLAT[(o*N + i)*GAIN_WIDTH +: GAIN_WIDTH].
//
// Timing: out is a function of in only. Outputs register on sample_valid_i
// (one pulse per audio frame); sample_valid_o is sample_valid_i delayed one
// mclk, marking when out_flat is fresh.
// -----------------------------------------------------------------------------
module pcm_matrix #(
    parameter int N            = 4,
    parameter int SAMPLE_WIDTH = 24,
    parameter int GAIN_WIDTH   = 18,
    parameter int GAIN_FRAC    = 16,
    // Default: N x N identity (out[k] = in[k] at unity). Override per design.
    parameter logic [N*N*GAIN_WIDTH-1:0] GAINS_FLAT = build_identity()
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic sample_valid_i,

    input  logic [N*SAMPLE_WIDTH-1:0] in_flat,   // packed: ch c = [c*SW +: SW], signed
    output logic [N*SAMPLE_WIDTH-1:0] out_flat,  // packed, same layout
    output logic                      sample_valid_o
);

    // ----- Derived widths -----
    localparam int PROD_WIDTH = SAMPLE_WIDTH + GAIN_WIDTH;
    localparam int ACC_WIDTH  = PROD_WIDTH + $clog2(N);

    // ----- Saturation limits (signed) -----
    localparam signed [SAMPLE_WIDTH-1:0] SAMP_MAX =  (1 <<< (SAMPLE_WIDTH-1)) - 1;
    localparam signed [SAMPLE_WIDTH-1:0] SAMP_MIN = -(1 <<< (SAMPLE_WIDTH-1));

    // Default-gain helper: unity on the diagonal, zero elsewhere.
    function automatic logic [N*N*GAIN_WIDTH-1:0] build_identity();
        logic [N*N*GAIN_WIDTH-1:0] g;
        g = '0;
        for (int o = 0; o < N; o++)
            g[(o*N + o)*GAIN_WIDTH +: GAIN_WIDTH] = (1 <<< GAIN_FRAC);
        return g;
    endfunction

    // ----- Unpack flat ports/params into arrays at elaboration -----
    // All part-selects here use genvar-constant bases, which every tool
    // supports; the always block below then does plain array reads.
    logic signed [GAIN_WIDTH-1:0]   gain_arr [N][N];
    logic signed [SAMPLE_WIDTH-1:0] in_arr   [N];

    genvar go, gi, gk;
    generate
        for (go = 0; go < N; go++)
            for (gi = 0; gi < N; gi++)
                assign gain_arr[go][gi] =
                    $signed(GAINS_FLAT[(go*N + gi)*GAIN_WIDTH +: GAIN_WIDTH]);

        for (gk = 0; gk < N; gk++)
            assign in_arr[gk] = $signed(in_flat[gk*SAMPLE_WIDTH +: SAMPLE_WIDTH]);
    endgenerate

    // ----- Crosspoint math, registered on each new sample frame -----
    // Done in the clocked block so the array reads are sampled on the edge
    // (avoids simulators that don't track always_comb sensitivity to unpacked
    // arrays) while still inferring DSP48s for the multiply/accumulate.
    logic signed [SAMPLE_WIDTH-1:0] out_reg [N];

    always_ff @(posedge mclk or negedge rst_n) begin
        logic signed [ACC_WIDTH-1:0]  acc;
        logic signed [ACC_WIDTH-1:0]  scaled;
        logic signed [PROD_WIDTH-1:0] prod;

        if (!rst_n) begin
            for (int o = 0; o < N; o++) out_reg[o] <= '0;
            sample_valid_o <= 1'b0;
        end else begin
            sample_valid_o <= sample_valid_i;
            if (sample_valid_i) begin
                for (int o = 0; o < N; o++) begin
                    acc = '0;
                    for (int i = 0; i < N; i++) begin
                        prod = in_arr[i] * gain_arr[o][i];  // signed * signed
                        acc  = acc + prod;                  // prod sign-extends
                    end

                    scaled = acc >>> GAIN_FRAC;             // descale, arithmetic

                    if (scaled > SAMP_MAX)
                        out_reg[o] <= SAMP_MAX;
                    else if (scaled < SAMP_MIN)
                        out_reg[o] <= SAMP_MIN;
                    else
                        out_reg[o] <= scaled;               // truncates to SAMPLE_WIDTH
                end
            end
        end
    end

    // ----- Pack the registered outputs back into the flat output port -----
    genvar gp;
    generate
        for (gp = 0; gp < N; gp++)
            assign out_flat[gp*SAMPLE_WIDTH +: SAMPLE_WIDTH] = out_reg[gp];
    endgenerate

endmodule
