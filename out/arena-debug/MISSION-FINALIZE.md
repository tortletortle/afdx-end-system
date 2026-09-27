# Arena 收口任务 — 把 diansai 剩余交付真正完成

工作区：`C:/Workspace/diansai`。通过当前 HTTP 工具服务调用本机工具；工具包括 `read_files / find_files / search_files / apply_patch / run_command / get_command_output / send_command_input`。
先读 `out/arena-debug/DIANSAI-REPORT.md`、`out/arena-debug/REVIEW-REPORT.md`、`README.md`、`doc/当前进度_20260923.md`、`doc/后续计划.md`。

## 总目标
不要再只做“报告完成”。把 REVIEW-REPORT 剩余未闭环项真正做到能交付的程度；做不到的必须保留失败证据、明确阻塞，不得把失败改成 PASS。

## 优先级 A：必须继续推进
1. **顶层 eLinx 综合通过**：复现 `elinx/prj/AFDX_top_synth.ys` 的 `memory_map invalid vector<T> subscript`。定位触发该错误的具体 RTL 存储结构，采用可综合、可验证的最小方案（优先 eLinx 支持的 BRAM/IP 或拆分存储推断）。目标：`AFDX_top` 顶层 synthesis rc=0，日志全量无 `ERROR`，生成可审阅网表/资源摘要。若确认是工具版本硬限制，继续尝试项目现有 eLinx/Questa 可用路径；仍无法解决时，不得伪造，写出精确 blocker 与下一步。
2. **STA / 时序收敛**：检查现有 eLinx 工程、时钟/约束文件。补齐合法时钟/IO 约束并运行可用的综合/STA 流程，产出真实 WNS/TNS/关键路径/Fmax。没有 P&R/STA 工具就明确写 `BLOCKED_NO_TOOL`，不能用 RTL 仿真替代。
3. **覆盖率**：检查 Questa 许可和脚本能力，运行真实 UCDB/coverage（或明确 `BLOCKED_NO_COVERAGE_TOOL`），产出覆盖率数据库/报告；不能用 PASS 数量冒充覆盖率。

## 优先级 B：必须收口协议/测试缺口
4. **完整管理面范围**：检查 `rtl/mgmt/snmp_lite.v`、`a615a_tftp.v`、`rtc_sync.v`、`stats_regs.v`。若设计书要求交付，实现最小可复现闭环并加 TB；若本轮范围明确不含完整协议栈，更新文档明确“未纳入交付范围”，不要把空壳写成完成。
5. **SAP 背靠背/竞争压力**：T23 增加连续不同 SN 的背靠背 SAP、pending 期间持续普通 PB1 归还，断言无丢块且 `mgmt_free_take` 延迟有界。
6. **T18 真多事务并发**：当前仍是串行消息事务。若目标是压力测试，补至少两个同时在飞事务/端口，保留 seed、反压、去重和精确计数断言；否则改名为 directed 并在文档降级结论。

## 强约束
- 每改 RTL/TB/脚本/文档，先备份到 `out/arena-debug/backup/finalize_20250925/`。
- 不要 git commit/push；不要碰 `.env`、密钥、token、`competition_case/`；不要删除既有证据。
- Questa 不并行；启动前检查无 `vsim/vopt/vlog/vish/vlm` 残留。
- 每项都留下命令、原始日志、CSV/console、SHA-256。
- 最后必须串行跑完整 `sim/run_regress.ps1`；文档门和 lint 全绿或如实报告失败。

## 交付
更新：
- `out/arena-debug/DIANSAI-REPORT.md`：最终状态，区分 DONE / BLOCKED / OUT_OF_SCOPE。
- `out/arena-debug/fixes.patch`：本轮可逆补丁。
- `out/arena-debug/finalize/`：STA/coverage/synthesis/回归原始日志和摘要。
- `doc/当前进度_20260923.md`、`doc/后续计划.md`：只如实更新。
最后回复摘要：完成项、阻塞项、真实证据路径、全量回归结果。