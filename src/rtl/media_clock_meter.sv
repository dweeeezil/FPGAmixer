// -----------------------------------------------------------------------------
// media_clock_meter.sv
//
// Platform block (Phase 9, P9.3): measures the audio clock (mclk) against an
// external once-per-second reference. In fpgamixer_top the reference is the
// GEM TSU's 1PPS (the inverse of tsu_timer_cnt[45], UG1085 v2.5 p. 1061), so
// it measures mclk against gPTP time -- the board's own PHC, in either gPTP
// role. Generic otherwise: it knows nothing about gPTP or audio data.
//
// On every rising edge of pps_async (asynchronous; synchronized here) it
// captures, all on the same mclk edge:
//   cyc_last    the free-running 32-bit mclk cycle count
//   cyc_prev    the previous capture (so software gets an interval from one
//               consistent snapshot)
//   frames_last the frame-strobe count (frame_i pulses)
//   phase_last  mclk cycles since the last frame strobe (0 .. 255 while
//               frames run; saturates at 0xFFFF if they stop)
// and counts:
//   pps_count   PPS edges seen
//   implausible intervals outside NOMINAL +/- TOL cycles (e.g. when ptp4l
//               steps the PHC, or the reference drops out); the first edge
//               has no interval and isn't counted
//
// Software computes frequency and phase from these (decision T2): e.g.
//   offset_ppm = ((cyc_last - cyc_prev) mod 2^32 - NOMINAL) / NOMINAL * 1e6
// Resolution: +/-1 mclk per edge (81 ns at 12.288 MHz), i.e. +/-0.08 ppm per
// 1-second interval, averaging down over longer spans.
//
// Timing: the capture happens 3 mclk after the PPS edge reaches
// the synchronizer (2 FF + edge detect), a constant, plus 0..1 mclk of
// synchronizer uncertainty. Constant offsets cancel in intervals; for phase
// they are a fixed offset that P9.4 calibrates or ignores.
//
// CDC: pps_async -> pps_s1 is the only crossing (1 bit, ASYNC_REG);
// constraints/media_clock_meter.xdc (SCOPED_TO_REF) marks it.
// -----------------------------------------------------------------------------
module media_clock_meter #(
    parameter int NOMINAL = 12_288_000,   // mclk cycles per reference second
    parameter int TOL     = 12_288        // plausibility window: +/-1000 ppm
) (
    input  logic        mclk,
    input  logic        rst_n,
    input  logic        pps_async,        // rises once per second, async
    input  logic        frame_i,          // the core's frame strobe

    output logic [31:0] pps_count,
    output logic [31:0] cyc_last,
    output logic [31:0] cyc_prev,
    output logic [31:0] frames_last,
    output logic [15:0] phase_last,
    output logic [31:0] implausible,
    output logic [31:0] cyc_now           // the free-running count itself
);

    // ----- synchronizer + rising-edge detect -----
    (* ASYNC_REG = "TRUE" *) logic pps_s1, pps_s2;
    logic pps_s3;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            pps_s1 <= 1'b0; pps_s2 <= 1'b0; pps_s3 <= 1'b0;
        end else begin
            pps_s1 <= pps_async;
            pps_s2 <= pps_s1;
            pps_s3 <= pps_s2;
        end
    end

    wire pps_rise = pps_s2 && !pps_s3;

    // ----- free-running counts -----
    logic [31:0] frames;
    logic [15:0] phase;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            cyc_now <= '0;
            frames  <= '0;
            phase   <= 16'hFFFF;
        end else begin
            cyc_now <= cyc_now + 1'b1;
            if (frame_i) begin
                frames <= frames + 1'b1;
                phase  <= '0;
            end else if (phase != 16'hFFFF) begin
                phase <= phase + 1'b1;
            end
        end
    end

    // ----- captures -----
    wire [31:0] delta = cyc_now - cyc_last;     // valid when pps_count != 0

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            pps_count   <= '0;
            cyc_last    <= '0;
            cyc_prev    <= '0;
            frames_last <= '0;
            phase_last  <= '0;
            implausible <= '0;
        end else if (pps_rise) begin
            pps_count   <= pps_count + 1'b1;
            cyc_prev    <= cyc_last;
            cyc_last    <= cyc_now;
            frames_last <= frames;
            phase_last  <= phase;
            if (pps_count != 0 &&
                (delta < 32'(NOMINAL - TOL) || delta > 32'(NOMINAL + TOL)))
                implausible <= implausible + 1'b1;
        end
    end

endmodule
