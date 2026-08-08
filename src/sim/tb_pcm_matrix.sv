// -----------------------------------------------------------------------------
// tb_pcm_matrix.sv
//
// Unit test for pcm_matrix. Pure PCM in / PCM out -- no I2S timing anywhere,
// so there is no hand-rolled bit alignment to get wrong. This is deliberately
// the opposite of the Phase 2 harnesses: the only thing under test is the
// fixed-point crosspoint arithmetic, which is exactly the Phase 3 risk.
//
// The expected output is produced by an INDEPENDENT reference model (ref_out)
// using 64-bit integer math, not by hardcoded constants. If the RTL and the
// reference disagree, one of them is wrong -- either way it surfaces a real
// discrepancy instead of a self-fulfilling hardcode.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pcm_matrix;

    localparam int N            = 4;
    localparam int SAMPLE_WIDTH = 24;
    localparam int GAIN_WIDTH   = 18;
    localparam int GAIN_FRAC    = 16;

    // Gain constants (Q2.16)
    localparam signed [GAIN_WIDTH-1:0] G_UNITY = 18'sh10000;  //  1.0
    localparam signed [GAIN_WIDTH-1:0] G_HALF  = 18'sh08000;  //  0.5
    localparam signed [GAIN_WIDTH-1:0] G_QTR   = 18'sh04000;  //  0.25
    localparam signed [GAIN_WIDTH-1:0] G_NEG   = 18'sh30000;  // -1.0
    localparam signed [GAIN_WIDTH-1:0] G_ZERO  = 18'sh00000;  //  0.0

    // Saturation limits used by the reference model.
    localparam longint SAMP_MAX =  (1 <<< (SAMPLE_WIDTH-1)) - 1;   //  8388607
    localparam longint SAMP_MIN = -(1 <<< (SAMPLE_WIDTH-1));       // -8388608

    // ----- DUT wiring -----
    logic mclk = 0;
    logic rst_n = 0;
    logic sample_valid_i = 0;
    logic sample_valid_o;

    // TB-side per-channel samples (readable); packed/unpacked bridges to the DUT.
    logic signed [SAMPLE_WIDTH-1:0] in_samples  [N];   // driven procedurally, feeds reference
    logic signed [SAMPLE_WIDTH-1:0] out_samples [N];   // unpacked view of out_flat for checking
    logic [N*SAMPLE_WIDTH-1:0]      in_flat;            // packed port into DUT
    logic [N*SAMPLE_WIDTH-1:0]      out_flat;           // packed port out of DUT

    // Pack inputs / unpack outputs with genvar-constant selects (iverilog-safe).
    genvar c;
    generate
        for (c = 0; c < N; c++) begin : bridge
            assign in_flat[c*SAMPLE_WIDTH +: SAMPLE_WIDTH] = in_samples[c];
            assign out_samples[c] = $signed(out_flat[c*SAMPLE_WIDTH +: SAMPLE_WIDTH]);
        end
    endgenerate

    // Per-crosspoint gain table the TB reasons about, gain[o][i].
    logic signed [GAIN_WIDTH-1:0] gain [N][N];

    always #5 mclk = ~mclk;   // 100 MHz TB clock (arbitrary; matrix is sync only to it)

    // -------------------------------------------------------------------------
    // Test gain matrix (rows = outputs, cols = inputs):
    //   out0 = 1.0*in0                          (unity passthrough)
    //   out1 = 1.0*in2                          (cross route)
    //   out2 = 0.5*in0 + 0.5*in2                (summed mix)
    //   out3 = 1.0*in0 + 1.0*in1 + (-1.0)*in3   (sum + phase-invert; drives saturation)
    // Assembled as a flat packed constant. MUST be declared before the
    // instance below that references it.
    // -------------------------------------------------------------------------
    localparam logic [N*N*GAIN_WIDTH-1:0] TEST_GAINS = {
        // out3: i3       i2       i1       i0
        G_NEG,  G_ZERO,  G_UNITY, G_UNITY,
        // out2
        G_ZERO, G_HALF,  G_ZERO,  G_HALF,
        // out1
        G_ZERO, G_UNITY, G_ZERO,  G_ZERO,
        // out0
        G_ZERO, G_ZERO,  G_ZERO,  G_UNITY
    };

    pcm_matrix #(
        .N            (N),
        .SAMPLE_WIDTH (SAMPLE_WIDTH),
        .GAIN_WIDTH   (GAIN_WIDTH),
        .GAIN_FRAC    (GAIN_FRAC),
        .GAINS_FLAT   (TEST_GAINS)
    ) dut (
        .mclk           (mclk),
        .rst_n          (rst_n),
        .sample_valid_i (sample_valid_i),
        .in_flat        (in_flat),
        .out_flat       (out_flat),
        .sample_valid_o (sample_valid_o)
    );

    // Populate the gain[o][i] table (for the reference model) to match TEST_GAINS.
    initial begin
        for (int o = 0; o < N; o++)
            for (int i = 0; i < N; i++)
                gain[o][i] = $signed(TEST_GAINS[(o*N + i)*GAIN_WIDTH +: GAIN_WIDTH]);
    end

    // ----- Independent reference model (64-bit, mirrors the RTL spec) -----
    function automatic logic signed [SAMPLE_WIDTH-1:0] ref_out(input int o);
        longint acc;
        longint scaled;
        acc = 0;
        for (int i = 0; i < N; i++)
            acc += longint'(in_samples[i]) * longint'(gain[o][i]);
        scaled = acc >>> GAIN_FRAC;              // arithmetic shift, truncates toward -inf
        if (scaled > SAMP_MAX)      return SAMP_MAX[SAMPLE_WIDTH-1:0];
        else if (scaled < SAMP_MIN) return SAMP_MIN[SAMPLE_WIDTH-1:0];
        else                        return scaled[SAMPLE_WIDTH-1:0];
    endfunction

    // ----- Apply one input vector, then check every output -----
    int errors = 0;
    task automatic apply_and_check(input string label,
                                   input logic signed [SAMPLE_WIDTH-1:0] v0,
                                   input logic signed [SAMPLE_WIDTH-1:0] v1,
                                   input logic signed [SAMPLE_WIDTH-1:0] v2,
                                   input logic signed [SAMPLE_WIDTH-1:0] v3);
        logic signed [SAMPLE_WIDTH-1:0] exp;
        @(negedge mclk);
        in_samples[0] = v0; in_samples[1] = v1;
        in_samples[2] = v2; in_samples[3] = v3;
        sample_valid_i = 1'b1;
        @(negedge mclk);
        sample_valid_i = 1'b0;
        @(negedge mclk);   // outputs registered by now (valid pulse + 1)

        $display("  %s: in = [%06h %06h %06h %06h]", label, v0, v1, v2, v3);
        for (int o = 0; o < N; o++) begin
            exp = ref_out(o);
            if (out_samples[o] === exp)
                $display("    [ok]  out%0d = %06h", o, out_samples[o]);
            else begin
                $display("    [FAIL] out%0d = %06h, ref = %06h", o, out_samples[o], exp);
                errors++;
            end
        end
    endtask

    initial begin
        $display("");
        $display("=== tb_pcm_matrix ===");

        // reset
        rst_n = 0;
        for (int i = 0; i < N; i++) in_samples[i] = '0;
        repeat (4) @(negedge mclk);
        rst_n = 1;
        repeat (2) @(negedge mclk);

        // 1. Routing: distinct values so cross-routes are unambiguous.
        apply_and_check("distinct",  24'h111111, 24'h222222, 24'h333333, 24'h444444);

        // 2. Truncation: 0.5 * odd value should truncate toward -inf.
        apply_and_check("trunc",     24'h000003, 24'h000000, 24'h000001, 24'h000000);

        // 3. Positive saturation: out3 = in0+in1 = 2*maxpos -> clamps to +FS.
        apply_and_check("sat_hi",    24'h7FFFFF, 24'h7FFFFF, 24'h000000, 24'h000000);

        // 4. Negative saturation: out3 = in0+in1 = 2*maxneg -> clamps to -FS.
        apply_and_check("sat_lo",    24'h800000, 24'h800000, 24'h000000, 24'h000000);

        // 5. Phase invert: out3 includes -1.0*in3.
        apply_and_check("invert",    24'h000000, 24'h000000, 24'h000000, 24'h123456);

        // 6. All zero.
        apply_and_check("zero",      24'h000000, 24'h000000, 24'h000000, 24'h000000);

        // 7. Full negative on a cross route (sign handling through the matrix).
        apply_and_check("neg_cross", 24'h000000, 24'h000000, 24'hFFFFFF, 24'h000000);

        $display("");
        if (errors == 0) $display("PASS: tb_pcm_matrix - all checks passed");
        else             $display("FAIL: tb_pcm_matrix - %0d check(s) failed", errors);
        $display("");
        $finish;
    end

    initial begin
        #100us;
        $display("FAIL: tb_pcm_matrix TIMEOUT");
        $finish;
    end

endmodule
