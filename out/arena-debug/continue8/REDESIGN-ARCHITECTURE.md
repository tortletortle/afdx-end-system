# Continue8 — TX/RX 端口状态重设计方案

## 1. 结论先行

**推荐路径：以方案 C 为目标架构，先以方案 A 做最小可验证的流水边界试点；只有在 STA 表明地址选择/阵列端口仍是主导路径时，才引入方案 B 的真实分银行。**

原因是当前 21 ns 路径跨越了事件控制、状态读取、宽字段计算和同端口旁路。单纯分割数组没有切断该依赖，Continue7 已经用负收益实验验证了这一点。要逼近 8 ns，必须让每一级只承担一个明确的状态转换职责，并把 backpressure、结果及所有权都寄存化。

### 目标数据流

```text
host commit / scheduler take / builder blk_free
                  │
                  ▼
       [事件前端：capture + admission]
                  │  Event{kind, port, type, depth, len, block-token, seq}
                  ▼
            [有界事件 FIFO]
                  │
                  ▼
       R: 状态读出 / hazard 查询（寄存）
                  │
                  ▼
       X: 规则执行与写意图生成（寄存）
                  │
                  ▼
       W: 单点提交 desc/qst/map/link/free（寄存）
                  │
       ├── response FIFO → host reject/accept、scheduler ack
       └── sch_req / buf_full / block owner 的已提交视图
```

新设计的原则不是“多打几拍”本身，而是：**未提交状态不直接组合地驱动下一事件的数组读数据；每个跨级依赖只经一个已定义的寄存器、FIFO 或 hazard 记录传播。**

## 2. 现有接口语义，必须冻结

| 语义 | 当前含义 | 重设计后的不可变要求 |
|---|---|---|
| 主机 `MSG_WR` / `msg_commit` | 主机先在开放块写 payload，再提交端口/长度；无块或队列满后产生拒绝 | payload 所属的开放块在提交被接收前不得重新分配；拒绝不能把块错误变成可调度消息 |
| `wr_blk` / `wr_blk_vld` | 指向主机当前可写开放块 | `wr_blk` 只在“新开放块已保留”后改变；FIFO 满、后继块不足均须有可观测的无接收/拒绝语义 |
| `sch_take` / `sch_ack` | 调度器取队头；ack 同时给出块号与长度 | `sch_ack` 可以因流水增加固定拍数，但必须只对应同一条 take，且 `sch_blk/sch_len` 与被移除队头一致 |
| 采样端口 | 最新消息覆盖旧消息并回收旧块 | 覆盖仅在 W 提交；覆盖前的块不可与新块同时可调度或重复释放 |
| 队列端口 | FIFO，满时拒绝；块由 `next_tab` 链接 | 同端口严格顺序、深度、`q_full` 和溢出计数保持；不得因跨端口重排破坏单端口 FIFO |
| `blk_free` | 构建器帧完成归还块 | 同一块只能由一个已提交 owner 归还一次；与 commit/take 相遇时按冻结的事务次序合并 |
| `desc_rd_data` | 主机读描述符 | 必须定义读到“上一次已提交状态”还是“包含当拍提交状态”；实现不能暗中依赖 LUT 异步读 |

块所有权不变量在任何提交边界都应成立：

```text
每个 TX 块恰好属于 FREE、OPEN、QUEUED 或 IN_FLIGHT 之一。
FREE + OPEN + QUEUED + IN_FLIGHT = TX 池块数。
```

该不变量应在 TB scoreboard 和断言中检查，而不是仅由计数器的最终值间接推断。

## 3. 三种可实施方案

### 方案 A：保留单时钟/单事件模型的局部流水化

**结构**：保留全局单事件顺序和现有外部端口；把 `tx_port_buf` 拆为 request capture、状态 read、execute、writeback 四个寄存阶段。`desc/qst` 的旧值在 R 阶段锁存，X 阶段只使用锁存值和一个**已寄存**的最近提交 forwarding record，W 阶段是唯一修改状态的位置。

```text
cycle n     : capture E0
cycle n+1   : R(E0), capture E1
cycle n+2   : X(E0), R(E1)
cycle n+3   : W(E0), X(E1), R(E2)
```

若 E1 与 E0 是同端口，X(E1) 从 W(E0) 的已寄存 forwarding record 选择状态；它不能使用 E0 的组合 `wb_desc` 直接喂回 R(E1)。针对同端口连续事务的初版可保守地串行化（队首事件为 busy port 时暂不 issue），以正确性优先；性能需求证明后再扩展 forwarding。

**收益预期**：直接切断当前 `s1_vld → wb_* → bypass → s1_desc` 组合环，是最低风险的可测试第一刀。它预计增加 2–3 个控制周期，但不应降低已被主机/调度握手限制的长期吞吐。单独实施未必足以把 21 ns 降到 8 ns，因为 256 端口状态选择和路由仍可能成为新瓶颈。

**风险**：主机提交没有显式 tag；因此响应必须按外部可观察的提交顺序产生。全局 FIFO 不能在未冻结语义前任意跨端口重排。`desc_rd` 的双读/写端口需求也要明确为同步快照或镜像。

**适用决策**：作为第一个 RTL 增量，且必须先跑 T02、T04、T17、T18、T22、T23 以及完整回归和 STA。

### 方案 B：端口状态/描述符的真实分银行

**结构**：按 `port_id[7:6]` 将 256 个端口划为 4 个 64-port bank。每个 bank 有独立的 request FIFO、状态 RAM、W 提交口和本地 `valid/qfull` 位图；中央单元只负责把 host commit、scheduler take、host descriptor read 分发到 bank，并仲裁 response。

真正有效的分银行必须满足以下条件：

1. state RAM、request FIFO、writeback 和 forwarding 都是 bank-local，不只是把 Verilog 数组改名为四份；
2. 每个 bank 的状态更新有明确 owner，跨 bank 不共享组合 `wb_desc`；
3. 中央仲裁只运送已寄存的 request/response，不能重新汇合到一条跨 bank 的宽组合回写链；
4. 同端口按 `seq` 保序，跨端口响应是否可乱序必须由 host adapter 明确吸收；
5. `sch_req`/`buf_full` 对外仍是 256-bit 已提交快照，不允许用长链把四个 bank 的实时状态重新组合为关键路径。

**为什么 Continue7 的四银行无效**：该试验没有将请求所有权、读写端口、结果回传和 bypass 变成 bank-local 流水边界；因此 `s1_vld → s1_desc[*]` 的控制—写回—旁路拓扑仍存在，同时加入 bank mux 和额外布线。Fmax 从 45.85 MHz 变为 45.84 MHz、WNS 轻微恶化，正符合“语法分块而非微结构分块”的预期。

**收益与风险**：B 可降低地址译码、局部扇出和布线拥塞，并为真正 RAM 推断创造条件；但它不天然提升一条全局 `sch_take` 的吞吐。若主机协议没有 response tag，跨 bank 完成乱序还会引入功能风险。故 B 只应在 A/C 已建立寄存化事件边界之后，依据新的 STA 热点实施。

### 方案 C：结构化事件队列与提交流水（推荐）

**结构**：把“消息提交/调度取队头/归还块”定义为显式事务。前端用小型、可观测的 event FIFO 接纳事务；后端以固定的 R/X/W pipeline 串行提交端口状态。FIFO 只提供弹性，不改变最终提交顺序；每个事务带序列号和端口号，response FIFO 将 accept/reject/ack 与输入精确配对。

#### C.1 事件与 admission

```text
COMMIT {seq, port, type, depth, len, open_block}
TAKE   {seq, port}
FREE   {seq, block}
```

- `COMMIT` 被 capture 时即锁存 `type/depth/len/open_block`，之后不得再看会变化的端口表或 `wr_blk`。
- 开放块管理属于 admission：只有确认该 block 仍为 OPEN 时才接受 COMMIT；之后为下一消息保留 successor block。无 successor 时，可接受当前 COMMIT 并将 `wr_blk_vld` 拉低，或按现有定义拒绝，二者必须由 T02/T17 的参考模型冻结，不能由实现便利性决定。
- 初版在 commit/take 同拍时保持旧规则“commit 优先、take 延迟”；二期可分别 capture 两者，但必须在 event order/response 语义和 T17 更新后才启用。
- FIFO 满时不得静默丢脉冲。主机侧需要 `valid/ready` 或保持型 bus-ack adapter；调度器在 `take_ready=0` 时必须保持请求/重试。若现有顶层仅能给 1 拍 pulse，则先在 adapter 内提供一项 skid register，并把“无法接收”反馈到原 ACK 状态机。

#### C.2 状态引擎与 hazard 处理

R 阶段同步读取 `desc/qst` 及相关 bitmap；X 阶段计算唯一的 `write_intent`；W 阶段同时提交 descriptor、队列状态、`valid/qfull/smp` 位、链表边、长度表、计数器和 free-map 的差分。对同一端口的未提交事务，issue 单元要么等待该端口的 `busy` 位清除，要么只读取一个**前一 W 阶段已寄存**的 forwarding record。第一版选择前者，避免重新生成长的宽数据 bypass 链。

`FREE` 可进入同一事务序列，或在 W 阶段合并为 `free_set` 位集合；无论哪种方式，都要显式处理“同拍 free + 新开放块分配”，使一个块不被同时 free/alloc 两次。

#### C.3 存储与主机读口

`desc`（256×28）与 `qst`（256×8）适合尝试同步 RAM，但**不能承诺**工具一定推断为 M20K。读端口需求是：事件状态读、提交写和 host descriptor read；真实双口 RAM只有两端口。编码前必须在下列方案中选一项并写进 TB：

1. host read 走已提交描述符镜像（FF 或第二块 RAM），事件引擎独占 state RAM；
2. host read request 进入响应 FIFO，声明一拍或多拍读取延迟；
3. event read 与 host read 仲裁，host 事务按 ready/ack 停顿。

这一步比“强行加 BRAM 属性”更重要；错误的多端口假设会让综合回退为 LUT/寄存器并再次恶化时序。

**收益与风险**：C 将关键路径拆为地址/读、规则计算、写提交三个可测阶段，是最有可能接近 8 ns 的方案。代价是控制响应增加固定 2–4 拍、需修改 host/scheduler adapter 与更多 scoreboard 断言。BAG 以帧首为基准，微秒级 BAG 不会因几个 125 MHz 周期自动失效，但必须通过 T04/T05/T13 重新量测；不得只凭数量级推断。

## 4. RX 的对应策略

`rx_port_buf` 也有 256 个端口状态数组与“主机操作优先、解析结果顺延”的单事件语义，但当前 STA 的最差路径在 TX，故不把 RX 与 TX 同时大改。TX C 架构稳定后，RX 应复用相同的事件定义：`DELIVER`、`HOST_DESC_READ`、`HOST_MSG_READ`、`FREE`，并保留采样 pin、队列链、双释放口以及块守恒规则。

RX 迁移前必须确保 D11 的级联释放语义和 D12 的帧首时间戳仲裁不被破坏；坏帧/IC/RM 拒绝不得污染端口状态或延迟归还块。

## 5. 正确性与性能保护

| 风险 | 保护契约 | 必测证据 |
|---|---|---|
| host ACK/拒绝错配 | 每个 commit 有不可复用 seq；response FIFO 保序 | T02、T17、主机前门断言 |
| queue 顺序破坏 | 同 port 的事务严格保序；head/tail/cnt 仅由 W 修改 | T02、T04、T18 |
| 块泄漏/双归还 | owner 四态与 `free+open+queued+inflight` 不变量 | T02、T17、T21、T23 |
| scheduler 早取/重取 | TAKE 直到 response 前不产生 `sch_ack`；ack 对应同一队头 | T04、T05b、T18 |
| BAG/Jitter 变化 | 调度仍以 `frame_start` 更新下一 BAG；控制加拍后重测 | T04、T05b/T05bg、T13/T13g |
| A/B 去重或 RX 投递变化 | TX 改动不改帧格式与 SN；RX 后续单独迁移 | T10、T11、T22、T23 |
| 管理面响应延迟 | SNMP/TFTP/RTC 的事务完成条件保持，明确 timeout 上界 | T14/T14g、T15/T15g、T16/T16g |

## 6. 对 125 MHz 的诚实预期

方案 C 的目标是在功能等价的前提下把当前 21 ns 跨阶段路径分割成不超过三段；理想情况下每段需留出路由裕量而小于约 6–7 ns，才有希望满足 8 ns。实际级数和延迟须由 post-map STA 决定：外部接口看到的 commit/take 响应可能增加 2–4 周期，网络线速/BAG 语义不能增加。

即便 post-map 报告达到 125 MHz，也仍缺少 IO 约束和 post-fit setup/hold；该结果只能称为内部 post-map 改善，不能称最终板级签核。
