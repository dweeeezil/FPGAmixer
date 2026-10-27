// -----------------------------------------------------------------------------
// tb_coef_smooth.sv
//
// coef_smooth (library foundation, LF2/LF3, 2026-10-26).
//
// Part A, the smoother alone, behind a coef_flat_reader with LATCH (a bank
// that swaps on a pulse), at four sizes (W 18; DEPTH x LANES x K =
// 20 x 1 x 3, 5 x 3 x 2, 1 x 1 x 1, 2 x 2 x 8). Reads come in sweeps (every
// word once, in a random order, with random idle cycles whose rd_en is low
// and whose address is random, so a non-read is seen as a read of a random
// word); the bank's targets change between sweeps, mostly after 1..4 sweeps,
// sometimes after a hold longer than the convergence bound; targets are
// random, the extremes, or a few LSBs from the last. Checked on every read:
//   - rd_data, one cycle after rd_addr, equals a bit-exact model;
//   - no overshoot: it moves toward the target and never past it
//     (independent of the model);
//   - exact arrival: after (W + 1) * 2^K reads of an unchanged target it IS
//     the target, and stays so;
//   - an idle cycle changes nothing (the model only steps on rd_en).
//
// Part B, through real blocks, every output beat bit-exact:
//   - pcm_gain (6 channels) -> coef_smooth (K 3) -> coef_flat_reader, the
//     bank swapping on the gain's last input beat (as in mixer_core);
//   - pcm_matrix (4 -> 3, 2 lanes, 8 words) -> coef_smooth (K 3) ->
//     coef_flat_reader, swapping on its last input beat;
// against models that smooth each coefficient ONCE PER FRAME (so coef_rd
// marks exactly one read per coefficient per frame) with the bank's target
// for that frame.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

// ======================= Part A: the smoother alone ==========================
module smooth_unit #(
    parameter int W = 18, DEPTH = 20, LANES = 1, K = 3,
    parameter int PHASES = 40,           // target changes
    localparam int AW = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic mclk,
    output int   errors,
    output int   reads,
    output int   arrivals,               // reads that found the target already reached after a long hold
    output bit   done
);
    localparam int  BOUND = (W + 1) << K;          // reads to reach a held target exactly
    localparam longint ONE = longint'(1) << K;

    logic [AW-1:0]        rd_addr = '0;
    logic                 rd_en = 0, swap = 0;
    logic [LANES*W-1:0]   rd_data, bk_data;
    logic [AW-1:0]        bk_addr;
    logic [DEPTH*LANES*W-1:0] flat = '0;           // word-major: index = t*LANES + l

    // the flat reader's layout is row-major over N_ROWS = DEPTH*LANES rows of
    // one coefficient: give it LANES = 1 rows and do the lane split here
    // instead, so word t lane l = flat[(t*LANES + l)*W]
    coef_flat_reader #(.W (LANES*W), .N_ROWS (DEPTH), .ROW_LEN (1), .LANES (1), .LATCH (1)) u_bank (
        .mclk, .frame_i (swap), .coefs_flat (flat), .rd_addr (bk_addr), .rd_data (bk_data));
    coef_smooth #(.W (W), .DEPTH (DEPTH), .LANES (LANES), .K (K)) dut (
        .mclk, .rd_addr, .rd_en, .rd_data, .bk_addr, .bk_data);

    // ----- model -----
    longint cur   [DEPTH][LANES];                   // current values (K fraction bits)
    logic [W-1:0] bank [DEPTH][LANES];              // the bank in use
    logic [W-1:0] last_out [DEPTH][LANES];
    int           since [DEPTH][LANES];             // reads since the target changed
    int           err = 0;

    function automatic longint step(input longint c, input logic [W-1:0] t);
        longint tx, d;
        tx = longint'($signed(t)) <<< K;
        d  = tx - c;
        if (d > -ONE && d < ONE) return tx;
        return c + (d >>> K);
    endfunction
    function automatic longint sw(input logic [W-1:0] v); return longint'($signed(v)); endfunction

    // what each edge's read expects in the next cycle
    bit           exp_v = 0;
    int           exp_t;
    logic [W-1:0] exp_d [LANES];
    logic [W-1:0] exp_tgt [LANES];

    always @(posedge mclk) begin
        // the read issued in the cycle ending here (and the bank as it was)
        exp_v = rd_en;
        if (rd_en) begin
            exp_t = int'(rd_addr);
            for (int l = 0; l < LANES; l++) begin
                longint n;
                n = step(cur[exp_t][l], bank[exp_t][l]);
                cur[exp_t][l] = n;
                exp_d[l]   = W'(n >>> K);
                exp_tgt[l] = bank[exp_t][l];
            end
        end
        // the bank swaps on this edge, after the read (a read in the swap cycle sees the old)
        if (swap)
            for (int t = 0; t < DEPTH; t++)
                for (int l = 0; l < LANES; l++) begin
                    if (flat[(t*LANES + l)*W +: W] != bank[t][l]) since[t][l] = 0;
                    bank[t][l] = flat[(t*LANES + l)*W +: W];
                end
    end

    always @(negedge mclk) begin
        if (exp_v) begin
            reads++;
            for (int l = 0; l < LANES; l++) begin
                logic [W-1:0] got, prv, tg;
                got = rd_data[l*W +: W]; prv = last_out[exp_t][l]; tg = exp_tgt[l];
                if (got !== exp_d[l]) begin
                    err++;
                    if (err < 8) $display("[%0t] smooth %0dx%0dx%0d: word %0d lane %0d = %h, model %h",
                                          $time, DEPTH, LANES, K, exp_t, l, got, exp_d[l]);
                end
                // no overshoot, toward the target (independent of the model)
                if ((sw(prv) <= sw(tg) && (sw(got) < sw(prv) || sw(got) > sw(tg))) ||
                    (sw(prv) >  sw(tg) && (sw(got) > sw(prv) || sw(got) < sw(tg)))) begin
                    err++;
                    if (err < 8) $display("[%0t] smooth %0dx%0dx%0d: word %0d lane %0d went %h -> %h, target %h",
                                          $time, DEPTH, LANES, K, exp_t, l, prv, got, tg);
                end
                since[exp_t][l]++;
                if (since[exp_t][l] >= BOUND) begin
                    if (got !== tg) begin
                        err++;
                        if (err < 8) $display("[%0t] smooth %0dx%0dx%0d: word %0d lane %0d = %h after %0d reads, target %h",
                                              $time, DEPTH, LANES, K, exp_t, l, got, since[exp_t][l], tg);
                    end else
                        arrivals++;
                end
                last_out[exp_t][l] = got;
            end
        end
    end

    // ----- stimulus -----
    function automatic logic [W-1:0] rtarget(input logic [W-1:0] prev);
        case ($urandom % 6)
            0: return {1'b0, {(W-1){1'b1}}};           // most positive
            1: return {1'b1, {(W-1){1'b0}}};           // most negative
            2: return prev + W'(int'($urandom % 11) - 5);   // a few LSBs away
            3: return '0;
            default: return W'($urandom);
        endcase
    endfunction

    task automatic idle(input int n);
        repeat (n) begin
            @(negedge mclk);
            rd_en = 0; rd_addr = AW'($urandom % DEPTH);
        end
    endtask

    task automatic sweep();
        int perm [DEPTH];
        int j, x;
        for (int t = 0; t < DEPTH; t++) perm[t] = t;
        for (int t = DEPTH - 1; t > 0; t--) begin
            j = $urandom % (t + 1); x = perm[t]; perm[t] = perm[j]; perm[j] = x;
        end
        for (int t = 0; t < DEPTH; t++) begin
            @(negedge mclk);
            rd_en = 1; rd_addr = AW'(perm[t]);
            if ($urandom % 3 == 0) idle(1 + $urandom % 2);
        end
        idle(2);                                         // no back-to-back read of a word
    endtask

    initial begin
        reads = 0; arrivals = 0; done = 0;
        for (int t = 0; t < DEPTH; t++)
            for (int l = 0; l < LANES; l++) begin
                cur[t][l] = 0; bank[t][l] = '0; last_out[t][l] = '0; since[t][l] = 0;
            end
        repeat (3) @(negedge mclk);
        for (int ph = 0; ph < PHASES; ph++) begin
            int hold;
            // new targets, then a swap pulse in an idle cycle
            for (int t = 0; t < DEPTH; t++)
                for (int l = 0; l < LANES; l++)
                    flat[(t*LANES + l)*W +: W] = rtarget(flat[(t*LANES + l)*W +: W]);
            @(negedge mclk); rd_en = 0; swap = 1;
            @(negedge mclk); swap = 0;
            hold = (ph % 5 == 4) ? BOUND + 3 : 1 + $urandom % 4;
            repeat (hold) sweep();
        end
        done = 1;
    end

    assign errors = err + ((done && arrivals == 0) ? 1 : 0);   // the exact-arrival check must have run
endmodule


// ================= Part B (below): real blocks through a smoother ============
module tb_coef_smooth;
    import mixer_core_pkg::*;
    import pcm_matrix_pkg::*;

    logic mclk = 0;
    always #5 mclk = ~mclk;

    // ----- Part A -----
    int ea [4], ra [4], aa [4];
    bit da [4];
    smooth_unit #(.DEPTH (20), .LANES (1), .K (3))                u_a0 (.mclk, .errors (ea[0]), .reads (ra[0]), .arrivals (aa[0]), .done (da[0]));
    smooth_unit #(.DEPTH (5),  .LANES (3), .K (2))                u_a1 (.mclk, .errors (ea[1]), .reads (ra[1]), .arrivals (aa[1]), .done (da[1]));
    smooth_unit #(.DEPTH (1),  .LANES (1), .K (1))                u_a2 (.mclk, .errors (ea[2]), .reads (ra[2]), .arrivals (aa[2]), .done (da[2]));
    smooth_unit #(.DEPTH (2),  .LANES (2), .K (8), .PHASES (10))  u_a3 (.mclk, .errors (ea[3]), .reads (ra[3]), .arrivals (aa[3]), .done (da[3]));

    // ----- Part B: shared -----
    localparam int SW = 24, GW = 18, GF = 16, KB = 3, FR = 64, FRAMES = 160;
    localparam longint ONEB = longint'(1) << KB;
    logic rst_n = 0;
    int   cyc = -1, fr = -1;             // cycle in the frame, frame number
    logic frame = 0;
    always @(posedge mclk) begin
        if (rst_n) begin
            cyc <= (cyc == FR - 1 || cyc < 0) ? 0 : cyc + 1;
            if (cyc == FR - 1 || cyc < 0) fr <= fr + 1;
        end
    end
    function automatic longint stepb(input longint c, input logic [GW-1:0] t);
        longint tx, d;
        tx = longint'($signed(t)) <<< KB;
        d  = tx - c;
        if (d > -ONEB && d < ONEB) return tx;
        return c + (d >>> KB);
    endfunction
    function automatic longint sat(input longint v);
        if (v >  64'sd8388607) return  64'sd8388607;
        if (v < -64'sd8388608) return -64'sd8388608;
        return v;
    endfunction
    function automatic logic [GW-1:0] rgain(input logic [GW-1:0] prev);
        case ($urandom % 5)
            0: return 18'h10000;                    // unity
            1: return 18'h00000;
            2: return prev;                          // unchanged
            default: return GW'(int'($urandom % 131073) - 65536);
        endcase
    endfunction
    int eb = 0, kg = 0, km = 0;

    // ----- Part B1: pcm_gain, 6 channels, beats in cycles 2 .. 7 -----
    localparam int NG = 6;
    logic          g_iv = 0;  logic [2:0] g_ic = '0;  logic [SW-1:0] g_id = '0;
    logic          g_ov;      logic [2:0] g_oc;       logic [SW-1:0] g_od;
    logic [2:0]    g_ca, g_ba;  logic g_rd;  logic [GW-1:0] g_cd, g_bd;
    logic [NG*GW-1:0] g_flat = '0;
    wire g_swap = g_iv && (g_ic == 3'(NG - 1));
    pcm_gain #(.N (NG), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_gain (
        .mclk, .rst_n, .in_valid (g_iv), .in_ch (g_ic), .in_data (g_id),
        .coef_addr (g_ca), .coef_rd (g_rd), .coef_data (g_cd),
        .out_valid (g_ov), .out_ch (g_oc), .out_data (g_od));
    coef_smooth #(.W (GW), .DEPTH (NG), .LANES (1), .K (KB)) u_gs (
        .mclk, .rd_addr (g_ca), .rd_en (g_rd), .rd_data (g_cd), .bk_addr (g_ba), .bk_data (g_bd));
    coef_flat_reader #(.W (GW), .N_ROWS (NG), .ROW_LEN (1), .LANES (1), .LATCH (1)) u_gb (
        .mclk, .frame_i (g_swap), .coefs_flat (g_flat), .rd_addr (g_ba), .rd_data (g_bd));

    // the model: the bank in use (swaps after the last beat's read), the
    // smoothed value per channel, stepped on that channel's beat
    logic [GW-1:0] g_bank [NG];
    longint        g_cur  [NG];
    longint        g_exp  [$];      // expected output beats, in order
    always @(posedge mclk) begin
        if (rst_n && g_iv) begin
            longint gs;
            g_cur[g_ic] = stepb(g_cur[g_ic], g_bank[g_ic]);
            gs = g_cur[g_ic] >>> KB;
            g_exp.push_back(sat((longint'($signed(g_id)) * gs) >>> GF));
            if (g_ic == 3'(NG - 1))
                for (int c = 0; c < NG; c++) g_bank[c] = g_flat[c*GW +: GW];
        end
        if (rst_n && g_ov) begin
            longint w;
            w = g_exp.pop_front();
            if (g_od !== SW'(w)) begin
                eb++;
                if (eb < 8) $display("[%0t] gain: ch%0d = %06h, model %06h", $time, g_oc, g_od, SW'(w));
            end
            if (g_oc == 3'(NG - 1)) kg++;
        end
    end
    always @(negedge mclk) begin
        g_iv = 0;
        if (cyc >= 2 && cyc < 2 + NG) begin
            g_iv = 1; g_ic = 3'(cyc - 2); g_id = SW'($urandom);
        end
        // new targets in cycle 0 of every 3rd frame, and of a long run every 40
        if (cyc == 0 && (fr % 3 == 0) && (fr % 40 < 30))
            for (int c = 0; c < NG; c++) g_flat[c*GW +: GW] = rgain(g_flat[c*GW +: GW]);
    end

    // ----- Part B2: pcm_matrix, 4 -> 3 on 2 lanes (8 words), beats in cycles 2 .. 5 -----
    localparam int MI = 4, MO = 3, ML = 2;
    localparam int MP = matrix_passes(MO, ML), MD = MP * MI;    // 2 passes, 8 words
    logic          m_iv = 0;  logic [1:0] m_ic = '0;  logic [SW-1:0] m_id = '0;
    logic          m_ov;      logic [1:0] m_oc;       logic [SW-1:0] m_od;
    logic [2:0]    m_ca, m_ba;  logic m_rd;  logic [ML*GW-1:0] m_cd, m_bd;
    logic [MO*MI*GW-1:0] m_flat = '0;                    // row = output, column = input
    wire m_swap = m_iv && (m_ic == 2'(MI - 1));
    pcm_matrix #(.N_IN (MI), .N_OUT (MO), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW),
                 .GAIN_FRAC (GF), .LANES (ML)) u_mx (
        .mclk, .rst_n, .in_valid (m_iv), .in_ch (m_ic), .in_data (m_id),
        .coef_addr (m_ca), .coef_rd (m_rd), .coef_data (m_cd),
        .out_valid (m_ov), .out_ch (m_oc), .out_data (m_od));
    coef_smooth #(.W (GW), .DEPTH (MD), .LANES (ML), .K (KB)) u_ms (
        .mclk, .rd_addr (m_ca), .rd_en (m_rd), .rd_data (m_cd), .bk_addr (m_ba), .bk_data (m_bd));
    coef_flat_reader #(.W (GW), .N_ROWS (MO), .ROW_LEN (MI), .LANES (ML), .LATCH (1)) u_mb (
        .mclk, .frame_i (m_swap), .coefs_flat (m_flat), .rd_addr (m_ba), .rd_data (m_bd));

    // the model: on the last input beat the bank swaps and the frame's reads
    // begin, so frame f's targets are the vector at that edge; each word's
    // lane is stepped once per frame (word t, lane l = output (t/MI)*ML + l,
    // input t % MI; slots past the last output read 0)
    longint        m_cur [MD][ML];
    logic [SW-1:0] m_x   [MI];
    longint        m_exp [$];
    always @(posedge mclk) begin
        if (rst_n && m_iv) begin
            m_x[m_ic] = m_id;
            if (m_ic == 2'(MI - 1)) begin
                longint acc [MO];
                for (int o = 0; o < MO; o++) acc[o] = 0;
                for (int t = 0; t < MD; t++)
                    for (int l = 0; l < ML; l++) begin
                        int o, i;
                        logic [GW-1:0] tg;
                        o = (t / MI) * ML + l; i = t % MI;
                        tg = (o < MO) ? m_flat[(o*MI + i)*GW +: GW] : '0;
                        m_cur[t][l] = stepb(m_cur[t][l], tg);
                        if (o < MO) acc[o] += longint'($signed(m_x[i])) * (m_cur[t][l] >>> KB);
                    end
                for (int o = 0; o < MO; o++) m_exp.push_back(sat(acc[o] >>> GF));
            end
        end
        if (rst_n && m_ov) begin
            longint w;
            w = m_exp.pop_front();
            if (m_od !== SW'(w)) begin
                eb++;
                if (eb < 8) $display("[%0t] matrix: out%0d = %06h, model %06h", $time, m_oc, m_od, SW'(w));
            end
            if (m_oc == 2'(MO - 1)) km++;
        end
    end
    always @(negedge mclk) begin
        m_iv = 0;
        if (cyc >= 2 && cyc < 2 + MI) begin
            m_iv = 1; m_ic = 2'(cyc - 2); m_id = SW'($urandom);
        end
        if (cyc == 0 && (fr % 2 == 0) && (fr % 40 < 30))
            for (int k = 0; k < MO*MI; k++) m_flat[k*GW +: GW] = rgain(m_flat[k*GW +: GW]);
    end

    // ----- run -----
    initial begin
        int total;
        for (int c = 0; c < NG; c++) begin g_bank[c] = '0; g_cur[c] = 0; end
        for (int t = 0; t < MD; t++) for (int l = 0; l < ML; l++) m_cur[t][l] = 0;
        repeat (5) @(posedge mclk);
        rst_n = 1;
        wait (da[0] && da[1] && da[2] && da[3] && kg >= FRAMES && km >= FRAMES);
        repeat (4) @(posedge mclk);
        $display("  A: 20 words x 1 lane, K 3: %0d reads, %0d checked at the bound, %0d errors", ra[0], aa[0], ea[0]);
        $display("  A:  5 words x 3 lanes, K 2: %0d reads, %0d checked at the bound, %0d errors", ra[1], aa[1], ea[1]);
        $display("  A:  1 word  x 1 lane, K 1: %0d reads, %0d checked at the bound, %0d errors", ra[2], aa[2], ea[2]);
        $display("  A:  2 words x 2 lanes, K 8: %0d reads, %0d checked at the bound, %0d errors", ra[3], aa[3], ea[3]);
        $display("  B: pcm_gain %0d frames, pcm_matrix %0d frames, %0d errors", kg, km, eb);
        total = eb + ea[0] + ea[1] + ea[2] + ea[3];
        if (kg < FRAMES || km < FRAMES) total++;
        if (total == 0) $display("PASS: tb_coef_smooth");
        else            $display("FAIL: tb_coef_smooth - %0d errors", total);
        $finish;
    end

    initial begin
        #200ms;
        $display("FAIL: tb_coef_smooth TIMEOUT");
        $finish;
    end
endmodule
