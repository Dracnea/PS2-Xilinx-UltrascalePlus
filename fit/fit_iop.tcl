# fit_iop.tcl -- out-of-context synthesis of the IOP subsystem on the C1100
#   vivado -mode batch -source fit_iop.tcl -tclargs [part]
set part  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xcu55n-fsvh2892-2L-e"}]
set here  [file dirname [file normalize [info script]]]
set root  [file normalize $here/..]
set up    $root/third_party/PSX_MiSTer/rtl
set rtl   $root/rtl
if {![file exists $up/cpu.vhd]} {
  puts "no PSX_MiSTer sources at $up"
  puts "run: git submodule update --init third_party/PSX_MiSTer"
  exit 1
}

read_vhdl -vhdl2008 -library altera_mf $rtl/altera_compat/altera_mf_components.vhd
read_verilog -library mem [list $rtl/altera_compat/altsyncram.v $rtl/altera_compat/altdpram.v]
read_vhdl -vhdl2008 -library mem [list \
  $up/RamMLAB.vhd $up/SyncFifoFallThroughMLAB.vhd $up/SyncFifo.vhd $up/SyncFifoFallThrough.vhd \
  $up/SyncRam.vhd $rtl/psx/SyncRamDual.vhd $rtl/psx/SyncRamDualNotPow2.vhd \
  $up/SyncRamDualByteEnable.vhd $up/dpram.vhd $up/export.vhd $up/divider.vhd $up/datacache.vhd \
  $up/cpu.vhd $up/timer.vhd $up/memctrl.vhd \
  $up/spu_gauss.vhd $up/spu_ram.vhd $up/spu.vhd \
  $rtl/iop/iop_regstub.vhd $rtl/iop/iop_console.vhd $rtl/iop/iop_intc.vhd $rtl/iop/iop_timer32.vhd \
  $rtl/iop/iop_ram.vhd $rtl/iop/iop_spuram.vhd $rtl/iop/iop_spu2.vhd \
  $rtl/iop/iop_sio2.vhd $rtl/iop/iop_cdvd.vhd \
  $rtl/iop/iop_memorymux.vhd $rtl/iop/iop_top.vhd]
synth_design -top iop_top -part $part -mode out_of_context -flatten_hierarchy rebuilt
# the IOP clock and the PSX core's phase-aligned multiples.  The periods must
# be exact multiples of each other: 27.127 / 13.563 / 9.042 leaves the
# clk2x -> clk1x paths with a 0.001 ns requirement (the two rising edges land
# 1 ps apart at 27.126 vs 27.127) and every such path fails by ~4 ns.
create_clock -period 27.126 -name clk1x [get_ports clk1x]
create_clock -period 13.563 -name clk2x [get_ports clk2x]
create_clock -period  9.042 -name clk3x [get_ports clk3x]
report_utilization -file utilization.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file utilization_hier.rpt
report_timing_summary -delay_type max -max_paths 10 -file timing.rpt
report_clocks -file clocks.rpt
write_checkpoint -force synth.dcp
puts "FIT DONE"
