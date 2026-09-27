# Continue8 — 分阶段实施、验证与回滚计划

## 0. 工作纪律

- 实施前创建局部备份并记录源码 SHA-256、tests manifest、工具版本、命令和输出目录；不执行 `git reset`、`git commit` 或 `git push`。
- 不修改 `competition_case/`、`data/`、`logs/`，不读取或回显凭据类文件。
- 每一步只改变一个可归因的微结构点；禁止把 TX pipeline、RX 改造、管理面改造和约束大改混入同一补丁。
- 本 Continue8 文档阶段不生成生产 RTL 补丁；下述文件名是后续编码候选，不表示它们本轮已经改变。

## 1. 阶段表

| 阶段 | 目标与可能文件 | 交付/断言 | 最小验证门 | 保留/回滚条件 |
|---|---|---|---|---|
| P0 — 冻结基线 | 备份 `rtl/tx/tx_port_buf.v`、`rtl/top/AFDX_top.v`、`rtl/top/host_if.v`、`sim/tests.manifest`；复制当前 map/STA 命令 | 哈希、命令、原始日志路径、无修改确认 | 检查工作树与当前 8 ns SDC | 基线不完整则不编码 |
| P1 — 契约先行 | 新增/更新 TX reference scoreboard 与断言；必要时只改 TB | commit/take 响应排序、块四态守恒、queue FIFO、`q_full`、覆盖/拒绝、复位取消事务 | T02、T04、T17、T18 的定向运行 | 新断言与现行实现不一致时，先澄清规格，不改 RTL |
| P2 — Admission adapter | 候选：`rtl/tx/tx_port_event_frontend.v`、`tx_port_buf.v` wrapper、`AFDX_top.v` / `host_if.v` 适配 | 有界 event FIFO、skid register、commit/take 同拍仍按旧优先级、无静默丢脉冲 | T02、T04、T17、T18、T22、T23 + lint | 任一 host ACK、开放块或调度握手变更未被 TB 覆盖即回滚 |
| P3 — R/X/W state engine | 候选：`rtl/tx/tx_port_state_engine.v`，逐步替换 `tx_port_buf` 的 S0/S1+bypass | 同步 read、寄存 X、唯一 W；busy port 串行；已提交 forward record（若需要） | P2 全部 + T05b/T05bg、T13/T13g、完整 56 项、lint/docgate | 任何功能失败或 post-map Fmax/WNS 不改善即回滚本步 |
| P4 — descriptor host-read 定案 | `tx_port_state_engine.v`、`host_if.v`、相关 TB | 在 mirror、response FIFO、或仲裁三选一；读语义写入设计书/scoreboard | 连续 host 读、读写碰撞、复位、T17 | 综合回退/读语义不明则不保留 |
| P5 — 有依据的分银行（可选） | bank wrapper、bank-local FIFO/RAM/state、中央 response arbiter | 每个 bank 独立 owner；接口响应可证明保序；不再复制全局 bypass | T02/T17 长压、T18、多端口并发专项、全量 56 项 | 若 STA 未显示 state/route 收益，或接口复杂度无收益，回滚 |
| P6 — RX 独立迁移（后续） | `rtl/rx/rx_port_buf.v`、top、RX TB | DELIVER/HOST/FREE 事件化，保留 pin/双释放/D11/D12 | T08–T12、T21、T22、T23、故障注入 | TX 未完成或 RX 证据不足时不启动 |
| P7 — 物理签核路径 | QSF/SDC、目标板 pin/IO 约束、fit 脚本 | post-map 比较、`quartus_fit`、post-fit setup/hold、未约束项归零或书面豁免 | 8 ns SDC 守卫、map/fit/STA 原始报告 | IO/hold/fit 未过，不得称签核 |

## 2. 每个 RTL 步骤的执行顺序

```text
1. 备份被改文件 + 记录 SHA-256
2. 先运行受影响 TB，失败时保存原始 console
3. 运行 lint 与严格文档门
4. 串行运行完整 56 项回归（不得并发占用同一 Questa 许可）
5. 在同一器件、同一 QSF/8 ns SDC 下运行 quartus_map + TimeQuest
6. 归档命令、rc、manifest、CSV、Fmax/WNS/TNS、最差路径和未约束项
7. 比较前后：功能 PASS 且 Fmax↑、WNS 改善才保留；否则应用局部回滚
```

建议后续每步使用独立目录，例如：

```text
out/arena-debug/continue8/p2-admission/
out/arena-debug/continue8/p3-state-engine/
out/arena-debug/continue8/p5-banking/
```

每个目录至少含 `COMMANDS.md`、`RESULTS.json`、原始回归/STA日志、补丁、备份 SHA 与 `REPORT.md`。失败原件保留，不以新日志覆盖。

## 3. 验证矩阵

| 关注点 | 必测用例/检查 | 通过条件 |
|---|---|---|
| TX 描述符、采样/队列、SN | T02、T03、T04 | 逐字节/描述符 scoreboard、BAG 不提前、块守恒 |
| 启动/满载抖动与延迟 | T05b/T05bg、T13/T13g | 用帧首真实时间戳量测；不以控制周期代替 |
| RX/冗余没有被 TX 副作用破坏 | T08–T12、T21、T22、T23 | A/B 只投递一次、释放/耗尽恢复、SAP 路径正确 |
| 长压与仲裁 | T17、T18/T18g + 新的同端口/多端口 event 压力 | 无丢/重/错 ACK；busy/backpressure 边界可观测 |
| 管理面 | T14/T14g、T15/T15g、T16/T16g | response、错误路径和超时边界保持 |
| 静态质量 | `tools_lint.ps1`、`tools/run_all.py --strict` | 0 lint Error、文档门通过 |
| 时序 | map + TimeQuest，最终 fit + post-fit | 同口径 Fmax/WNS 改善；最终无 setup/hold/IO 未闭环声明 |

## 4. 接口与测试需要新增的内容

1. **事务观测点**：`event_accept`、`event_issue`、`event_commit`、`event_response`、`event_seq`，只在仿真/调试可见也可，但不能改变综合功能。
2. **断言**：同 port 保序；commit 至多一个 accept/reject；take 至多一个 ack；`sch_ack` 与块/长度来自同一 committed head；free 不作用于非 owner。
3. **可配置压力**：event FIFO 深度 1/2/4、连续同端口、host/take 同拍、block-free 与 commit 同拍、复位截断。
4. **延迟约束**：用最大 commit-to-response、take-to-ack 周期数写成有界断言；管理面和 host adapter 不得用无界等待掩盖 deadlock。

## 5. 物理实现与签核的后续门

当前仅有内部时钟的 post-map 比较。最终签核还必须：

- 固化正确器件/Family 与实际 active revision；
- 为 71 输入/121 输出补目标板 pin、IO standard、input/output delay 与外部时钟关系，或以书面范围豁免列出；
- 检查 `check_timing`、unconstrained paths、recovery/removal、clock crossing；
- 运行 `quartus_fit` 后的 setup/hold 报告，检查资源、拥塞和路由；
- 对 GMII/相关接口做 L089 所指向的时序裕量和异常/应力验证。

在以上全部完成前，允许使用“post-map 改善”措辞，不允许使用“125 MHz 收敛”“板级时序通过”或“签核完成”。
