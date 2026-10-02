# continue10 (2026-09-27): post-fit TimeQuest analysis - the first real routed-delay numbers.
# Run from elinx/prj/quartus after quartus_fit succeeds:
#   quartus_sta -t sta_post_fit.tcl
# Output dir defaults to out/arena-debug/continue10/sta ; override with env DIANSAI_STA_OUT.
package require ::quartus::sta
source [file join [file dirname [info script]] check_sdc_8ns.tcl]
project_open AFDX_top -revision AFDX_top
create_timing_netlist
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue10/sta
if {[info exists ::env(DIANSAI_STA_OUT)] && $::env(DIANSAI_STA_OUT) ne ""} { set out $::env(DIANSAI_STA_OUT) }
file mkdir $out
report_clocks -file $out/post_fit_clocks.rpt
report_sdc -file $out/post_fit_sdc.rpt
check_sdc_8ns $out/post_fit_sdc.rpt
puts "SDC_GUARD_OK: clk=8.000 ns"
report_clock_fmax_summary -file $out/post_fit_fmax.rpt
report_timing -setup -npaths 50 -detail full_path -file $out/post_fit_setup.rpt
report_timing -hold  -npaths 20 -detail full_path -file $out/post_fit_hold.rpt
report_timing -recovery -npaths 10 -file $out/post_fit_recovery.rpt
report_timing -removal  -npaths 10 -file $out/post_fit_removal.rpt
report_ucp -file $out/post_fit_unconstrained.rpt
check_timing -include {no_clock unconstrained_input_ports unconstrained_output_ports latency_override multiple_clock no_input_delay no_output_delay partial_input_delay partial_output_delay reference_pin generated_clock loops latches pos_neg_clock_domain pll_cross_check uncertainty virtual_clock partial_multicycle multicycle_consistency partial_min_max_delay io_min_max_delay_consistency clock_assignments_on_output_ports input_delay_assigned_to_clock} -file $out/post_fit_check_timing.rpt
# Machine-readable summary
set fs [open $out/post_fit_summary.txt w]
foreach dom [get_clock_domain_info -setup] { puts $fs "SETUP clock=[lindex $dom 0] slack=[lindex $dom 1] tns=[lindex $dom 2]" }
foreach dom [get_clock_domain_info -hold]  { puts $fs "HOLD  clock=[lindex $dom 0] slack=[lindex $dom 1] tns=[lindex $dom 2]" }
foreach dom [get_clock_fmax_info]          { puts $fs "FMAX  clock=[lindex $dom 0] fmax_MHz=[lindex $dom 1] restricted_MHz=[lindex $dom 2]" }
close $fs
puts [read [open $out/post_fit_summary.txt r]]
foreach_in_collection p [get_timing_paths -setup -npaths 1] { puts "POST_FIT_WORST_SETUP_SLACK_NS=[get_path_info $p -slack]" }
foreach_in_collection p [get_timing_paths -hold  -npaths 1] { puts "POST_FIT_WORST_HOLD_SLACK_NS=[get_path_info $p -slack]" }
puts "POST_FIT_STA_DONE"
delete_timing_netlist
project_close
