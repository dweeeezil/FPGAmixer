// -----------------------------------------------------------------------------
// pcm_pack2stream.sv
//
// Core boundary converter (generic): packed PCM contract -> PCM stream
// contract (docs/architecture_modules.md 2 and 2.1). Knows nothing about what
// the channels are or what consumes them.
//
//   frame_i (cycle 0) : in_flat is captured
//   cycles 1 .. N     : one beat per cycle, s_ch = 0, 1, .. N-1, ascending
//
// Stated timing (PCM stream contract): FIRST_BEAT = 1, LAST_BEAT = N cycles
// after the strobe, contiguous. "Cycle c" is the c-th mclk edge after the one
// that samples frame_i high, i.e. s_valid is high in cycles 1..N.
//
// in_flat only has to be stable on the strobe edge (as for the packed
// contract): it is copied into a shift register there, so the front doors are
// free to change it during the frame.
//
// A strobe arriving before the previous frame has been sent restarts the
// stream with the new frame. It cannot happen with N < FRAME_CYCLES, which is
// checked at elaboration.
// -----------------------------------------------------------------------------
module pcm_pack2stream #(
    parameter int N            = 12,    // channels
    parameter int SW           = 24,    // sample width
    parameter int FRAME_CYCLES = 256,   // mclk cycles per frame (LRCK = mclk/256)
    localparam int CW          = (N > 1) ? $clog2(N) : 1
) (
    input  logic            mclk,
    input  logic            rst_n,
    input  logic            frame_i,

    input  logic [N*SW-1:0] in_flat,    // packed: ch c = [c*SW +: SW], signed

    output logic            s_valid,
    output logic [CW-1:0]   s_ch,
    output logic [SW-1:0]   s_data
);

    localparam int FIRST_BEAT = 1;
    localparam int LAST_BEAT  = N;

    generate
        if (LAST_BEAT >= FRAME_CYCLES)
            $error("pcm_pack2stream: %0d channels do not fit a %0d-cycle frame",
                   N, FRAME_CYCLES);
    endgenerate

    logic [N*SW-1:0] shift;     // channel 0 at the bottom, shifted down per beat
    logic [CW:0]     idx;       // next channel to send; N = frame done

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            shift   <= '0;
            idx     <= (CW+1)'(N);
            s_valid <= 1'b0;
            s_ch    <= '0;
            s_data  <= '0;
        end else begin
            s_valid <= 1'b0;
            if (frame_i) begin
                shift <= in_flat;
                idx   <= '0;
            end else if (idx != (CW+1)'(N)) begin
                s_valid <= 1'b1;
                s_ch    <= idx[CW-1:0];
                s_data  <= shift[0 +: SW];
                shift   <= shift >> SW;
                idx     <= idx + 1'b1;
            end
        end
    end

endmodule
