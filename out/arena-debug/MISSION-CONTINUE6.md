# Continue6 —— P0 时序收敛（结构优化）

在 `C:\Workspace\diansai` 把 post-map STA 的 Fmax 从 **42.15 MHz** 往 125 MHz 方向推进。产出写入 `out/arena-debug/continue6/`。

## 背景（已核实的时序瓶颈，来自 continue4/5 的 StAA 报告）

- 当前实测（post-map，8 ns SDC 守卫确认）：Fmax ~42.15 MHz、最差 setup slack ~−15.72 ns；continue5 加了 GMII 变体但未重测时序。
- 已点名的长组合路径：
  1. `rx_port_buf` 256 端口计数器/描述符（continue2 最差路径 `rst_sync→p_cnt~508`，22.975 ns）→ 分银行；
  2. `rtc_sync` 64bit offset 加法器（continue4 最差 `sec_phase[22]→offset[63]`）→ 流水/进位拆分；
  3. `snmp_lite.walk()` 56 组比较器 + `stats_regs` 48:1 读译码 → 读口打一拍；
  4. 大位宽 `$eq` 比较链（顶层 ~19,019 个）→ 对多周期可容忍路径寄存后比较/预译码。

## 本轮要求

1. **一次只动一条瓶颈路径**，先建"当前基线"（56 项回归 + post-map STA，8ns 守卫），再改一条、回归、STA，记录 Fmax/WNS/TNS 变化；不要几条一起改导致无法归因。
2. 改前备份到 `out/arena-debug/continue6/backup/`；每步生成独立 `timing_stepN.patch`。
3. 每步必须：56 项全量回归确认功能不变（不允许功能回退）→ post-map STA 看 Fmax/WNS 是否单调改善。
4. **负收益立即回滚**（保留 negative 日志 + 回滚证据），只在确实改善时保留。
5. 用 continue3 固化的 `check_sdc_8ns` 守卫，任何 STA 数字必须先确认 `clk=8.000`；不伪造时序收敛。
6. 每次 STA 耗时约 10-16 分钟（map）+ 2 分钟（sta），耐心等待真实 run，不要跳过。

## 产出
- `REPORT.md`：基线 vs 每步 Fmax/WNS/TNS 对照表 + 保留/回滚决策 + 诚实边界；
- `fixes.patch`（最终保留改动）、每步 `timing_stepN.patch` + `*-rejected.patch`（负收益回滚证据）；
- 原始 `raw/` 日志（map/sta/regress 每步）、`COMMANDS.md/jsonl`、`RESULTS.json`、`SHA256SUMS.txt`。

## 纪律（强制）
- 不读取/回显 `.env`、`*.local.*`、密钥/账号/密码/token 原文；不碰 `competition_case/`、`data/`、`logs/`；不 `git commit/push/reset`；
- 不并行跑两份 Questa；跑不动/许可证阻塞如实写；不把局部通过写成整机通过。