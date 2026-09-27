# Continue5 —— 覆盖率深化 + 管理面边界补强（阶段 1）

在 `C:\Workspace\diansai` 完成两件可独立复验的工作，产出写入 `out/arena-debug/continue5/`。

## 目标 A（主）：覆盖率深化（P2）

现状是「含 TB 的分支/语句」覆盖率（分支 ~62~66%、语句 ~73~77%），plan 已点名不得改称 RTL-only 或功能覆盖率。本轮把它做扎实：

1. 用 `+cover=sb` 在**全 53 项**回归上重采 UCDB（不要只采定向 4 项）；
2. `vcover merge` 合并后，**分别报告**：
   - 全量（含 TB）分支/语句；
   - **RTL-only 过滤**（排除 sim/tb 实例）分支/语句；
   - 未命中路径分析：列 Top-N 未覆盖的 RTL 模块与原因（死代码/未激励/仅 MII）。
3. 若新增 covergroup 功能覆盖率能低成本落地就做，否则如实标注未做。
4. 输出 `COVERAGE.md`：数字、命令、UCDB/合并日志、SHA256。

## 目标 B（次）：管理面边界补强（按 continue4 §4 登记的最小项）

从 continue4 的覆盖边界里选**可在本环境闭环**的 2~3 项实现并验证（不要选需要板级/协议标准扩展的大项）：

候选（按 ROI 排序）：
1. **管理面回包真正上线**：当前两个引擎的响应只经 MGMT 观测窗读出、未接入 TX 帧构建器。接入管理响应 TX，让 T15/T16 验证"请求→上线响应"闭环。
2. **SNMP 按 VL 索引对象**（设计书 §7.16 的 `.5~.9`）：补实现并让 T15 覆盖。
3. **T14/T15/T16 的 GMII 变体用例**：三 TB 各加 IF_MODE=1 变体，进 manifest（53→56）。

每项：改前备份到 `out/arena-debug/continue5/backup/`，改后跑定向回归确认，最终**全量回归**确认无回退。

## 纪律（强制）

- 不读取/回显 `.env`、`*.local.*`、密钥/账号/密码/token 原文；不碰 `competition_case/`、`data/`、`logs/`；
- 不 `git commit/push/reset`；不并行跑两份 Questa 回归；跑不动/许可证阻塞如实写明，不伪造 PASS；
- 产物：`REPORT.md`、`fixes.patch`、`timing_attempt.patch`（若做了时序项）、原始日志、`COMMANDS.md/jsonl`、`RESULTS.json`、`SHA256SUMS.txt` 全写入 `continue5/`；
- 覆盖率数字必须区分"含 TB"与"RTL-only"，不得混称；局部通过不等于整机完成。
