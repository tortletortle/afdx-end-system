# continue2（2026-09-25）：post-map（综合后、布局布线前）TimeQuest 分析。
# 边界：post-map 网表没有布线延时与最终布局，**不是时序签核**；
#       其 setup slack 是乐观上界，hold 结论无意义，故只取 setup/Fmax 并明确标注。
package require ::quartus::sta
source [file join [file dirname [info script]] check_sdc_8ns.tcl]
project_open AFDX_top -revision AFDX_top
create_timing_netlist -post_map
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue2/sta
if {[info exists ::env(DIANSAI_STA_OUT)] && $::env(DIANSAI_STA_OUT) ne ""} {
  set out $::env(DIANSAI_STA_OUT)
}
file mkdir $out
report_clocks -file $out/post_map_clocks.rpt
report_sdc -file $out/post_map_sdc.rpt
check_sdc_8ns $out/post_map_sdc.rpt
puts "SDC_GUARD_OK: clk=8.000 ns"
report_timing -setup -npaths 20 -detail full_path -file $out/post_map_setup.rpt
report_clock_fmax_summary -file $out/post_map_fmax.rpt
foreach_in_collection p [get_timing_paths -setup -npaths 1] {
  puts "POST_MAP_WORST_SETUP_SLACK_NS=[get_path_info $p -slack]"
}
puts "POST_MAP_STA_DONE"
delete_timing_netlist
project_close
