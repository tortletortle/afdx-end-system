# Continue5-finalize —— 接手收尾（不重做已完成 coverage）

在 `C:\Workspace\diansai\out\arena-debug\continue5\` 完成上一轮 claude-opus-5 因会话中断未收尾的部分。**不要重跑已完成的 53 项 UCDB 覆盖采集/合并**。

## 现状（已核实，勿重做）
- `coverage_merged.ucdb`、`coverage_merged_completed53.ucdb`、`coverage_metrics.json` 已存在（含 TB 与 RTL-only 已区分）。
- 原始 54 个 UCDB（53 项 + 合并）在 `ucdb/`。

## 本轮目标（接续上一轮的 todo）
1. **GMII 变体补强**：T14/T15/T16 各加 IF_MODE=1 变体用例（T14g/T15g/T16g），进 manifest（53→56），`run_regress.ps1` 加映射，跑定向回归确认。改前备份到 `continue5/backup/`。
2. **COVERAGE.md**：写覆盖率报告——含 TB 分支/语句、RTL-only 分支/语句、Top-N 未覆盖 RTL 模块（用 `coverage_metrics.json` 的 `top_uncovered_rtl`）、命令、UCDB/合并日志、SHA256。
3. **最终全量回归**（56 项）确认无回退；lint + `run_all.py --strict` 门禁。
4. **REPORT.md / fixes.patch / RESULTS.json / SHA256SUMS.txt** 收尾打包。

## 纪律
- 不读取/回显敏感配置/凭据；不碰 `competition_case/`、`data/`、`logs/`；不 `git commit/push/reset`；
- 不并行跑两份 Questa；覆盖率数字必须区分"含 TB"与"RTL-only"，不得混称；
- 不伪造 PASS；跑不动/许可证阻塞如实写。
