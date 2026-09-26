// -----------------------------------------------------------------------------
// pcm_stream2pack.sv
//
// Core boundary converter (generic): PCM stream contract -> packed PCM
// contract (docs/architecture_modules.md 2 and 2.1). Knows nothing about what
// the channels are or what produced them.
//
// Beats are collected by s_ch into a staging register. The beat for the last
// channel (N-1) completes the frame: on the next edge ALL channels move to
// out_flat together and valid_o pulses, so downstream sees the whole frame
// change on one edge, as the packed contract promises.
//
// Stated timing: out_flat/valid_o update 1 cycle after the producer's last
// beat. With pcm_pack2stream straight in front (LAST_BEAT = N): cycle N+1
// after the strobe. The cycle at which the core's outputs update is the
// core's latency D (phase9_status_2026-09-26.md 5.1, C2).
//
// Checking (the stream carries s_ch for this): err_o pulses for one cycle when
//   - a beat arrives with a channel other than the expected next one
//     (out of order, repeated, or skipped), or
//   - a strobe arrives while a frame is incomplete (beats started, last one
//     missing).
// A frame with an error is still delivered if its last beat arrives; the
// channels that were missed keep their previous values. err_o is for status
// counters and TB monitors; it never blocks audio.
// -----------------------------------------------------------------------------
module pcm_stream2pack #(
    parameter int N  = 12,    // channels
    parameter int SW = 24,    // sample width
    localparam int CW = (N > 1) ? $clog2(N) : 1
) (
    input  logic            mclk,
    input  logic            rst_n,
    input  logic            frame_i,

    input  logic            s_valid,
    input  logic [CW-1:0]   s_ch,
    input  logic [SW-1:0]   s_data,

    output logic [N*SW-1:0] out_flat,   // packed: ch c = [c*SW +: SW], signed
    output logic            valid_o,    // one pulse per completed frame
    output logic            err_o
);

    logic [N*SW-1:0] stage;
    logic [CW:0]     expect_ch;   // next channel expected; 0 = frame not started

    wire last_beat = s_valid && (s_ch == CW'(N-1));

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            stage     <= '0;
            out_flat  <= '0;
            valid_o   <= 1'b0;
            err_o     <= 1'b0;
            expect_ch <= '0;
        end else begin
            valid_o <= 1'b0;
            err_o   <= 1'b0;

            if (s_valid) begin
                // s_ch < N for a well-formed stream; an out-of-range index
                // is only flagged, never written.
                if ((CW+1)'(s_ch) < (CW+1)'(N))
                    stage[s_ch*SW +: SW] <= s_data;
                if ((CW+1)'(s_ch) != expect_ch)
                    err_o <= 1'b1;
                expect_ch <= (CW+1)'(s_ch) + 1'b1;
            end

            if (last_beat) begin
                // The last beat goes straight to the output with the rest.
                for (int c = 0; c < N; c++)
                    out_flat[c*SW +: SW] <= (c == N-1) ? s_data : stage[c*SW +: SW];
                valid_o   <= 1'b1;
                expect_ch <= '0;
            end

            if (frame_i) begin
                if (expect_ch != '0 && !last_beat)
                    err_o <= 1'b1;          // previous frame never completed
                if (!s_valid)
                    expect_ch <= '0;
            end
        end
    end

endmodule
