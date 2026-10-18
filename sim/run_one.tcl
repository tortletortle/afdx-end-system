# =====================================================================
# run_one.tcl - run a single TB in this vsim session (called by
# run_regress.ps1; TB module name comes from env TEST_TB).
# One vsim process per test case = doc 12.4 "independent vsim session".
# Wave visibility: default vopt optimization strips all signals, so
# $dumpvars writes a header-only VCD (week-0 pitfall #11, root-caused
# 2026-09-22). Set env VSIM_ACC=1 to add -voptargs=+acc when you need
# real waveforms (about 2x sim time).
# =====================================================================
onerror { quit -f -code 1 }
if {![info exists env(TEST_TB)]} {
  puts "ERROR: TEST_TB env not set"
  quit -f -code 1
}
if {![info exists env(TEST_BIND_TOP)]} {
  puts "ERROR: TEST_BIND_TOP env not set"
  quit -f -code 1
}
set bind_top $env(TEST_BIND_TOP)
if {$bind_top ni {"none" "afdx_bind_full" "afdx_bind_rx_ic" "afdx_bind_mac_tx_if"}} {
  puts "ERROR: invalid TEST_BIND_TOP '$bind_top'"
  quit -f -code 1
}
set vsim_args {}
if {[info exists env(VSIM_ACC)] && $env(VSIM_ACC) == "1"} {
  lappend vsim_args -voptargs=+acc
}
if {[info exists env(UCDB_OUT)]} {
  lappend vsim_args -coverage
}
# optional plusargs for negative/limit runs (run_regress.ps1 -PlusArgs)
if {[info exists env(VSIM_PLUSARGS)] && $env(VSIM_PLUSARGS) ne ""} {
  foreach pa [split $env(VSIM_PLUSARGS)] { if {$pa ne ""} { lappend vsim_args $pa } }
}
set tops [list $env(TEST_TB)]
if {$bind_top ne "none"} { lappend tops work.$bind_top }
if {[catch {vsim {*}$vsim_args {*}$tops} msg]} {
  puts "VSIM-ERROR: $msg"
  quit -f -code 1
} else {
  if {[info exists env(UCDB_OUT)]} {
    coverage save -onexit $env(UCDB_OUT)
  }
  run -all
}
quit -f
