// -----------------------------------------------------------------------------
// insert_router.sv
//
// The insert router (docs/insert_architecture_proposal_2026-10-31.md): closes
// mixer_core's three insert ports and feeds NP processor pools, so any zone
// channel can run through any chain of pool slots, in any order, and come
// back with the same latency as every other channel. Mixer architecture, not
// a DSP block: it knows the core's insert contract (mixer_core_pkg::INS_LAT)
// and the pools' stream contract, not what the pools do.
//
// ----- Per zone (inputs, buses, outputs) -----
//   send   : the zone's stream from the core. Each beat is written into the
//            zone's HISTORY (hist_frames(K) frames per channel).
//   return : the same beat, INS_LAT cycles later: the channel's sample from
//            delay_frames(K) frames ago (dry), or the output of the slot its
//            RETURN entry names (that slot's previous run).
// ----- Per pool -----
//   pool_in  : the pool's input stream, slots 0 .. S-1, one per cycle, slot s
//              at POOL_IN_FIRST + s cycles after the strobe; slot s's sample
//              is what its SOURCE entry names: a zone channel's history at an
//              age, another slot's previous run, or silence.
//   pool_out : the pool's output stream (the stream contract, channel =
//              slot), kept in a double buffer by frame for the next run's
//              readers.
// insert_router_pkg has the timing in frames, the entry format and the table
// layout. Tables: one read port per reader (zones 0..2, pools 3..3+NP-1), all
// on ONE bank (coef_bank_ram PORTS = 3 + NP, insert_router_regs_axil), with
// the swap on the strobe (tab_swap): a read in the strobe cycle still sees
// the old tables, every later one the new, so an edit lands whole in one
// frame. Reset tables (all 0): every channel dry, every slot silent.
//
// ----- Frame rules (router_fits, checked at elaboration) -----
// The frame index (hw, the history slot; fpar, the pool buffer) advances at
// the end of the strobe cycle, so beats 1 .. FRAME cycles after a strobe
// belong to its frame. Every zone's send must lie there (true while the core
// fits one frame), and every pool must finish its run inside the frame
// (POOL_LAT: the longest output-after-input latency of the pools). Then:
//   - a run reads history frames >= the previous one, all written, none being
//     overwritten (the history holds K + 2 frames, the oldest read is K + 1);
//   - a run, and a zone's returns, read the pools' previous run, complete,
//     while the current run writes the other buffer.
//
// ----- Memories -----
// Each reader has its own copy of every buffer it may read (one write, one
// registered read each), written together: histories 512 x 24 at 20
// channels, pool buffers 64 x 24. Synthesis drops the copies a reader never
// reads (a zone's return reads only its own history).
// -----------------------------------------------------------------------------
module insert_router
    import mixer_core_pkg::*;
    import insert_router_pkg::*;
#(
    parameter int N_I = 20,           // zone channels
    parameter int N_B = 20,
    parameter int N_O = 20,
    parameter int SW  = 24,
    parameter int K   = 8,            // the most inserts on one channel
    parameter int S   = 32,           // slots per pool
    parameter int NP  = 1,            // pools
    parameter int POOL_LAT = 3,       // the pools' longest output-after-input latency
    // the zones' send last beats, cycles after the strobe (mixer_core_pkg)
    parameter int SEND_LAST_I = 0,
    parameter int SEND_LAST_B = 0,
    parameter int SEND_LAST_O = 0,
    localparam int CWI = (N_I > 1) ? $clog2(N_I) : 1,
    localparam int CWB = (N_B > 1) ? $clog2(N_B) : 1,
    localparam int CWO = (N_O > 1) ? $clog2(N_O) : 1,
    localparam int SLW = (S > 1) ? $clog2(S) : 1,
    localparam int NR  = 3 + NP,                         // table readers
    localparam int N_TAB = N_I + N_B + N_O + NP * S,
    localparam int TAW = (N_TAB > 1) ? $clog2(N_TAB) : 1
) (
    input  logic                 mclk,
    input  logic                 rst_n,
    input  logic                 frame_i,

    // ----- the core's insert ports -----
    input  logic                 in_send_valid,
    input  logic [CWI-1:0]       in_send_ch,
    input  logic [SW-1:0]        in_send_data,
    output logic                 in_ret_valid,
    output logic [CWI-1:0]       in_ret_ch,
    output logic [SW-1:0]        in_ret_data,
    input  logic                 bus_send_valid,
    input  logic [CWB-1:0]       bus_send_ch,
    input  logic [SW-1:0]        bus_send_data,
    output logic                 bus_ret_valid,
    output logic [CWB-1:0]       bus_ret_ch,
    output logic [SW-1:0]        bus_ret_data,
    input  logic                 out_send_valid,
    input  logic [CWO-1:0]       out_send_ch,
    input  logic [SW-1:0]        out_send_data,
    output logic                 out_ret_valid,
    output logic [CWO-1:0]       out_ret_ch,
    output logic [SW-1:0]        out_ret_data,

    // ----- the pools (pool p at [p]) -----
    output logic [NP-1:0]        pool_in_valid,
    output logic [NP*SLW-1:0]    pool_in_ch,
    output logic [NP*SW-1:0]     pool_in_data,
    input  logic [NP-1:0]        pool_out_valid,
    input  logic [NP*SLW-1:0]    pool_out_ch,
    input  logic [NP*SW-1:0]     pool_out_data,

    // ----- table read ports (reader r: 0 inputs, 1 buses, 2 outputs, 3+p pool p) -----
    output logic                 tab_swap,         // = frame_i: wire to the bank's frame_i
    output logic [NR*TAW-1:0]    tab_addr,
    input  logic [NR*EW-1:0]     tab_data,

    output logic                 err_o             // a pool output beat with no such slot
);

    localparam int H    = hist_frames(K);
    localparam int HIW  = $clog2(H);
    localparam int NMAX = (N_I > N_B) ? ((N_I > N_O) ? N_I : N_O) : ((N_B > N_O) ? N_B : N_O);
    localparam int CWM  = (NMAX > 1) ? $clog2(NMAX) : 1;
    localparam int HAW  = HIW + CWM;                     // history address {frame, channel}
    localparam int PAW  = 1 + SLW;                       // pool buffer address {parity, slot}
    localparam int RET_BASE_B = N_I;
    localparam int RET_BASE_O = N_I + N_B;
    localparam int SRC_BASE   = N_I + N_B + N_O;

    generate
        if (!router_fits(SEND_LAST_I, SEND_LAST_B, SEND_LAST_O, S, POOL_LAT, K))
            $error("insert_router: frame rules fail (sends %0d/%0d/%0d, S %0d, pool latency %0d, K %0d; insert_router_pkg::router_fits)",
                   SEND_LAST_I, SEND_LAST_B, SEND_LAST_O, S, POOL_LAT, K);
        if (NP < 1 || NP > 16)
            $error("insert_router: NP = %0d must be 1 .. 16 (the entry's sel field)", NP);
        if (NMAX > 256)
            $error("insert_router: zones of %0d channels don't fit the entry's idx field", NMAX);
    endgenerate

    function automatic int zone_n(input int z);
        return (z == ZONE_IN) ? N_I : (z == ZONE_BUS) ? N_B : N_O;
    endfunction

    // the history slot d frames before frame h (d < H)
    function automatic logic [HIW-1:0] hsub(input logic [HIW-1:0] h, input int d);
        return (int'(h) >= d) ? HIW'(int'(h) - d) : HIW'(int'(h) + H - d);
    endfunction

    assign tab_swap = frame_i;

    // ===== the frame index: hw (history slot, mod H) and fpar (pool buffer) =====
    logic [HIW-1:0] hw;
    logic           fpar;
    always_ff @(posedge mclk) begin
        if (!rst_n) begin
            hw   <= '0;
            fpar <= 1'b0;
        end else if (frame_i) begin
            hw   <= (int'(hw) == H - 1) ? '0 : hw + 1'b1;
            fpar <= ~fpar;
        end
    end

    // ===== write buses: each zone's history, each pool's output buffer =====
    logic           zs_v [3];
    logic [CWM-1:0] zs_c [3];
    logic [SW-1:0]  zs_d [3];
    assign zs_v[0] = in_send_valid;   assign zs_c[0] = CWM'(in_send_ch);   assign zs_d[0] = in_send_data;
    assign zs_v[1] = bus_send_valid;  assign zs_c[1] = CWM'(bus_send_ch);  assign zs_d[1] = bus_send_data;
    assign zs_v[2] = out_send_valid;  assign zs_c[2] = CWM'(out_send_ch);  assign zs_d[2] = out_send_data;

    logic           zw_v [3];
    logic [HAW-1:0] zw_a [3];
    logic [SW-1:0]  zw_d [3];
    logic           pw_v [NP];
    logic [PAW-1:0] pw_a [NP];
    logic [SW-1:0]  pw_d [NP];
    logic           bad_slot;

    always_comb begin
        bad_slot = 1'b0;
        for (int p = 0; p < NP; p++)
            if (pool_out_valid[p] && int'(pool_out_ch[p*SLW +: SLW]) >= S) bad_slot = 1'b1;
    end

    always_ff @(posedge mclk) begin
        for (int z = 0; z < 3; z++) begin
            zw_v[z] <= rst_n && zs_v[z];
            zw_a[z] <= {hw, zs_c[z]};
            zw_d[z] <= zs_d[z];
        end
        for (int p = 0; p < NP; p++) begin
            pw_v[p] <= rst_n && pool_out_valid[p] && int'(pool_out_ch[p*SLW +: SLW]) < S;
            pw_a[p] <= {fpar, pool_out_ch[p*SLW +: SLW]};
            pw_d[p] <= pool_out_data[p*SW +: SW];
        end
        err_o <= rst_n && bad_slot;
    end

    // ===== readers =====
    // Each reader r computes, one cycle after it asked its table, an address
    // for every buffer (rd_ha[r][z], rd_pa[r][p]); its copies of them answer
    // one cycle later (hq[r][z], pq[r][p]).
    logic [HAW-1:0] rd_ha [NR][3];
    logic [PAW-1:0] rd_pa [NR][NP];
    logic [SW-1:0]  hq    [NR][3];
    logic [SW-1:0]  pq    [NR][NP];

    genvar gr, gz, gp;
    generate
        for (gr = 0; gr < NR; gr++) begin : g_rd
            for (gz = 0; gz < 3; gz++) begin : g_h
                logic [SW-1:0] mem [2**HAW];
                initial for (int j = 0; j < 2**HAW; j++) mem[j] = '0;
                always_ff @(posedge mclk) begin
                    if (zw_v[gz]) mem[zw_a[gz]] <= zw_d[gz];
                    hq[gr][gz] <= mem[rd_ha[gr][gz]];
                end
            end
            for (gp = 0; gp < NP; gp++) begin : g_p
                logic [SW-1:0] mem [2**PAW];
                initial for (int j = 0; j < 2**PAW; j++) mem[j] = '0;
                always_ff @(posedge mclk) begin
                    if (pw_v[gp]) mem[pw_a[gp]] <= pw_d[gp];
                    pq[gr][gp] <= mem[rd_pa[gr][gp]];
                end
            end
        end
    endgenerate

    // ----- zone readers (r = 0 .. 2): the returns -----
    logic           r1z_v  [3];
    logic [CWM-1:0] r1z_c  [3];
    logic [HIW-1:0] r1z_h  [3];
    logic           r1z_p  [3];
    logic           r2z_v  [3];
    logic [CWM-1:0] r2z_c  [3];
    logic           r2z_sl [3];      // the return is a slot
    logic [3:0]     r2z_pl [3];      // ... of this pool
    logic           rz_v   [3];
    logic [CWM-1:0] rz_c   [3];
    logic [SW-1:0]  rz_d   [3];

    generate
        for (gz = 0; gz < 3; gz++) begin : g_zone
            localparam int BASE = (gz == ZONE_IN) ? 0 : (gz == ZONE_BUS) ? RET_BASE_B : RET_BASE_O;
            logic [EW-1:0] ent;
            logic [1:0]    kind;
            logic [3:0]    sel;
            logic [7:0]    idx;
            logic          is_slot;

            // beat t: ask the table
            assign tab_addr[gz*TAW +: TAW] = TAW'(BASE + int'(zs_c[gz]));

            // beat t + 1: the entry -> the addresses
            assign ent     = tab_data[gz*EW +: EW];
            assign kind    = ent[17:16];
            assign sel     = ent[15:12];
            assign idx     = ent[7:0];
            assign is_slot = (kind == KIND_SLOT) && (int'(sel) < NP) && (int'(idx) < S);

            always_comb begin
                for (int z = 0; z < 3; z++) rd_ha[gz][z] = {hsub(r1z_h[gz], delay_frames(K)), r1z_c[gz]};
                for (int p = 0; p < NP; p++) rd_pa[gz][p] = {~r1z_p[gz], SLW'(idx)};
            end

            always_ff @(posedge mclk) begin
                if (!rst_n) begin
                    r1z_v[gz] <= 1'b0;
                    r2z_v[gz] <= 1'b0;
                    rz_v[gz]  <= 1'b0;
                end else begin
                    r1z_v[gz] <= zs_v[gz];
                    r2z_v[gz] <= r1z_v[gz];
                    rz_v[gz]  <= r2z_v[gz];
                end
                r1z_c[gz]  <= zs_c[gz];
                r1z_h[gz]  <= hw;
                r1z_p[gz]  <= fpar;
                r2z_c[gz]  <= r1z_c[gz];
                r2z_sl[gz] <= is_slot;
                r2z_pl[gz] <= sel;
                // beat t + 2: choose
                rz_c[gz]   <= r2z_c[gz];
                rz_d[gz]   <= r2z_sl[gz] ? pq[gz][r2z_pl[gz]] : hq[gz][gz];
            end
        end
    endgenerate

    assign in_ret_valid  = rz_v[0];  assign in_ret_ch  = CWI'(rz_c[0]);  assign in_ret_data  = rz_d[0];
    assign bus_ret_valid = rz_v[1];  assign bus_ret_ch = CWB'(rz_c[1]);  assign bus_ret_data = rz_d[1];
    assign out_ret_valid = rz_v[2];  assign out_ret_ch = CWO'(rz_c[2]);  assign out_ret_data = rz_d[2];

    // ----- pool readers (r = 3 + p): the pools' input streams -----
    generate
        for (gp = 0; gp < NP; gp++) begin : g_pool
            localparam int R = 3 + gp;
            logic           run;
            logic [SLW-1:0] cnt;
            logic           r1_v, r2_v, o_v;
            logic [SLW-1:0] r1_s, r2_s, o_s;
            logic [HIW-1:0] r1_h;
            logic           r1_p;
            logic [1:0]     r2_k;            // 0 silence, 1 zone, 2 slot
            logic [3:0]     r2_sel;
            logic [SW-1:0]  o_d;
            logic [EW-1:0]  ent;
            logic [1:0]     kind;
            logic [3:0]     sel, age;
            logic [7:0]     idx;
            logic           ok_zone, ok_slot;

            // cycles 1 .. S after the strobe: ask the table for slot cnt
            assign tab_addr[R*TAW +: TAW] = TAW'(SRC_BASE + gp*S + int'(cnt));

            assign ent  = tab_data[R*EW +: EW];
            assign kind = ent[17:16];
            assign sel  = ent[15:12];
            assign age  = ent[11:8];
            assign idx  = ent[7:0];
            assign ok_zone = (kind == KIND_ZONE) && (int'(sel) < 3) && (int'(age) <= K)
                          && (int'(idx) < zone_n(int'(sel)));
            assign ok_slot = (kind == KIND_SLOT) && (int'(sel) < NP) && (int'(idx) < S);

            always_comb begin
                for (int z = 0; z < 3; z++) rd_ha[R][z] = {hsub(r1_h, 1 + int'(age)), CWM'(idx)};
                for (int p = 0; p < NP; p++) rd_pa[R][p] = {~r1_p, SLW'(idx)};
            end

            always_ff @(posedge mclk) begin
                if (!rst_n) begin
                    run  <= 1'b0;
                    cnt  <= '0;
                    r1_v <= 1'b0;
                    r2_v <= 1'b0;
                    o_v  <= 1'b0;
                end else begin
                    if (frame_i) begin
                        run <= 1'b1;
                        cnt <= '0;
                    end else if (run) begin
                        cnt <= cnt + 1'b1;
                        if (int'(cnt) == S - 1) run <= 1'b0;
                    end
                    r1_v <= run && !frame_i;
                    r2_v <= r1_v;
                    o_v  <= r2_v;
                end
                r1_s   <= cnt;
                r1_h   <= hw;
                r1_p   <= fpar;
                r2_s   <= r1_s;
                r2_k   <= ok_zone ? 2'd1 : ok_slot ? 2'd2 : 2'd0;
                r2_sel <= sel;
                o_s    <= r2_s;
                o_d    <= (r2_k == 2'd1) ? hq[R][r2_sel] :
                          (r2_k == 2'd2) ? pq[R][r2_sel] : '0;
            end

            assign pool_in_valid[gp]             = o_v;
            assign pool_in_ch[gp*SLW +: SLW]     = o_s;
            assign pool_in_data[gp*SW +: SW]     = o_d;
        end
    endgenerate

endmodule
