// -----------------------------------------------------------------------------
// tb_pcm_link.sv
//
// pcm_link (Phase 8 front door, PL half) between a model of the AMD Audio
// Formatter's AXI4-Stream audio and the PCM contract, on UNRELATED clocks:
// aclk 100 MHz, mclk 12.2919 MHz (the board's real, +324 ppm audio clock).
//
// Every sample carries its own identity -- {channel, frame number} -- so the
// checkers can tell a wrong channel, a stale frame, a dropped frame and a
// zero (starved) frame apart without a reference model.
//
// PS -> PL phases (source = formatter MM2S model, random TVALID gaps):
//   A  paced      one frame per frame period, like the formatter's aud_mclk pacing
//   B  burst      source runs flat out: the FIFO fills, TREADY back-pressures,
//                 nothing is lost (frame numbers stay consecutive)
//   C  pause      source stops for PAUSE frames: zeros delivered, `starved`
//                 counts them, `underruns` counts ONE interruption
//   D  TID error  one frame has a beat with an out-of-range TID: that frame
//                 is lost, tid_errors counts the discarded beats, the next
//                 frame is intact and channels are not rotated
// PL -> PS phases (sink = formatter S2MM model):
//   random TREADY, then a long stall: whole frames dropped and counted as
//   overruns, the stream resumes on a frame boundary (TID 0), and the samples
//   sit at TDATA[27:4] with every other bit zero.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pcm_link;

    localparam int N_CH  = 8;
    localparam int SW    = 24;
    localparam int PAUSE = 20;

    // ----- clocks: unrelated on purpose -----
    logic aclk = 0, mclk = 0;
    always #5.000  aclk = ~aclk;          // 100 MHz
    always #40.677 mclk = ~mclk;          // 12.2919 MHz

    logic aresetn = 0, rst_n = 0;

    // ----- frame strobe: one mclk pulse every 256 cycles -----
    logic [7:0] fcnt = 0;
    logic       frame_i;
    always_ff @(posedge mclk) fcnt <= rst_n ? fcnt + 1'b1 : '0;
    assign frame_i = rst_n && (fcnt == 8'd0);

    // ----- DUT -----
    logic [31:0] s_tdata, m_tdata;
    logic [7:0]  s_tid,   m_tid;
    logic        s_tvalid = 0, s_tready, m_tvalid, m_tready = 0;
    logic [N_CH*SW-1:0] rx_flat, tx_flat = '0;
    logic        rx_valid, rx_running;
    logic [31:0] frames_rx, frames_tx, underruns, starved, overruns, tid_errors;
    logic [15:0] rx_fill;

    pcm_link #(.N_CH (N_CH), .SW (SW)) dut (
        .aclk (aclk), .aresetn (aresetn),
        .s_axis_tdata (s_tdata), .s_axis_tid (s_tid),
        .s_axis_tvalid (s_tvalid), .s_axis_tready (s_tready),
        .m_axis_tdata (m_tdata), .m_axis_tid (m_tid),
        .m_axis_tvalid (m_tvalid), .m_axis_tready (m_tready),
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame_i),
        .rx_flat (rx_flat), .rx_valid (rx_valid), .tx_flat (tx_flat),
        .frames_rx (frames_rx), .frames_tx (frames_tx), .underruns (underruns),
        .starved (starved), .overruns (overruns), .tid_errors (tid_errors),
        .rx_fill (rx_fill), .rx_running (rx_running)
    );

    int errors = 0;

    // Sample identity: channel in the top nibble, frame number below.
    function automatic logic [SW-1:0] pat(input int ch, input int k);
        return {4'(ch), 20'(k)};
    endfunction

    // =========================================================================
    // PS -> PL source: the formatter's MM2S
    // =========================================================================
    int  allowed    = 2;       // frames the source may have sent (pacing)
    bit  unpaced    = 0;       // phase B: ignore `allowed`
    int  sent       = 0;       // frames fully sent
    int  bad_frame  = -1;      // phase D: the frame that carries a bad TID
    bit  src_stop   = 0;

    // pacing: +1 allowed frame per frame period, mid-frame (unrelated phase)
    always @(posedge mclk) if (fcnt == 8'd97) allowed <= allowed + 1;

    task automatic send_beat(input logic [7:0] tid, input logic [SW-1:0] smp);
        repeat ($urandom_range(0, 3)) @(posedge aclk);
        s_tdata  <= 32'(smp) << 4;
        s_tid    <= tid;
        s_tvalid <= 1'b1;
        do @(posedge aclk); while (!s_tready);
        s_tvalid <= 1'b0;
    endtask

    initial begin : source
        int k;
        wait (aresetn);
        k = 1;                                    // frame 0 would be all zeros
        forever begin
            while (src_stop || (!unpaced && sent >= allowed)) @(posedge aclk);
            for (int c = 0; c < N_CH; c++) begin
                if (k == bad_frame && c == 2) send_beat(8'd12, pat(c, k));
                else                          send_beat(8'(c), pat(c, k));
            end
            sent++;
            k++;
        end
    end

    // =========================================================================
    // PS -> PL checker (mclk)
    // =========================================================================
    int exp_k       = 1;
    int got_frames  = 0;
    int got_zero    = 0;
    int skips       = 0;

    always @(posedge mclk) if (rst_n && rx_valid) begin
        if (rx_flat == '0) begin
            got_zero++;
        end else begin
            int k0;
            k0 = int'(rx_flat[19:0]);
            for (int c = 0; c < N_CH; c++) begin
                if (rx_flat[c*SW +: SW] != pat(c, k0)) begin
                    if (errors < 10)
                        $display("ERROR rx: frame %0d ch %0d = %06h, expected %06h",
                                 k0, c, rx_flat[c*SW +: SW], pat(c, k0));
                    errors++;
                end
            end
            if (k0 != exp_k) begin
                if (k0 == bad_frame + 1 && exp_k == bad_frame) begin
                    skips++;                      // the one frame phase D destroys
                end else begin
                    if (errors < 10)
                        $display("ERROR rx: frame %0d delivered, expected %0d", k0, exp_k);
                    errors++;
                end
            end
            exp_k = k0 + 1;
            got_frames++;
        end
    end

    // =========================================================================
    // PL -> PS: core side drives tx_flat, formatter S2MM model sinks it
    // =========================================================================
    int tx_k = 1;                                 // frame number on tx_flat now
    initial for (int c = 0; c < N_CH; c++) tx_flat[c*SW +: SW] = pat(c, 1);
    always @(posedge mclk) if (rst_n && frame_i) begin
        // the DUT captured tx_flat on this edge; present the next frame
        tx_k <= tx_k + 1;
        for (int c = 0; c < N_CH; c++) tx_flat[c*SW +: SW] <= pat(c, tx_k + 1);
    end

    bit sink_stall = 0;
    always @(posedge aclk) m_tready <= !sink_stall && ($urandom_range(0, 9) < 7);

    int sink_exp_c = 0, sink_k = -1, sink_frames = 0, sink_gaps = 0;
    always @(posedge aclk) if (aresetn && m_tvalid && m_tready) begin
        logic [SW-1:0] smp;
        smp = m_tdata[27:4];
        if (m_tdata[31:28] != 0 || m_tdata[3:0] != 0) begin
            if (errors < 10) $display("ERROR tx: sideband bits not zero: %08h", m_tdata);
            errors++;
        end
        if (int'(m_tid) != sink_exp_c || int'(smp[23:20]) != sink_exp_c) begin
            if (errors < 10)
                $display("ERROR tx: tid %0d / sample %06h, expected channel %0d",
                         m_tid, smp, sink_exp_c);
            errors++;
        end
        if (sink_exp_c == 0) begin
            if (sink_k >= 0 && int'(smp[19:0]) != sink_k + 1) sink_gaps++;
            sink_k = int'(smp[19:0]);
        end else if (int'(smp[19:0]) != sink_k) begin
            if (errors < 10) $display("ERROR tx: frame mixed within a frame");
            errors++;
        end
        if (sink_exp_c == N_CH - 1) sink_frames++;
        sink_exp_c = (sink_exp_c + 1) % N_CH;
    end

    // =========================================================================
    // sequence
    // =========================================================================
    task automatic frames(input int n);
        repeat (n) @(posedge frame_i);
    endtask

    int st0, ur0, te0, ov0;

    initial begin
        $display("tb_pcm_link: N_CH=%0d, aclk 100 MHz, mclk 12.2919 MHz", N_CH);
        #200 aresetn = 1; rst_n = 1;

        // ---- A: paced ----
        frames(60);
        if (got_frames < 50) begin
            $display("ERROR A: only %0d frames delivered while paced", got_frames);
            errors++;
        end
        $display("A paced     : %0d frames, %0d zero frames (start-up), fill %0d words",
                 got_frames, got_zero, rx_fill);

        // ---- B: burst (back-pressure, nothing lost) ----
        unpaced = 1;
        frames(40);
        if (!(rx_fill > 16'(N_CH * 4))) begin
            $display("ERROR B: FIFO did not fill under a burst (fill %0d)", rx_fill);
            errors++;
        end
        $display("B burst     : fill %0d words, underruns %0d", rx_fill, underruns);
        unpaced = 0;
        @(posedge aclk) allowed = sent;           // back to paced from here

        // ---- C: pause ----
        frames(20);
        st0 = starved; ur0 = underruns;
        src_stop = 1;
        frames(PAUSE + 20);                       // drain the buffered frames, then starve
        src_stop = 0;
        @(posedge aclk) allowed = sent + 2;
        frames(20);
        if (starved - st0 < 5 || underruns - ur0 != 1) begin
            $display("ERROR C: starved +%0d (want >= 5), underruns +%0d (want 1)",
                     starved - st0, underruns - ur0);
            errors++;
        end
        $display("C pause     : starved +%0d, underruns +%0d, running again %0d",
                 starved - st0, underruns - ur0, rx_running);

        // ---- D: TID error ----
        te0 = tid_errors;
        bad_frame = sent + 3;
        frames(20);
        if (tid_errors - te0 != N_CH - 2 || skips != 1) begin
            $display("ERROR D: tid_errors +%0d (want %0d), frames lost %0d (want 1)",
                     tid_errors - te0, N_CH - 2, skips);
            errors++;
        end
        $display("D TID error : tid_errors +%0d, frames lost %0d", tid_errors - te0, skips);

        // ---- PL -> PS: stall the sink ----
        ov0 = overruns;
        sink_stall = 1;
        frames(40);
        sink_stall = 0;
        frames(20);
        if (overruns - ov0 < 20 || sink_gaps != 1) begin
            $display("ERROR tx: overruns +%0d (want >= 20), gaps in the stream %0d (want 1)",
                     overruns - ov0, sink_gaps);
            errors++;
        end
        if (sink_frames < 100) begin
            $display("ERROR tx: only %0d frames reached the sink", sink_frames);
            errors++;
        end
        $display("tx stall    : overruns +%0d, one gap %0d, %0d frames sunk, frames_tx %0d",
                 overruns - ov0, sink_gaps, sink_frames, frames_tx);

        if (errors == 0) $display("PASS tb_pcm_link");
        else             $display("FAIL tb_pcm_link: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #30ms;
        $display("FAIL tb_pcm_link: timeout");
        $finish;
    end

endmodule
