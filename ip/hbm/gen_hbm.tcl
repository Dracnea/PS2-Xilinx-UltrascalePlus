# Generate the HBM2 IP that LiteX's USPHBM2 wrapper expects at ip/hbm/hbm_0.xci.
#
#   vivado -mode batch -source ip/hbm/gen_hbm.tcl -tclargs <part> [module]
#
# The configuration is Corundum's for the Alveo cards, which is the public
# upstream this project already follows for the C1100's pin data
# (fpga/mqnic/Alveo/fpga_25g/ip/hbm_0.tcl).  It is deliberately minimal: 8 GB
# across two stacks with ECC correction on all sixteen memory controllers, and
# Vivado's defaults for everything else -- all 32 pseudo-channels enabled, the
# AXI ports at their default clock, the APB ports present.
#
# ECC is kept on.  It costs a little capacity and latency, and this card is one
# that runs hot enough for the satellite controller to care about; a bit flip in
# a staged disc image would surface as a corrupt game rather than an error.
set part   [lindex $argv 0]
set module [expr {[llength $argv] > 1 ? [lindex $argv 1] : "hbm_0"}]
set here   [file dirname [file normalize [info script]]]

create_project -in_memory -part $part
create_ip -name hbm -vendor xilinx.com -library ip -module_name $module -dir $here

# 33-bit AXI addressing, not the 32-bit default: 32 bits reaches 4 GB, which is
# one stack, and the disc sector cache is 6 GiB and therefore spans both.  The
# per-stack switches are left enabled so a single master can reach all of it.
#
# 250 MHz on the AXI ports rather than the 400 MHz default.  A 256-bit port at
# 250 MHz is 8 GB/s, and the thing being served is a disc: a PS2 DVD drive
# delivers tens of MB/s, so this is already two orders of magnitude of headroom
# and there is no reason to spend timing closure on the difference.
set cfg [list \
    CONFIG.USER_HBM_DENSITY {8GB} \
    CONFIG.USER_HBM_STACK {2} \
    CONFIG.USER_AXI_ADDR_SIZE {33} \
    CONFIG.USER_AXI_CLK_FREQ {250} \
    CONFIG.USER_SWITCH_ENABLE_00 {TRUE} \
    CONFIG.USER_SWITCH_ENABLE_01 {TRUE} \
]
for {set i 0} {$i < 16} {incr i} {
    lappend cfg CONFIG.USER_MC${i}_ENABLE_ECC_CORRECTION {true}
}
set_property -dict $cfg [get_ips $module]

generate_target all [get_ips $module]
puts "HBM_IP_OK [get_property IP_FILE [get_ips $module]]"
