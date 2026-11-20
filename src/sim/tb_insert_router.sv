// -----------------------------------------------------------------------------
// tb_insert_router.sv
//
// The insert router (docs/insert_architecture_proposal_2026-10-31.md sec. 11)
// with its real table store (coef_bank_ram, PORTS = 3 + NP, on an unrelated
// aclk) and two behavioural gain pools (y = sat(x * g >>> 16), latency 3, a
// gain per slot), against an exact model, frame by frame:
//   x(z, c, g)   the sample zone z channel c sent in frame g
//   src(p, s, g) slot s of pool p in run g: its SOURCE entry (the tables in
//                effect in frame g): silence, x(z, c, g - 1 - age), or
//                y(q, t, g - 1); out-of-range entries are silence
//   y(p, s, g)   sat(src(p, s, g) * gain(p, s, g) >>> 16)
//   ret(z, c, f) RETURN entry a slot: y(q, t, f - 1); otherwise (dry, or out
//                of range) x(z, c, f - (K + 1))
// The frame of the tables is observed at the bank's swap (its ack toggle),
// so every check uses exactly the tables the hardware should have used; a
// reader that saw half an edit fails it.
// Checked on every beat:
//   - each return comes back exactly INS_LAT cycles after its send, same
//     channel, with ret(z, c, f);
//   - each pool's input stream: slot s exactly POOL_IN_FIRST + s cycles
//     after the strobe, with src(p, s, g);
//   - err_o never pulses.
// Phases:
//   1. reset tables: every channel dry (K + 1 frames late), every slot silent;
//   2. random chains, rounds of them: 0 .. K slots per channel on all three
//      zones, in random order over both pools (hops pool -> pool both ways,
//      a type twice in one chain), heads mostly the channel itself, some
//      another zone's channel; random gains (saturation included); unused
//      slots read random (also out-of-range) sources; the last round uses
//      every slot;
//   3. edits on a channel with a chain, identity slots (gain 1.0):
//      front add, front remove: NO output of ANY channel changes (bit-exact,
//      against the model pinned to the tables before the edit);
//      mid-chain add: only that channel changes, in a few frames, then it is
//      bit-exact again (the slip the server covers with a dip).
// Two sizes: 5/4/3 channels, K 3, 6 slots; and the build's 20/20/20, K 8,
// 32 slots.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module router_harness
    import mixer_core_pkg::*;
    import insert_router_pkg::*;
#(
    parameter int N_I = 5,
    parameter int N_B = 4,
    parameter int N_O = 3,
    parameter int K   = 3,
    parameter int S   = 6,
    parameter int NP  = 2,
    parameter int ROUNDS = 4
) (
    input  logic aclk,
    input  logic mclk,
    output int   errors,
    output bit   done
);
    localparam int SW   = 24;
    localparam int LAT  = 3;                      // the behavioural pools
    localparam int CWI  = (N_I > 1) ? $clog2(N_I) : 1;
    localparam int CWB  = (N_B > 1) ? $clog2(N_B) : 1;
    localparam int CWO  = (N_O > 1) ? $clog2(N_O) : 1;
    localparam int SLW  = (S > 1) ? $clog2(S) : 1;
    localparam int NR   = 3 + NP;
    localparam int N_TAB = N_I + N_B + N_O + NP * S;
    localparam int TAW  = (N_TAB > 1) ? $clog2(N_TAB) : 1;
    localparam int SL_I = N_I + 1;               // the zones' send windows
    localparam int B0   = 100, O0 = 180;
    localparam int SL_B = B0 + 3 * N_B;
    localparam int SL_O = O0 + 3 * N_O;
    localparam int SRC_BASE = N_I + N_B + N_O;
    localparam int G1 = 32'h10000;                // gain 1.0

    function automatic int zone_n(input int z);
        return (z == 0) ? N_I : (z == 1) ? N_B : N_O;
    endfunction
    function automatic int ret_base(input int z);
        return (z == 0) ? 0 : (z == 1) ? N_I : N_I + N_B;
    endfunction

    // ----- DUT and its table store -----
    logic rst_n = 0, aresetn = 0, frame = 0;
    logic           is_v = 0, bs_v = 0, os_v = 0;
    logic [CWI-1:0] is_c = '0;  logic [CWB-1:0] bs_c = '0;  logic [CWO-1:0] os_c = '0;
    logic [SW-1:0]  is_d = '0, bs_d = '0, os_d = '0;
    logic           ir_v, br_v, or_v;
    logic [CWI-1:0] ir_c;  logic [CWB-1:0] br_c;  logic [CWO-1:0] or_c;
    logic [SW-1:0]  ir_d, br_d, or_d;
    logic [NP-1:0]     pi_v;
    logic [NP*SLW-1:0] pi_c;
    logic [NP*SW-1:0]  pi_d;
    logic [NP-1:0]     po_v = '0;
    logic [NP*SLW-1:0] po_c = '0;
    logic [NP*SW-1:0]  po_d = '0;
    logic              tab_swap, err_o;
    logic [NR*TAW-1:0] tab_addr;
    logic [NR*EW-1:0]  tab_data;

    insert_router #(.N_I (N_I), .N_B (N_B), .N_O (N_O), .SW (SW), .K (K), .S (S), .NP (NP),
                    .POOL_LAT (LAT), .SEND_LAST_I (SL_I), .SEND_LAST_B (SL_B),
                    .SEND_LAST_O (SL_O)) dut (
        .mclk, .rst_n, .frame_i (frame),
        .in_send_valid (is_v), .in_send_ch (is_c), .in_send_data (is_d),
        .in_ret_valid (ir_v), .in_ret_ch (ir_c), .in_ret_data (ir_d),
        .bus_send_valid (bs_v), .bus_send_ch (bs_c), .bus_send_data (bs_d),
        .bus_ret_valid (br_v), .bus_ret_ch (br_c), .bus_ret_data (br_d),
        .out_send_valid (os_v), .out_send_ch (os_c), .out_send_data (os_d),
        .out_ret_valid (or_v), .out_ret_ch (or_c), .out_ret_data (or_d),
        .pool_in_valid (pi_v), .pool_in_ch (pi_c), .pool_in_data (pi_d),
        .pool_out_valid (po_v), .pool_out_ch (po_c), .pool_out_data (po_d),
        .tab_swap (tab_swap), .tab_addr (tab_addr), .tab_data (tab_data),
        .err_o (err_o));

    logic             st_valid = 0, st_we = 0, st_ready, st_rvalid;
    logic [TAW-1:0]   st_idx = '0;
    logic [EW-1:0]    st_wdata = '0, st_rdata;
    logic             commit = 0, busy, queued;
    logic [31:0]      commits;

    coef_bank_ram #(.W (EW), .N_ROWS (N_TAB), .ROW_LEN (1), .LANES (1), .PORTS (NR),
                    .RESET_COEFS ('0)) u_bank (
        .aclk, .aresetn,
        .st_valid, .st_ready, .st_we, .st_idx, .st_wdata, .st_rvalid, .st_rdata,
        .commit, .busy, .queued, .commits,
        .mclk, .frame_i (tab_swap), .rd_addr (tab_addr), .rd_data (tab_data));

    int err = 0;
    task automatic fail(input string s);
        err++;
        if (err <= 15) $display("[%0t] %0d/%0d/%0d K%0d S%0d: %s", $time, N_I, N_B, N_O, K, S, s);
    endtask

    // ===== the model =====
    typedef logic [EW-1:0] ent_t;
    ent_t ver_tab [int][N_TAB];       // the tables of each version
    int   tabver  [longint];          // frame -> version in effect
    int   ver_frame [int];            // version -> its first frame
    longint xs    [longint];          // x(z, c, g)
    int   gains   [longint];          // gain(p, s, g)
    longint ymemo [longint];

    function automatic longint xkey(input int z, input int c, input longint g);
        return (longint'(z) * 256 + c) * 64'd10000000 + g;
    endfunction
    function automatic longint gkey(input int p, input int s, input longint g);
        return (longint'(p) * 512 + s) * 64'd10000000 + g;
    endfunction
    function automatic longint sat(input longint v);
        if (v >  64'sd8388607) return  64'sd8388607;
        if (v < -64'sd8388608) return -64'sd8388608;
        return v;
    endfunction
    function automatic longint xval(input int z, input int c, input longint g);
        if (g < 0 || !xs.exists(xkey(z, c, g))) return 0;
        return xs[xkey(z, c, g)];
    endfunction
    function automatic int ver_at(input longint g, input int pin);
        if (pin >= 0) return pin;
        return tabver.exists(g) ? tabver[g] : 0;
    endfunction

    function automatic longint yval(input int p, input int s, input longint g, input int pin);
        longint key, v, gn;
        if (g < 0) return 0;
        key = gkey(p, s, g) + longint'(pin + 1) * 64'd1000000000000;
        if (ymemo.exists(key)) return ymemo[key];
        v  = srcval(p, s, g, pin);
        gn = gains.exists(gkey(p, s, g)) ? gains[gkey(p, s, g)] : 0;
        v  = sat((v * gn) >>> 16);
        ymemo[key] = v;
        return v;
    endfunction

    function automatic longint srcval(input int p, input int s, input longint g, input int pin);
        ent_t e;
        int kind, sel, age, idx;
        e    = ver_tab[ver_at(g, pin)][SRC_BASE + p*S + s];
        kind = e[17:16]; sel = e[15:12]; age = e[11:8]; idx = e[7:0];
        if (kind == 1 && sel < 3 && age <= K && idx < zone_n(sel))
            return xval(sel, idx, g - 1 - age);
        if (kind == 2 && sel < NP && idx < S)
            return yval(sel, idx, g - 1, pin);
        return 0;
    endfunction

    function automatic longint retval(input int z, input int c, input longint f, input int pin);
        ent_t e;
        int kind, sel, idx;
        e    = ver_tab[ver_at(f, pin)][ret_base(z) + c];
        kind = e[17:16]; sel = e[15:12]; idx = e[7:0];
        if (kind == 2 && sel < NP && idx < S)
            return yval(sel, idx, f - 1, pin);
        return xval(z, c, f - delay_frames(K));
    endfunction

    // ===== the cycle loop: stimulus and checks =====
    longint T = 0;                    // the current mclk cycle (strobe when T % 256 == 0)
    longint fr = 0;                   // the frame of beats at offsets 1 .. 256
    int     gain_now [NP][S], gain_next [NP][S];
    int     sched_c [3][256];         // zone z: channel sent at offset o, or -1
    logic   ack_prev = 0;
    int     swaps = 0, cur_ver = 0;
    longint act [longint];            // returns seen, by xkey(z, c, f)
    int     pin_now = -1;             // >= 0: also count beats differing from that version

    typedef struct { int ch; longint f; longint t; } beat_t;
    beat_t  pend [3][$];
    typedef struct { int ch; longint d; longint t; } pout_t;
    pout_t  pq [NP][$];

    task automatic new_frame();
        int o;
        for (int z = 0; z < 3; z++) for (int j = 0; j < 256; j++) sched_c[z][j] = -1;
        for (int c = 0; c < N_I; c++) sched_c[0][2 + c] = c;          // like the input patch
        o = B0;
        for (int c = 0; c < N_B; c++) begin sched_c[1][o] = c; o += 1 + ($urandom % 3); end
        o = O0;
        for (int c = 0; c < N_O; c++) begin sched_c[2][o] = c; o += 1 + ($urandom % 3); end
        for (int z = 0; z < 3; z++)
            for (int c = 0; c < zone_n(z) && fr > 0; c++) begin   // frame 0 sends nothing
                longint v;
                v = $signed(24'($urandom));
                if ($urandom % 8 == 0) v = ($urandom % 2) ? 64'sd8388607 : -64'sd8388608;
                xs[xkey(z, c, fr)] = v;
            end
        for (int p = 0; p < NP; p++)
            for (int s = 0; s < S; s++) gains[gkey(p, s, fr)] = gain_now[p][s];
    endtask

    always @(posedge mclk) begin : cycle
        int o;
        #1;
        T++;
        o = int'(T % 256);
        if (T % 256 == 1) fr = (T - 1) / 256;

        // the bank's swap: the version for this frame
        if (o == 1) begin
            if (u_bank.ack_tgl !== ack_prev) begin
                swaps++;
                cur_ver = (swaps > 1) ? swaps - 1 : 0;
                ver_frame[cur_ver] = fr;
            end
            ack_prev = u_bank.ack_tgl;
            tabver[fr] = cur_ver;
            new_frame();
        end
        if (o == 150) gain_now = gain_next;

        if (rst_n) begin
            // ----- returns -----
            for (int z = 0; z < 3; z++) begin
                logic v; int ch; longint d;
                v  = (z == 0) ? ir_v : (z == 1) ? br_v : or_v;
                ch = (z == 0) ? int'(ir_c) : (z == 1) ? int'(br_c) : int'(or_c);
                d  = $signed((z == 0) ? ir_d : (z == 1) ? br_d : or_d);
                if (pend[z].size() > 0 && pend[z][0].t + INS_LAT == T) begin
                    beat_t b;
                    longint want;
                    b = pend[z].pop_front();
                    want = retval(z, b.ch, b.f, -1);
                    if (!v) fail($sformatf("zone %0d ch %0d: no return %0d cycles after its send", z, b.ch, INS_LAT));
                    else if (ch != b.ch) fail($sformatf("zone %0d: return ch %0d, want %0d", z, ch, b.ch));
                    else if (d != want)
                        fail($sformatf("zone %0d ch %0d frame %0d: return %0d, want %0d", z, ch, b.f, d, want));
                    act[xkey(z, b.ch, b.f)] = d;
                end else if (v)
                    fail($sformatf("zone %0d: a return with no send %0d cycles before", z, INS_LAT));
            end

            // ----- pool inputs; the pools -----
            for (int p = 0; p < NP; p++) begin
                if (pi_v[p]) begin
                    int s; longint d, want;
                    s = int'(pi_c[p*SLW +: SLW]);
                    d = $signed(pi_d[p*SW +: SW]);
                    if (o != POOL_IN_FIRST + s)
                        fail($sformatf("pool %0d slot %0d at offset %0d, want %0d", p, s, o, POOL_IN_FIRST + s));
                    want = srcval(p, s, fr, -1);
                    if (d != want)
                        fail($sformatf("pool %0d slot %0d run %0d: input %0d, want %0d", p, s, fr, d, want));
                    pq[p].push_back('{s, sat((d * gain_now[p][s]) >>> 16), T + LAT});
                end else if (o >= POOL_IN_FIRST && o < POOL_IN_FIRST + S && fr > 0 && T > 600)
                    fail($sformatf("pool %0d: no input beat at offset %0d", p, o));
            end
            if (err_o) fail("err_o");
        end

        // ----- drive this cycle -----
        frame = (T % 256 == 0);
        is_v = 0; bs_v = 0; os_v = 0;
        if (rst_n && T > 256) begin
            if (sched_c[0][o] >= 0) begin
                is_v = 1; is_c = CWI'(sched_c[0][o]); is_d = SW'(xval(0, sched_c[0][o], (T - 1) / 256));
                pend[0].push_back('{sched_c[0][o], (T - 1) / 256, T});
            end
            if (sched_c[1][o] >= 0) begin
                bs_v = 1; bs_c = CWB'(sched_c[1][o]); bs_d = SW'(xval(1, sched_c[1][o], (T - 1) / 256));
                pend[1].push_back('{sched_c[1][o], (T - 1) / 256, T});
            end
            if (sched_c[2][o] >= 0) begin
                os_v = 1; os_c = CWO'(sched_c[2][o]); os_d = SW'(xval(2, sched_c[2][o], (T - 1) / 256));
                pend[2].push_back('{sched_c[2][o], (T - 1) / 256, T});
            end
        end
        po_v = '0;
        for (int p = 0; p < NP; p++)
            if (pq[p].size() > 0 && pq[p][0].t == T) begin
                pout_t q;
                q = pq[p].pop_front();
                po_v[p] = 1'b1;
                po_c[p*SLW +: SLW] = SLW'(q.ch);
                po_d[p*SW +: SW]   = SW'(q.d);
            end
    end

    // ===== the tables, from the aclk side =====
    ent_t tab [N_TAB];
    int   nver = 0;

    task automatic st_write(input int k, input ent_t d);
        @(negedge aclk);
        st_valid = 1; st_we = 1; st_idx = TAW'(k); st_wdata = d;
        forever begin @(posedge aclk); if (st_ready) break; end
        @(negedge aclk) st_valid = 0; st_we = 0;
    endtask

    task automatic commit_tables();
        for (int k = 0; k < N_TAB; k++) st_write(k, tab[k]);
        nver++;
        ver_tab[nver] = tab;
        @(negedge aclk) commit = 1;
        @(negedge aclk) commit = 0;
        do @(posedge aclk); while (busy || queued);
        wait (cur_ver == nver);
    endtask

    task automatic wait_frames(input int n);
        longint f0;
        f0 = fr;
        wait (fr >= f0 + n);
    endtask

    // ----- chains -----
    int chain [3][256][$];             // slot ids p*S + s, head first
    int free_ids [$];

    function automatic ent_t slot_ent(input int id);
        return ent_slot(id / S, id % S);
    endfunction

    task automatic set_gain(input int id, input int g);
        gain_next[id / S][id % S] = g;
    endtask

    // write zone z channel c's chain into tab (heads at head_age(K, n))
    task automatic write_chain(input int z, input int c);
        int n;
        n = chain[z][c].size();
        if (n == 0) begin
            tab[ret_base(z) + c] = ENT_DRY;
            return;
        end
        for (int j = 0; j < n; j++) begin
            int id;
            id = chain[z][c][j];
            if (j == 0) begin
                if (tab[SRC_BASE + id][17:16] == KIND_ZONE)   // keep a chosen head channel
                    tab[SRC_BASE + id] = ent_zone(tab[SRC_BASE + id][15:12], tab[SRC_BASE + id][7:0],
                                                  head_age(K, n));
                else
                    tab[SRC_BASE + id] = ent_zone(z, c, head_age(K, n));
            end else
                tab[SRC_BASE + id] = slot_ent(chain[z][c][j-1]);
        end
        tab[ret_base(z) + c] = slot_ent(chain[z][c][n-1]);
    endtask

    task automatic random_round(input bit use_all, input int max_len);
        int ids [$];
        int reserve;
        reserve = use_all ? 0 : 3;                    // free slots kept for the edits
        for (int id = 0; id < NP*S; id++) ids.push_back(id);
        ids.shuffle();
        for (int k = 0; k < N_TAB; k++) tab[k] = '0;
        for (int z = 0; z < 3; z++)
            for (int c = 0; c < zone_n(z); c++) begin
                int n;
                chain[z][c].delete();
                n = $urandom % (max_len + 1);
                if (use_all) n = max_len;
                for (int j = 0; j < n && ids.size() > reserve; j++) chain[z][c].push_back(ids.pop_front());
                if (chain[z][c].size() > 0 && $urandom % 5 == 0) begin
                    int hz;
                    hz = $urandom % 3;                        // a head from elsewhere
                    tab[SRC_BASE + chain[z][c][0]] = ent_zone(hz, $urandom % zone_n(hz), 0);
                end
                write_chain(z, c);
            end
        free_ids = ids;
        // unused slots: random sources, some out of range
        foreach (ids[j]) begin
            int r;
            r = $urandom % 6;
            tab[SRC_BASE + ids[j]] =
                (r == 0) ? ENT_DRY :
                (r == 1) ? ent_zone($urandom % 3, $urandom % 4, $urandom % (K + 1)) :
                (r == 2) ? slot_ent($urandom % (NP*S)) :
                (r == 3) ? ent_zone(3 + $urandom % 2, 0, 0) :           // no such zone
                (r == 4) ? ent_zone(0, 0, K + 1 + $urandom % 2) :       // too old
                           {2'd3, 16'($urandom)};                       // no such kind
        end
        // the reserved slots probe the edges every round (a pool reads every
        // slot, used or not): the oldest valid age, kind 3 with fields that
        // would be valid as a zone, a channel past its zone
        if (ids.size() > 0) tab[SRC_BASE + ids[0]] = ent_zone(2, zone_n(2) - 1, K);
        if (ids.size() > 1) tab[SRC_BASE + ids[1]] = {2'd3, 4'd0, 4'd0, 8'd1};
        if (ids.size() > 2) tab[SRC_BASE + ids[2]] = ent_zone(0, N_I, 0);
        for (int p = 0; p < NP; p++)
            for (int s = 0; s < S; s++) begin
                int r;
                r = $urandom % 6;
                gain_next[p][s] = (r == 0) ? G1 : (r == 1) ? G1 / 2 : (r == 2) ? -G1 :
                                  (r == 3) ? G1 + G1 / 2 : (r == 4) ? 2 * G1 :
                                  int'($urandom % (2 * G1)) - G1;
            end
        // a few returns out of range: dry
        if (N_O > 1) tab[ret_base(2) + N_O - 1] = ent_slot(NP + 1, 0);
        if (N_B > 1 && chain[1][N_B-1].size() == 0) tab[ret_base(1) + N_B - 1] = ent_slot(0, S + 1);
    endtask

    // returns of every channel, frames f0 .. f1, against the model pinned to version v
    task automatic count_diffs(input longint f0, input longint f1, input int v,
                               output int n_other, output int n_this, input int tz, input int tc,
                               output longint last_diff);
        n_other = 0; n_this = 0; last_diff = -1;
        for (longint f = f0; f <= f1; f++)
            for (int z = 0; z < 3; z++)
                for (int c = 0; c < zone_n(z); c++) begin
                    longint k;
                    k = xkey(z, c, f);
                    if (!act.exists(k)) fail($sformatf("no return recorded: zone %0d ch %0d frame %0d", z, c, f));
                    else if (act[k] != retval(z, c, f, v)) begin
                        if (z == tz && c == tc) begin n_this++; last_diff = f; end
                        else n_other++;
                    end
                end
    endtask

    initial begin
        int ez, ec, n, id_c, id_d, vb, n_o, n_t;
        longint fb, ld;
        errors = 0; done = 0;
        for (int k = 0; k < N_TAB; k++) tab[k] = '0;
        ver_tab[0] = tab;
        foreach (gain_now[p, s]) begin gain_now[p][s] = G1; gain_next[p][s] = G1; end
        repeat (5) @(posedge aclk);
        aresetn = 1;
        repeat (3) @(posedge mclk);
        rst_n = 1;

        // ----- 1. reset tables -----
        wait_frames(K + 6);

        // ----- 2. random chains -----
        for (int r = 0; r < ROUNDS; r++) begin
            random_round(r == ROUNDS - 1, K);
            commit_tables();
            wait_frames(K + 4);
        end
        // the last round must have used every slot
        if (free_ids.size() != 0) fail($sformatf("%0d slots unused in the full round", free_ids.size()));

        // ----- 3. edits, identity slots -----
        random_round(0, (K > 2) ? K - 2 : 1);
        // the edited channel: a bus with a chain of n, 1 <= n <= K - 2 (room for two more)
        ez = 1; ec = 0;
        for (int c = 0; c < N_B; c++) if (chain[1][c].size() > 0) begin ec = c; break; end
        if (chain[ez][ec].size() == 0) chain[ez][ec].push_back(free_ids.pop_front());
        tab[SRC_BASE + chain[ez][ec][0]] = '0;           // its head: the channel itself
        write_chain(ez, ec);
        id_c = free_ids.pop_front();
        id_d = free_ids.pop_front();
        set_gain(id_c, G1);
        set_gain(id_d, G1);
        commit_tables();
        wait_frames(K + 4);
        n = chain[ez][ec].size();

        // front add: C reads the channel one frame fresher, then the head reads C
        tab[SRC_BASE + id_c] = ent_zone(ez, ec, head_age(K, n + 1));
        commit_tables();                                  // C unused yet: changes nothing
        wait_frames(2);
        vb = nver;
        chain[ez][ec].push_front(id_c);
        write_chain(ez, ec);
        commit_tables();
        fb = ver_frame[nver];
        wait_frames(K + 4);
        count_diffs(fb - 3, fb + K + 2, vb, n_o, n_t, ez, ec, ld);
        $display("  %0d/%0d/%0d K%0d: front add on bus %0d (chain %0d -> %0d): %0d frames changed",
                 N_I, N_B, N_O, K, ec, n, n + 1, n_t + n_o);
        if (n_o + n_t != 0) fail("front add was not bit-exact");

        // front remove: the second slot reads the channel again
        vb = nver;
        void'(chain[ez][ec].pop_front());
        write_chain(ez, ec);
        tab[SRC_BASE + id_c] = '0;
        commit_tables();
        fb = ver_frame[nver];
        wait_frames(K + 4);
        count_diffs(fb - 3, fb + K + 2, vb, n_o, n_t, ez, ec, ld);
        $display("  %0d/%0d/%0d K%0d: front remove: %0d frames changed", N_I, N_B, N_O, K, n_t + n_o);
        if (n_o + n_t != 0) fail("front remove was not bit-exact");

        // mid-chain add: D after the head (D reads the head first, unused)
        tab[SRC_BASE + id_d] = slot_ent(chain[ez][ec][0]);
        commit_tables();
        wait_frames(2);
        vb = nver;
        chain[ez][ec].insert(1, id_d);
        write_chain(ez, ec);
        commit_tables();
        fb = ver_frame[nver];
        wait_frames(K + 6);
        count_diffs(fb - 3, fb + K + 4, vb, n_o, n_t, ez, ec, ld);
        $display("  %0d/%0d/%0d K%0d: mid-chain add: that channel changed in %0d frames (last %0d after the edit), others %0d",
                 N_I, N_B, N_O, K, n_t, ld - fb, n_o);
        if (n_o != 0)      fail("mid-chain add changed another channel");
        if (n_t == 0)      fail("mid-chain add changed nothing (the slip is expected)");
        if (n_t > 2)       fail($sformatf("mid-chain add: %0d frames changed, expected at most 2", n_t));
        if (ld - fb > n + 2) fail("mid-chain add: the channel did not settle");

        wait_frames(3);
        errors = err;
        done = 1;
    end
endmodule


module tb_insert_router;
    logic aclk = 0, mclk = 0;
    always #5      aclk = ~aclk;          // 100 MHz
    always #40.690 mclk = ~mclk;          // 12.288 MHz, unrelated

    int e_a, e_b;
    bit d_a, d_b;
    router_harness #(.N_I (5),  .N_B (4),  .N_O (3),  .K (3), .S (6),  .NP (2), .ROUNDS (5)) u_a (
        .aclk, .mclk, .errors (e_a), .done (d_a));
    router_harness #(.N_I (20), .N_B (20), .N_O (20), .K (8), .S (32), .NP (2), .ROUNDS (4)) u_b (
        .aclk, .mclk, .errors (e_b), .done (d_b));

    initial begin
        wait (d_a && d_b);
        $display("5/4/3, K 3, 6 slots x 2 pools    : %0d errors", e_a);
        $display("20/20/20, K 8, 32 slots x 2 pools: %0d errors", e_b);
        if (e_a + e_b == 0) $display("PASS: tb_insert_router");
        else                $display("FAIL: tb_insert_router - %0d errors", e_a + e_b);
        $finish;
    end

    initial begin
        #400ms;
        $display("FAIL: tb_insert_router - timeout (done %0d %0d)", d_a, d_b);
        $finish;
    end
endmodule
