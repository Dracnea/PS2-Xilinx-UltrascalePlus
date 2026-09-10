# The same measurement as fmax.tcl, but with the core confined to a few clock
# regions.  An out-of-context module placed loose on a die this large can spread
# out and pay routing delay it would never pay inside a real design, so a number
# measured without a floorplan can understate the core.  Half the critical path
# is routing, which is exactly the symptom, so this asks the question directly.
set part [lindex $argv 0]
set period [lindex $argv 1]
read_vhdl -vhdl2008 rtl/ee/ee_core.vhd
synth_design -top ee_core -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
create_pblock pb_core
add_cells_to_pblock pb_core [get_cells -hierarchical -filter {IS_PRIMITIVE}]
resize_pblock pb_core -add CLOCKREGION_X0Y0:CLOCKREGION_X1Y1
opt_design -quiet
place_design -quiet
route_design -quiet
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts "RESULT-PBLOCK part=$part period=${period}ns wns=${wns}ns fmax=[format %.1f $fmax]MHz"
report_timing -max_paths 3 -file fit/ee/timing_pblock.rpt
