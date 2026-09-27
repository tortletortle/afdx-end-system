vsim -coverage tb_t14_stats_regs
run -all
puts ""BEFORE_SAVE""
coverage save C:/Workspace/diansai/out/arena-debug/continue5/ucdb/probe.ucdb
puts ""AFTER_SAVE""
quit -f
