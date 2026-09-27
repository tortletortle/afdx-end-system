# Arena 持续收口任务 — diansai（顶层综合、STA、覆盖率与管理面）

工作区：C:/Workspace/diansai。通过当前 HTTP 工具服务调用本机工具；工作区内允许真实读写、编译、仿真、综合探针。读取本文件后执行。

## 现状
功能侧上一轮已独立确认：Questa 50/50 PASS、lint 0 Error、文档门 5/5；T23 SAP、T18 双事务有限并发、4 个 UCDB 已有证据。
最终报告：out/arena-debug/DIANSAI-REPORT.md；最终证据目录：out/arena-debug/finalize/。

## 本轮只做未完成项，严禁重复造报告
### A. 顶层综合
- 复现 elinx/prj/AFDX_top_synth.ys 的 `memory_map invalid vector<T> subscript`。
- 读现有 finalize/synth 全部日志，定位具体触发故障的存储结构/模块。
- 尝试最小、可逆、可综合修复：拆分/简化不受支持的二维存储、使用项目现有 BRAM 推断形式，或提供受支持的 eLinx IP wrapper。
- 每次修改前备份到 out/arena-debug/backup/continue_20250925/。
- 目标是顶层 eLinx synthesis rc=0、全日志无 ERROR、网表/资源摘要；不能做到就明确 BLOCKED_TOOL 或 BLOCKED_RTL，保留原始失败日志，不得冒充 PASS。

### B. STA
- 检查 eLinx/Quartus/TimeQuest 是否有 active revision、合法时钟/IO 约束；补最小正确约束文件，不要伪造 IO delay。
- 能运行就产出 WNS/TNS/Fmax/关键路径；不能运行就写精确阻塞：缺 netlist、缺 revision、缺 license 或缺 IO 约束。

### C. 覆盖率
- 现有 4 用例 UCDB 只覆盖小子集。检查 Questa `vlog/vsim/vcover` 能力，尝试对全量 50 项以 `+cover=sb` 运行并 merge UCDB。
- 若全量成本/工具限制不可行，至少扩展关键 T08/T11/T17/T18/T21/T23 并明确实际覆盖范围，不把 4 例写成全量覆盖率。

### D. 管理面
- 检查 snmp_lite.v、a615a_tftp.v、rtc_sync.v、stats_regs.v 与总体设计书要求。
- 若这些不在本轮可验收范围，正式写 OUT_OF_SCOPE_FINALIZE/OPEN_SPEC_GAP；若要求实现，做最小真实闭环和 TB，不能只改文档。

## 约束
- 不要 git commit/push/reset；不碰 competition_case/.env/密钥/token。
- 不删除旧证据；Questa 不并行。每项保存命令、rc、原始日志、SHA-256。
- 收尾串行跑 50/50 功能回归、lint、文档门；有失败如实记录。

## 交付
更新 out/arena-debug/DIANSAI-REPORT.md，新增 out/arena-debug/continue/ 原始日志与摘要，更新 out/arena-debug/fixes.patch（只包含本轮修改）。同步 doc/当前进度和 doc/后续计划，区分 DONE/BLOCKED/OUT_OF_SCOPE。