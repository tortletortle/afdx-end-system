# =====================================================================
# T01 骨架冒烟运行脚本（Questasim / ModelSim 批处理）
# 用法: sim/ 目录下  .\\run_t01.ps1   或: vsim.exe -c -do "source run_t01.tcl"（需 SALT_LICENSE_SERVER，ps1 会自动补）
# 产出: 控制台 PASS/FAIL + out/t01_smoke.vcd
# =====================================================================
onerror { quit -f -code 1 }
file delete -force work
vlib work
vlog -sv +notimingcheck \
  ../rtl/common/rst_sync.v \
  ../rtl/common/timebase.v \
  ../rtl/common/sync_fifo.v \
  ../rtl/common/crc32.v \
  ../rtl/common/bram_sdp.v \
  ../rtl/top/init_sweep.v \
  ../rtl/top/AFDX_top.v \
  ../rtl/tx/tx_sn_gen.v ../rtl/tx/tx_port_buf.v \
  ../rtl/tx/tx_frame_builder.v ../rtl/tx/tx_vl_scheduler.v \
  ../rtl/tx/tx_rm.v ../rtl/tx/tx_pace.v ../rtl/tx/mac_tx_if.v \
  tb/tb_t01_reset_regs.v
file mkdir out
# -voptargs=+acc: T01 的 VCD 是正式产出（out/t01_smoke.vcd）。默认 vopt
# 优化会剥掉所有信号可见性，$dumpvars 只写出 scope 头（299 B，踩坑#11，
# 根因 2026-09-22 定位）。+acc 保住波形内容，代价约 2x 仿真时间。
vsim -voptargs=+acc tb_t01_reset_regs
run -all
quit -f
