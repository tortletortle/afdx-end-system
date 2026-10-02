package require ::quartus::sta
project_open AFDX_top -revision AFDX_top
create_timing_netlist
read_sdc
update_timing_netlist
set out C:/Workspace/diansai/out/arena-debug/continue10/sta
report_timing -setup -npaths 3 -detail full_path -to [get_registers {rx_vl_lookup:u_rxlookup|*}] -file $out/post_fit_setup_rxlookup.rpt
report_timing -setup -npaths 3 -detail full_path -to [get_registers {tx_port_buf:u_txbuf|*}]  -file $out/post_fit_setup_txbuf.rpt
report_timing -setup -npaths 3 -detail full_path -to [get_registers {tx_cfg_mem*}]  -file $out/post_fit_setup_txcfg.rpt
report_timing -setup -npaths 3 -detail full_path -to [get_registers {tx_vl_scheduler:u_sched|*}]  -file $out/post_fit_setup_sched.rpt
report_timing -setup -npaths 3 -detail full_path -to [get_registers {cfg_sum_r*}]  -file $out/post_fit_setup_cfgsum.rpt
puts "GROUPS_DONE"
delete_timing_netlist
project_close
