# continue2（2026-09-25）：为 AFDX_top 建立真实 Quartus(Passkey/Quartus II 13.0.1)
# 工程与 revision，用于取得可审计的 Analysis&Synthesis / Fit / TimeQuest 结果。
# 器件族与型号取自本机实际安装清单（out/arena-debug/continue2/sta/part_list.txt）。
package require ::quartus::project
project_new -overwrite -revision AFDX_top AFDX_top
set_global_assignment -name FAMILY "Stratix IV"
set_global_assignment -name DEVICE EP4SGX230HF35C2
set_global_assignment -name TOP_LEVEL_ENTITY AFDX_top
set_global_assignment -name VERILOG_INPUT_VERSION VERILOG_2001
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
# 无板级引脚约束：允许自动引脚分配，结论仅覆盖内部寄存器到寄存器路径。
set_global_assignment -name AUTO_RESTART_CONFIGURATION OFF
set R C:/Workspace/diansai/rtl
foreach f [list \
  $R/common/rst_sync.v $R/common/timebase.v $R/common/sync_fifo.v \
  $R/common/crc32.v $R/common/bram_sdp.v $R/top/init_sweep.v \
  $R/tx/tx_sn_gen.v $R/tx/tx_port_buf.v $R/tx/tx_frame_builder.v \
  $R/tx/tx_vl_scheduler.v $R/tx/tx_rm.v $R/tx/tx_pace.v $R/tx/mac_tx_if.v \
  $R/rx/mac_rx_if.v $R/rx/rx_block_pool.v $R/rx/rx_pmem_queue.v $R/rx/rx_ic.v \
  $R/rx/rx_vl_lookup.v $R/rx/rx_flt.v $R/rx/rx_rm.v $R/rx/rx_ip_udp_parse.v \
  $R/rx/rx_port_buf.v $R/mgmt/mgmt_sap_rx.v $R/top/AFDX_top.v] {
  set_global_assignment -name VERILOG_FILE $f
}
set_global_assignment -name SDC_FILE C:/Workspace/diansai/elinx/sdc/AFDX_top.sdc
export_assignments
puts "PROJECT_CREATED revision=[get_current_revision]"
project_close
