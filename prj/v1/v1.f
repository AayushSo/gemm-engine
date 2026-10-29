// GEMM engine v1: design file list
//
// lint : verilator --lint-only -Wall -f prj/v1/v1.f --top-module <top>
// elab : iverilog -g2012 -c prj/v1/v1.f -s gemm_top -o <out>.vvp
//
// Order: project package first, then rtl/ (generic and shared modules),
// then prj/v1 (project modules). Nothing in rtl/ may import the package.

// ---- project package ----
prj/v1/gemm_v1_pkg.sv

// ---- rtl/: generic and shared ----
rtl/ram_1r1w.sv
rtl/pe.sv
rtl/systolic.sv
rtl/skew.sv
rtl/delay_line.sv
rtl/sync_fifo.sv

// ---- prj/v1: project modules  ----
prj/v1/weight_controller.sv
prj/v1/activation_controller.sv
prj/v1/out_controller.sv
prj/v1/top_controller.sv
prj/v1/gemm_top.sv
