# Run from sim/ after compile_cov.tcl, env COV_TB and COV_DB set by caller.
onerror {quit -f -code 1}
if {![info exists env(COV_TB)] || ![info exists env(COV_DB)]} {
  puts "COVERAGE_RUN_FAIL: COV_TB/COV_DB not set"
  quit -f -code 1
}
if {[catch {vsim -coverage $env(COV_TB)} msg]} {
  puts "COVERAGE_RUN_FAIL: $msg"
  quit -f -code 1
}
run -all
if {[catch {coverage save $env(COV_DB)} msg]} {
  puts "COVERAGE_SAVE_FAIL: $msg"
  quit -f -code 1
}
puts "COVERAGE_SAVE_OK: $env(COV_DB)"
quit -f
