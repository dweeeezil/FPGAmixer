// -----------------------------------------------------------------------------
// pcm_patch2stream.sv
//
// Core boundary converter with the INPUT PATCH (Phase 15, decision CS1): the
// packed PCM contract of the I/O ports -> the PCM stream contract of the
// core's input channels (docs/architecture_modules.md 2 and 2.1). Each
// channel k takes the I/O port its source entry names:
//
//   source[k] = 0        None: channel k is silence
//   source[k] = p + 1    channel k = port p   (p < P)
//   source[k] > P        silence (never written by the server)
//
// Any number of channels may name the same port. Knows nothing about what the
// ports or channels are (the platform's port map, the server's patch).
//
// The source table arrives through a coefficient READ PORT (coef_addr ->
// coef_data one cycle later; coef_bank_ram or coef_flat_reader with
// ROW_LEN 1, N_ROWS = N, LANES 1, W = $clog2(P+1)): word k is source[k].
//
// ----- Timing -----
//   frame_i (cycle 0)  : in_flat is captured; the reads start
//   cycles 0 .. N-1    : coef_addr = k (read k is issued in cycle k)
//   cycles 2 .. N+1    : one beat per cycle, s_ch = 0, 1, .. N-1, ascending
// Stated timing (PCM stream contract): FIRST_BEAT = 2, LAST_BEAT = N + 1,
// contiguous: one cycle later than pcm_pack2stream, the read port's latency.
// Reading earlier is not possible: a read issued in the strobe cycle still
// sees the previous bank (coef_bank_ram), and the first read after the
// strobe is in cycle 0. Every read of a frame is issued in cycles 0 .. N-1,
// so a frame uses one table.
//
// in_flat only has to be stable on the strobe edge (as for the packed
// contract): it is copied into a register there, so the front doors are free
// to change it during the frame. A strobe arriving before the previous frame
// has been sent restarts the stream with the new frame; it cannot happen with
// N + 1 < FRAME_CYCLES, which is checked at elaboration.
// -----------------------------------------------------------------------------
module pcm_patch2stream #(
    parameter int P            = 20,    // I/O ports (packed input)
    parameter int N            = 20,    // channels (stream output)
    parameter int SW           = 24,    // sample width
    parameter int FRAME_CYCLES = 256,   // mclk cycles per frame (LRCK = mclk/256)
    localparam int CW          = (N > 1) ? $clog2(N) : 1,
    localparam int PW          = $clog2(P + 1)          // a table entry: 0 .. P
) (
    input  logic            mclk,
    input  logic            rst_n,
    input  logic            frame_i,
    input  logic [P*SW-1:0] in_flat,    // packed: port p = [p*SW +: SW], signed
    // ----- source table read port -----
    output logic [CW-1:0]   coef_addr,
    input  logic [PW-1:0]   coef_data,
    // ----- output stream -----
    output logic            s_valid,
    output logic [CW-1:0]   s_ch,
    output logic [SW-1:0]   s_data
);

    localparam int FIRST_BEAT = 2;
    localparam int LAST_BEAT  = N + 1;

    generate
        if (LAST_BEAT >= FRAME_CYCLES)
            $error("pcm_patch2stream: %0d channels do not fit a %0d-cycle frame",
                   N, FRAME_CYCLES);
        if (P < 1)
            $error("pcm_patch2stream: no ports");
    endgenerate

    logic [P*SW-1:0] cap;       // the frame's ports, captured on the strobe
    logic [CW:0]     rd_idx;    // next read to issue; N = all issued
    logic            v1;        // a read was issued last cycle ...
    logic [CW-1:0]   c1;        // ... for this channel

    assign coef_addr = rd_idx[CW-1:0];

    // The port a table entry names, or silence.
    function automatic logic [SW-1:0] pick(input logic [P*SW-1:0] ports,
                                           input logic [PW-1:0] src);
        logic [SW-1:0] s;
        s = '0;
        for (int p = 0; p < P; p++)
            if (src == PW'(p + 1)) s = ports[p*SW +: SW];
        return s;
    endfunction

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            cap     <= '0;
            rd_idx  <= (CW+1)'(N);
            v1      <= 1'b0;
            c1      <= '0;
            s_valid <= 1'b0;
            s_ch    <= '0;
            s_data  <= '0;
        end else begin
            // stage 2: the entry is here; emit the beat
            s_valid <= v1;
            s_ch    <= c1;
            s_data  <= v1 ? pick(cap, coef_data) : '0;
            // stage 1: issue the reads, one per cycle after the strobe
            v1 <= 1'b0;
            if (frame_i) begin
                cap    <= in_flat;
                rd_idx <= '0;
                v1     <= 1'b0;
            end else if (rd_idx != (CW+1)'(N)) begin
                v1     <= 1'b1;
                c1     <= rd_idx[CW-1:0];
                rd_idx <= rd_idx + 1'b1;
            end
        end
    end

endmodule
