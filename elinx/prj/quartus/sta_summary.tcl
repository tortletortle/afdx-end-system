# continue2（2026-09-25）：post-map TimeQuest 汇总 —— TNS/WNS 与未约束路径取证。
package require ::quartus::sta
project_open AFDX_top -revision AFDX_top
create_timing_netlist -post_map
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue2/sta
create_timing_summary -setup -file $out/post_map_setup_summary.rpt
create_timing_summary -hold  -file $out/post_map_hold_summary.rpt
report_ucp -file $out/post_map_unconstrained.rpt
puts "SUMMARY_DONE"
delete_timing_netlist
project_close
