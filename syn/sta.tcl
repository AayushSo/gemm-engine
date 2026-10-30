# GEMM engine v1: pre-layout STA of the synthesized netlist (OpenROAD's OpenSTA)
# Env: LIB (liberty), ODB (ORFS's 1_synth.odb: the synthesized netlist, linked), SDC.
# Called by syn/run.sh. No placement yet, so net delays come from the liberty's wire load model
# and the clock is ideal.

read_liberty $::env(LIB)
read_db $::env(ODB)
read_sdc $::env(SDC)
set_wire_load_model -name 5K_hvratio_1_1	;# the liberty's default model

set T  [get_property [get_clocks core_clock] period]
set io 0.2					;# I/O delay as a fraction of the period (constraint.sdc)

set regs_ck [all_registers -clock_pins]
set regs_d  [all_registers -data_pins]
set ins     [lsearch -inline -all -not -exact [all_inputs] [get_ports clk]]
set outs    [all_outputs]

# path type -> {from, to, fraction of the period left for logic (+ setup + uncertainty)}
set groups [list \
	reg2reg [list $regs_ck $regs_d 1.0] \
	in2reg  [list $ins     $regs_d [expr {1.0 - $io}]] \
	reg2out [list $regs_ck $outs   [expr {1.0 - $io}]] \
	in2out  [list $ins     $outs   [expr {1.0 - 2 * $io}]]]

set summary {}
foreach {name g} $groups {
	lassign $g from to frac
	puts "\n==== worst $name path"
	report_checks -path_delay max -from $from -to $to -fields {fanout cap} -digits 3
	set p [find_timing_paths -path_delay max -from $from -to $to -group_path_count 1]
	if {[llength $p] == 0} { lappend summary [format "%-8s  no paths" $name]; continue }
	set slack [expr {[[lindex $p 0] slack] * 1e9}]	;# s -> ns
	# slack = frac*T - need, so the minimum period for this path type is T - slack/frac
	lappend summary [format "%-8s  slack %7.3f ns   min period %6.3f ns" $name $slack [expr {$T - $slack / $frac}]]
}

puts "\n==== worst hold path"
report_checks -path_delay min -digits 3

puts "\n==== summary (clock period $T ns)"
foreach l $summary { puts $l }
report_wns -digits 3
report_tns -digits 3
report_check_types -max_slew -max_capacitance -violators
