# Continue8 — 设计决策日志

本日志把**已验证事实**、**设计假设**和**待验证选择**分开记录。状态为“推荐”不等于 RTL 已实现。

| ID | 决策 | 依据 | 备选与否决理由 | 状态 | 必需验证 |
|---|---|---|---|---|---|
| D8-01 | 把 `tx_port_buf` 作为当前唯一时序主攻点 | Continue7 最差路径是 `s1_vld → s1_desc[*]`，21.292 ns；Fmax 45.84 MHz | 同时重构 RX、管理面会扩大变量集合，且当前最差路径不在它们 | 已冻结 | 每个 TX 增量都跑回归和 STA |
| D8-02 | 禁止再次做“仅语法分块”的四银行试验 | Continue7 的四银行试验 Fmax -0.01 MHz、WNS -0.006 ns，已回滚 | 真实 bank-local ownership 可在后续考虑；未切断 bypass 的 array rename 不再重复 | 已冻结 | 新 B 方案须证明 request/state/writeback 都本地化 |
| D8-03 | 采用事件 FIFO + R/X/W 提交流水作为目标架构 | 当前路径跨 event control、数组读、规则计算、bypass；寄存化边界可拆分它们 | 只做表达式化简预计不足以弥补 13.292 ns 缺口 | 推荐 | T02/T17 合同断言、56/56、post-map STA |
| D8-04 | 第一编码增量先维持全局事务保序 | 当前 host commit/commit_rej 没有外部 response tag 的明确证据；无依据的跨端口乱序可能误配响应 | 在 adapter/scoreboard 明确 tag 与排序前，不启用跨 bank 乱序完成 | 已冻结 | 连续 commit、commit/take 撞拍、复位中断 |
| D8-05 | 同端口 RAW hazard 的初版选择保守串行化 | 它能消除组合 `bypass`，保留单端口顺序和块所有权；不同端口仍能流水 | 组合 forwarding 会把宽状态链重新引入关键路径；多版本 CAM 在尚无 STA 证据时风险过高 | 推荐 | 同端口长串、T02 随机、T18 压力和吞吐测量 |
| D8-06 | 不承诺 `desc/qst` 自动映射 BRAM | 事件读、提交写和 host read 至少构成 2R1W 需求；当前数组/异步读写法不能证明 BRAM 推断 | 只加 RAM 属性会掩盖端口冲突并可能回退为 LUT | 已冻结 | 综合存储报告、资源统计、功能读时序 TB |
| D8-07 | BAG 以帧首而非控制接受时间定义 | 现设计书/调度器以 `frame_start` 更新 BAG；控制加拍不能改变线上帧间隔口径 | 以 commit 或 frame done 计 BAG 会改变协议行为 | 已冻结 | T04/T05b/T13 的帧首时间戳断言 |
| D8-08 | TX 与 RX 不在同一增量联动重构 | D11 块释放、D12 时间戳仲裁及 RX pin/双释放的风险独立；一次只验证一个状态机域 | 同时重构会使 block ownership 失效难以定位 | 已冻结 | TX 稳定后按 RX 专项计划迁移 |
| D8-09 | post-map 达标不是签核 | 当前有 71 输入、121 输出未约束，且无 post-fit/IO delay | 只用 Fmax/WNS 宣称 125 MHz 会误导 | 已冻结 | 管脚/IO 约束、fit、post-fit setup/hold |
| D8-10 | 文献仅指导职责边界和验证方法 | L001 等支撑 VL/BAG/冗余和端口架构；它们不是本项目 RTL 证据 | 用论文性能数替代本器件 STA 被禁止 | 已冻结 | `LITERATURE-TRACE.md` 的“文献→决策→工程证据”闭环 |

## 负收益回滚规则

一个增量只有同时满足以下条件才可保留：相关功能回归为 PASS、lint/文档门通过、同一器件/同一 8 ns SDC 的 post-map Fmax 上升且 WNS 改善。任一条件不满足，保存原始日志与补丁后恢复到该增量前的文件哈希；不得用 TNS 的局部变化掩盖 Fmax/WNS 恶化。
