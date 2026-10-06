// -----------------------------------------------------------------------------
// pcm_peak.sv
//
// Per-channel peak meter on a PCM stream (Phase 13, F4a): listens to one
// stream (docs/architecture_modules.md 2.1, a mixer_core tap port) and keeps,
// for every channel, the largest magnitude since the last snapshot. Seen from
// the register window it is a coefficient store read the other way: the
// audio clock produces the bank, the AXI clock reads it.
//
//   peak[c] = max |x[c]| over the frames of the window   (-2^23 -> 2^23-1)
//
// ----- Windows and snapshots (decision M2) -----
// The audio side keeps one accumulator per channel. A snapshot request
// (commit, from the window's CTRL write) is carried to the audio side, which
// on its next frame strobe copies ALL accumulators into the closed bank on
// that one edge and clears them. So:
//   - a window is a whole number of frames, the same frames for every channel
//     (atomic across channels by construction);
//   - nothing is lost between snapshots: every frame belongs to exactly one
//     window, and every beat of a frame lies between two strobes;
//   - clearing to 0 at a frame boundary is the same as starting at the first
//     sample of the new window (max(0, |x|) = |x|), so a loud frame at the
//     boundary is never lost (the F4a handoff's "clear means start at the
//     current sample").
// The meaning is "max since the previous snapshot", for ONE reader (the
// server; a second reader would split the windows between them).
//
// ----- aclk side: the store interface of axil_coef_window -----
//   commit   : request a snapshot (the window's COMMIT = SNAP).
//   busy     : a snapshot is in flight (until the copy is acknowledged).
//   queued   : a snapshot was requested while busy; it launches when busy
//              clears (back-to-back requests merge, as for coef_bank_ram).
//   commits  : snapshots completed since aresetn (wraps).
//   st_*     : a read returns channel st_idx's peak of the last closed
//              window, magnitude in [SW-2:0], bit SW-1 = 0 (the window's sign
//              extension reads it as positive). Writes are accepted and
//              ignored. st_ready is low while busy or queued, so a read after
//              a SNAP sees the new snapshot.
//
// ----- mclk side -----
//   s_valid / s_ch / s_data : the stream (each channel once per frame, beats
//                             strictly between strobes).
//   frame_i                 : the frame strobe; a pending copy happens on it.
// A beat updates its accumulator on the next edge, so a frame's last beat is
// in before the strobe for every core block (D <= 250).
//
// ----- CDC: the only paths between the clocks -----
//   1. req_tgl (aclk) -> req_s1/req_s2 (mclk)   "snapshot, please"
//   2. ack_tgl (mclk) -> ack_s1/ack_s2 (aclk)   "copied"
//   3. closed (mclk) -> st_rdata (aclk)   multi-bit, captured only under a
//      read enable that is true only while not busy: closed changes on the
//      copy edge, which happens only between a request and its
//      acknowledgement, so it has been stable for >= 2 aclk periods (the
//      ack's synchronizer) whenever it is captured (the MCP formulation of
//      coef_bank_handoff).
// constraints/pcm_peak.xdc (SCOPED_TO_REF) bounds all three; keep the
// register names in step.
//
// No reset on the toggles or the audio side (as coef_bank_ram): they start
// from configuration, so a reset of either domain alone can't pair a stale
// bank with a new request. aresetn resets queued, commits and st_rvalid.
// -----------------------------------------------------------------------------
module pcm_peak #(
    parameter int N  = 4,
    parameter int SW = 24,
    localparam int CW = (N > 1) ? $clog2(N) : 1
) (
    // ----- aclk domain: store interface -----
    input  logic           aclk,
    input  logic           aresetn,

    input  logic           st_valid,
    output logic           st_ready,
    input  logic           st_we,
    input  logic [CW-1:0]  st_idx,
    input  logic [SW-1:0]  st_wdata,      // ignored: the window is read-only
    output logic           st_rvalid,
    output logic [SW-1:0]  st_rdata,

    input  logic           commit,
    output logic           busy,
    output logic           queued,
    output logic [31:0]    commits,

    // ----- mclk domain: the stream -----
    input  logic           mclk,
    input  logic           frame_i,
    input  logic           s_valid,
    input  logic [CW-1:0]  s_ch,
    input  logic [SW-1:0]  s_data
);

    localparam logic [SW-1:0] MAG_MAX = {1'b0, {(SW-1){1'b1}}};
    localparam logic [SW-1:0] MOST_NEG = {1'b1, {(SW-1){1'b0}}};

    // =========================================================================
    // Handshake toggles (no reset: see header)
    // =========================================================================
    logic req_tgl = 1'b0;                                   // aclk
    logic ack_tgl = 1'b0;                                   // mclk
    (* ASYNC_REG = "TRUE" *) logic req_s1 = 1'b0, req_s2 = 1'b0;   // mclk
    (* ASYNC_REG = "TRUE" *) logic ack_s1 = 1'b0, ack_s2 = 1'b0;   // aclk

    // =========================================================================
    // mclk: accumulate; on a requested strobe, copy and clear
    // =========================================================================
    logic [SW-1:0] acc    [N];
    logic [SW-1:0] closed [N];
    initial for (int j = 0; j < N; j++) begin acc[j] = '0; closed[j] = '0; end

    logic [SW-1:0] mag;
    always_comb begin
        if (s_data == MOST_NEG)  mag = MAG_MAX;
        else if (s_data[SW-1])   mag = ~s_data + 1'b1;
        else                     mag = s_data;
    end

    always_ff @(posedge mclk) begin
        req_s1 <= req_tgl;
        req_s2 <= req_s1;
        if (frame_i && req_s2 != ack_tgl) begin
            // A beat sampled on the strobe edge is the closing frame's last
            // cycle (stream contract), so it belongs to the closed window.
            for (int j = 0; j < N; j++) begin
                closed[j] <= (s_valid && int'(s_ch) == j && mag > acc[j]) ? mag : acc[j];
                acc[j]    <= '0;
            end
            ack_tgl <= req_s2;
        end else if (s_valid && int'(s_ch) < N && mag > acc[s_ch]) begin
            acc[s_ch] <= mag;
        end
    end

    // =========================================================================
    // aclk: requests and reads
    // =========================================================================
    always_ff @(posedge aclk) begin
        ack_s1 <= ack_tgl;
        ack_s2 <= ack_s1;
    end

    logic hs_busy, hs_busy_q, rd_en;
    assign hs_busy  = (req_tgl != ack_s2);
    assign busy     = hs_busy;
    assign st_ready = !hs_busy && !queued;
    assign rd_en    = st_valid && st_ready && !st_we;

    always_ff @(posedge aclk)
        if (rd_en) st_rdata <= closed[st_idx];

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            queued    <= 1'b0;
            commits   <= '0;
            st_rvalid <= 1'b0;
            hs_busy_q <= 1'b0;
        end else begin
            st_rvalid <= rd_en;
            hs_busy_q <= hs_busy;
            if (hs_busy_q && !hs_busy)
                commits <= commits + 1'b1;
            if ((commit || queued) && !hs_busy) begin
                req_tgl <= ~ack_s2;                         // launch
                queued  <= 1'b0;
            end else if (commit) begin
                queued  <= 1'b1;
            end
        end
    end

endmodule
