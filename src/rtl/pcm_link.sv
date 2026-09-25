// -----------------------------------------------------------------------------
// pcm_link.sv
//
// Front door (docs/architecture_modules.md 2), PL half of the PS <-> PL audio
// link (Phase 8, docs/phase8_status_2026-09-25.md). It converts between the
// AMD Audio Formatter's AXI4-Stream audio (on the AXI clock) and the PCM
// contract (on mclk). It knows the AXIS audio format and its own two clocks;
// it knows nothing about USB, the matrix, or who is on the Linux side.
//
//   s_axis (formatter MM2S, PS -> PL) -> async_fifo -> frame assembler
//        -> rx_flat / rx_valid  (samples INTO the core, like i2s_port's rx)
//   tx_flat (samples OUT of the core) -> frame serializer -> async_fifo
//        -> m_axis (formatter S2MM, PL -> PS)
//
// ----- AXIS audio format (formatter <-> this block) -----
// One beat per channel sample: TID = channel number (0 .. N_CH-1), TDATA in the
// AES3-subframe layout the formatter uses for 24-bit PCM: sample at
// [SAMPLE_LSB +: 24] (default [27:4]), other bits 0 towards S2MM and ignored
// from MM2S. The formatter sends MM2S channels in order 0 .. N_CH-1 and
// accepts S2MM channels in any order; we send them in order.
//
// ----- Frame timing -----
// frame_i is the core's frame strobe (one mclk pulse per frame; the platform
// wires the same strobe the matrix uses). On each strobe:
//   - rx_flat takes the next complete frame from the PS (or all zeros if none
//     is ready: an UNDERRUN, never stale or partial samples), and rx_valid
//     pulses. The matrix samples rx_flat on its next frame, so this door adds
//     one frame of latency, like the I2S receiver.
//   - tx_flat is captured and queued towards the PS; if the FIFO can't take a
//     whole frame, the frame is dropped (an OVERRUN).
//
// ----- Clocks -----
// This door does NOT adapt rates. The formatter's MM2S is paced by its
// aud_mclk input (= this design's mclk), and S2MM gets one frame per strobe,
// so the Linux-side ALSA card runs on mclk time. Whatever feeds that card
// (USB gadget, AVB) bridges its own clock in its own front door half. The only
// clock crossing here is the pair of async FIFOs (async_fifo, scoped XDC).
//
// ----- Channel alignment -----
// The assembler expects TID 0, 1, .., N_CH-1. A beat with any other TID is a
// TID error: the partial frame is discarded, and the assembler waits for
// TID 0 (a TID 0 beat always starts a new frame). A lost beat therefore costs
// frames, never rotates channels.
//
// ----- Status (mclk domain, free-running counters, wrap) -----
//   frames_rx      frames delivered to the core from the PS
//   frames_tx      frames queued towards the PS
//   underruns      starts of an underrun: a frame missing after one delivered
//   starved        frames that were zeros because none was ready
//   overruns       frames dropped towards the PS
//   tid_errors     beats discarded for a TID out of sequence
//   rx_fill        words waiting in the PS -> PL FIFO, as seen from mclk
//   rx_running     the last strobe delivered a real frame
// A stopped ALSA stream shows as `starved` climbing; `underruns` counts the
// interruptions of a running one.
//
// Resets: aresetn (AXI side) and rst_n (mclk side) are asserted together at
// power-up (see async_fifo); they are used asynchronously for the FIFOs and
// synchronously elsewhere, matching each domain's existing convention.
// -----------------------------------------------------------------------------
module pcm_link #(
    parameter int N_CH        = 8,   // 2, 4, 6 or 8 (the formatter's range)
    parameter int SW          = 24,
    parameter int SAMPLE_LSB  = 4,   // sample at TDATA[SAMPLE_LSB +: SW]
    parameter int FIFO_FRAMES = 8    // FIFO depth per direction, in frames (power of 2)
) (
    // ----- AXI side (formatter), aclk domain -----
    input  logic               aclk,
    input  logic               aresetn,

    input  logic [31:0]        s_axis_tdata,    // formatter MM2S -> here
    input  logic [7:0]         s_axis_tid,
    input  logic               s_axis_tvalid,
    output logic               s_axis_tready,

    output logic [31:0]        m_axis_tdata,    // here -> formatter S2MM
    output logic [7:0]         m_axis_tid,
    output logic               m_axis_tvalid,
    input  logic               m_axis_tready,

    // ----- PCM contract, mclk domain -----
    input  logic               mclk,
    input  logic               rst_n,
    input  logic               frame_i,
    output logic [N_CH*SW-1:0] rx_flat,
    output logic               rx_valid,
    input  logic [N_CH*SW-1:0] tx_flat,

    // ----- status, mclk domain -----
    output logic [31:0]        frames_rx,
    output logic [31:0]        frames_tx,
    output logic [31:0]        underruns,
    output logic [31:0]        starved,
    output logic [31:0]        overruns,
    output logic [31:0]        tid_errors,
    output logic [15:0]        rx_fill,
    output logic               rx_running
);

    localparam int CW    = $clog2(N_CH);                   // channel index width
    localparam int WW    = CW + SW;                        // FIFO word: {tid, sample}
    localparam int DEPTH = FIFO_FRAMES * (1 << CW);        // power of two
    localparam int LW    = $clog2(DEPTH) + 1;

    // synthesis translate_off
    initial begin
        if (N_CH < 2 || N_CH > 8 || (N_CH % 2) != 0)
            $fatal(1, "pcm_link: N_CH (%0d) must be 2, 4, 6 or 8", N_CH);
        if (SAMPLE_LSB + SW > 32)
            $fatal(1, "pcm_link: sample field [%0d +: %0d] exceeds TDATA", SAMPLE_LSB, SW);
    end
    // synthesis translate_on

    // =========================================================================
    // PS -> PL
    // =========================================================================
    logic          rxf_full, rxf_empty, rxf_rd;
    logic [LW-1:0] rxf_rd_level;
    logic [LW-1:0] rxf_wr_level_unused;
    logic          rxf_tid_ok;
    logic [CW-1:0] rxf_tid;
    logic [SW-1:0] rxf_sample;

    // The FIFO stores only CW bits of TID, so an out-of-range TID (>= N_CH)
    // could alias onto a valid channel. It travels as an explicit flag instead.
    logic          s_tid_ok;
    assign s_tid_ok      = (s_axis_tid < 8'(N_CH));
    assign s_axis_tready = !rxf_full;

    async_fifo #(.WIDTH (WW + 1), .DEPTH (DEPTH)) u_rx_fifo (
        .wclk (aclk), .wrst_n (aresetn),
        .wr_en (s_axis_tvalid),
        .wdata ({s_tid_ok, s_axis_tid[CW-1:0], s_axis_tdata[SAMPLE_LSB +: SW]}),
        .full (rxf_full), .wr_level (rxf_wr_level_unused),
        .rclk (mclk), .rrst_n (rst_n),
        .rd_en (rxf_rd),
        .rdata ({rxf_tid_ok, rxf_tid, rxf_sample}),
        .empty (rxf_empty), .rd_level (rxf_rd_level)
    );

    // Assembler: pops beats into stage[] while the staged frame is incomplete.
    logic [N_CH*SW-1:0] stage;
    logic [CW-1:0]      next_ch;
    logic               stage_full;     // all N_CH channels staged
    logic               hunting;        // waiting for TID 0 after an error

    assign rxf_rd = !rxf_empty && !stage_full;

    always_ff @(posedge mclk) begin
        if (!rst_n) begin
            stage      <= '0;
            next_ch    <= '0;
            stage_full <= 1'b0;
            hunting    <= 1'b0;
            tid_errors <= '0;
            rx_flat    <= '0;
            rx_valid   <= 1'b0;
            rx_running <= 1'b0;
            frames_rx  <= '0;
            underruns  <= '0;
            starved    <= '0;
        end else begin
            rx_valid <= 1'b0;

            // ----- pop one beat -----
            if (rxf_rd) begin
                if (rxf_tid_ok && rxf_tid == '0) begin
                    // TID 0 always starts a frame; a partial one before it is lost
                    if (next_ch != '0 && !hunting) tid_errors <= tid_errors + 1'b1;
                    stage[0 +: SW] <= rxf_sample;
                    next_ch        <= CW'(1);
                    hunting        <= 1'b0;
                end else if (!hunting && rxf_tid_ok && rxf_tid == next_ch) begin
                    stage[int'(rxf_tid)*SW +: SW] <= rxf_sample;
                    if (int'(next_ch) == N_CH - 1) begin
                        stage_full <= 1'b1;
                        next_ch    <= '0;
                    end else begin
                        next_ch <= next_ch + 1'b1;
                    end
                end else begin
                    tid_errors <= tid_errors + 1'b1;
                    hunting    <= 1'b1;
                    next_ch    <= '0;
                end
            end

            // ----- frame strobe: deliver -----
            if (frame_i) begin
                rx_valid <= 1'b1;
                if (stage_full) begin
                    rx_flat    <= stage;
                    stage_full <= 1'b0;
                    frames_rx  <= frames_rx + 1'b1;
                    rx_running <= 1'b1;
                end else begin
                    rx_flat    <= '0;
                    starved    <= starved + 1'b1;
                    rx_running <= 1'b0;
                    if (rx_running) underruns <= underruns + 1'b1;
                end
            end
        end
    end

    assign rx_fill = 16'(rxf_rd_level);

    // =========================================================================
    // PL -> PS
    // =========================================================================
    logic          txf_wr, txf_full, txf_empty;
    logic [WW-1:0] txf_wdata, txf_rdata;
    logic [LW-1:0] txf_wr_level, txf_rd_level_unused;

    logic [N_CH*SW-1:0] tx_hold;
    logic [CW-1:0]      tx_ch;
    logic               tx_busy;

    assign txf_wr    = tx_busy;
    assign txf_wdata = {tx_ch, tx_hold[int'(tx_ch)*SW +: SW]};

    always_ff @(posedge mclk) begin
        if (!rst_n) begin
            tx_hold   <= '0;
            tx_ch     <= '0;
            tx_busy   <= 1'b0;
            frames_tx <= '0;
            overruns  <= '0;
        end else begin
            if (tx_busy) begin
                if (int'(tx_ch) == N_CH - 1) begin
                    tx_busy <= 1'b0;
                    tx_ch   <= '0;
                end else begin
                    tx_ch <= tx_ch + 1'b1;
                end
            end

            // A frame is 256 mclk cycles and serializing takes N_CH <= 8, so a
            // strobe never finds the serializer busy.
            if (frame_i) begin
                if (int'(txf_wr_level) <= DEPTH - N_CH) begin
                    tx_hold   <= tx_flat;
                    tx_ch     <= '0;
                    tx_busy   <= 1'b1;
                    frames_tx <= frames_tx + 1'b1;
                end else begin
                    overruns  <= overruns + 1'b1;
                end
            end
        end
    end

    async_fifo #(.WIDTH (WW), .DEPTH (DEPTH)) u_tx_fifo (
        .wclk (mclk), .wrst_n (rst_n),
        .wr_en (txf_wr), .wdata (txf_wdata),
        .full (txf_full), .wr_level (txf_wr_level),
        .rclk (aclk), .rrst_n (aresetn),
        .rd_en (m_axis_tvalid && m_axis_tready),
        .rdata (txf_rdata),
        .empty (txf_empty), .rd_level (txf_rd_level_unused)
    );

    always_comb begin
        m_axis_tdata = '0;
        m_axis_tdata[SAMPLE_LSB +: SW] = txf_rdata[SW-1:0];
    end
    assign m_axis_tid    = 8'(txf_rdata[SW +: CW]);
    assign m_axis_tvalid = !txf_empty;

endmodule
