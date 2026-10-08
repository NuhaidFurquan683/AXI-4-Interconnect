# =============================================================================
# Simulation with Verilator (>= 5.0, uses --timing)
#   make            -> unit tests + crossbar system test (both REG_SLICE builds)
#   make xbar1      -> crossbar system test with register slices
#   make xbar0      -> crossbar system test without register slices
#   make unit       -> skid_buffer, round_robin_arbiter, address_decoder
#   make lint       -> verilator -Wall lint of the RTL
#   make clean
# Build directories live outside the repo (default ~/.cache/axi4_sim) because
# Verilator's generated makefiles cannot build in paths containing spaces
# (e.g. /mnt/c/Users/HP OMEN/...). Override with: make OBJ=/some/path
# If your g++ is older than 13 and complains about coroutines, keep
# EXTRA_CFLAGS as below; with clang set EXTRA_CFLAGS= (empty).
# =============================================================================
VERILATOR    ?= verilator
EXTRA_CFLAGS ?= -CFLAGS -fcoroutines -CFLAGS -std=c++20
OBJ          ?= $(HOME)/.cache/axi4_sim
VFLAGS        = --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style $(EXTRA_CFLAGS)

RTL_DIR = ../rtl
TB_DIR  = ../tb

RTL = $(RTL_DIR)/axi4_if.sv $(RTL_DIR)/axi4_lite_if.sv $(RTL_DIR)/skid_buffer.sv \
      $(RTL_DIR)/round_robin_arbiter.sv $(RTL_DIR)/address_decoder.sv \
      $(RTL_DIR)/axi4_crossbar.sv $(RTL_DIR)/axi4_lite_control.sv

TB  = $(TB_DIR)/axi_tb_pkg.sv $(TB_DIR)/axi_master_bfm.sv $(TB_DIR)/axi_slave_mem.sv \
      $(TB_DIR)/axi_protocol_checker.sv $(TB_DIR)/axil_master_bfm.sv \
      $(TB_DIR)/tb_axi4_crossbar.sv

.PHONY: all unit xbar0 xbar1 lint clean

all: unit xbar1 xbar0

xbar1:
	mkdir -p $(OBJ)
	$(VERILATOR) $(VFLAGS) -GREG_SLICE=1 --top-module tb_axi4_crossbar -Mdir $(OBJ)/xbar1 -o sim $(RTL) $(TB)
	$(OBJ)/xbar1/sim | tee xbar1.log | grep -E "\-\-\-\-|ERROR|\*\*\*|counters|parallel|stall cycles|grant order"

xbar0:
	mkdir -p $(OBJ)
	$(VERILATOR) $(VFLAGS) -GREG_SLICE=0 --top-module tb_axi4_crossbar -Mdir $(OBJ)/xbar0 -o sim $(RTL) $(TB)
	$(OBJ)/xbar0/sim | tee xbar0.log | grep -E "\-\-\-\-|ERROR|\*\*\*|counters|parallel|stall cycles|grant order"

unit:
	mkdir -p $(OBJ)
	$(VERILATOR) $(VFLAGS) --top-module tb_skid_buffer -Mdir $(OBJ)/skid -o sim $(RTL_DIR)/skid_buffer.sv $(TB_DIR)/tb_skid_buffer.sv
	$(OBJ)/skid/sim | grep -E "ERROR|\*\*\*"
	$(VERILATOR) $(VFLAGS) --top-module tb_round_robin_arbiter -Mdir $(OBJ)/arb -o sim $(RTL_DIR)/round_robin_arbiter.sv $(TB_DIR)/tb_round_robin_arbiter.sv
	$(OBJ)/arb/sim | grep -E "ERROR|\*\*\*"
	$(VERILATOR) $(VFLAGS) --top-module tb_address_decoder -Mdir $(OBJ)/dec -o sim $(RTL_DIR)/address_decoder.sv $(TB_DIR)/tb_address_decoder.sv
	$(OBJ)/dec/sim | grep -E "ERROR|\*\*\*"

lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module axi4_crossbar \
	    $(RTL_DIR)/axi4_if.sv $(RTL_DIR)/skid_buffer.sv $(RTL_DIR)/round_robin_arbiter.sv \
	    $(RTL_DIR)/address_decoder.sv $(RTL_DIR)/axi4_crossbar.sv
	$(VERILATOR) --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNDRIVEN --top-module axi4_lite_control \
	    $(RTL_DIR)/axi4_lite_if.sv $(RTL_DIR)/axi4_lite_control.sv

clean:
	rm -rf $(OBJ) *.log
