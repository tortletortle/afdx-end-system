file delete -force work
vlib work
set src [split $env(VLOG_SRC)]
if {[catch {eval vlog -sv +notimingcheck $src} msg]} {
  puts "VLOG-ERROR: $msg"
  quit -f -code 1
}
puts "VLOG-OK"
quit -f
