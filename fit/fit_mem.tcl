# fit_mem.tcl -- out-of-context synthesis of the GS and EE memory blocks.
#   vivado -mode batch -source fit_mem.tcl -tclargs [part] [top]
#
# The point is the resource count, not the logic: docs/hbm.md claims the GS's
# 4 MB of local memory costs 128 UltraRAM and that the EE's 32 MB could not
# possibly fit on-die.  The first of those is a number worth checking rather
# than repeating, because the whole argument for where each memory lives rests
# on it.
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xcu55n-fsvh2892-2LV-e"}]
set top  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "gs_lmem"}]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../rtl]

read_vhdl -vhdl2008 -library mem [list $rtl/gs/gs_lmem.vhd $rtl/ee/ee_ram.vhd]
synth_design -top $top -part $part -mode out_of_context
report_utilization -file utilization_$top.rpt
report_timing_summary -file timing_$top.rpt
