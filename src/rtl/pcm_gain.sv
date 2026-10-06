// -----------------------------------------------------------------------------
// pcm_gain.sv
//
// A per-channel gain stage (a PCM core block, Phase 12): one multiplier
// (DSP48E2) time-shared over N channels of a PCM stream.
//
//   y[c] = saturate( x[c] * GAIN[c] )
//
// Arithmetic: the same as one pcm_matrix crosspoint, so the two agree bit for
// bit on a single term: signed SAMPLE_WIDTH samples, signed Q2.16 gains
// (GAIN_WIDTH=18, GAIN_FRAC=16: 0x10000 = 1.0, 0 = mute), the exact product
// >>> GAIN_FRAC (arithmetic, truncating toward -inf), saturated to
// SAMPLE_WIDTH.
//
// Where it is used (mixer_core): after the inputs, on the buses, before the
// outputs: the inputChannel / busChannel / outputChannel levels. It is also
// where later per-channel work goes without changing any contract: mute is a
// gain of 0 (software), gain smoothing a ramp on the coefficient inside this
// block (docs/architecture_modules.md 3), and its output stream is the
// "post-DSP" meter tap (OSC standard, Metering).
//
// ----- Ports: the PCM stream contract (docs/architecture_modules.md 2.1) -----
// Input and output streams carry channels 0..N-1, ascending, once per frame.
// Each beat leaves exactly GAIN_LAT cycles after it arrived
// (mixer_core_pkg::GAIN_LAT = 4), so the output keeps the input's order,
// gaps and timing: first/last beat = the input's + GAIN_LAT.
//
// Coefficients arrive through a READ PORT (coef_addr -> coef_data one cycle
// later), served by coef_bank_ram or coef_flat_reader with ROW_LEN = 1,
// N_ROWS = N, LANES = 1: word c is channel c's gain. The address is the
// beat's channel, so all of a frame's reads fall between its two strobes
// (beats never sit in the strobe cycle) and each frame uses one bank.
//
// ----- Pipeline (cycle c = the input beat's cycle) -----
//   c+1  sample, channel, valid registered; coef_data(ch) arrives
//   c+2  A <= sample, B <= gain                 \
//   c+3  M <= A * B                              > one DSP48E2 (AREG/BREG, MREG)
//   c+4  out <= saturate(M >>> GAIN_FRAC)        (fabric), out_valid
// Data registers have no reset, so they pack into the DSP; control resets.
// -----------------------------------------------------------------------------
module pcm_gain
    import mixer_core_pkg::*;
#(
    parameter int N            = 4,
    parameter int SAMPLE_WIDTH = 24,
    parameter int GAIN_WIDTH   = 18,
    parameter int GAIN_FRAC    = 16,
    localparam int CW = (N > 1) ? $clog2(N) : 1
) (
    input  logic                      mclk,
    input  logic                      rst_n,

    // ----- input stream -----
    input  logic                      in_valid,
    input  logic [CW-1:0]             in_ch,
    input  logic [SAMPLE_WIDTH-1:0]   in_data,

    // ----- coefficient read port -----
    output logic [CW-1:0]             coef_addr,
    input  logic [GAIN_WIDTH-1:0]     coef_data,

    // ----- output stream -----
    output logic                      out_valid,
    output logic [CW-1:0]             out_ch,
    output logic [SAMPLE_WIDTH-1:0]   out_data
);

    localparam int SW = SAMPLE_WIDTH;
    localparam int GW = GAIN_WIDTH;
    localparam int MW = SW + GW;

    generate
        if (SW + GW > 45 || SW > 27 || GW > 18)
            $error("pcm_gain: %0d x %0d bits is not one DSP48E2 multiply", SW, GW);
        if (GAIN_LAT != 4)
            $error("pcm_gain: the pipeline below is 4 stages; GAIN_LAT = %0d", GAIN_LAT);
    endgenerate

    localparam logic signed [MW-1:0] SAMP_MAX =  (MW'(1) <<< (SW-1)) - 1;
    localparam logic signed [MW-1:0] SAMP_MIN = -(MW'(1) <<< (SW-1));

    assign coef_addr = in_ch;

    // ----- data path (no reset) -----
    logic        [SW-1:0] s1;
    logic signed [SW-1:0] a2;
    logic signed [GW-1:0] b2;
    logic signed [MW-1:0] m3;

    always_ff @(posedge mclk) begin
        s1 <= in_data;
        a2 <= s1;
        b2 <= coef_data;
        m3 <= a2 * b2;
    end

    // ----- control (reset) -----
    logic          v1, v2, v3;
    logic [CW-1:0] c1, c2, c3;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            c1 <= '0;   c2 <= '0;   c3 <= '0;
        end else begin
            v1 <= in_valid; c1 <= in_ch;
            v2 <= v1;       c2 <= c1;
            v3 <= v2;       c3 <= c2;
        end
    end

    // ----- descale, saturate, emit -----
    always_ff @(posedge mclk or negedge rst_n) begin
        logic signed [MW-1:0] scaled;
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_ch    <= '0;
            out_data  <= '0;
        end else begin
            out_valid <= v3;
            out_ch    <= c3;
            scaled = m3 >>> GAIN_FRAC;
            if (scaled > SAMP_MAX)      out_data <= SAMP_MAX[SW-1:0];
            else if (scaled < SAMP_MIN) out_data <= SAMP_MIN[SW-1:0];
            else                        out_data <= scaled[SW-1:0];
        end
    end

endmodule
