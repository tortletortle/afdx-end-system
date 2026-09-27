# Continue4 FINALIZE 报告

**一句话结论：收尾打包完成；四个管理面 RTL 非空壳、历史回归 53/53、lint 0 %Error、strict 5/5 均有实证，BASE 与当前候选 post-map 已分离核对，但 8 ns 时序仍未收敛。**

日期：2026-09-26。本次仅复核及生成交付物，未修改 RTL 功能，未启动新的回归/lint/strict/综合/STA。

## 证据清单

| 项目 | 复核结果 | 证据 |
|---|---|---|
| 四个管理面 RTL | stats_regs 308 行、snmp_lite 565 行、a615a_tftp 360 行、rtc_sync 149 行；实际事件计数、协议状态机和对时逻辑，非空壳；前后 SHA-256 不变 | 当前 RTL、raw/finalize_audit.json |
| manifest | 53 个唯一 test-id，T14/T15/T16 已纳入；与两份回归 CSV 完全一致 | sim/tests.manifest |
| 历史独占回归 | 日志 53 个 PASS 行、CSV 53/53，wall 542 s | raw/regress_clean53.log/.csv |
| 既有 RTC 候选回归 | 日志及 CSV 53/53，wall 477.2 s | raw/regress_timing_attempt.log/.csv |
| 历史 lint | 最终 gate PASS，无 %Error 诊断，不表示无 warnings | raw/lint.log |
| 历史 strict | 5/5，仅文档/理论模型一致性，不代替 RTL/STA | raw/run_all_strict.log |
| SDC | BASE 与候选均 create_clock clk 8.000 ns，STA 日志均有守卫 OK | raw/sta/*post_map_sdc.rpt、raw/sta_base.log、raw/sta_cand.log |
| 补丁 | 15 个实现/测试/构建输入，按声明混合基线在内存逐段回放，与当前源码逐行相符 | fixes.patch、tools/mkpatch.py、raw/finalize_audit.json |
| 完整性 | 排序逐文件 SHA-256，包含所有保留文件（含 Quartus db/output_files、缓存及本报告）；只排除清单自身 | SHA256SUMS.txt、tools/make_sha256.py |

## 真实 STA 数字

| 指标 | BASE：RTC 候选前 | 当前保留 RTC 候选 | 候选 − BASE |
|---|---:|---:|---:|
| Worst setup slack | -18.569 ns | **-15.723 ns** | +2.846 ns |
| End Point TNS | -661896.147 ns | **-665200.142 ns** | -3303.995 ns（更差） |
| Fmax / Restricted Fmax | 37.64 MHz | **42.15 MHz** | +4.51 MHz |
| map rc / wall | 0 / 592 s | 0 / 615.3 s | — |
| STA rc / wall | 0 / 116.3 s | 0 / 138.8 s | — |

BASE 证据：`raw/map_base.log`、`raw/sta_base.log`、`raw/sta/BASE_post_map_*.rpt`。
候选证据：`raw/map_cand.log`、`raw/sta_cand.log`、`raw/sta/post_map_*.rpt`。
`RESULTS.json` 的 `goal_b.sta_measurement_this_round` 引用候选，`baseline_measurement` 保存 BASE。
两者均通过返回码、完成标记、SDC 守卫及报告/日志 WNS 一致性核验。
**这是 post-map 测量，不是布线后签核；WNS/Fmax 改善不抵消 TNS 恶化，8 ns 目标仍未达成。**

## 修复的问题及边界

1. 初读时候选日志未完整，现存无前缀 STA 报告还与 BASE 相同。封包前的独立断言检测到报告更新并阻止封包；随后既有候选 map/STA 输出完成，两次 rc=0，重新读取后采用上表数据。本次没有启动这些运行，不能把首次观察写成最终状态。
2. 当前 `rtc_sync.v` 已保留 `err_q/disc_pend/disc_q_pps` 两拍候选，改前版本在 `backup/timing_attempt_before/rtc_sync.v`。旧报告“根本没做”已纠正：`goal_b.attempted=true`、`structural_attempt_measured=true`，但 `done=false` 表示时序目标尚未达成。本次未改 RTL。
3. 旧补丁 RTC 段落过期，并漏了 `elinx/prj/AFDX_top_synth.ys`。现重建为 15 个输入并验证回放。`tools_lint.ps1` 用 HEAD；**mgmt_sap_rx.v 无现场备份且不在 HEAD 中**，只能交付完整文件镜像，不能声称恢复其改前 50 行基线。具体 HEAD commit、基线摘要与源码哈希见审计 JSON。
4. 历史 clean53/lint/strict 都早于 RTC 候选；候选另有 53/53 回归和已完成 post-map，但本次未补跑候选后 lint，不宣称所有门禁均在最新 RTL 上重跑。
5. 既有协议覆盖边界不变：管理面响应未进入线上 TX、统计/协议/对时仍有已登记限制；非空壳和用例通过不等于整机符合性通过。
6. 返回码位于 UTF-16 日志末尾追加的 ASCII 段；已修复 `tools/make_results.py`，避免整文件单编码读取丢失 rc/wall。WNS/TNS 直接取自 .rpt，并与对应日志核对。
7. 原 9 项 SHA 清单过期，现使用同样的排序逐文件 SHA-256 方法，扩展为所有保留文件，无生成目录遗漏。

## 交付物与复核方法

已更新 `RESULTS.json`、`REPORT.md`、`COMMANDS.md`、`fixes.patch`、三个生成脚本，新增 `tools/finalize_verify.py`、`raw/finalize_audit.json` 及本报告。
实现补丁不混入收尾文档；这些收尾文件均由完整哈希清单覆盖。

```powershell
Set-Location C:\Workspace\diansai
python -B out/arena-debug/continue4/tools/finalize_verify.py
python -B out/arena-debug/continue4/tools/make_sha256.py
python -B out/arena-debug/continue4/tools/finalize_verify.py --verify-seal
```

第二条是最后写文件步骤。第三条只读，逐文件校验摘要、清单覆盖及源码未变。
补丁核验为混合基线内存回放，非当前工作区直接应用，也非单一 HEAD 的差分。

纪律：未访问 competition_case/、data/、logs/ 或敏感配置/凭据；未执行 git commit/push/reset；本次未改写原始门禁或 STA 输出。后续应补候选后 lint，并继续优化/布线后验证，不能以 post-map 数字代替时序签核。
