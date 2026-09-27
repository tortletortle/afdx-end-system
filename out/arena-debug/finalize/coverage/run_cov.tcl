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
# The TB's $finish terminates the Questa script immediately: register the
# database write BEFORE run -all; commands after run -all never execute.
if {[catch {coverage save -onexit $env(COV_DB)} msg]} {
  puts "COVERAGE_ARM_FAIL: $msg"
  quit -f -code 1
}
puts "COVERAGE_ARMED: $env(COV_DB)"
run -all
