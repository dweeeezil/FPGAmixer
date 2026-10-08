// -----------------------------------------------------------------------------
// pcm_stream2patch.sv
//
// Core boundary converter with the OUTPUT PATCH (Phase 15, decision CS1): the
// PCM stream contract of the core's output channels -> the packed PCM
// contract of the I/O ports (docs/architecture_modules.md 2 and 2.1). Each
// channel c feeds the I/O port its destination entry names:
//
//   destination[c] = 0       None: channel c feeds nothing
//   destination[c] = p + 1   port p carries channel c   (p < P)
//   destination[c] > P       nothing (never written by the server)
//
// A port no channel names is silence. A port belongs to at most one channel
// (the server's rule, OSC standard "I/O patch"); if two name the same port
// anyway, the later channel in the frame wins, deterministically. Knows
// nothing about what the ports or channels are.
//
// The destination table arrives through a coefficient READ PORT (coef_addr ->
// coef_data one cycle later; coef_bank_ram or coef_flat_reader with
// ROW_LEN 1, N_ROWS = N, LANES 1, W = $clog2(P+1)): word c is destination[c].
// The address is the beat's channel, as in pcm_gain, so all of a frame's
// reads fall between its two strobes and each frame uses one table.
//
// ----- Timing (cycle b = an input beat's cycle) -----
//   b+1  the beat is registered; its table entry arrives
//   b+2  the beat is in its port's slot. The beat for channel 0 starts the
//        frame with every slot silent; the beat for channel N-1 completes it:
//        ALL ports move to out_flat on that edge and valid_o pulses.
// Stated timing: out_flat/valid_o update 2 cycles after the producer's last
// beat (pcm_stream2pack: 1). The cycle at which the core's outputs update is
// the core's latency D (mixer_core_pkg).
//
// Checking (as pcm_stream2pack, on the input beats): err_o pulses for one
// cycle when a beat arrives with a channel other than the expected next one,
// or a strobe arrives while a frame is incomplete. A frame with an error is
// still delivered if its last beat arrives; err_o never blocks audio.
// -----------------------------------------------------------------------------
module pcm_stream2patch #(
    parameter int N  = 20,    // channels (stream input)
    parameter int P  = 20,    // I/O ports (packed output)
    parameter int SW = 24,    // sample width
    localparam int CW = (N > 1) ? $clog2(N) : 1,
    localparam int PW = $clog2(P + 1)           // a table entry: 0 .. P
) (
    input  logic            mclk,
    input  logic            rst_n,
    input  logic            frame_i,
    input  logic            s_valid,
    input  logic [CW-1:0]   s_ch,
    input  logic [SW-1:0]   s_data,
    // ----- destination table read port -----
    output logic [CW-1:0]   coef_addr,
    input  logic [PW-1:0]   coef_data,
    // ----- output -----
    output logic [P*SW-1:0] out_flat,   // packed: port p = [p*SW +: SW], signed
    output logic            valid_o,    // one pulse per completed frame
    output logic            err_o
);

    generate
        if (P < 1)
            $error("pcm_stream2patch: no ports");
    endgenerate

    assign coef_addr = s_ch;

    // stage 1: the beat, waiting for its table entry
    logic          v1;
    logic [CW-1:0] c1;
    logic [SW-1:0] d1;
    logic [P*SW-1:0] stage;     // the frame's ports so far

    always_ff @(posedge mclk or negedge rst_n) begin
        logic [P*SW-1:0] nxt;
        if (!rst_n) begin
            v1       <= 1'b0;
            c1       <= '0;
            d1       <= '0;
            stage    <= '0;
            out_flat <= '0;
            valid_o  <= 1'b0;
        end else begin
            v1 <= s_valid;
            c1 <= s_ch;
            d1 <= s_data;
            valid_o <= 1'b0;
            if (v1) begin
                // channel 0 opens a frame: every port silent until named
                nxt = (c1 == '0) ? '0 : stage;
                for (int p = 0; p < P; p++)
                    if (coef_data == PW'(p + 1)) nxt[p*SW +: SW] = d1;
                stage <= nxt;
                if (c1 == CW'(N - 1)) begin
                    out_flat <= nxt;
                    valid_o  <= 1'b1;
                end
            end
        end
    end

    // ----- stream check (the same rules as pcm_stream2pack) -----
    logic [CW:0] expect_ch;     // next channel expected; 0 = frame not started
    wire last_beat = s_valid && (s_ch == CW'(N - 1));

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            err_o     <= 1'b0;
            expect_ch <= '0;
        end else begin
            err_o <= 1'b0;
            if (s_valid) begin
                if ((CW+1)'(s_ch) != expect_ch)
                    err_o <= 1'b1;
                expect_ch <= (CW+1)'(s_ch) + 1'b1;
            end
            if (last_beat)
                expect_ch <= '0;
            if (frame_i) begin
                if (expect_ch != '0 && !last_beat)
                    err_o <= 1'b1;          // previous frame never completed
                if (!s_valid)
                    expect_ch <= '0;
            end
        end
    end

endmodule
