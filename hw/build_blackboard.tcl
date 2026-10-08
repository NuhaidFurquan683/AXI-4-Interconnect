# =============================================================================
# Build the crossbar hardware test bitstream for the RealDigital Blackboard
# (Zynq XC7Z007S-1CLG400C). PL only — no processor/software required.
#
# Usage (from the hw/ directory):
#   vivado -mode batch -source build_blackboard.tcl
#   vivado -mode batch -source build_blackboard.tcl -tclargs <CLK_IN_MHZ> <SYS_MHZ> <REG_SLICE>
#
#   CLK_IN_MHZ  frequency of the board oscillator on pin H16 (default 100).
#               Check this against the Blackboard reference manual.
#   SYS_MHZ     0 (default) = run the test directly on the board clock;
#               100 / 125 / 160 / 200 / 250 = generate this with an MMCM
#   REG_SLICE   1 (default) or 0
#
# Output: hw/build/axi4_xbar_hw_<tag>.bit plus timing/utilisation reports.
# =============================================================================

set clk_in    [expr {[llength $argv] > 0 ? [lindex $argv 0] : 100}]
set sys_mhz   [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0}]
set reg_slice [expr {[llength $argv] > 2 ? [lindex $argv 2] : 1}]
set part      xc7z007sclg400-1

set use_mmcm  [expr {$sys_mhz > 0 ? 1 : 0}]
set run_mhz   [expr {$use_mmcm ? $sys_mhz : $clk_in}]
set tag       "${run_mhz}mhz_slice${reg_slice}"
file mkdir build

set rtl ../rtl
read_verilog -sv [list \
    $rtl/axi4_if.sv $rtl/axi4_lite_if.sv $rtl/skid_buffer.sv $rtl/round_robin_arbiter.sv \
    $rtl/address_decoder.sv $rtl/axi4_crossbar.sv $rtl/axi4_lite_control.sv \
    axi_traffic_gen.sv axi_bram_slave.sv axi4_xbar_hw_top.sv ]
read_xdc blackboard_xbar.xdc

set generics [list REG_SLICE=$reg_slice USE_MMCM=$use_mmcm CLK_IN_MHZ=$clk_in SYS_MHZ=$run_mhz]
synth_design -top axi4_xbar_hw_top -part $part -flatten_hierarchy rebuilt -generic $generics

# Board clock; the MMCM output clock (if used) is derived automatically
create_clock -name clk_in -period [expr {1000.0 / $clk_in}] [get_ports clk]
# Switches/buttons are asynchronous (synchronised in RTL); LEDs/7-seg are slow
set_false_path -from [get_ports {sw[*] btn[*]}]
set_false_path -to   [get_ports {led[*] RGB_led_A[*] RGB_led_B[*] seg_an[*] seg_cat[*]}]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 10      -file build/timing_${tag}.rpt
report_utilization                       -file build/util_${tag}.rpt
report_utilization -hierarchical         -file build/util_hier_${tag}.rpt
write_bitstream -force build/axi4_xbar_hw_${tag}.bit

set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
proc cnt {grp inst} { return [llength [get_cells -hier -quiet -filter "PRIMITIVE_GROUP == $grp && NAME =~ $inst/*"]] }
puts "\n========================== BUILD SUMMARY =========================="
puts [format "clock %d MHz (MMCM=%d)  REG_SLICE=%d  WNS=%+.3f ns  %s" \
        $run_mhz $use_mmcm $reg_slice $wns [expr {$wns >= 0 ? "TIMING MET" : "TIMING FAILED - do not trust results"}]]
puts [format "crossbar      : %5d LUT %5d FF" [cnt LUT u_xbar] [cnt FLOP_LATCH u_xbar]]
puts [format "control plane : %5d LUT %5d FF" [cnt LUT u_ctrl] [cnt FLOP_LATCH u_ctrl]]
puts [format "whole test    : %5d LUT %5d FF %d BRAM  (device: 14400 LUT, 28800 FF, 50 BRAM)" \
        [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
        [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] \
        [llength [get_cells -hier -filter {PRIMITIVE_GROUP == BLOCKRAM}]]]
puts "bitstream: hw/build/axi4_xbar_hw_${tag}.bit"
