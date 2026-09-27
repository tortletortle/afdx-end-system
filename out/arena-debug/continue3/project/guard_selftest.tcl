# Exercise the same production guard on an 8 ns real report and the archived
# 1 ns silent-fallback report. This does not modify an SDC or project file.
source C:/Workspace/diansai/elinx/prj/quartus/check_sdc_8ns.tcl
set good C:/Workspace/diansai/out/arena-debug/continue3/raw/guarded/post_map_sdc.rpt
set bad C:/Workspace/diansai/out/arena-debug/continue2/sta/default_1ns_no_sdc/post_map_sdc.rpt
if {![check_sdc_8ns $good]} {
  error "8 ns valid report not accepted"
}
if {![catch {check_sdc_8ns $bad} why]} {
  error "1 ns default report incorrectly accepted"
}
if {![string match "*SDC_GUARD_FAILED*" $why]} {
  error "Unexpected negative-case error: $why"
}
puts "SDC_GUARD_SELFTEST_PASS good_8ns=accepted bad_1ns=rejected"
