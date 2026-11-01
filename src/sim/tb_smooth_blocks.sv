// -----------------------------------------------------------------------------
// tb_smooth_blocks.sv
//
// The library's coef_smooth (src/lib, HDL-DSP-Library; tested alone there,
// tb_coef_smooth) through FPGAmixer's own blocks, every output beat
// bit-exact (library foundation LF2/LF3, 2026-10-26; split off in step 3):
//   - pcm_gain (6 channels) -> coef_smooth (K 3) -> coef_flat_reader, the
//     bank swapping on the gain's coef_swap (its last input beat);
//   - pcm_matrix (4 -> 3, 2 lanes, 8 words) -> coef_smooth (K 3) ->
//     coef_flat_reader, swapping on the matrix's coef_swap;
// against models that smooth each coefficient ONCE PER FRAME (so coef_rd
// marks exactly one read per coefficient per frame) with the bank's target
// for that frame.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_smooth_blocks;
    import mixer_core_pkg::*;
    import pcm_matrix_pkg::*;

    logic mclk = 0;
    always #5 mclk = ~mclk;

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
    logic g_swap;                      // the gain's coef_swap (its last input beat)
    pcm_gain #(.N (NG), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW), .GAIN_FRAC (GF)) u_gain (
        .mclk, .rst_n, .in_valid (g_iv), .in_ch (g_ic), .in_data (g_id),
        .coef_addr (g_ca), .coef_rd (g_rd), .coef_swap (g_swap), .coef_data (g_cd),
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
    logic m_swap;                      // the matrix's coef_swap (its last input beat)
    pcm_matrix #(.N_IN (MI), .N_OUT (MO), .SAMPLE_WIDTH (SW), .GAIN_WIDTH (GW),
                 .GAIN_FRAC (GF), .LANES (ML)) u_mx (
        .mclk, .rst_n, .in_valid (m_iv), .in_ch (m_ic), .in_data (m_id),
        .coef_addr (m_ca), .coef_rd (m_rd), .coef_swap (m_swap), .coef_data (m_cd),
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
        wait (kg >= FRAMES && km >= FRAMES);
        repeat (4) @(posedge mclk);
        $display("  B: pcm_gain %0d frames, pcm_matrix %0d frames, %0d errors", kg, km, eb);
        total = eb;
        if (kg < FRAMES || km < FRAMES) total++;
        if (total == 0) $display("PASS: tb_smooth_blocks");
        else            $display("FAIL: tb_smooth_blocks - %0d errors", total);
        $finish;
    end

    initial begin
        #200ms;
        $display("FAIL: tb_smooth_blocks TIMEOUT");
        $finish;
    end
endmodule
