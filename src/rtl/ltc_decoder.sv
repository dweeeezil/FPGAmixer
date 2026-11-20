// -----------------------------------------------------------------------------
// ltc_decoder.sv
//
// Decodes LTC (SMPTE 12M linear timecode) from one audio signal, one sample per
// frame strobe. A listener: it has no path back into the audio. It knows
// nothing about ports, registers or the mixer
// (docs/timecode_proposal_2026-11-18.md).
//
// ----- The signal -----
// LTC is biphase mark: the level flips at the start of every bit, and once more
// in mid-bit for a 1. At 48 kHz a bit is 20 samples (30 fps) to 25 (24 fps), so
//   half bit (one of a 1's two intervals) : 10 .. 12.5 samples
//   full bit (a 0)                        : 20 .. 25 samples
// Only the transitions carry data, so polarity and level don't matter.
//
// ----- The stages (each runs once per sample) -----
//   1. Slicer: the level follows the sample's sign, with hysteresis +/-TH.
//   2. Interval: samples since the last transition.
//        HALF_MIN .. HALF_MAX = a half bit,  FULL_MIN .. FULL_MAX = a full bit,
//        anything else (a glitch, or silence) = lost: restart.
//      These bounds hold every rate from 0.85x to 1.2x of its speed.
//   3. Bits: a full bit is 0, two half bits are 1. A full bit while a half bit
//      waits for its partner = lost: restart (it also realigns the pairing).
//   4. Frame: the bits go through an 80-bit shift register, newest at the top.
//      When the newest 16 are the sync word and exactly 80 good bits have
//      arrived since a previous sync word, the frame is reported. So the first
//      frame after a restart is never reported: its start may be missing. A
//      frame's last bit is a 1, so it is known at the next frame's first edge.
//
// ----- Outputs (mclk; all change together on the edge a frame is reported) -----
//   tc_data       : LTC bits 63:0 of the last frame reported
//   frames        : frames reported since reset (wraps)
//   frame_samples : samples between the last two sync words
// and, updated every sample:
//   signal        : a transition within the last HOLD samples
//   locked        : a frame reported within the last HOLD samples
//
// clear restarts everything but the counter `frames` (the source has changed).
// -----------------------------------------------------------------------------
module ltc_decoder #(
    parameter int SW       = 24,
    parameter int TH       = 32768,     // hysteresis, about -48 dBFS at 24 bits
    parameter int HOLD     = 4800,      // samples (100 ms at 48 kHz)
    parameter int HALF_MIN = 7,
    parameter int HALF_MAX = 15,
    parameter int FULL_MIN = 16,
    parameter int FULL_MAX = 31
) (
    input  logic                 mclk,
    input  logic                 rst_n,
    input  logic                 clear,
    input  logic                 sample_valid,
    input  logic signed [SW-1:0] sample,

    output logic [63:0]          tc_data,
    output logic [31:0]          frames,
    output logic [15:0]          frame_samples,
    output logic                 signal,
    output logic                 locked
);

    // The sync word, bits 64..79 of the frame, as it sits in the shift register
    // (bit 79, the newest, at the top): sent as 0011 1111 1111 1101.
    localparam logic [15:0] SYNC_WORD = 16'hBFFC;
    localparam int          BITS      = 80;
    localparam int          IW        = $clog2(FULL_MAX + 2);
    localparam int          HW        = $clog2(HOLD + 1);

    logic              level;
    logic [IW-1:0]     interval;
    logic              pending;      // a half bit waits for its partner
    logic [BITS-1:0]   shift;
    logic [6:0]        bit_count;    // good bits since the previous sync; stops at 81
    logic              have_sync;    // a sync word has been seen since the last restart
    logic [15:0]       samples;      // samples since the previous sync word; stops at the top
    logic [HW-1:0]     signal_hold, lock_hold;

    // ----- one sample's decisions (combinational) -----
    logic signed [SW-1:0] th_pos, th_neg;
    assign th_pos =  SW'(TH);
    assign th_neg = -SW'(TH);

    logic next_level, edge_seen, is_half, is_full, too_long, lost, new_bit, bit_value;
    logic [BITS-1:0] next_shift;
    logic [6:0]      next_count;
    logic            sync_seen, report;

    always_comb begin
        next_level = level;
        if (sample > th_pos)      next_level = 1'b1;
        else if (sample < th_neg) next_level = 1'b0;

        edge_seen = (next_level != level);
        is_half   = edge_seen && interval >= IW'(HALF_MIN) && interval <= IW'(HALF_MAX);
        is_full   = edge_seen && interval >= IW'(FULL_MIN) && interval <= IW'(FULL_MAX);
        too_long  = (interval > IW'(FULL_MAX));

        lost      = (edge_seen && !is_half && !is_full) || too_long || (is_full && pending);
        new_bit   = !lost && (is_full || (is_half && pending));
        bit_value = is_half;

        next_shift = {bit_value, shift[BITS-1:1]};
        next_count = (bit_count == 7'(BITS + 1)) ? bit_count : bit_count + 7'd1;
        sync_seen  = new_bit && (next_shift[BITS-1:BITS-16] == SYNC_WORD);
        report     = sync_seen && have_sync && (next_count == 7'(BITS));
    end

    always_ff @(posedge mclk) begin
        if (!rst_n) begin
            level         <= 1'b0;
            interval      <= '0;
            pending       <= 1'b0;
            shift         <= '0;
            bit_count     <= '0;
            have_sync     <= 1'b0;
            samples       <= '0;
            signal_hold   <= '0;
            lock_hold     <= '0;
            tc_data       <= '0;
            frames        <= '0;
            frame_samples <= '0;
        end else if (clear) begin
            interval      <= '0;
            pending       <= 1'b0;
            shift         <= '0;
            bit_count     <= '0;
            have_sync     <= 1'b0;
            samples       <= '0;
            signal_hold   <= '0;
            lock_hold     <= '0;
        end else if (sample_valid) begin
            level <= next_level;

            // the interval: restarts at a transition, stops just past the longest
            if (edge_seen)     interval <= IW'(1);
            else if (!too_long) interval <= interval + IW'(1);

            if (samples != 16'hFFFF) samples <= samples + 16'd1;

            if (lost) begin
                pending   <= 1'b0;
                bit_count <= '0;
                have_sync <= 1'b0;
            end else if (is_half && !pending) begin
                pending   <= 1'b1;
            end else if (new_bit) begin
                pending   <= 1'b0;
                shift     <= next_shift;
                bit_count <= sync_seen ? 7'd0 : next_count;
                if (sync_seen) have_sync <= 1'b1;
            end

            if (sync_seen) samples <= 16'd1;
            if (report) begin
                tc_data       <= next_shift[63:0];
                frames        <= frames + 32'd1;
                frame_samples <= samples;
            end

            if (edge_seen)                signal_hold <= HW'(HOLD);
            else if (signal_hold != '0)   signal_hold <= signal_hold - HW'(1);
            if (report)                   lock_hold   <= HW'(HOLD);
            else if (lock_hold != '0)     lock_hold   <= lock_hold - HW'(1);
        end
    end

    assign signal = (signal_hold != '0);
    assign locked = (lock_hold != '0);

endmodule
