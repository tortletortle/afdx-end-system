# Continue8 — 架构重设计基线与证据边界

**范围**：本目录只记录时序重设计决策；本轮不修改 `rtl/`、`sim/` 或 `doc/` 的生产文件，也不把设计建议写成已验证结论。

## 1. 已复核的事实基线

| 项目 | 当前可用证据 | 结论/数值 | 证据位置 |
|---|---|---:|---|
| 功能回归 | Continue7 保存的原始回归输出 | 56/56 PASS，73.8 s | `out/arena-debug/continue7/raw/step1_regress.log`、`step1_regress.csv` |
| 时钟约束守卫 | post-map TimeQuest | `clk = 8.000 ns` | `continue7/step1_sta/post_map_sdc*.rpt` |
| post-map Fmax | TimeQuest | 45.84 MHz | `continue7/step1_sta/post_map_fmax.rpt` |
| setup WNS | TimeQuest | -13.815 ns | `continue7/step1_sta/post_map_setup.rpt` |
| endpoint TNS | TimeQuest | -700108.256 ns | `continue7/raw/step1_tns.log` |
| 最差路径 | TimeQuest | `tx_port_buf:u_txbuf|s1_vld` → `tx_port_buf:u_txbuf|s1_desc[*]`，数据延迟约 21.292 ns | `continue7/step1_sta/post_map_setup.rpt` |
| 最近被拒绝的试验 | Continue7 | `tx_port_buf` 的四银行描述符方案：45.85 → 45.84 MHz，WNS -13.809 → -13.815 ns，已按负收益回滚 | `continue7/REPORT.md`、`timing_step1-rollback.patch` |
| 现有 TX 源快照 | 源文件 SHA-256 | `rtl/tx/tx_port_buf.v` = `349f7dde3b98587cb02cd63b393a3a434683ebc16f1211aaed63df8f64cbb9ff` | Continue7 回滚核验及当前文件 |

以上功能与 STA 结果是先前工作留下的可追溯证据，本轮**没有重新运行**它们。它们足以决定下一步设计优先级，但不能替代任何后续改动后的回归。

## 2. 问题的精确表述

目标时钟周期为 8 ns；当前最差路径约 21.292 ns，故需要削减约 13.292 ns 的组合与路由延迟，不能依赖小幅逻辑化简。45.84 MHz 的 post-map 数值仅用于相对比较，尚不是 post-fit 签核。

`tx_port_buf` 当前把事件采样、数组异步读取、条件判断、描述符/队列状态计算，以及同端口连续事件的 `bypass` 放在紧耦合路径上：

```text
s1_vld / s1_port
    → valid_map、desc/qst、next_tab 的地址选择和读取
    → 满/空、采样/队列、链表和回收判断
    → wb_desc / wb_qst / wb_we
    → bypass（与下一事件同端口时）
    → 下一拍 s1_desc / s1_qst 的输入 mux
```

这解释了 STA 中 `s1_vld → s1_desc[*]` 的控制到数据端点；它不是一句“逻辑太多”可以概括的问题。

还存在三个互相独立、必须分别处理的因素：

1. **RTL 组合链**：`bypass` 把上一个事件的完整写回计算组合地送回下一个 S0 读结果；`q_cnt/depth`、`next_tab`、`free_set` 又使控制与宽数据字段耦合。
2. **存储推断与端口约束**：`desc[256]`、`qst[256]` 是数组，但 TX 状态同时需要事件读取、写回和主机描述符读取；若保留异步多读口及旁路，不能假定它会自动变成低延迟双口 BRAM。`valid_map/qfull_map/smp_map` 的 256 位向量输出也天然带有译码、扇出和路由成本。
3. **物理实现**：Continue7 已表明仅把阵列语法切成四块而不改变请求、写回、旁路和全局仲裁的时序边界，不会缩短这条路径，且会增加 bank 选择/路由负担。

## 3. 不能越过的边界

- 当前工程仍有 **71 个输入、121 个输出未约束**；没有目标板管脚、IO delay 和 post-fit setup/hold 报告，因此不得声称整机 125 MHz 签核通过。
- 56/56 PASS 是功能仿真证据，不是覆盖率、时序或 ARINC 664P7 认证证据。
- BAG 的约束点、帧首时间戳、A/B 冗余、SN/PSN、块所有权、管理面响应语义均不可因控制面加拍而改变；新增延迟必须被接口契约与测试明确吸收。
- 本目录引用文献作为**设计依据**；文献结论不替代该 RTL 的综合、仿真或 STA 结果。详细映射见 `LITERATURE-TRACE.md`。

## 4. Continue8 的成功判据

本轮成功是形成可执行、可回滚的方案和验证门，而不是在文档中宣称时序收敛。后续编码阶段每一增量都必须满足：

1. 相关定向 TB、完整 56 项回归、lint 与严格文档门均通过；
2. 在相同器件、相同 8 ns SDC 和同一份脚本口径下重跑 post-map STA；
3. 只有 Fmax **提高**且 WNS **单调改善**才保留；否则回滚该步骤；
4. 到达 8 ns 附近后仍要运行 `quartus_fit`、post-fit setup/hold 和 IO 约束检查，才可讨论签核。
