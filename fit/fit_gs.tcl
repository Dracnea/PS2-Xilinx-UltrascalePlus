# fit_gs.tcl -- out-of-context synthesis of one Graphics Synthesizer block.
#   vivado -mode batch -source fit_gs.tcl -tclargs [part] [top]
#
# The blocks of the GS are built one at a time and each one's cost is recorded
# in docs/gs.md or docs/gs-texture.md as it lands.  Out of context is the right
# measurement for that: it is the block's own cost with nothing optimised away
# across its boundary, which is what a number in a table has to mean if the
# table is going to be added up.
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xcu55n-fsvh2892-2LV-e"}]
set top  [expr {[llength $argv] > 1 ? [lindex $argv 1] : "gs_texcache"}]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../rtl]

# Every source, so that `top` can be any block of the GS or the whole of it.
# Out of context means nothing is optimised across the chosen top's boundary
# either way, so listing them all costs an unused block nothing.
read_vhdl -vhdl2008 [list \
   $rtl/gs/gs_addr_pkg.vhd \
   $rtl/gs/gs_texaddr.vhd \
   $rtl/gs/gs_clut.vhd \
   $rtl/gs/gs_texsample.vhd \
   $rtl/gs/gs_texcache.vhd \
   $rtl/gs/gs_edge_dda.vhd \
   $rtl/gs/gs_chan_dda.vhd \
   $rtl/gs/gs_gif.vhd \
   $rtl/gs/gs_pcrtc.vhd \
   $rtl/gs/gs_top.vhd \
   $rtl/gs/gs_lmem.vhd]
synth_design -top $top -part $part -mode out_of_context
# The GS's own clock. Without a constraint report_timing_summary has nothing to
# say, and a block whose cost is quoted but whose Fmax is not has only been half
# measured -- these blocks sit on the rasteriser's per-pixel path.
create_clock -period 6.782 -name clk [get_ports clk]
report_utilization -file utilization_$top.rpt
report_timing_summary -file timing_$top.rpt
