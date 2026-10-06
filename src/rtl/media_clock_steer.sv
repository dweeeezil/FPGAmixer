// -----------------------------------------------------------------------------
// media_clock_steer.sv
//
// Platform block (Phase 9, P9.4b): steers the audio MMCM's output frequency by
// its dynamic fine phase shift (UG572): each PSEN pulse moves the phase of the
// selected output by 1/56 of the VCO period (12.3 ps at 1450 MHz), gradually,
// and the next step may start once PSDONE has pulsed (12 PSCLK cycles). A
// steady stream of steps is a frequency offset:
//     delta_f / f  =  steps per second  x  step size
// This block turns a signed RATE into that stream. It knows nothing about
// gPTP; the loop that sets RATE (fpgamixer-mediaclock, decision S3) does.
//
// RATE: signed 32-bit, steps per PSCLK cycle in units of 2^-32. A phase
// accumulator adds |RATE| every cycle; each carry requests one step in the
// direction of RATE's sign:
//     RATE > 0 : increments (output phase delayed)   -> mclk runs SLOWER
//     RATE < 0 : decrements (output phase advanced)  -> mclk runs FASTER
// Resolution at 100 MHz: 0.023 steps/s (~3e-7 ppm). The MMCM takes at most
// one step per 14 PSCLK cycles (PSEN, PSDONE 12 cycles later, the next PSEN
// only after PSDONE has pulsed): 7.14 M steps/s at 100 MHz = +/-88 ppm of
// mclk at 12.3 ps per step. Requests wait in a signed PENDING count
// (opposite requests cancel) and beyond +/-MAX_PENDING are DROPPED (counted),
// so an impossible rate saturates at the hardware's maximum slew instead of
// accumulating a backlog.
//
// While the MMCM is not locked (UG572: no phase shift before LOCKED) the
// accumulator, the backlog and the handshake are held in reset.
//
// Status (all psclk domain, free-running, wrap): steps_inc / steps_dec count
// COMPLETED steps (at PSDONE); dropped counts discarded requests.
//
// CDC: mmcm_locked (asynchronous MMCM output) -> 2FF (ASYNC_REG); the scoped
// constraints/media_clock_steer.xdc marks it. PSEN / PSINCDEC / PSDONE are
// synchronous to PSCLK by the MMCM's definition and are timed normally.
// -----------------------------------------------------------------------------
module media_clock_steer #(
    parameter int MAX_PENDING = 255
) (
    input  logic        psclk,
    input  logic        rst_n,          // psclk domain
    input  logic [31:0] rate,           // signed, 2^-32 steps per psclk cycle
    input  logic        mmcm_locked,    // asynchronous

    // ----- MMCM dynamic phase-shift port (psclk domain) -----
    output logic        psen,
    output logic        psincdec,
    input  logic        psdone,

    // ----- status (psclk domain) -----
    output logic [31:0] steps_inc,
    output logic [31:0] steps_dec,
    output logic [31:0] dropped,
    output logic        busy,
    output logic        locked
);

    // ----- locked, synchronized -----
    (* ASYNC_REG = "TRUE" *) logic lk_s1, lk_s2;
    always_ff @(posedge psclk or negedge rst_n) begin
        if (!rst_n) begin lk_s1 <= 1'b0; lk_s2 <= 1'b0; end
        else        begin lk_s1 <= mmcm_locked; lk_s2 <= lk_s1; end
    end
    assign locked = lk_s2;

    // ----- rate -> requests -----
    wire        neg  = rate[31];
    wire [31:0] mag  = neg ? ((rate == 32'h8000_0000) ? 32'h7FFF_FFFF : -rate) : rate;

    logic [31:0] acc;
    logic [32:0] sum;
    assign sum = {1'b0, acc} + {1'b0, mag};
    wire request = sum[32];

    logic signed [15:0] pending;
    logic               dir_inc;     // direction of the step in flight

    always_ff @(posedge psclk or negedge rst_n) begin
        logic signed [15:0] p;
        logic               b;
        if (!rst_n) begin
            acc       <= '0;
            pending   <= '0;
            psen      <= 1'b0;
            psincdec  <= 1'b0;
            busy      <= 1'b0;
            dir_inc   <= 1'b0;
            steps_inc <= '0;
            steps_dec <= '0;
            dropped   <= '0;
        end else if (!lk_s2) begin
            acc     <= '0;
            pending <= '0;
            psen    <= 1'b0;
            busy    <= 1'b0;
        end else begin
            psen <= 1'b0;
            acc  <= sum[31:0];

            // new request into the backlog (saturating)
            p = pending;
            if (request) begin
                if (!neg) begin
                    if (p < MAX_PENDING) p = p + 1;
                    else                 dropped <= dropped + 1'b1;
                end else begin
                    if (p > -MAX_PENDING) p = p - 1;
                    else                  dropped <= dropped + 1'b1;
                end
            end

            // a finished step frees the port on this same edge, so the next
            // PSEN goes out the cycle right after PSDONE: one step per 14
            // PSCLK cycles at most (PSEN, 12 cycles, PSDONE, PSEN ...)
            b = busy;
            if (busy && psdone) begin
                b = 1'b0;
                if (dir_inc) steps_inc <= steps_inc + 1'b1;
                else         steps_dec <= steps_dec + 1'b1;
            end

            // issue the next one: one PSEN pulse, then wait for PSDONE
            if (!b && p != 0) begin
                psen     <= 1'b1;
                psincdec <= (p > 0);
                dir_inc  <= (p > 0);
                b = 1'b1;
                p = (p > 0) ? p - 1 : p + 1;
            end

            busy    <= b;
            pending <= p;
        end
    end

endmodule
