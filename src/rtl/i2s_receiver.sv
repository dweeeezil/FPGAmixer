// -----------------------------------------------------------------------------
// i2s_receiver.sv
//
// Deserializes an I2S bit stream into parallel left/right 24-bit registers.
// Runs entirely in the mclk domain; SCLK and LRCK are treated as sampled
// signals with edges detected by 2FF-registered comparison.
//
// Assumes standard Philips I2S format:
//   - LRCK = 0 -> left channel active
//   - LRCK = 1 -> right channel active
//   - Data changes on falling SCLK edge (at the transmitter)
//   - Data is sampled on rising SCLK edge (at the receiver)
//   - MSB of a new word appears one SCLK cycle AFTER LRCK transitions
//     (the intervening bit is the "delay bit" and is ignored)
//   - Data is MSB-first, DATA_WIDTH bits (default 24)
//
// Timing (referenced from LRCK transition, ignoring mclk-domain register
// delays which shift everything by ~1 mclk cycle):
//
//   LRCK edge (rising or falling)
//     |
//     | <-- 1 SCLK cycle: "delay bit" (ignored)
//     |
//     v
//   MSB sampled on next SCLK rising edge
//     |
//     | <-- 23 more SCLK cycles
//     |
//     v
//   LSB sampled
//
// The `sample_valid` output pulses for one mclk cycle when a complete stereo
// pair (both left AND right) is available on {left_data, right_data}. It fires
// on the LRCK transition that ends the right channel (i.e., LRCK going low).
// -----------------------------------------------------------------------------
module i2s_receiver #(
    parameter int DATA_WIDTH = 24
) (
    input  logic mclk,
    input  logic rst_n,

    // I2S signals (from ADC, or from the same divider that drives the ADC)
    input  logic sclk_i,
    input  logic lrck_i,
    input  logic sdata_i,

    // Parallel output
    output logic [DATA_WIDTH-1:0] left_data,
    output logic [DATA_WIDTH-1:0] right_data,
    output logic                  sample_valid  // 1-cycle pulse
);

    // ----- Input registering and edge detection -----
    logic sclk_r, sclk_prev;
    logic lrck_r, lrck_prev;
    logic sdata_r;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_r    <= 1'b0;
            sclk_prev <= 1'b0;
            lrck_r    <= 1'b0;
            lrck_prev <= 1'b0;
            sdata_r   <= 1'b0;
        end else begin
            sclk_r    <= sclk_i;
            sclk_prev <= sclk_r;
            lrck_r    <= lrck_i;
            lrck_prev <= lrck_r;
            sdata_r   <= sdata_i;
        end
    end

    wire sclk_rising  = sclk_r && !sclk_prev;
    wire lrck_changed = (lrck_r != lrck_prev);

    // ----- Deserialization -----
    logic [DATA_WIDTH-1:0] shift_reg;
    logic [5:0]            bit_counter;   // 0..DATA_WIDTH+1
    logic                  channel_prev;  // The channel we WERE receiving

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg    <= '0;
            bit_counter  <= 6'd0;
            left_data    <= '0;
            right_data   <= '0;
            channel_prev <= 1'b0;
            sample_valid <= 1'b0;
        end else begin
            sample_valid <= 1'b0;  // default: no pulse this cycle

            if (lrck_changed) begin
                // End of a word - latch whatever we captured to the channel
                // register indicated by channel_prev (the channel we WERE on).
                if (channel_prev == 1'b0)
                    left_data  <= shift_reg;
                else
                    right_data <= shift_reg;

                // Finishing a right channel means a full stereo pair is ready.
                if (channel_prev == 1'b1)
                    sample_valid <= 1'b1;

                // Prepare to receive the new channel.
                channel_prev <= lrck_r;   // NEW channel (what we're on now)
                bit_counter  <= 6'd0;
                shift_reg    <= '0;
            end
            else if (sclk_rising) begin
                if (bit_counter == 6'd0) begin
                    // First SCLK rising edge after LRCK edge - the "delay
                    // bit". Skip it, advance the counter.
                    bit_counter <= 6'd1;
                end
                else if (bit_counter <= DATA_WIDTH[5:0]) begin
                    // Shift in bits 1..DATA_WIDTH (bit_counter = 1 -> MSB,
                    // bit_counter = DATA_WIDTH -> LSB).
                    shift_reg   <= {shift_reg[DATA_WIDTH-2:0], sdata_r};
                    bit_counter <= bit_counter + 6'd1;
                end
                // else: past LSB, ignore trailing bits until next LRCK edge
            end
        end
    end

endmodule
