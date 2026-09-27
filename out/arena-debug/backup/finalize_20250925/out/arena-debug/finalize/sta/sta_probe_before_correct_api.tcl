# Negative precondition probe only; no AFDX_top mapped/P&R timing netlist exists.
# This MUST NOT be reported as timing sign-off or used to invent WNS/TNS/Fmax.
puts "STA_PROBE: attempting TimeQuest read_netlist without a compiled project"
if {[catch {read_netlist} why]} {
  puts "STA_BLOCKED_NO_NETLIST: $why"
  exit 3
}
puts "UNEXPECTED: read_netlist succeeded; inspect netlist identity before reporting"
exit 4
