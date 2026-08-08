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

# RTL needed by the datapath (excludes phaseN_top except phase3).
CORE_RTL := $(RTL)/pcm_matrix.sv $(RTL)/i2s_receiver.sv $(RTL)/i2s_transmitter.sv \
            $(RTL)/i2s_clock_divider.sv $(RTL)/reset_sync.sv

.PHONY: all matrix phase3 clean
all: matrix phase3

$(BUILD):
	@mkdir -p $(BUILD)

# --- Matrix unit test: pure PCM in/out, checked vs an independent reference ---
matrix: | $(BUILD)
	@echo ">>> Building tb_pcm_matrix"
	@$(IVERILOG) $(FLAGS) -s tb_pcm_matrix -o $(BUILD)/tb_pcm_matrix.vvp \
		$(RTL)/pcm_matrix.sv $(SIM)/tb_pcm_matrix.sv
	@$(VVP) $(BUILD)/tb_pcm_matrix.vvp

# --- Phase-3 integration: real phase3_top, MMCM stubbed, rx/tx as fixtures ---
phase3: | $(BUILD)
	@echo ">>> Building tb_phase3_datapath"
	@$(IVERILOG) $(FLAGS) -s tb_phase3_datapath -o $(BUILD)/tb_phase3_datapath.vvp \
		$(CORE_RTL) $(RTL)/phase3_top.sv \
		$(SIM)/clk_wiz_audio_stub.sv $(SIM)/tb_phase3_datapath.sv
	@$(VVP) $(BUILD)/tb_phase3_datapath.vvp

clean:
	@rm -rf $(BUILD)
