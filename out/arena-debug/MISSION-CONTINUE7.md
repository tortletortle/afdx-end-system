# Continue7 —— P0 时序批量优化（加速模式）

在 `C:\Workspace\diansai` 继续 P0 时序收敛。目标：把 post-map Fmax 从 continue6 的 **45.85 MHz** 继续提升，同时**尽量少跑完整回归/STA 轮次**（每轮 map ~25-30 分钟是主要耗时）。

## 加速方式（区别于 continue6）
continue6 每步都单独跑 56 回归 + map + STA（很慢）。本轮改为：
1. 先读 `continue6/step2_sta/post_map_setup.rpt` 拿到**当前最差路径列表（top-N）**；
2. 对每条独立模块路径做最小结构优化（`tx_port_buf` 的 `s1_vld→s1_desc` 描述符读口流水/分银行、`rtc_sync` 64bit offset 进位拆分、`stats_regs` 读译码打拍 等），每步**独立 patch**；
3. **只跑一轮** 56 项全量回归 + **一轮** post-map STA 做整体验收；
4. 若整体 Fmax/WNS 改善则保留；若某条使最差路径恶化，用独立 patch 回滚那条再重测。

## 约束（每条必须）
- 每步改前备份到 `out/arena-debug/continue7/backup/<stepN>/`；每步独立 `timing_stepN.patch`；
- 功能必须 56/56 回归全绿（不允许功能回退）；STA 必须过 `check_sdc_8ns` 守卫（`clk=8.000`）；
- **不并行跑两份 Questa / 两份 quartus_map**；map 结束确认无残留进程后再跑下一轮；
- 负收益立即回滚，保留失败日志 + 回滚 patch。

## 产出
- `REPORT.md`：continue6(45.85) vs 本轮 Fmax/WNS/TNS 对照 + 保留/回滚决策 + 诚实边界；
- `fixes.patch`（最终保留）、每步 `timing_stepN.patch`、`*-rejected.patch`；
- 原始 `raw/` 日志、`COMMANDS.md/jsonl`、`RESULTS.json`、`SHA256SUMS.txt`。

## 纪律（强制）
- 不读取/回显 `.env`、`*.local.*`、密钥/账号/密码/token 原文；不碰 `competition_case/`、`data/`、`logs/`；不 `git commit/push/reset`；
- 不伪造时序收敛；post-map 非签核，如实标注。
