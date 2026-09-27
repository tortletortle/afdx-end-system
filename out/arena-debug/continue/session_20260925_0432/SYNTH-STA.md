# 顶层综合与 STA 续作证据（2026-09-25）

## 结论

**BLOCKED_TOOL**：当前 eLinx 顶层流程仍失败；没有完整成功网表，没有可签核资源利用率，没有 WNS/TNS/Fmax/关键路径数据。以下 rc 均来自实际子进程，不以外层 Python 正常退出冒充综合成功。

| 探针 | 实际 rc | 结果与适用范围 |
|---|---:|---|
| old_top_repro | 1 | 在独立 .ys 中仅把 tx_rm 源路径替换成 finalize 前备份，复现 memory_map `invalid vector<T> subscript`；未回滚工作树 |
| tx_rm_old | 1 | 独立旧 tx_rm 即可复现；触发结构为 exp_q[0:15]（2bit）和 vl_q[0:15]（8bit）的循环同步复位多写口 |
| tx_rm_current | 0 | 上轮已有 packed-flop 最小修复复验；整份日志无 ERROR、check 完成，554 generic cells；不是本轮新修，也不是顶层结果 |
| current_top_repro | 1 | 当前原始 AFDX_top_synth.ys 的 memory_map 已通过，后续 OPT_MUXTREE 报 bad allocation |
| rx_cfg_isolate | 0 | **无效隔离探针**：仅选内存名字未发生映射（memory_map 0ms，仍有 5 memories）；不能用于证明修复或缩小故障范围 |
| top_module_isolate | 3221225477 (0xC0000005) | 只映射 AFDX_top 模块后有 150603 generic cells / 88757 mux；OPT_EXPR 崩溃。说明顶层配置存储展开本身即触发工具问题，但未证明单个数组唯一根因 |
| top_fast_probe | 1 | 最小可逆脚本变体 opt -fast，保留所有参数/模块/检查/网表导出目标；OPT_MERGE 中仍 bad allocation，未产出完整网表 |
| top_bram_attempt | 1 | 使用项目现有器件 brams.txt/brams_map.v：memory_collect → memory_bram → techmap → opt/check/stat/write_verilog；优化时仍 bad allocation；部分 altsyncram 统计不能视为顶层 PASS |
| sta_probe | 3 | 已安装 TimeQuest，create_timing_netlist 报 Can't find active revision；不是许可证缺失或工具缺失的证明 |

全部命令/rc/耗时/console SHA-256 见 commands.jsonl，各探针另有 *_rc.txt、*.log、*_tool.log、*.ys。旧 finalize/synth 所有日志（含 UTF-16 console）已逐文件完整读取和校验，索引 prior_synth_full_log_audit.json；旧证据不覆盖。

## 瓶颈与最小修复边界

- eLinx_synthesis.exe 的 PE machine=0x14c（32 位），文件 SHA-256 在 tool_inventory.json。分配失败/访问异常是工具层可见故障；并不等价于已证明 RTL 在目标器件可实现。
- AFDX_top 的五张表合计 322176 bit：rx_cfg_mem=8192x32、tx_cfg_mem=640x32、port_cfg_mem=1024x32、cfg_share_mem=128x21、vl_stat_mem=128x32。多个组合读口直接服务 FLT/RM/解析/主机/调度，不能无验证地替换成一拍同步 BRAM。
- 本轮没有削减 VL/端口参数、黑盒化大 RAM、删除 check、替换 TB 断言或伪造器件 IP。保留当前 RTL/TB；新增独立综合脚本作为可逆尝试，失败也保留。
- 下一步需给这些组合配置读口分银行/复制或加寄存握手，并保证配置生效、读延迟、反压语义；每次结构调整需重跑真实顶层 TB。或用受支持的 64 位供应商综合器/器件 IP 完成同参数网表。当前不能宣称综合已修复。

## STA

现有 elinx/sdc/AFDX_top.edc 与设计书 §11.2 一致：clk=8ns，uncertainty=0.45ns，transition=0.30ns，pps_in false path。设计书明确无板卡时 IO delay 默认注掉；没有把示例 3.2ns 填成测量值。该最小约束已经存在，本轮不重复创建。

elinx/、sim/ 工程扫描未发现 qpf/qsf active revision，当前顶层综合失败，TimeQuest 负向实跑确认缺 active revision。精确阻塞：**缺 active revision + 完整可用 timing netlist/器件实现**；板级 IO 预算未定义是外部时序签核的另一个缺口，不声称它阻止内部路径分析。没有证据证明许可证缺失。WNS/TNS/Fmax/关键路径全部 N/A，不使用设计预算冒充实测。
