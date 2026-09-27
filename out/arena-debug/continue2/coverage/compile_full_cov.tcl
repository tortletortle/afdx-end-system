# =====================================================================
# compile.tcl - fresh work lib + vlog all RTL & TB (called by run_regress.ps1)
# File list comes from env VLOG_SRC (space separated, forward slashes,
# relative to sim/). Kept as a file so the vsim cmdline stays quote-free.
# =====================================================================
if {![info exists env(VLOG_SRC)]} {
  puts "ERROR: VLOG_SRC env not set"
  quit -f -code 1
}
file delete -force work
vlib work
if {[catch {vlog -sv +cover=sb +notimingcheck {*}$env(VLOG_SRC)} msg]} {
  puts "VLOG-ERROR: $msg"
  quit -f -code 1
}
quit -f

