# Continue4-finalize —— 收尾打包（不新增功能）

在 `C:\Workspace\diansai\out\arena-debug\continue4\` 完成上一轮 claude-opus-5 的收尾，不改任何 RTL 功能：

## 目标
1. 独立复核上一轮产物是否真实存在且互相一致：
   - 四个管理面 RTL 非空壳（`rtl/mgmt/snmp_lite.v`、`a615a_tftp.v`、`rtc_sync.v`、`rtl/top/stats_regs.v`）；
   - `sim/tests.manifest` 确为 53 项（T14/T15/T16 已入）；
   - `raw/regress_clean53.log` 确为 53/53 PASS、`raw/lint.log` 0 %Error、`raw/run_all_strict.log` 5/5；
   - `raw/sta/` 的 BASE 与当前 post-map 报告（SDC 8.000 ns 守卫确认）。
2. 把 STA 影响测量的真实数字写入 `RESULTS.json` 的 `goal_b.sta_measurement_this_round`（attempted=true, map_rc, sdc_guard_8ns_seen, worst_setup_slack_ns, fmax 等，以 raw/sta 报告实际值为准）。
3. 用上一轮相同方法**重新生成完整 `SHA256SUMS.txt`**（含所有保留产物，逐文件哈希）。
4. 确认 `fixes.patch` 覆盖本轮真实改动，必要时按既有 baseline 注释核对。

## 纪律
- 不读取/回显敏感配置/凭据；不碰 `competition_case/`、`data/`、`logs/`；不 `git commit/push/reset`；
- 不伪造 STA 数字：RESULTS 里必须与 `raw/sta/*.rpt` 实际输出一致；
- 完成后把结论写入 `out/arena-debug/continue4/FINALIZE-REPORT.md`（一句话 + 证据清单）。
