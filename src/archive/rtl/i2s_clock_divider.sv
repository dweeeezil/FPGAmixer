// -----------------------------------------------------------------------------
// i2s_clock_divider.sv
//
// Divides MCLK to generate SCLK and LRCK for the Pmod I2S2.
//
//   mclk (12.288 MHz) -> sclk (mclk / 4  = 3.072 MHz)
//                     -> lrck (mclk / 256 = 48 kHz)
//
// The ratios (MCLK/LRCK = 256, SCLK/LRCK = 64) are required by CS5343 (ADC)
// and CS4344 (DAC) for 48 kHz Fs. See Pmod I2S2 Reference Manual.
//
// Phase 1 note: this is a plain counter with two output bits tapped off. It
// does NOT enforce the standard I2S phase relationship where LRCK transitions
// one SCLK cycle before the MSB. That's fine for the loopback in Phase 1,
// because the ADC and DAC both consume our generated LRCK/SCLK identically -
// whatever we produce, both interpret in agreement. Phase 2 will introduce a
// proper I2S receiver/transmitter that DOES care about this alignment.
// -----------------------------------------------------------------------------
module i2s_clock_divider (
    input  logic mclk,   // ~12.288 MHz (from MMCM)
    input  logic rst_n,  // active-low, sync'd to MCLK; deassert after MMCM locks

    output logic sclk,   // mclk / 4   = ~3.072 MHz
    output logic lrck    // mclk / 256 = ~48 kHz
);

    // 8-bit counter is enough:
    //   cnt[1] toggles every 2 mclk cycles  -> period 4  mclk -> SCLK
    //   cnt[7] toggles every 128 mclk cycles -> period 256 mclk -> LRCK
    logic [7:0] cnt;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n)
            cnt <= 8'd0;
        else
            cnt <= cnt + 8'd1;
    end

    assign sclk = cnt[1];
    assign lrck = cnt[7];

endmodule
