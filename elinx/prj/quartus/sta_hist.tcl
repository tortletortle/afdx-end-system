package require ::quartus::sta
project_open AFDX_top -revision AFDX_top
create_timing_netlist
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue10/sta
report_timing -setup -npaths 20000 -pairs_only -less_than_slack 0 -file $out/post_fit_setup_pairs.rpt
# Per-endpoint worst slack histogram by module instance
array set mod {}
array set modw {}
set n 0
foreach_in_collection p [get_timing_paths -setup -npaths 20000 -less_than_slack 0 -pairs_only] {
  set to [get_node_info -name [get_path_info $p -to]]
  set sl [get_path_info $p -slack]
  set m [lindex [split $to |] 0]
  if {[info exists mod($m)]} { incr mod($m) } else { set mod($m) 1; set modw($m) $sl }
  if {$sl < $modw($m)} { set modw($m) $sl }
  incr n
}
set fh [open $out/post_fit_failing_by_module.txt w]
puts $fh "failing_endpoint_pairs_counted=$n (cap 20000)"
foreach m [lsort -command {apply {{a b} {upvar 1 modw w; expr {$w($a) < $w($b) ? -1 : 1}}}} [array names mod]] {
  puts $fh [format "%-45s count=%6d worst_slack=%8.3f" $m $mod($m) $modw($m)]
}
close $fh
puts [read [open $out/post_fit_failing_by_module.txt r]]
puts "HIST_DONE"
delete_timing_netlist
project_close
