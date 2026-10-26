// GEMM engine v1: testbench file list (testbench files only)
//
// Always pass it together with the design list, from the repo root:
//   iverilog -g2012 -c prj/v1/v1.f -c prj/v1/tb/tb.f -o <out>.vvp
//   verilator ... -f prj/v1/v1.f -f prj/v1/tb/tb.f
// Not nested on purpose: Icarus resolves a nested list relative to the outer list's
// directory, Verilator relative to the working directory, so no nested path works in both.

// ---- testbench (add as written) ----
