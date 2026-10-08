// -----------------------------------------------------------------------------
// i2s_port.sv
//
// Front door: one Digilent Pmod I2S2 (CS4344 DAC + CS5343 ADC, both clock
// slaves) <-> the PCM contract (docs/architecture_modules.md 2). It knows its
// pins and the I2S protocol; it knows nothing about the matrix or the PS.
//
//   ad_sdout pin -> i2s_receiver    -> rx_flat {R, L}, rx_valid
//   tx_flat {R, L} -> i2s_transmitter -> da_sdin pin
//
// PCM side: 2 channels, packed, channel 0 = left at [0 +: SW], channel 1 =
// right at [SW +: SW], signed. rx_valid pulses once per frame. tx_flat is
// sampled once per frame, both channels together, at the LRCK falling edge
// (the start of the DAC's frame; see STEREO PAIRING below).
//
// Clocks: mclk/sclk/lrck come from audio_clocking and are SHARED by every
// port, which is what keeps all ports sample-synchronous. This module only
// forwards them to its own pins.
//
// ----- Pin forwarding (codec interface timing) -----
// Every codec-facing output leaves through an ODDR (oddr_out), one per
// physical pin, all clocked by mclk. MCLK pins use the clock-forwarding
// pattern (d1=1, d2=0); SCLK/LRCK/SDIN pass through as SDR data (d1=d2=signal),
// which re-launches them on the mclk rising edge and adds one identical MCLK
// of pin latency to each.
//
// INVARIANT: SCLK, LRCK and SDIN must all get this same SDR treatment so their
// relative pin alignment (data changes mid-cell, half an SCLK before the DAC's
// sampling edge) is preserved. Mixing ODDR and combinational forwarding here
// re-creates the Phase 3 pin-phase race. See
// docs/archive/handoff_codec_interface_timing.md 4.2 and oddr_out.sv.
//
// The board XDC defines forwarded clocks on these ODDRs by path
// (<port instance>/u_fwd_{da,ad}_{mclk,sclk}/u_oddr/C) -- keep the instance
// names in step with it.
// -----------------------------------------------------------------------------
module i2s_port #(
    parameter int SW = 24
) (
    input  logic mclk,
    input  logic rst_n,
    input  logic sclk,
    input  logic lrck,

    // ----- Pmod pins -----
    output logic da_mclk,      // Pmod pin 1
    output logic da_lrck,      // Pmod pin 2
    output logic da_sclk,      // Pmod pin 3
    output logic da_sdin,      // Pmod pin 4
    output logic ad_mclk,      // Pmod pin 7
    output logic ad_lrck,      // Pmod pin 8
    output logic ad_sclk,      // Pmod pin 9
    input  logic ad_sdout,     // Pmod pin 10

    // ----- PCM contract (mclk domain) -----
    output logic [2*SW-1:0] rx_flat,
    output logic            rx_valid,
    input  logic [2*SW-1:0] tx_flat
);

    // ----- Clock forwarding to both codecs -----
    oddr_out u_fwd_da_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(da_mclk));
    oddr_out u_fwd_ad_mclk (.clk(mclk), .d1(1'b1), .d2(1'b0), .q(ad_mclk));

    oddr_out u_fwd_da_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(da_sclk));
    oddr_out u_fwd_ad_sclk (.clk(mclk), .d1(sclk), .d2(sclk), .q(ad_sclk));

    oddr_out u_fwd_da_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(da_lrck));
    oddr_out u_fwd_ad_lrck (.clk(mclk), .d1(lrck), .d2(lrck), .q(ad_lrck));

    // ----- ADC: I2S -> PCM -----
    i2s_receiver #(.DATA_WIDTH(SW)) u_rx (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .sdata_i (ad_sdout),
        .left_data  (rx_flat[0 +: SW]),
        .right_data (rx_flat[SW +: SW]),
        .sample_valid (rx_valid)
    );

    // ----- DAC: PCM -> I2S -----
    // sdata leaves through the same SDR ODDR pattern as SCLK/LRCK above, so
    // the mid-cell launch phase fixed in i2s_transmitter survives at the pin.
    //
    // STEREO PAIRING: the transmitter loads L at the LRCK falling edge and R
    // half a frame later, at the rising edge. Fed straight from tx_flat, R
    // would come from a later core frame than L whenever the core updates
    // tx_flat in between (it did: R led L by one sample, seen in
    // tb_phase3_dynamic, phase9_status_2026-09-26.md 5.3). So the pair is
    // sampled ONCE, when L is loaded: L goes to the transmitter directly and R
    // is held for the rising edge. Both halves of every DAC frame now come
    // from one core frame, whatever the core's timing.
    //
    // Deadline this sets for the core: tx_flat must hold the new frame by the
    // LRCK falling edge (the cycle the transmitter loads L). lrck_q uses the
    // same 1FF detection as the transmitter, so the two see the edge on the
    // same mclk cycle.
    logic          sdin_int;
    logic          lrck_q;
    logic [SW-1:0] tx_r_hold;

    always_ff @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            lrck_q    <= 1'b0;
            tx_r_hold <= '0;
        end else begin
            lrck_q <= lrck;
            if (lrck_q && !lrck)                 // falling edge: L loads now
                tx_r_hold <= tx_flat[SW +: SW];
        end
    end

    i2s_transmitter #(.DATA_WIDTH(SW)) u_tx (
        .mclk (mclk), .rst_n (rst_n), .sclk_i (sclk), .lrck_i (lrck),
        .left_data  (tx_flat[0 +: SW]),
        .right_data (tx_r_hold),
        .sdata_o (sdin_int)
    );

    oddr_out u_fwd_da_sdin (.clk(mclk), .d1(sdin_int), .d2(sdin_int), .q(da_sdin));

endmodule
