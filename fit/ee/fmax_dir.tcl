# Fmax for one core under one set of implementation directives.
#   vivado ... -tclargs <file> <name> <place_dir> <phys_dir> <route_dir>
#
# The core is now 86% route on a five-level path, so the question has changed
# from "how deep is the logic" to "where did the placer put things". A single
# run answers neither: identical netlists have measured 15 MHz apart here.
set src   [lindex $argv 0]
set name  [lindex $argv 1]
set pdir  [lindex $argv 2]
set phdir [lindex $argv 3]
set rdir  [lindex $argv 4]
set part xcu55n-fsvh2892-2LV-e
set period 3.39
read_vhdl -vhdl2008 $src
synth_design -top ee_core -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
opt_design -quiet
place_design -directive $pdir -quiet
phys_opt_design -directive $phdir -quiet
route_design -directive $rdir -quiet
phys_opt_design -directive $phdir -quiet
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT name=$name place=$pdir phys=$phdir route=$rdir wns=${wns}ns fmax=[format %.1f [expr {1000.0/($period-$wns)}]]MHz"
report_timing -max_paths 4 -unique_pins -path_type summary -file fit/ee/sweep_$name.rpt
