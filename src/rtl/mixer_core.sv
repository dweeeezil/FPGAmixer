// -----------------------------------------------------------------------------
// mixer_core.sv
//
// The PCM core (docs/architecture_modules.md 1, 2, 2.1): everything between
// the front doors, as one block with the PACKED PCM contract on both sides.
// Inside, blocks are chained by the PCM stream contract (2.1). Since Phase 12
// the core is the console's signal flow (decisions L1-L5), and since LF8
// (2026-10-31) three sections, each with an insert point [I] [B] [O],
// pre-fader (mixer_core_pkg, sec. "sections"):
//
//   in_flat -patch2stream-> [I] -> pcm_gain -> pcm_matrix -> [B] -> pcm_gain -> pcm_matrix -> [O] -> pcm_gain -stream2patch-> out_flat
//   P_IN     input patch           input      input matrix          bus        bus matrix            output    output patch   P_OUT
//   I/O ports                      levels     N_IN -> N_BUS         levels     N_BUS -> N_OUT        levels                 I/O ports
//              ^             ^       ^             ^         ^        ^            ^          ^        ^           ^
//          in_patch_*   ins_in_*  in_lvl_*     in_mx_*  ins_bus_*  bus_lvl_*    bus_mx_*  ins_out_*  out_lvl_*  out_patch_*
//
// Insert ports: at each insert point the zone's stream leaves (send) and
// must come back INS_LAT cycles later (return), same beats; the core checks
// the timing (err_o) and nothing else. The insert router closes them in the
// builds (docs/insert_architecture_proposal_2026-10-31.md), pcm_insert_loop
// in TBs of the core alone. The core doesn't know about pools.
//
// Phase 15 (decision CS1): the packed sides are the I/O PORTS (P_IN in,
// P_OUT out), and the converters at the ends are the patch: input channel k
// takes the port its source entry names, output channel c feeds the port its
// destination entry names (0 = None; pcm_patch2stream.sv, pcm_stream2patch.sv).
// The core still doesn't know what the ports are (the platform's map).
//
// Seven coefficient read ports, one per block, each served by the control
// plane's coef_bank_ram (one register window per block) or by a
// coef_flat_reader (non-PS builds, TBs); the core can't tell which:
//   *_lvl_* : ROW_LEN 1, N_ROWS = the stage's channels, LANES 1 (pcm_gain.sv)
//   in_mx_* : ROW_LEN N_IN,  N_ROWS N_BUS, LANES L1  (row = bus,    pcm_matrix.sv)
//   bus_mx_*: ROW_LEN N_BUS, N_ROWS N_OUT, LANES L2  (row = output)
//   *_patch_*: ROW_LEN 1, N_ROWS = the channels, LANES 1, W = $clog2(P+1)
// so a matrix's register index is k = destination*N_source + source, as
// before. Every block saturates its output to SW bits (L5): a bus sum clips at
// the bus, as on a console.
//
// Tap ports (Phase 13, decision M1): the three level stages' output streams
// leave the core as copies (stream contract), the zones' post-DSP points the
// OSC standard meters; the peak meters (pcm_peak) attach there, outside the
// chain. Last beats (cycles after the strobe): tap_in = sec_in_last,
// tap_bus = sec_bus_last, tap_out = sec_out_last = D - OUT_PATCH_LAT.
//
// DSP processors are not core stages: they are pools behind the insert
// router (LF8), so the core, the platform layer and the front doors don't
// change when a new processor type arrives.
// (Phase 9, P9.A4: the core was pack2stream -> pcm_matrix -> stream2pack.)
//
// Timing: in_flat is captured on the strobe (frame_i). out_flat changes on one
// edge, D = mixer_core_pkg::chain_latency(N_IN, N_BUS, N_OUT, L1, L2) cycles
// after the strobe (20/20/20 on 4 + 5 lanes: 241), valid_o pulsing on that
// edge's cycle. L1/L2 default to the package's chooser (the fewest lanes with
// D <= D_MAX); the core refuses to elaborate past D_MAX. err_o pulses on a
// malformed internal stream (never expected; for a status counter).
// -----------------------------------------------------------------------------
module mixer_core
    import pcm_matrix_pkg::*;
    import mixer_core_pkg::*;
#(
    parameter int N_IN  = 12,
    parameter int N_BUS = 12,
    parameter int N_OUT = 12,
    parameter int P_IN  = N_IN,     // I/O ports in (Phase 15)
    parameter int P_OUT = N_OUT,    // I/O ports out
    parameter int SW    = 24,
    parameter int GW    = 18,
    parameter int GF    = 16,
    parameter int L1    = chain_l1(N_IN, N_BUS, N_OUT),
    parameter int L2    = chain_l2(N_IN, N_BUS, N_OUT),
    localparam int CWI  = (N_IN  > 1) ? $clog2(N_IN)  : 1,
    localparam int CWB  = (N_BUS > 1) ? $clog2(N_BUS) : 1,
    localparam int CWO  = (N_OUT > 1) ? $clog2(N_OUT) : 1,
    localparam int PWI  = $clog2(P_IN + 1),     // a patch entry: 0 = None, 1 .. P
    localparam int PWO  = $clog2(P_OUT + 1),
    localparam int DEPTH1 = matrix_passes(N_BUS, (L1 > 0) ? L1 : 1) * N_IN,
    localparam int DEPTH2 = matrix_passes(N_OUT, (L2 > 0) ? L2 : 1) * N_BUS,
    localparam int AW1  = (DEPTH1 > 1) ? $clog2(DEPTH1) : 1,
    localparam int AW2  = (DEPTH2 > 1) ? $clog2(DEPTH2) : 1
) (
    input  logic                 mclk,
    input  logic                 rst_n,
    input  logic                 frame_i,

    input  logic [P_IN*SW-1:0]   in_flat,       // the I/O ports
    output logic [P_OUT*SW-1:0]  out_flat,
    output logic                 valid_o,
    output logic                 err_o,

    // bank swap pulses (LF1), one per coefficient port: wire each to its
    // bank's frame_i (coef_bank_ram, or coef_flat_reader with LATCH)
    output logic                 in_patch_swap,
    output logic                 in_lvl_swap,
    output logic                 in_mx_swap,
    output logic                 bus_lvl_swap,
    output logic                 bus_mx_swap,
    output logic                 out_lvl_swap,
    output logic                 out_patch_swap,

    // read strobes (LF2): high in the cycle a block issues a real read, each
    // coefficient once per frame; for a coef_smooth on the port (the banks
    // ignore them). The patch ports have none (not smoothed).
    output logic                 in_lvl_rd,
    output logic                 in_mx_rd,
    output logic                 bus_lvl_rd,
    output logic                 bus_mx_rd,
    output logic                 out_lvl_rd,

    // coefficient read ports (address -> data one cycle later)
    output logic [CWI-1:0]       in_patch_addr,
    input  logic [PWI-1:0]       in_patch_data,
    output logic [CWI-1:0]       in_lvl_addr,
    input  logic [GW-1:0]        in_lvl_data,
    output logic [AW1-1:0]       in_mx_addr,
    input  logic [L1*GW-1:0]     in_mx_data,
    output logic [CWB-1:0]       bus_lvl_addr,
    input  logic [GW-1:0]        bus_lvl_data,
    output logic [AW2-1:0]       bus_mx_addr,
    input  logic [L2*GW-1:0]     bus_mx_data,
    output logic [CWO-1:0]       out_lvl_addr,
    input  logic [GW-1:0]        out_lvl_data,
    output logic [CWO-1:0]       out_patch_addr,
    input  logic [PWO-1:0]       out_patch_data,

    // tap ports (Phase 13): copies of the three level stages' output streams
    // (the zones' post-DSP points), for listeners such as the peak meters
    output logic                 tap_in_valid,
    output logic [CWI-1:0]       tap_in_ch,
    output logic [SW-1:0]        tap_in_data,
    output logic                 tap_bus_valid,
    output logic [CWB-1:0]       tap_bus_ch,
    output logic [SW-1:0]        tap_bus_data,
    output logic                 tap_out_valid,
    output logic [CWO-1:0]       tap_out_ch,
    output logic [SW-1:0]        tap_out_data,

    // insert ports (LF8, insert architecture 2026-10-31): each zone's stream
    // leaves at its insert point (send) and must come back (return) exactly
    // INS_LAT cycles later, same channels, same timing; the content is the
    // closer's (insert_router, or pcm_insert_loop). A return off that timing
    // pulses err_o.
    output logic                 ins_in_send_valid,
    output logic [CWI-1:0]       ins_in_send_ch,
    output logic [SW-1:0]        ins_in_send_data,
    input  logic                 ins_in_ret_valid,
    input  logic [CWI-1:0]       ins_in_ret_ch,
    input  logic [SW-1:0]        ins_in_ret_data,
    output logic                 ins_bus_send_valid,
    output logic [CWB-1:0]       ins_bus_send_ch,
    output logic [SW-1:0]        ins_bus_send_data,
    input  logic                 ins_bus_ret_valid,
    input  logic [CWB-1:0]       ins_bus_ret_ch,
    input  logic [SW-1:0]        ins_bus_ret_data,
    output logic                 ins_out_send_valid,
    output logic [CWO-1:0]       ins_out_send_ch,
    output logic [SW-1:0]        ins_out_send_data,
    input  logic                 ins_out_ret_valid,
    input  logic [CWO-1:0]       ins_out_ret_ch,
    input  logic [SW-1:0]        ins_out_ret_data
);

    localparam int D = chain_latency(N_IN, N_BUS, N_OUT, L1, L2);

    generate
        if (L1 < 1 || L2 < 1)
            $error("mixer_core: %0d -> %0d -> %0d does not fit the frame budget",
                   N_IN, N_BUS, N_OUT);
        else if (INS_LAT < 2)
            $error("mixer_core: the insert check below needs INS_LAT >= 2 (%0d)", INS_LAT);
        else if (!chain_fits(N_IN, N_BUS, N_OUT, L1, L2))
            $error("mixer_core: lanes %0d + %0d don't keep up with the frame rate (D = %0d; mixer_core_pkg::chain_fits)",
                   L1, L2, D);
    endgenerate

    // ----- streams between the blocks (a..f, in chain order; ai/ci/ei are
    //       the insert points' returns) -----
    logic           a_valid, b_valid, c_valid, d_valid, e_valid, f_valid;
    logic [CWI-1:0] a_ch, b_ch;
    logic [CWB-1:0] c_ch, d_ch;
    logic [CWO-1:0] e_ch, f_ch;
    logic [SW-1:0]  a_data, b_data, c_data, d_data, e_data, f_data;
    logic           ai_valid, ci_valid, ei_valid;
    logic [CWI-1:0] ai_ch;
    logic [CWB-1:0] ci_ch;
    logic [CWO-1:0] ei_ch;
    logic [SW-1:0]  ai_data, ci_data, ei_data;

    // ===== section: inputs =====
    pcm_patch2stream #(.P (P_IN), .N (N_IN), .SW (SW)) u_in (
        .mclk (mclk), .rst_n (rst_n), .frame_i (frame_i), .in_flat (in_flat),
        .coef_addr (in_patch_addr), .coef_swap (in_patch_swap), .coef_data (in_patch_data),
        .s_valid (a_valid), .s_ch (a_ch), .s_data (a_data));

    // insert point [I]
    assign ins_in_send_valid = a_valid;
    assign ins_in_send_ch    = a_ch;
    assign ins_in_send_data  = a_data;
    assign ai_valid = ins_in_ret_valid;
    assign ai_ch    = ins_in_ret_ch;
    assign ai_data  = ins_in_ret_data;

    pcm_gain #(.N (N_IN), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_in_lvl (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (ai_valid), .in_ch (ai_ch), .in_data (ai_data),
        .coef_addr (in_lvl_addr), .coef_rd (in_lvl_rd), .coef_swap (in_lvl_swap), .coef_data (in_lvl_data),
        .out_valid (b_valid), .out_ch (b_ch), .out_data (b_data));

    pcm_matrix #(
        .N_IN (N_IN), .N_OUT (N_BUS), .SAMPLE_WIDTH (SW),
        .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (L1)
    ) u_in_mx (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (b_valid), .in_ch (b_ch), .in_data (b_data),
        .coef_addr (in_mx_addr), .coef_rd (in_mx_rd), .coef_swap (in_mx_swap), .coef_data (in_mx_data),
        .out_valid (c_valid), .out_ch (c_ch), .out_data (c_data));

    // insert point [B]
    assign ins_bus_send_valid = c_valid;
    assign ins_bus_send_ch    = c_ch;
    assign ins_bus_send_data  = c_data;
    assign ci_valid = ins_bus_ret_valid;
    assign ci_ch    = ins_bus_ret_ch;
    assign ci_data  = ins_bus_ret_data;

    pcm_gain #(.N (N_BUS), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_bus_lvl (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (ci_valid), .in_ch (ci_ch), .in_data (ci_data),
        .coef_addr (bus_lvl_addr), .coef_rd (bus_lvl_rd), .coef_swap (bus_lvl_swap), .coef_data (bus_lvl_data),
        .out_valid (d_valid), .out_ch (d_ch), .out_data (d_data));

    pcm_matrix #(
        .N_IN (N_BUS), .N_OUT (N_OUT), .SAMPLE_WIDTH (SW),
        .GAIN_WIDTH (GW), .GAIN_FRAC (GF), .LANES (L2)
    ) u_bus_mx (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (d_valid), .in_ch (d_ch), .in_data (d_data),
        .coef_addr (bus_mx_addr), .coef_rd (bus_mx_rd), .coef_swap (bus_mx_swap), .coef_data (bus_mx_data),
        .out_valid (e_valid), .out_ch (e_ch), .out_data (e_data));

    // insert point [O]
    assign ins_out_send_valid = e_valid;
    assign ins_out_send_ch    = e_ch;
    assign ins_out_send_data  = e_data;
    assign ei_valid = ins_out_ret_valid;
    assign ei_ch    = ins_out_ret_ch;
    assign ei_data  = ins_out_ret_data;

    pcm_gain #(.N (N_OUT), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_out_lvl (
        .mclk (mclk), .rst_n (rst_n),
        .in_valid (ei_valid), .in_ch (ei_ch), .in_data (ei_data),
        .coef_addr (out_lvl_addr), .coef_rd (out_lvl_rd), .coef_swap (out_lvl_swap), .coef_data (out_lvl_data),
        .out_valid (f_valid), .out_ch (f_ch), .out_data (f_data));

    // ----- bank swaps (LF1): each block states its own (coef_swap, step 3 Q2) -----
    // The read issued in the swap cycle still sees the old bank
    // (coef_bank_ram), every later one the new. Today every block's pulse is
    // its input's last beat, except the input patch's (the strobe, since its
    // reads follow it): a pcm_gain or the output patch reads per input beat, so
    // the next frame gets the new bank; a pcm_matrix starts its frame's reads
    // on that edge, so that frame does (chain_fits: the previous frame's reads
    // are done by then). Each frame sees one whole bank per block, however far
    // down a long chain it runs. A block with another read schedule (an EQ,
    // a delay) states its own; the core only wires the pulses out.

    // ----- taps: listen only; the chain doesn't know they exist -----
    assign tap_in_valid  = b_valid;
    assign tap_in_ch     = b_ch;
    assign tap_in_data   = b_data;
    assign tap_bus_valid = d_valid;
    assign tap_bus_ch    = d_ch;
    assign tap_bus_data  = d_data;
    assign tap_out_valid = f_valid;
    assign tap_out_ch    = f_ch;
    assign tap_out_data  = f_data;

    logic patch_err;
    pcm_stream2patch #(.N (N_OUT), .P (P_OUT), .SW (SW)) u_out (
        .mclk (mclk), .rst_n (rst_n),
        .s_valid (f_valid), .s_ch (f_ch), .s_data (f_data),
        .coef_addr (out_patch_addr), .coef_swap (out_patch_swap), .coef_data (out_patch_data),
        .out_flat (out_flat), .valid_o (valid_o), .err_o (patch_err));

    // ----- insert returns on time: the same beats, INS_LAT cycles later -----
    // (the sections' arithmetic, and so every later block, relies on it)
    logic [INS_LAT-1:0]   iv_d, bv_d, ov_d;
    logic [CWI-1:0]       ic_d [INS_LAT];
    logic [CWB-1:0]       bc_d [INS_LAT];
    logic [CWO-1:0]       oc_d [INS_LAT];
    logic                 ins_err;
    always_ff @(posedge mclk) begin
        if (!rst_n) begin
            iv_d <= '0; bv_d <= '0; ov_d <= '0;
            ins_err <= 1'b0;
        end else begin
            iv_d <= {iv_d[INS_LAT-2:0], a_valid};
            bv_d <= {bv_d[INS_LAT-2:0], c_valid};
            ov_d <= {ov_d[INS_LAT-2:0], e_valid};
            ins_err <= (ai_valid != iv_d[INS_LAT-1]) || (ai_valid && ai_ch != ic_d[INS_LAT-1])
                    || (ci_valid != bv_d[INS_LAT-1]) || (ci_valid && ci_ch != bc_d[INS_LAT-1])
                    || (ei_valid != ov_d[INS_LAT-1]) || (ei_valid && ei_ch != oc_d[INS_LAT-1]);
        end
        ic_d[0] <= a_ch;  bc_d[0] <= c_ch;  oc_d[0] <= e_ch;
        for (int j = 1; j < INS_LAT; j++) begin
            ic_d[j] <= ic_d[j-1];  bc_d[j] <= bc_d[j-1];  oc_d[j] <= oc_d[j-1];
        end
    end
    assign err_o = patch_err || ins_err;

endmodule
