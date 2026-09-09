# The HBM IP brings a debug hub whose clock Vivado does not connect on its own,
# and opt_design stops with "dbg_hub/clk has 1 unconnected channels".  Corundum
# hits the same thing on the same IP and pins it to the HBM APB clock
# (fpga/mqnic/Alveo/fpga_25g/hbm.xdc); that is the right clock because the hub
# then shares a domain with the block it monitors.
#
# This lives in a file rather than inline in the board script because LiteX runs
# str.format() over inline commands, and Tcl is made of braces.
set _hbmclk [get_nets -quiet apb_clk]
if {![llength $_hbmclk]} {
    set _hbmclk [lindex [get_nets -quiet -hierarchical -filter {NAME =~ *APB_0_PCLK*}] 0]
}
if {[llength [get_debug_cores -quiet dbg_hub]] && [llength $_hbmclk]} {
    connect_debug_port dbg_hub/clk $_hbmclk
    puts "HBM_DBGHUB_CLK $_hbmclk"
} else {
    puts "HBM_DBGHUB_SKIPPED (hub or apb clock net not found)"
}
