# =============================================================================
# Out-of-context synthesis + implementation on Zynq-7020 (xc7z020clg400-1)
# Runs the crossbar twice (REG_SLICE = 0 and 1) and reports timing + area.
#
# Usage (from the syn/ directory, Vivado Tcl shell or batch mode):
#   vivado -mode batch -source run_vivado.tcl
#   vivado -mode batch -source run_vivado.tcl -tclargs 4.0     ;# clock period in ns
#
# xc7z020clg400-1 is the part on PYNQ-Z2 / Zybo Z7-20 / Arty Z7-20.
# =============================================================================

set part    xc7z020clg400-1
set period  [expr {[llength $argv] > 0 ? [lindex $argv 0] : 5.0}]
set rtl_dir ../rtl
file mkdir reports

set sources [list \
    $rtl_dir/axi4_if.sv \
    $rtl_dir/axi4_lite_if.sv \
    $rtl_dir/skid_buffer.sv \
    $rtl_dir/round_robin_arbiter.sv \
    $rtl_dir/address_decoder.sv \
    $rtl_dir/axi4_crossbar.sv \
    $rtl_dir/axi4_lite_control.sv \
    axi4_xbar_synth_top.sv ]

set summary {}

foreach slice {0 1} {
    puts "\n=================  REG_SLICE = $slice   period = $period ns  ================="
    close_project -quiet
    create_project -in_memory -part $part
    read_verilog -sv $sources

    synth_design -top axi4_xbar_synth_top -part $part -mode out_of_context \
                 -generic REG_SLICE=$slice -flatten_hierarchy rebuilt

    create_clock -name clk -period $period [get_ports clk]

    opt_design
    place_design
    route_design

    set tag "slice${slice}_${period}ns"
    report_timing_summary -max_paths 10 -file reports/timing_${tag}.rpt
    report_utilization                  -file reports/util_${tag}.rpt
    report_timing -max_paths 5 -nworst 1 -file reports/worst_paths_${tag}.rpt

    set wns  [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
    set lut  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
    set ff   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
    set fmax [format "%.1f" [expr {1000.0 / ($period - $wns)}]]
    lappend summary [format "REG_SLICE=%d  period=%.2fns  WNS=%+.3fns  est.Fmax=%s MHz  LUTs=%d  FFs=%d" \
                            $slice $period $wns $fmax $lut $ff]
}

puts "\n======================== SUMMARY ========================"
foreach line $summary { puts $line }
puts "(LUT/FF counts include the timing-harness boundary registers)"
puts "Reports written to syn/reports/"

