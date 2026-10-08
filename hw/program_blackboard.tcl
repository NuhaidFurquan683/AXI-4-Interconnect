# =============================================================================
# Program the Blackboard PL over USB-JTAG
# Usage (from hw/, board plugged in and powered):
#   vivado -mode batch -source program_blackboard.tcl -tclargs build/axi4_xbar_hw_100mhz_slice1.bit
# =============================================================================
set bit [expr {[llength $argv] > 0 ? [lindex $argv 0] : "build/axi4_xbar_hw_100mhz_slice1.bit"}]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7z007s*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "Programmed $dev with $bit"
close_hw_target
disconnect_hw_server
