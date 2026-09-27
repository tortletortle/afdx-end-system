# Arena 最终推进任务 — diansai 直到可交付收口

工作区：C:/Workspace/diansai。通过 HTTP 工具服务操作本机；先读取本文件以及当前 DIANSAI-REPORT.md。只做真实工程工作，不要只写建议。

## 已知状态
- 50/50 Questa 功能回归 PASS；lint/docgate PASS；50 UCDB 已生成（含 TB，非 RTL-only）。
- 顶层 eLinx 综合仍 BLOCKED：memory_map/OPT_MUXTREE bad allocation；STA 无 active revision/netlist；完整 T14-T16 管理协议未交付。
- 不要重复已经完成的功能回归；优先解决真正阻塞，能解决就修，不能解决就留下最小复现与精确阻塞证据。

## 目标 1：顶层综合（最高优先）
1. 阅读 `out/arena-debug/finalize/synth/` 全部日志、现有 `AFDX_top_synth.ys`、所有 RAM/队列 RTL 和 eLinx 版本信息。
2. 二分定位触发 `memory_map invalid vector<T> subscript` / `OPT_MUXTREE bad allocation` 的具体模块/存储结构：逐模块综合、最小顶层 wrapper、替换一个存储结构后验证。
3. 只采用可综合且可验证的修复：显式 bank/单写端口/受支持 BRAM wrapper/拆分宽深存储；不要把功能删掉、缩窄地址、屏蔽错误来换“通过”。
4. 成功标准：顶层 eLinx synthesis rc=0，全日志无 ERROR，输出网表/资源摘要；失败则写清模块、最小复现、工具限制与下一条可执行路径，不能把 probe PASS 写成 top PASS。

## 目标 2：STA
1. 检查现有 Quartus/eLinx 工程文件、revision、时钟和 IO 约束。
2. 若有可用工程，建立合法 revision/约束后运行真实 TimeQuest，产出 WNS/TNS/Fmax/关键路径；没有 netlist/active revision/合法 IO 约束就生成证据化 BLOCKED，不伪造数值。

## 目标 3：覆盖率与管理范围
- 已有 50 UCDB，核对是否真正合并、保存最终摘要；若不是 RTL-only/功能覆盖，准确标注边界。
- 检查 SNMP/TFTP/RTC/stats 空壳。如果总体设计书要求它们，完成最小可测闭环+TB；若本轮明确不交付，写正式 OPEN_SPEC_GAP/OUT_OF_SCOPE，并同步文档，不能把空壳标 DONE。

## 纪律
- 改动前备份 `out/arena-debug/backup/continue2_20250925/`；不要 commit/push/reset；不要碰 competition_case/.env/凭据。
- 不并行跑 Questa/eLinx；保留每次失败日志、rc 和 SHA256。
- 收尾串行跑 50/50 回归、lint、docgate，真实报告 DONE/BLOCKED/OUT_OF_SCOPE。

## 交付
更新：
- `out/arena-debug/DIANSAI-REPORT.md`
- `out/arena-debug/fixes.patch`
- `out/arena-debug/continue2/`（原始命令、日志、rc、SHA256、综合/STA/coverage/管理范围证据）
- `doc/当前进度_20260923.md` 与 `doc/后续计划.md`
