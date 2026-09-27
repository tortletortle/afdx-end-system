file delete -force work
vlib work
if {{[catch {{eval vlog -sv +notimingcheck $env(VLOG_FILES)}} msg]}} {{ puts "VLOG-ERROR: $msg" ; quit -f -code 1 }}
quit -f
