// -----------------------------------------------------------------------------
// coef_smooth.sv
//
// Generic (library foundation, LF2/LF3, 2026-10-26): click-free coefficient
// changes. Sits on a coefficient READ PORT between the bank (coef_bank_ram,
// coef_flat_reader) and the block, with the same port on both sides, so
// neither knows it is there (docs/library_foundation_proposal_2026-10-10.md
// sec. 3, 11; docs/architecture_modules.md 3).
//
// It keeps the CURRENT value of every coefficient (per lane) and, on each
// real read (rd_en), moves it toward the bank's TARGET and returns the moved
// value:
//
//   cur' = cur + (target*2^K - cur) >>> K      (cur kept with K extra bits)
//   cur' = target*2^K  once |target*2^K - cur| < 2^K (within one output LSB)
//   data = cur' >>> K
//
// Each coefficient is read exactly once per frame (the read-port rule since
// LF2: coef_rd), so this is a one-pole lowpass per coefficient at the frame
// rate: tau = 2^K frames (K = 8: 256 frames, 5.3 ms at 48 kHz). The extra
// bits keep small steps from stalling short of the target, and the snap
// makes it arrive EXACTLY (unity stays unity, bit for bit) after at most
// about (W + 1) * 2^K reads. It never overshoots (each step is at most the
// remaining distance, toward the target).
//
// ----- Timing: the read port's, unchanged -----
//   cycle t   : rd_addr (and rd_en) from the block; bk_addr = rd_addr
//   edge t+1  : the bank's word (bk_data) and the current value (cur_q)
//               are registered; rd_data = the moved value, combinational
//               from them: valid in cycle t+1, one cycle after rd_addr
//   edge t+2  : the moved value is written back, if rd_en was high
// A coefficient must not be read with rd_en again before its write-back
// (one cycle): the once-per-frame rule guarantees it.
//
// Signed coefficients (W bits, two's complement: the Q2.16 gains). The
// current values start at 0 (no reset: the RAM's configuration value), so
// after power-up every coefficient fades in from 0 (the user, 2026-10-26, Q2).
// -----------------------------------------------------------------------------
module coef_smooth #(
    parameter int W     = 18,     // coefficient width
    parameter int DEPTH = 20,     // words (the block's read-port depth)
    parameter int LANES = 1,      // coefficients per word
    parameter int K     = 8,      // tau = 2^K reads (frames)
    localparam int AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    localparam int XW   = W + K   // a current value: W bits + K fraction bits
) (
    input  logic               mclk,
    // block side (as the bank's read port)
    input  logic [AW-1:0]      rd_addr,
    input  logic               rd_en,       // a real read (the block's coef_rd)
    output logic [LANES*W-1:0] rd_data,
    // bank side
    output logic [AW-1:0]      bk_addr,
    input  logic [LANES*W-1:0] bk_data
);

    generate
        if (K < 1 || K > 16)
            $error("coef_smooth: K = %0d must be 1 .. 16", K);
    endgenerate

    assign bk_addr = rd_addr;

    logic [AW-1:0] a_q;
    logic          en_q;
    always_ff @(posedge mclk) begin
        a_q  <= rd_addr;
        en_q <= rd_en;
    end

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl++) begin : g_lane
            logic signed [XW-1:0] cur [DEPTH];
            logic signed [XW-1:0] cur_q, nxt;
            logic signed [XW:0]   diff;            // one bit wider: the full range
            logic signed [XW-1:0] tgt;

            initial for (int j = 0; j < DEPTH; j++) cur[j] = '0;

            always_ff @(posedge mclk) begin
                cur_q <= cur[rd_addr];
                if (en_q) cur[a_q] <= nxt;
            end

            always_comb begin
                tgt  = XW'($signed(bk_data[gl*W +: W])) <<< K;
                diff = (XW+1)'(tgt) - (XW+1)'(cur_q);
                if (diff > -(XW+1)'(1 << K) && diff < (XW+1)'(1 << K))
                    nxt = tgt;                                  // within one LSB: arrive
                else
                    nxt = cur_q + XW'(diff >>> K);              // one step toward it
            end

            assign rd_data[gl*W +: W] = nxt[XW-1:K];
        end
    endgenerate

endmodule
