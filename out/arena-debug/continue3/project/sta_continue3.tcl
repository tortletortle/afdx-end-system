# Same EP4SGX230HF35C2 and 8.000 ns SDC as continue2; post-map only.
package require ::quartus::sta
project_open AFDX_top -revision AFDX_top
create_timing_netlist -post_map
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue3/raw
report_clocks -file $out/post_map_clocks.rpt
report_sdc -file $out/post_map_sdc.rpt
# Quartus silently substitutes a 1 ns default if SDC is absent/invalid.
# Fail closed before reporting a fabricated 125 MHz comparison.
set f [open $out/post_map_sdc.rpt r]
set sdc_text [read $f]
close $f
if {![regexp {;[[:space:]]*create_clock[[:space:]]*;[[:space:]]*clk[[:space:]]*;[[:space:]]*8\.000[[:space:]]*;} $sdc_text]} {
  error "SDC_GUARD_FAILED: expected create_clock clk 8.000 ns"
}
puts "SDC_GUARD_OK: clk=8.000 ns"
report_timing -setup -npaths 20 -detail full_path -file $out/post_map_setup.rpt
report_clock_fmax_summary -file $out/post_map_fmax.rpt
create_timing_summary -setup -file $out/post_map_setup_summary.rpt
# Do not expand report_ucp here: the previous full report was >2.5M lines.
# The unchanged SDC intentionally leaves external IO delays unspecified.
foreach_in_collection p [get_timing_paths -setup -npaths 1] {
  puts "CONTINUE3_WORST_SETUP_SLACK_NS=[get_path_info $p -slack]"
}
puts "CONTINUE3_POST_MAP_STA_DONE"
delete_timing_netlist
project_close
