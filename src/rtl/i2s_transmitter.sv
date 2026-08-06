// -----------------------------------------------------------------------------
// i2s_transmitter.sv
//
// Serializes parallel 24-bit left/right samples into an I2S bit stream.
// Symmetric to i2s_receiver: same clocks, same MCLK domain, same Philips I2S
// timing assumptions (data changes on falling SCLK edge, MSB delayed by one
// SCLK cycle from LRCK transition).
//
// On every LRCK transition, the appropriate channel's sample is loaded into
// the shift register based on the NEW LRCK level:
//   LRCK just went to 0 -> load left_data
//   LRCK just went to 1 -> load right_data
//
// The first falling SCLK edge after the LRCK transition drives the "delay
// bit" (zero). The next 24 falling SCLK edges drive MSB..LSB. Any remaining
// falling SCLK edges in the LRCK half-period drive zero.
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

    // ----- Input registering and edge detection -----
    logic sclk_r, sclk_prev;
    logic lrck_r, lrck_prev;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_r    <= 1'b0;
            sclk_prev <= 1'b0;
            lrck_r    <= 1'b0;
            lrck_prev <= 1'b0;
        end else begin
            sclk_r    <= sclk_i;
            sclk_prev <= sclk_r;
            lrck_r    <= lrck_i;
            lrck_prev <= lrck_r;
        end
    end

    wire sclk_falling = !sclk_r && sclk_prev;
    wire lrck_changed = (lrck_r != lrck_prev);

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
                // Load new channel data. LRCK=0 means we're now on left
                // channel; LRCK=1 means right.
                shift_reg   <= (lrck_r == 1'b0) ? left_data : right_data;
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
