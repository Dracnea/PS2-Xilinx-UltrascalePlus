# What clock does the R5900 integer datapath actually close at on this part?
# Constrained at the EE's own 294.912 MHz so the slack says directly how far
# off we are; Fmax follows as 1/(period - WNS).
set part [lindex $argv 0]
set period [lindex $argv 1]
read_vhdl -vhdl2008 rtl/ee/ee_core.vhd
synth_design -top ee_core -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
opt_design -quiet
place_design -quiet
route_design -quiet
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts "RESULT part=$part period=${period}ns wns=${wns}ns fmax=[format %.1f $fmax]MHz"
report_utilization -file fit/ee/util_[file tail $part].rpt
report_timing -max_paths 3 -file fit/ee/timing_[file tail $part].rpt
