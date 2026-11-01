# =============================================================================
# sim.mk  -- command-line simulation with Icarus Verilog (no Vivado/XSim)
#
# This is the trustworthy sim path: it drives the RTL through an open-source
# event-driven simulator, entirely independent of Vivado's XSim GUI/Tcl flow.
# Every module under test is plain synthesizable SystemVerilog with no Xilinx
# primitives; the one Vivado IP (the Clocking Wizard MMCM) is replaced for sim
# by src/sim/clk_wiz_audio_stub.sv, which is NEVER synthesized.
#
# Requires Icarus Verilog >= 11 (macOS: `brew install icarus-verilog`;
# Debian/Ubuntu: `apt-get install iverilog`).
#
# Usage (from repo root):
#   make -f scripts/sim.mk matrix     # matrix unit test
#   make -f scripts/sim.mk matrix_rect  # non-square matrices (3->5, 5->2)
#   make -f scripts/sim.mk corepkg    # Phase 12 core chain arithmetic (lanes, D)
#   make -f scripts/sim.mk gain       # Phase 12 per-channel gain stage
#   make -f scripts/sim.mk core       # Phase 12 whole core chain (levels + two matrices)
#   make -f scripts/sim.mk stream     # Phase 9 PCM stream contract + packed<->stream converters
#   make -f scripts/sim.mk smooth_blocks  # LF2/LF3: pcm_gain / pcm_matrix through the library's coef_smooth
# (coefram and the smoother alone moved to the library's regression, step 3)
#   make -f scripts/sim.mk link       # Phase 8 PS<->PL link front door (AXIS <-> PCM, two clocks)
#   make -f scripts/sim.mk linkstat   # Phase 8 link status window (RO, snapshot atomicity)
#   make -f scripts/sim.mk regs       # Phase 5 AXI gain registers + CDC + matrix
#   make -f scripts/sim.mk router     # LF8 insert router (chains, edits, the table store)
#   make -f scripts/sim.mk topwin     # fpgamixer_top as a PS build: every window wired
#   make -f scripts/sim.mk all        # all of them (default)
# (The Pmod I2S tests rx, tx, txphase, loopback, phase3, dynamic moved to
# src/archive/sim with the Pmod RTL in Phase 11.)
#   make -f scripts/sim.mk clean
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
FLAGS    ?= -g2012 -Wall
BUILD    ?= build_sim

RTL      := src/rtl
SIM      := src/sim
# the library (submodule HDL-DSP-Library, library step 3): its primitives;
# their own TBs run in the library's regression
LRTL     := src/lib/rtl
LSIM     := src/lib/sim

# RTL for fpgamixer_top: the platform clocking and the PCM core (the Pmod
# front doors are gone since Phase 11). The PCM core: mixer_core = converters + gain stages + two time-shared
# matrices (Phase 12). The packages must come first. MXSIM: the single matrix
# between the converters, for the matrix TBs (sim only).
MIXCORE  := $(RTL)/pcm_matrix_pkg.sv $(RTL)/mixer_core_pkg.sv \
            $(RTL)/pcm_pack2stream.sv $(RTL)/pcm_stream2pack.sv \
            $(RTL)/pcm_patch2stream.sv $(RTL)/pcm_stream2patch.sv \
            $(RTL)/pcm_matrix.sv $(RTL)/pcm_gain.sv $(RTL)/pcm_insert_loop.sv \
            $(RTL)/mixer_core.sv
MXSIM    := $(SIM)/matrix_packed_sim.sv

# LF8 (2026-10-31): the insert router, and the library's template block (the gain pool)
LTPL     := src/lib/template
ROUTER   := $(RTL)/insert_router_pkg.sv $(RTL)/insert_router.sv

CORE_RTL := $(MIXCORE) $(LRTL)/coef_flat_reader.sv $(LRTL)/coef_smooth.sv \
            $(ROUTER) $(LTPL)/lib_template_pkg.sv $(LTPL)/lib_template.sv \
            $(RTL)/reset_sync.sv $(RTL)/audio_clocking.sv

.PHONY: all matrix matrix_rect corepkg gain core stream patch smooth_blocks mclk steer regs gainregs patchregs peak link linkstat router topwin clean
all: matrix matrix_rect corepkg gain core stream patch smooth_blocks mclk steer regs gainregs patchregs peak link linkstat router topwin

# --- LF8: the insert router with its table store and two gain pools ---
router: | $(BUILD)
	@echo ">>> Building tb_insert_router"
	@$(IVERILOG) $(FLAGS) -s tb_insert_router -o $(BUILD)/tb_insert_router.vvp \
		$(RTL)/pcm_matrix_pkg.sv $(RTL)/mixer_core_pkg.sv $(ROUTER) \
		$(LRTL)/coef_bank_ram.sv $(SIM)/tb_insert_router.sv
	@$(VVP) $(BUILD)/tb_insert_router.vvp

$(BUILD):
	@mkdir -p $(BUILD)

# --- Matrix unit test: pure PCM in/out, checked vs an independent reference ---
matrix: | $(BUILD)
	@echo ">>> Building tb_pcm_matrix"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_matrix -o $(BUILD)/tb_pcm_matrix.vvp \
		$(MIXCORE) $(MXSIM) $(LRTL)/coef_flat_reader.sv $(SIM)/tb_pcm_matrix.sv
	@$(VVP) $(BUILD)/tb_pcm_matrix.vvp

# --- Sizes and lane counts (3->5 ... 32x32, forced lanes), random vs a reference ---
matrix_rect: | $(BUILD)
	@echo ">>> Building tb_pcm_matrix_rect"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_matrix_rect -o $(BUILD)/tb_pcm_matrix_rect.vvp \
		$(MIXCORE) $(MXSIM) $(LRTL)/coef_flat_reader.sv \
		$(LSIM)/pcm_stream_monitor.sv $(SIM)/tb_pcm_matrix_rect.sv
	@$(VVP) $(BUILD)/tb_pcm_matrix_rect.vvp

# --- Phase 12: the whole core chain (levels, two matrices), random vs a chain model ---
core: | $(BUILD)
	@echo ">>> Building tb_mixer_core"
	@$(IVERILOG) $(FLAGS) -s tb_mixer_core -o $(BUILD)/tb_mixer_core.vvp \
		$(MIXCORE) $(LRTL)/coef_flat_reader.sv \
		$(LSIM)/pcm_stream_monitor.sv $(SIM)/tb_mixer_core.sv
	@$(VVP) $(BUILD)/tb_mixer_core.vvp

# --- Phase 12: the core chain's arithmetic (lanes, D) vs independent values ---
corepkg: | $(BUILD)
	@echo ">>> Building tb_mixer_core_pkg"
	@$(IVERILOG) $(FLAGS) -s tb_mixer_core_pkg -o $(BUILD)/tb_mixer_core_pkg.vvp \
		$(RTL)/pcm_matrix_pkg.sv $(RTL)/mixer_core_pkg.sv $(SIM)/tb_mixer_core_pkg.sv
	@$(VVP) $(BUILD)/tb_mixer_core_pkg.vvp

# --- Phase 12: per-channel gain stage (N = 1, 4, 20, 28; gaps), random vs a reference ---
gain: | $(BUILD)
	@echo ">>> Building tb_pcm_gain"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_gain -o $(BUILD)/tb_pcm_gain.vvp \
		$(RTL)/pcm_matrix_pkg.sv $(RTL)/mixer_core_pkg.sv $(RTL)/pcm_gain.sv \
		$(LRTL)/coef_flat_reader.sv $(LSIM)/pcm_stream_monitor.sv $(SIM)/tb_pcm_gain.sv
	@$(VVP) $(BUILD)/tb_pcm_gain.vvp

# --- Phase 9: PCM stream contract, packed <-> stream converters (N = 1, 12, 20) ---
stream: | $(BUILD)
	@echo ">>> Building tb_pcm_stream"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_stream -o $(BUILD)/tb_pcm_stream.vvp \
		$(RTL)/pcm_pack2stream.sv $(RTL)/pcm_stream2pack.sv \
		$(LSIM)/pcm_stream_monitor.sv $(SIM)/tb_pcm_stream.sv
	@$(VVP) $(BUILD)/tb_pcm_stream.vvp

# --- Phase 15: the patch converters (input / output patch), random tables vs a model ---
patch: | $(BUILD)
	@echo ">>> Building tb_pcm_patch"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_patch -o $(BUILD)/tb_pcm_patch.vvp \
		$(RTL)/pcm_patch2stream.sv $(RTL)/pcm_stream2patch.sv $(LRTL)/coef_flat_reader.sv \
		$(LSIM)/pcm_stream_monitor.sv $(SIM)/tb_pcm_patch.sv
	@$(VVP) $(BUILD)/tb_pcm_patch.vvp

# --- LF2/LF3: pcm_gain / pcm_matrix through the library's coef_smooth ---
smooth_blocks: | $(BUILD)
	@echo ">>> Building tb_smooth_blocks"
	@$(IVERILOG) $(FLAGS) -s tb_smooth_blocks -o $(BUILD)/tb_smooth_blocks.vvp \
		$(RTL)/pcm_matrix_pkg.sv $(RTL)/mixer_core_pkg.sv $(RTL)/pcm_gain.sv $(RTL)/pcm_matrix.sv \
		$(LRTL)/coef_flat_reader.sv $(LRTL)/coef_smooth.sv $(SIM)/tb_smooth_blocks.sv
	@$(VVP) $(BUILD)/tb_smooth_blocks.vvp

# --- Phase 9: media-clock meter (mclk vs a 1PPS from a TSU model), unrelated clocks ---
mclk: | $(BUILD)
	@echo ">>> Building tb_media_clock_meter"
	@$(IVERILOG) $(FLAGS) -s tb_media_clock_meter -o $(BUILD)/tb_media_clock_meter.vvp \
		$(RTL)/media_clock_meter.sv $(RTL)/coef_bank_handoff.sv $(RTL)/axil_stat_window.sv \
		$(RTL)/media_clock_stat_regs.sv $(SIM)/tb_media_clock_meter.sv
	@$(VVP) $(BUILD)/tb_media_clock_meter.vvp

# --- Phase 9: media-clock steering (MMCM phase-step model + the meter) ---
steer: | $(BUILD)
	@echo ">>> Building tb_media_clock_steer"
	@$(IVERILOG) $(FLAGS) -s tb_media_clock_steer -o $(BUILD)/tb_media_clock_steer.vvp \
		$(RTL)/axil_reg_window.sv $(RTL)/media_clock_ctrl_regs.sv $(RTL)/media_clock_steer.sv \
		$(RTL)/media_clock_meter.sv $(SIM)/tb_media_clock_steer.sv
	@$(VVP) $(BUILD)/tb_media_clock_steer.vvp

# --- Phase 8: PS<->PL link front door, formatter AXIS <-> PCM on unrelated clocks ---
link: | $(BUILD)
	@echo ">>> Building tb_pcm_link"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_link -o $(BUILD)/tb_pcm_link.vvp \
		$(RTL)/async_fifo.sv $(RTL)/pcm_link.sv $(SIM)/tb_pcm_link.sv
	@$(VVP) $(BUILD)/tb_pcm_link.vvp

# --- Phase 8: the link's read-only status window (handoff in reverse, mclk -> aclk) ---
linkstat: | $(BUILD)
	@echo ">>> Building tb_link_stat_regs"
	@$(IVERILOG) $(FLAGS) -s tb_link_stat_regs -o $(BUILD)/tb_link_stat_regs.vvp \
		$(RTL)/coef_bank_handoff.sv $(RTL)/axil_stat_window.sv \
		$(RTL)/pcm_link_stat_regs.sv $(SIM)/tb_link_stat_regs.sv
	@$(VVP) $(BUILD)/tb_link_stat_regs.vvp

# --- Phase 5: AXI4-Lite gain registers across aclk/mclk into the matrix ---
regs: | $(BUILD)
	@echo ">>> Building tb_matrix_regs"
	@$(IVERILOG) $(FLAGS) -s tb_matrix_regs -o $(BUILD)/tb_matrix_regs.vvp \
		$(MIXCORE) $(MXSIM) $(LRTL)/coef_bank_ram.sv $(LRTL)/axil_coef_window.sv \
		$(RTL)/matrix_regs_axil.sv $(SIM)/tb_matrix_regs.sv
	@$(VVP) $(BUILD)/tb_matrix_regs.vvp

# --- Phase 12: a gain stage's AXI4-Lite window across aclk/mclk into pcm_gain ---
gainregs: | $(BUILD)
	@echo ">>> Building tb_gain_regs"
	@$(IVERILOG) $(FLAGS) -s tb_gain_regs -o $(BUILD)/tb_gain_regs.vvp \
		$(MIXCORE) $(LRTL)/coef_bank_ram.sv $(LRTL)/axil_coef_window.sv \
		$(RTL)/gain_regs_axil.sv $(SIM)/tb_gain_regs.sv
	@$(VVP) $(BUILD)/tb_gain_regs.vvp

# --- Phase 15: the two patch windows across aclk/mclk into the patch converters ---
patchregs: | $(BUILD)
	@echo ">>> Building tb_patch_regs"
	@$(IVERILOG) $(FLAGS) -s tb_patch_regs -o $(BUILD)/tb_patch_regs.vvp \
		$(RTL)/pcm_patch2stream.sv $(RTL)/pcm_stream2patch.sv $(LRTL)/coef_bank_ram.sv \
		$(LRTL)/axil_coef_window.sv $(RTL)/patch_regs_axil.sv $(SIM)/tb_patch_regs.sv
	@$(VVP) $(BUILD)/tb_patch_regs.vvp

# --- Phase 13: the peak meter window (SNAP, windows vs a model) across aclk/mclk ---
peak: | $(BUILD)
	@echo ">>> Building tb_pcm_peak"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_peak -o $(BUILD)/tb_pcm_peak.vvp \
		$(LRTL)/axil_coef_window.sv $(RTL)/pcm_peak.sv $(RTL)/peak_regs_axil.sv \
		$(SIM)/tb_pcm_peak.sv
	@$(VVP) $(BUILD)/tb_pcm_peak.vvp

# --- Phase 12: fpgamixer_top as a PS build (INCLUDE_PS), the BD replaced by
# ps_sys_wrapper_stub: each register window on its port, driving its block ---
topwin: | $(BUILD)
	@echo ">>> Building tb_top_windows"
	@$(IVERILOG) $(FLAGS) -DINCLUDE_PS -s tb_top_windows -o $(BUILD)/tb_top_windows.vvp \
		$(CORE_RTL) $(LRTL)/coef_bank_ram.sv $(LRTL)/axil_coef_window.sv \
		$(RTL)/matrix_regs_axil.sv $(RTL)/gain_regs_axil.sv $(RTL)/pcm_peak.sv \
		$(RTL)/peak_regs_axil.sv $(RTL)/patch_regs_axil.sv \
		$(RTL)/insert_router_regs_axil.sv $(LTPL)/lib_template_regs_axil.sv $(RTL)/fpgamixer_top.sv \
		$(SIM)/ps_sys_wrapper_stub.sv $(SIM)/clk_wiz_audio_stub.sv $(SIM)/tb_top_windows.sv
	@$(VVP) $(BUILD)/tb_top_windows.vvp

clean:
	@rm -rf $(BUILD)
