package require ::quartus::sta
source C:/Workspace/diansai/elinx/prj/quartus/check_sdc_8ns.tcl
project_open AFDX_top -revision AFDX_top
create_timing_netlist -post_map
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue7/step1_sta
report_sdc -file $out/post_map_sdc_tns_guard.rpt
check_sdc_8ns $out/post_map_sdc_tns_guard.rpt
puts "SDC_GUARD_OK: clk=8.000 ns"
create_timing_summary -setup -file $out/post_map_setup_summary.rpt
report_ucp -file $out/post_map_unconstrained.rpt
puts "TNS_SUMMARY_DONE"
delete_timing_netlist
project_close

