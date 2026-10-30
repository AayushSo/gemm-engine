# GEMM engine v1: timing constraints (single clock domain)
#
# CLK_PERIOD (ns) can be overridden from the environment for period sweeps.
# I/O: every input arrives, and every output is needed, 20% of the period from the edge;
# so a flop-to-output or input-to-flop path gets 80% of the period, and the environment
# is assumed to register both sides of every bus.

set clk_period 5.0
if {[info exists ::env(CLK_PERIOD)]} { set clk_period $::env(CLK_PERIOD) }

create_clock -name core_clock -period $clk_period [get_ports clk]
set_clock_uncertainty 0.05 [get_clocks core_clock]

set io_delay [expr {0.2 * $clk_period}]
set non_clk_inputs [lsearch -inline -all -not -exact [all_inputs] [get_ports clk]]
set_input_delay  $io_delay -clock core_clock $non_clk_inputs
set_output_delay $io_delay -clock core_clock [all_outputs]

set_driving_cell -lib_cell BUF_X4 $non_clk_inputs
set_load 0.01 [all_outputs]
