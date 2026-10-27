// -----------------------------------------------------------------------------
// coef_flat_reader.sv
//
// Generic (Phase 9, P9.A3): the coefficient READ PORT of coef_bank_ram, served
// from a flat vector instead of RAM. For builds without the PS (the vector is
// a constant, e.g. MATRIX_GAINS) and for unit TBs, so a core block never knows
// where its coefficients come from (docs/architecture_modules.md 3).
//
// Same layout and timing as coef_bank_ram's mclk side: flat index
// k = r*ROW_LEN + c at [k*W +: W]; row r served by lane r % LANES at word
// (r / LANES)*ROW_LEN + c, lane l at rd_data[l*W +: W]; one cycle of read
// latency. Lane slots past the last row read 0.
//
// LATCH = 0 (the default): no bank swap. Whoever drives coefs_flat must change
// it only in the strobe cycle (as for the packed coefficient port it
// replaces), so each frame sees one bank. A constant needs nothing; frame_i
// is unused, kept so the two sources are interchangeable port for port.
//
// LATCH = 1 (library foundation, LF1): a bank swap like coef_bank_ram's.
// coefs_flat is copied into the bank on frame_i (a read issued in that cycle
// still sees the old bank) and once on the first clock edge, so the frames
// before the first swap read a defined bank (coef_bank_ram's reset bank).
// For TBs whose chain spans frames, where a frame's reads at one block can
// fall after the next strobe and coefs_flat may change at any time.
// -----------------------------------------------------------------------------
module coef_flat_reader #(
    parameter int W       = 18,
    parameter int N_ROWS  = 12,
    parameter int ROW_LEN = 12,
    parameter int LANES   = 1,
    parameter bit LATCH   = 1'b0,
    localparam int N_COEF = N_ROWS * ROW_LEN,
    localparam int PASSES = (N_ROWS + LANES - 1) / LANES,
    localparam int DEPTH  = PASSES * ROW_LEN,
    localparam int AW     = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                  mclk,
    input  logic                  frame_i,
    input  logic [N_COEF*W-1:0]   coefs_flat,
    input  logic [AW-1:0]         rd_addr,
    output logic [LANES*W-1:0]    rd_data
);

    // The bank the words come from: coefs_flat itself, or its latched copy.
    logic [N_COEF*W-1:0] bank;
    generate
        if (LATCH) begin : g_latch
            logic [N_COEF*W-1:0] held;
            logic                loaded = 1'b0;
            always_ff @(posedge mclk)
                if (frame_i || !loaded) begin
                    held   <= coefs_flat;
                    loaded <= 1'b1;
                end
            assign bank = held;
        end else begin : g_live
            assign bank = coefs_flat;
        end
    endgenerate

    // The same words coef_bank_ram would hold, built at elaboration.
    logic [LANES*W-1:0] words [DEPTH];

    genvar gp, gc, gl;
    generate
        for (gp = 0; gp < PASSES; gp++)
            for (gc = 0; gc < ROW_LEN; gc++)
                for (gl = 0; gl < LANES; gl++) begin : g_w
                    localparam int R = gp*LANES + gl;
                    if (R < N_ROWS)
                        assign words[gp*ROW_LEN + gc][gl*W +: W] =
                            bank[(R*ROW_LEN + gc)*W +: W];
                    else
                        assign words[gp*ROW_LEN + gc][gl*W +: W] = '0;
                end
    endgenerate

    always_ff @(posedge mclk)
        rd_data <= (int'(rd_addr) < DEPTH) ? words[rd_addr] : '0;

endmodule
