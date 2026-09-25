// -----------------------------------------------------------------------------
// pcm_matrix.sv
//
// N_IN-in / N_OUT-out PCM crosspoint matrix mixer (a PCM core block).
//
//   out[o] = saturate( sum over i of ( in[i] * GAIN[o][i] ) )
//
// Crosspoint gains arrive on the gains_flat port (Phase 5: from the PS via
// matrix_regs_axil; Phase 3 tied it to a constant). gains_flat must be in the
// mclk domain and only change between frames -- it is sampled on the same edge
// as sample_valid_i, so a whole-bank update lands atomically on one frame.
// Samples are signed two's-complement PCM. Gains are signed
// fixed-point in Q(GAIN_WIDTH-GAIN_FRAC . GAIN_FRAC) format, so with the
// defaults (GAIN_WIDTH=18, GAIN_FRAC=16) a gain of 1.0 is 18'sh10000, 0.5 is
// 18'sh08000, -1.0 (phase invert) is 18'sh30000, and 0.0 mutes the crosspoint.
//
// Arithmetic, per output, sized to never overflow before the final saturate:
//   product   = sample (SAMPLE_WIDTH, signed) * gain (GAIN_WIDTH, signed)
//             -> PROD_WIDTH = SAMPLE_WIDTH + GAIN_WIDTH bits
//   accumulate N_IN products
//             -> ACC_WIDTH  = PROD_WIDTH + clog2(N_IN) bits (headroom for the sum)
//   descale   = acc >>> GAIN_FRAC          (arithmetic shift; truncates toward -inf)
//   saturate  = clamp to signed SAMPLE_WIDTH range
//
// Truncation (not rounding) is used for the descale so the result is trivially
// hand-checkable. Rounding is a one-line half-LSB add before the shift and can
// be added later without changing the interface.
//
// The SAMPLE_WIDTH operand + 18-bit gain maps to one DSP48E2 per crosspoint
// (27x18 signed multiplier), so a 4x4 matrix infers 16 DSPs. With constant
// gains (Phase 3) synthesis folded most of them away; runtime gains keep them.
//
// PORT FORMAT: samples are carried as flat PACKED vectors (channel c occupies
// bits [c*SAMPLE_WIDTH +: SAMPLE_WIDTH], interpreted signed), not unpacked
// arrays. Packed vectors propagate identically across every simulator and
// synthesizer; unpacked-array *output* ports do not (Icarus, in particular,
// drops them). Gains are likewise passed flattened, indexed
//   GAIN[o][i] = gains_flat[(o*N_IN + i)*GAIN_WIDTH +: GAIN_WIDTH].
// N_IN and N_OUT are independent, so the same block serves an input -> bus
// stage and a bus -> output stage of different widths
// (docs/architecture_modules.md).
//
// Timing: out is a function of in only. Outputs register on sample_valid_i
// (one pulse per audio frame); sample_valid_o is sample_valid_i delayed one
// mclk, marking when out_flat is fresh.
// -----------------------------------------------------------------------------
module pcm_matrix #(
    parameter int N_IN         = 4,
    parameter int N_OUT        = 4,
    parameter int SAMPLE_WIDTH = 24,
    parameter int GAIN_WIDTH   = 18,
    parameter int GAIN_FRAC    = 16
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic sample_valid_i,

    input  logic [N_OUT*N_IN*GAIN_WIDTH-1:0] gains_flat, // packed, see header; signed Q

    input  logic [N_IN*SAMPLE_WIDTH-1:0]  in_flat,   // packed: ch c = [c*SW +: SW], signed
    output logic [N_OUT*SAMPLE_WIDTH-1:0] out_flat,  // packed, same layout
    output logic                          sample_valid_o
);

    // ----- Derived widths -----
    localparam int PROD_WIDTH = SAMPLE_WIDTH + GAIN_WIDTH;
    localparam int ACC_WIDTH  = PROD_WIDTH + $clog2(N_IN);

    // ----- Saturation limits (signed) -----
    localparam signed [SAMPLE_WIDTH-1:0] SAMP_MAX =  (1 <<< (SAMPLE_WIDTH-1)) - 1;
    localparam signed [SAMPLE_WIDTH-1:0] SAMP_MIN = -(1 <<< (SAMPLE_WIDTH-1));

    // ----- Unpack flat ports/params into arrays at elaboration -----
    // All part-selects here use genvar-constant bases, which every tool
    // supports; the always block below then does plain array reads.
    logic signed [GAIN_WIDTH-1:0]   gain_arr [N_OUT][N_IN];
    logic signed [SAMPLE_WIDTH-1:0] in_arr   [N_IN];

    genvar go, gi, gk;
    generate
        for (go = 0; go < N_OUT; go++)
            for (gi = 0; gi < N_IN; gi++)
                assign gain_arr[go][gi] =
                    $signed(gains_flat[(go*N_IN + gi)*GAIN_WIDTH +: GAIN_WIDTH]);

        for (gk = 0; gk < N_IN; gk++)
            assign in_arr[gk] = $signed(in_flat[gk*SAMPLE_WIDTH +: SAMPLE_WIDTH]);
    endgenerate

    // ----- Crosspoint math, registered on each new sample frame -----
    // Done in the clocked block so the array reads are sampled on the edge
    // (avoids simulators that don't track always_comb sensitivity to unpacked
    // arrays) while still inferring DSP48s for the multiply/accumulate.
    logic signed [SAMPLE_WIDTH-1:0] out_reg [N_OUT];

    always_ff @(posedge mclk or negedge rst_n) begin
        logic signed [ACC_WIDTH-1:0]  acc;
        logic signed [ACC_WIDTH-1:0]  scaled;
        logic signed [PROD_WIDTH-1:0] prod;

        if (!rst_n) begin
            for (int o = 0; o < N_OUT; o++) out_reg[o] <= '0;
            sample_valid_o <= 1'b0;
        end else begin
            sample_valid_o <= sample_valid_i;
            if (sample_valid_i) begin
                for (int o = 0; o < N_OUT; o++) begin
                    acc = '0;
                    for (int i = 0; i < N_IN; i++) begin
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
        for (gp = 0; gp < N_OUT; gp++)
            assign out_flat[gp*SAMPLE_WIDTH +: SAMPLE_WIDTH] = out_reg[gp];
    endgenerate

endmodule
