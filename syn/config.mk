# GEMM engine v1: OpenROAD-flow-scripts design config (nangate45)
#
# Used through syn/run.sh, which runs ORFS in its Docker image with the repo mounted at /work.
# Paths are relative to this file, so the config also works from a native ORFS install:
#   make -C <orfs>/flow DESIGN_CONFIG=<repo>/syn/config.mk synth

SYN_DIR  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_DIR := $(abspath $(SYN_DIR)/..)

export DESIGN_NAME     = gemm_top
export DESIGN_NICKNAME = gemm_v1
export PLATFORM        = nangate45

# same order as prj/v1/v1.f (package first)
export VERILOG_FILES = $(REPO_DIR)/prj/v1/gemm_v1_pkg.sv \
                       $(REPO_DIR)/rtl/ram_1r1w.sv \
                       $(REPO_DIR)/rtl/pe.sv \
                       $(REPO_DIR)/rtl/systolic.sv \
                       $(REPO_DIR)/rtl/skew.sv \
                       $(REPO_DIR)/rtl/delay_line.sv \
                       $(REPO_DIR)/rtl/sync_fifo.sv \
                       $(REPO_DIR)/prj/v1/weight_controller.sv \
                       $(REPO_DIR)/prj/v1/activation_controller.sv \
                       $(REPO_DIR)/prj/v1/out_controller.sv \
                       $(REPO_DIR)/prj/v1/top_controller.sv \
                       $(REPO_DIR)/prj/v1/gemm_top.sv
export SDC_FILE      = $(SYN_DIR)/constraint.sdc

# SystemVerilog (packages, structs, unpacked array ports) through the slang frontend
export SYNTH_HDL_FRONTEND = slang

# floorplan / place, for the later P&R run (no macros: all buffers are flops)
export CORE_UTILIZATION = 40
export PLACE_DENSITY    = 0.60
