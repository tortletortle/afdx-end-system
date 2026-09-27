# Negative precondition probe only; no AFDX_top mapped/P&R timing netlist exists.
# This MUST NOT be reported as timing sign-off or used to invent WNS/TNS/Fmax.
puts "STA_PROBE: attempting TimeQuest create_timing_netlist without a compiled project"
if {[catch {package require ::quartus::sta} why]} {
  puts "STA_PACKAGE_ERROR: $why"
  exit 2
}
if {[catch {create_timing_netlist} why]} {
  puts "STA_BLOCKED_NO_PROJECT_OR_NETLIST: $why"
  exit 3
}
puts "UNEXPECTED: create_timing_netlist succeeded; inspect netlist identity before reporting"
exit 4
