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
#   make -f scripts/sim.mk stream     # Phase 9 PCM stream contract + packed<->stream converters
#   make -f scripts/sim.mk coefram    # Phase 9 coefficient bank in RAM (read port, swap at the frame)
#   make -f scripts/sim.mk link       # Phase 8 PS<->PL link front door (AXIS <-> PCM, two clocks)
#   make -f scripts/sim.mk linkstat   # Phase 8 link status window (RO, snapshot atomicity)
#   make -f scripts/sim.mk regs       # Phase 5 AXI gain registers + CDC + matrix
#   make -f scripts/sim.mk phase3     # full phase-3 datapath integration test
#   make -f scripts/sim.mk all        # both (default)
#   make -f scripts/sim.mk clean
# =============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
FLAGS    ?= -g2012 -Wall
BUILD    ?= build_sim

RTL      := src/rtl
SIM      := src/sim

# RTL for the full non-PS top (fpgamixer_top without INCLUDE_PS): the platform
# clocking, the I2S front doors and the PCM core. Excludes the legacy
# phase1/phase2 tops and the control plane (not instantiated without the PS).
# Phase 9: the PCM core (mixer_core = converters + time-shared pcm_matrix).
# The package must come first.
MIXCORE  := $(RTL)/pcm_matrix_pkg.sv $(RTL)/pcm_pack2stream.sv $(RTL)/pcm_stream2pack.sv \
            $(RTL)/pcm_matrix.sv $(RTL)/mixer_core.sv

CORE_RTL := $(MIXCORE) $(RTL)/coef_flat_reader.sv \
            $(RTL)/i2s_receiver.sv $(RTL)/i2s_transmitter.sv \
            $(RTL)/i2s_clock_divider.sv $(RTL)/reset_sync.sv \
            $(RTL)/audio_clocking.sv $(RTL)/i2s_port.sv

.PHONY: all rx tx txphase loopback matrix matrix_rect stream coefram mclk regs link linkstat phase3 dynamic clean
all: rx tx txphase loopback matrix matrix_rect stream coefram mclk regs link linkstat phase3 dynamic

$(BUILD):
	@mkdir -p $(BUILD)

# --- Phase 2 unit / integration tests ---
rx: | $(BUILD)
	@echo ">>> Building tb_i2s_receiver"
	@$(IVERILOG) $(FLAGS) -s tb_i2s_receiver -o $(BUILD)/tb_i2s_receiver.vvp \
		$(RTL)/i2s_receiver.sv $(RTL)/i2s_clock_divider.sv $(SIM)/tb_i2s_receiver.sv
	@$(VVP) $(BUILD)/tb_i2s_receiver.vvp

tx: | $(BUILD)
	@echo ">>> Building tb_i2s_transmitter"
	@$(IVERILOG) $(FLAGS) -s tb_i2s_transmitter -o $(BUILD)/tb_i2s_transmitter.vvp \
		$(RTL)/i2s_transmitter.sv $(RTL)/i2s_clock_divider.sv $(SIM)/tb_i2s_transmitter.sv
	@$(VVP) $(BUILD)/tb_i2s_transmitter.vvp

# Pin-phase regression: sdata_o may only change while SCLK is low. Catches
# the launch-on-sampling-edge class of bug that functional capture checks
# (which use the in-house receiver as monitor) are structurally blind to.
txphase: | $(BUILD)
	@echo ">>> Building tb_i2s_tx_pin_phase"
	@$(IVERILOG) $(FLAGS) -s tb_i2s_tx_pin_phase -o $(BUILD)/tb_i2s_tx_pin_phase.vvp \
		$(RTL)/i2s_transmitter.sv $(RTL)/i2s_clock_divider.sv $(SIM)/tb_i2s_tx_pin_phase.sv
	@$(VVP) $(BUILD)/tb_i2s_tx_pin_phase.vvp

loopback: | $(BUILD)
	@echo ">>> Building tb_i2s_loopback"
	@$(IVERILOG) $(FLAGS) -s tb_i2s_loopback -o $(BUILD)/tb_i2s_loopback.vvp \
		$(RTL)/i2s_receiver.sv $(RTL)/i2s_transmitter.sv $(RTL)/i2s_clock_divider.sv \
		$(SIM)/tb_i2s_loopback.sv
	@$(VVP) $(BUILD)/tb_i2s_loopback.vvp

# --- Matrix unit test: pure PCM in/out, checked vs an independent reference ---
matrix: | $(BUILD)
	@echo ">>> Building tb_pcm_matrix"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_matrix -o $(BUILD)/tb_pcm_matrix.vvp \
		$(MIXCORE) $(RTL)/coef_flat_reader.sv $(SIM)/tb_pcm_matrix.sv
	@$(VVP) $(BUILD)/tb_pcm_matrix.vvp

# --- Sizes and lane counts (3->5 ... 32x32, forced lanes), random vs a reference ---
matrix_rect: | $(BUILD)
	@echo ">>> Building tb_pcm_matrix_rect"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_matrix_rect -o $(BUILD)/tb_pcm_matrix_rect.vvp \
		$(MIXCORE) $(RTL)/coef_flat_reader.sv \
		$(SIM)/pcm_stream_monitor.sv $(SIM)/tb_pcm_matrix_rect.sv
	@$(VVP) $(BUILD)/tb_pcm_matrix_rect.vvp

# --- Phase 9: PCM stream contract, packed <-> stream converters (N = 1, 12, 20) ---
stream: | $(BUILD)
	@echo ">>> Building tb_pcm_stream"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_stream -o $(BUILD)/tb_pcm_stream.vvp \
		$(RTL)/pcm_pack2stream.sv $(RTL)/pcm_stream2pack.sv \
		$(SIM)/pcm_stream_monitor.sv $(SIM)/tb_pcm_stream.sv
	@$(VVP) $(BUILD)/tb_pcm_stream.vvp

# --- Phase 9: coefficient bank in RAM (read port, swap at the frame), unrelated clocks ---
coefram: | $(BUILD)
	@echo ">>> Building tb_coef_bank_ram"
	@$(IVERILOG) $(FLAGS) -s tb_coef_bank_ram -o $(BUILD)/tb_coef_bank_ram.vvp \
		$(RTL)/coef_bank_ram.sv $(RTL)/coef_flat_reader.sv $(SIM)/tb_coef_bank_ram.sv
	@$(VVP) $(BUILD)/tb_coef_bank_ram.vvp

# --- Phase 9: media-clock meter (mclk vs a 1PPS from a TSU model), unrelated clocks ---
mclk: | $(BUILD)
	@echo ">>> Building tb_media_clock_meter"
	@$(IVERILOG) $(FLAGS) -s tb_media_clock_meter -o $(BUILD)/tb_media_clock_meter.vvp \
		$(RTL)/media_clock_meter.sv $(RTL)/coef_bank_handoff.sv $(RTL)/axil_stat_window.sv \
		$(RTL)/media_clock_stat_regs.sv $(SIM)/tb_media_clock_meter.sv
	@$(VVP) $(BUILD)/tb_media_clock_meter.vvp

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
		$(MIXCORE) $(RTL)/coef_bank_ram.sv $(RTL)/axil_coef_window.sv \
		$(RTL)/matrix_regs_axil.sv $(SIM)/tb_matrix_regs.sv
	@$(VVP) $(BUILD)/tb_matrix_regs.vvp

# --- Phase-3 integration: real fpgamixer_top (no PS), MMCM stubbed, rx/tx as fixtures ---
# -DSIM_ODDR selects the behavioral ODDR model inside oddr_out (the Xilinx
# primitive doesn't elaborate under Icarus). Sim-only define -- Vivado
# synthesis must see the real primitive. NOTE: a green run here only proves
# the datapath logic; the ODDR/pin-constraint timing this guards is validated
# by STA + hardware, not by this suite (handoff doc 6).
phase3: | $(BUILD)
	@echo ">>> Building tb_phase3_datapath"
	@$(IVERILOG) $(FLAGS) -DSIM_ODDR -s tb_phase3_datapath -o $(BUILD)/tb_phase3_datapath.vvp \
		$(CORE_RTL) $(RTL)/oddr_out.sv $(RTL)/fpgamixer_top.sv \
		$(SIM)/clk_wiz_audio_stub.sv $(SIM)/tb_phase3_datapath.sv
	@$(VVP) $(BUILD)/tb_phase3_datapath.vvp

# --- Phase-3 dynamic: changing value every frame, checked sample-by-sample ---
dynamic: | $(BUILD)
	@echo ">>> Building tb_phase3_dynamic"
	@$(IVERILOG) $(FLAGS) -DSIM_ODDR -s tb_phase3_dynamic -o $(BUILD)/tb_phase3_dynamic.vvp \
		$(CORE_RTL) $(RTL)/oddr_out.sv $(RTL)/fpgamixer_top.sv \
		$(SIM)/clk_wiz_audio_stub.sv $(SIM)/tb_phase3_dynamic.sv
	@$(VVP) $(BUILD)/tb_phase3_dynamic.vvp

clean:
	@rm -rf $(BUILD)
