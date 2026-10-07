// -----------------------------------------------------------------------------
// phase2_top.sv
//
// Phase 2: I2S <-> PCM <-> I2S round-trip on JB.
//
// Same pin interface and same clocks as Phase 1, but now the FPGA
// deserializes the ADC's bit stream into parallel 24-bit L/R registers, then
// reserializes them back to the DAC. The audible result is identical to
// Phase 1 (bypass), which is the point - it proves the rx/tx logic is
// bit-exact before we start actually modifying samples in Phase 3.
//
// Signal flow (inside the FPGA):
//
//   sysclk (25 MHz) --> MMCM --> mclk (~12.288 MHz)
//                                    |
//                                    +--> reset_sync --> rst_n (clean, mclk-domain)
//                                    +--> divider --> sclk, lrck
//                                    |
//                                    v
//   sdata_in (from ADC) --> i2s_receiver --> {left_data, right_data} -->  i2s_transmitter --> sdata_out (to DAC)
//                              ^                                             ^
//                              |                                             |
//                          sclk, lrck                                   sclk, lrck
//
// Latency: one LRCK period (~21 us at 48 kHz). Inaudible; expected.
// -----------------------------------------------------------------------------
module phase2_top (
    input  logic sysclk,      // 25 MHz PL ref, pin E12 (LVCMOS18)

    // Pmod JB - Pmod I2S2 (same pinout as Phase 1)
    output logic jb_da_mclk,  // JB1
    output logic jb_da_lrck,  // JB2
    output logic jb_da_sclk,  // JB3
    output logic jb_da_sdin,  // JB4
    output logic jb_ad_mclk,  // JB7
    output logic jb_ad_lrck,  // JB8
    output logic jb_ad_sclk,  // JB9
    input  logic jb_ad_sdout  // JB10
);

    // ----- Clocking -----
    logic mclk;
    logic mmcm_locked;

    clk_wiz_audio u_mmcm (
        .clk_in1  (sysclk),
        .reset    (1'b0),
        .clk_out1 (mclk),
        .locked   (mmcm_locked)
    );

    // Synchronize MMCM lock (async) to mclk for use as active-low reset.
    logic rst_n;
    reset_sync u_rst_sync (
        .clk         (mclk),
        .async_rst_n (mmcm_locked),
        .sync_rst_n  (rst_n)
    );

    // ----- SCLK / LRCK generation -----
    logic sclk, lrck;
    i2s_clock_divider u_div (
        .mclk  (mclk),
        .rst_n (rst_n),
        .sclk  (sclk),
        .lrck  (lrck)
    );

    // ----- Drive clocks to both sides of the Pmod -----
    assign jb_da_mclk = mclk;
    assign jb_da_lrck = lrck;
    assign jb_da_sclk = sclk;
    assign jb_ad_mclk = mclk;
    assign jb_ad_lrck = lrck;
    assign jb_ad_sclk = sclk;

    // ----- Receiver: I2S -> PCM registers -----
    logic [23:0] left_data, right_data;
    logic        sample_valid;  // unused in Phase 2 (transmitter picks up from L/R regs on LRCK edges); wired for observability during sim

    i2s_receiver #(.DATA_WIDTH(24)) u_rx (
        .mclk         (mclk),
        .rst_n        (rst_n),
        .sclk_i       (sclk),
        .lrck_i       (lrck),
        .sdata_i      (jb_ad_sdout),
        .left_data    (left_data),
        .right_data   (right_data),
        .sample_valid (sample_valid)
    );

    // ----- Transmitter: PCM registers -> I2S -----
    // The transmitter reads left_data/right_data at each LRCK edge. Because
    // both rx and tx respond to the same LRCK edge, and non-blocking
    // assignments read pre-update values, tx serializes the value written
    // at the PREVIOUS LRCK edge. That's the one-frame latency.
    i2s_transmitter #(.DATA_WIDTH(24)) u_tx (
        .mclk       (mclk),
        .rst_n      (rst_n),
        .sclk_i     (sclk),
        .lrck_i     (lrck),
        .left_data  (left_data),
        .right_data (right_data),
        .sdata_o    (jb_da_sdin)
    );

endmodule
