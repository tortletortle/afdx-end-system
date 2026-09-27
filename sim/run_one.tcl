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
set vsim_args {}
if {[info exists env(VSIM_ACC)] && $env(VSIM_ACC) == "1"} {
  lappend vsim_args -voptargs=+acc
}
if {[info exists env(UCDB_OUT)]} {
  lappend vsim_args -coverage
}
if {[catch {vsim {*}$vsim_args $env(TEST_TB)} msg]} {
  puts "VSIM-ERROR: $msg"
  quit -f -code 1
} else {
  if {[info exists env(UCDB_OUT)]} {
    coverage save -onexit $env(UCDB_OUT)
  }
  run -all
}
quit -f
