# Where does the R5900 datapath's time actually go?
#
# Fmax off one worst path tells you how far short you are; it does not tell you
# whether the shortfall is one structure or the whole core.  Twenty paths do:
# if they all start in the same place the fix is local, and if they are spread
# across unrelated units the core needs a pipeline stage, not a rewrite.
set part xcu55n-fsvh2892-2LV-e
set period 3.39
read_vhdl -vhdl2008 rtl/ee/ee_core.vhd
synth_design -top ee_core -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]
opt_design -quiet
place_design -quiet
phys_opt_design -quiet
route_design -quiet
phys_opt_design -quiet
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT wns=${wns}ns fmax=[format %.1f [expr {1000.0/($period-$wns)}]]MHz"

# -unique_pins so twenty paths are twenty *different* endpoints rather than
# twenty views of the same one.
report_timing -max_paths 20 -unique_pins -path_type summary -file fit/ee/paths_summary.rpt
report_timing -max_paths 8  -unique_pins -file fit/ee/paths_detail.rpt
report_utilization -file fit/ee/paths_util.rpt
