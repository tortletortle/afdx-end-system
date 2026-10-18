# =====================================================================
# compile.tcl - fresh work lib + vlog all RTL & TB (called by run_regress.ps1)
# File list comes from env VLOG_SRC (space separated, forward slashes,
# relative to sim/). Kept as a file so the vsim cmdline stays quote-free.
# =====================================================================
if {![info exists env(VLOG_SRC)]} {
  puts "ERROR: VLOG_SRC env not set"
  quit -f -code 1
}
if {![info exists env(RUN_ISOLATED)] || $env(RUN_ISOLATED) ne "1"} {
  puts "ERROR: refusing to delete/create work outside an isolated regression snapshot"
  quit -f -code 1
}
file delete -force work
vlib work
set cov_args {}
if {[info exists env(VLOG_COVERAGE)] && $env(VLOG_COVERAGE) == "1"} {
  set cov_args {+cover=sb}
}
if {[catch {vlog -sv -mfcu -cuname afdx_regress +notimingcheck {*}$cov_args {*}$env(VLOG_SRC)} msg]} {
  puts "VLOG-ERROR: $msg"
  quit -f -code 1
}
quit -f


