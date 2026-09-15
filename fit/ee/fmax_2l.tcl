# Fmax for a candidate ee_core, named on the command line, so a timing
# experiment never has to be staged through the tree it is being compared to.
#   vivado -mode batch -source fit/ee/fmax_file.tcl -tclargs <file> <name>
set src  [lindex $argv 0]
set name [lindex $argv 1]
set part xcu55n-fsvh2892-2L-e
set period 3.39
read_vhdl -vhdl2008 $src
synth_design -top ee_core -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
opt_design -quiet
place_design -quiet
phys_opt_design -quiet
route_design -quiet
phys_opt_design -quiet
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT name=$name wns=${wns}ns fmax=[format %.1f [expr {1000.0/($period-$wns)}]]MHz"
report_utilization -file fit/ee/util_$name.rpt
report_timing -max_paths 20 -unique_pins -path_type summary -file fit/ee/paths_$name.rpt
# The detail as well as the summary.  The summary says which endpoint is losing;
# only the cell-by-cell report says whether the time went into logic levels or
# into the wires between them, and those want opposite fixes.
report_timing -max_paths 6 -unique_pins -file fit/ee/detail_$name.rpt
