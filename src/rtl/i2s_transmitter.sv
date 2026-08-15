// -----------------------------------------------------------------------------
// i2s_transmitter.sv
//
// Serializes parallel 24-bit left/right samples into an I2S bit stream.
// Same MCLK domain and Philips I2S framing as i2s_receiver (data changes on
// falling SCLK edge, MSB delayed by one SCLK cycle from the LRCK transition).
//
// On every LRCK transition, the appropriate channel's sample is loaded into
// the shift register based on the NEW LRCK level:
//   LRCK just went to 0 -> load left_data
//   LRCK just went to 1 -> load right_data
//
// The first falling SCLK edge after the LRCK transition drives the "delay
// bit" (zero). The next 24 falling SCLK edges drive MSB..LSB. Any remaining
// falling SCLK edges in the LRCK half-period drive zero.
//
// PIN-PHASE CONSTRAINT -- why edge detection here is 1FF, not 2FF:
// sclk/lrck (divider bits) and sdata_o are all mclk-registered, so every pin
// transition lands on an mclk posedge, and with SCLK = mclk/4 a half SCLK
// period is exactly 2 mclk. Detecting edges through two registered copies
// adds 2 mclk of latency, which launches sdata_o exactly ON the SCLK rising
// edge at the pins -- the edge the external DAC samples -- and leaves the
// captured bit to per-build routing skew. Comparing sclk_i/lrck_i against a
// single registered copy launches sdata_o one mclk after the falling edge
// instead: mid-cell, stable across the rising edge, ~81 ns setup / ~244 ns
// hold at the DAC pin. This is only safe because sclk_i/lrck_i are
// synchronous same-mclk-domain divider outputs, never external/async inputs:
// do not add FFs back "for metastability", and do not reuse this detection
// with clocks from another domain. The contract "sdata_o only changes while
// SCLK is low" is regression-checked by tb_i2s_tx_pin_phase.
// -----------------------------------------------------------------------------
module i2s_transmitter #(
    parameter int DATA_WIDTH = 24
) (
    input  logic mclk,
    input  logic rst_n,

    input  logic sclk_i,
    input  logic lrck_i,

    input  logic [DATA_WIDTH-1:0] left_data,
    input  logic [DATA_WIDTH-1:0] right_data,

    output logic sdata_o
);

    // ----- Edge detection (1FF-early; see PIN-PHASE CONSTRAINT above) -----
    logic sclk_r, lrck_r;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_r <= 1'b0;
            lrck_r <= 1'b0;
        end else begin
            sclk_r <= sclk_i;
            lrck_r <= lrck_i;
        end
    end

    wire sclk_falling = !sclk_i && sclk_r;
    wire lrck_changed = (lrck_i != lrck_r);

    // ----- Serialization -----
    logic [DATA_WIDTH-1:0] shift_reg;
    logic [5:0]            bit_counter;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg   <= '0;
            bit_counter <= 6'd0;
            sdata_o     <= 1'b0;
        end else begin
            if (lrck_changed) begin
                // Load new channel data. lrck_i already holds the NEW level
                // here (lrck_r is still the old one): 0 -> left, 1 -> right.
                shift_reg   <= (lrck_i == 1'b0) ? left_data : right_data;
                bit_counter <= 6'd0;
                sdata_o     <= 1'b0;   // delay bit
            end
            else if (sclk_falling) begin
                if (bit_counter < DATA_WIDTH[5:0]) begin
                    // Drive shift_reg[MSB], then shift left. bit_counter=0
                    // drives the MSB, bit_counter=DATA_WIDTH-1 drives the LSB.
                    sdata_o     <= shift_reg[DATA_WIDTH-1];
                    shift_reg   <= {shift_reg[DATA_WIDTH-2:0], 1'b0};
                    bit_counter <= bit_counter + 6'd1;
                end
                else begin
                    // Past LSB - trailing zeros until next LRCK edge.
                    sdata_o <= 1'b0;
                end
            end
        end
    end

endmodule
