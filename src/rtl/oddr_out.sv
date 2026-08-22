// -----------------------------------------------------------------------------
// oddr_out.sv
//
// Single-pin output forwarder through a 7-series ODDR (UG471), so the launch
// instant of every codec-facing pin is pinned to the MCLK network through the
// dedicated OLOGIC->OBUF path instead of general fabric routing.
//
// Two usage patterns (see phase3_top):
//   clock forwarding : d1=1'b1, d2=1'b0 -> reconstructs `clk` at the pin
//   SDR re-launch    : d1=d2=<signal>   -> signal re-registered on the `clk`
//                                          rising edge (+1 clk pin latency)
//
// INVARIANT (docs/handoff_codec_interface_timing.md 4.2): SCLK, LRCK and SDIN
// must ALL use the identical SDR pattern on the same clock, so all three get
// the same +1 MCLK launch latency and their relative pin alignment survives.
// Forwarding some of them through ODDR and others combinationally re-creates
// the Phase 3 pin-phase race (docs/bugfix_2026-08-14_phase3-noise.md).
//
// SIM_ODDR: the ODDR primitive doesn't elaborate under Icarus, so a
// behavioral model stands in (same SAME_EDGE latency semantics). The define
// is set by scripts/sim.mk only; Vivado synthesis must see the real
// primitive. Precedent: src/sim/clk_wiz_audio_stub.sv.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module oddr_out (
    input  logic clk,  // mclk (BUFG) -- the one clock all codec pins launch from
    input  logic d1,   // presented at the pin after the clk rising edge
    input  logic d2,   // presented at the pin after the clk falling edge
    output logic q     // to output pad
);

`ifdef SIM_ODDR
    // Behavioral ODDR, DDR_CLK_EDGE="SAME_EDGE": both D inputs are captured
    // on the rising clk edge; Q shows d1 from the rising edge and the
    // captured d2 from the following falling edge.
    logic d2_hold;
    always @(posedge clk) d2_hold <= d2;
    always @(clk) begin
        if (clk) q <= d1;       // rising edge: launch d1
        else     q <= d2_hold;  // falling edge: launch d2 (captured at rise)
    end
`else
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr (
        .Q  (q),
        .C  (clk),
        .CE (1'b1),
        .D1 (d1),
        .D2 (d2),
        .R  (1'b0),
        .S  (1'b0)
    );
`endif

endmodule
