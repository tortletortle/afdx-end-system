# Continue4 —— 管理面 T14–T16 关闭 + P0 时序优化尝试

在 `C:\Workspace\diansai` 完成两件可独立复验的工作，产出写入 `out/arena-debug/continue4/`。

## 目标 A（主）：关闭 P1 管理面 `OPEN_SPEC_GAP`（T14/T15/T16）

按 `out/arena-debug/continue2/MANAGEMENT-SCOPE.md` §5 的最小可验收定义：

1. `rtl/top/stats_regs.v`：按设计书 §9 定义端口，接 `AFDX_top` 0x0100~0x01FF 页；
   TB `T14` 校验帧/字节/丢弃计数与直方图分桶，含复位清零与读清语义。
2. `rtl/mgmt/snmp_lite.v`：GET/GETNEXT/SET + STATS_BLOCK 只读组，走 `mgmt_sap_rx` 的
   SAP 描述符通路；TB `T15` 用真实 SAP 帧驱动，校验 PDU 编解码与错误码。
3. `rtl/mgmt/a615a_tftp.v` + `rtl/mgmt/rtc_sync.v`：TFTP RRQ/WRQ/DATA/ACK 状态机
   与 PPS 对时；TB `T16`。
4. 三条用例进 `sim/tests.manifest`（50 → 53），`sim/run_regress.ps1` 加映射；
   全量回归、`tools_lint.ps1`、`python tools/run_all.py --strict` 同时通过。
5. 只做真实协议的最小闭环，**不得**把空壳/占位当作完成；如实标注覆盖边界。

## 目标 B（次）：P0 时序关键路径结构优化一次尝试

基于 `out/arena-debug/continue3/REPORT.md` 与 `doc/后续计划.md` P0 结论
（Fmax 42.56 MHz、WNS −15.498 ns，起点 `rst_sync:u_rstsync|r[2]` → `rx_port_buf` 256 计数器组）。
按收益排序选一个可逆的结构性改动（复位树分级 / `rx_port_buf` 分银行 / 宽比较链打拍）。
要求：
- 改前先备份到 `out/arena-debug/continue4/backup/`；
- 每步改完先跑原 50 项回归确认功能不变，再跑 post-map STA 看 Fmax/WNS 变化；
- 用 `out/arena-debug/continue3` 固化的 8ns SDC 守卫（`check_sdc_8ns.tcl`）确保约束真实；
- 若改动为负收益，如实报告并回滚，保留 `timing_attempt.patch` 作证据。

## 纪律（所有轮次强制）

- 不读取/回显 `.env`、`*.local.*`、密钥/账号/密码/token 原文；不碰 `competition_case/`、`data/`、`logs/`；
- 不 `git commit/push/reset`；改源码前先备份到 `continue4/backup/`；
- 不并行跑两份 Questa 回归；拿不到许可/跑不动如实写明，不伪造 PASS；
- 产物：`REPORT.md`、`fixes.patch`、`timing_attempt.patch`（若做了 B）、原始日志、
  `COMMANDS.md/jsonl`、`RESULTS.json`、`SHA256SUMS.txt` 全部写入 `continue4/`；
- 局部通过不等于整机/协议/时序完成，报告必须分开标注。
