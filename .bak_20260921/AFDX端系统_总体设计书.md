# AFDX 端系统设计与仿真验证 —— 总体设计书

| 项目 | 内容 |
|---|---|
| 作品题目 | 基于以太网 MAC 总线实现 AFDX 端系统（eLinx 软件编译与仿真验证，无板卡、不指定器件） |
| 赛题 | 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 中科亿海微命题 · 选题一「基于以太网 MAC 总线实现 AFDX」 |
| 交付平台 | 指南原文：「本赛题全部通过 eLinx 软件进行编译及仿真，无需硬件平台」。因此全文不出现器件型号、管脚约束与片内资源占比，开销一律给绝对量。组委会《问题汇总》另有两条口径相关的答复：「要求基于 FPGA 做仿真」——必须在 eLinx/ModelSim 里对 RTL 或综合后网表跑波形，不许拿纯软件功能模型代替；「需要参赛者自己编写仿真激励（文件）并验证内容」——赛方不提供激励与参考测试环境，见附录 D |
| 开发环境 | eLinx（RTL 输入、综合、时序分析、IP 生成、Tcl 自动化、ModelSim 联合仿真）、ModelSim、Python 3 |
| 评测依据 | 指南「测评标准」四项：代码及仿真环境 40%、设计文档 20%、测试（仿真）报告 20%、技术指标 20%。技术指标全部由仿真测量；综合与时序属可选自证材料，见 §9、§11 |
| 文档版本 | v0.5.1（v0.2 按「无器件、软件仿真评测」重写开销与综合章节；v0.3 起的全部修订见附录 F） |
| 编写 / 评审 | 编写：全队；评审：指导教师；变更需在第 4 周 P0 闭环前提出 |

---

## 1 引言

### 1.1 目的

本文档给出 AFDX 端系统（End System，下文简称 ES）的完整工程实现方案：需求分解、总体架构、接口与协议格式、地址空间与寄存器定义、逐模块设计、关键算法、存储开销与时间预算、验证环境和进度安排；综合自证（可选）单独放一章。文档同时作为设计赛「设计文档」评分项（20%）的母本，第 4 周末出 v1.0。

写作约定：本文中出现的具体数值（位宽、地址、周期数、资源量）都是设计基线，实现时若调整必须回写本文档，不允许代码与文档各说各话。

### 1.2 范围

设计范围内：ES 内部全部 RTL、eLinx 工程与 SDC、仿真验证环境（TB/BFM/记分板/黄金模型）、交付文档。

以下都不在本设计范围内，赛题按约定由外部提供或不作要求：交换机与网络拓扑、航电终端应用、真实 PHY 与变压器、板级时序与 IO 约束、航电环境（温度、EMC）相关指标。

### 1.3 术语

| 缩写 | 全称 | 含义 |
|---|---|---|
| AFDX | Avionics Full Duplex switched ethernet | 航空电子全双工交换式以太网 |
| A664P7 | ARINC 664 Part 7 | AFDX 的协议规范 |
| VL | Virtual Link | 虚拟链路，点到多点的单向逻辑通道 |
| VLID | Virtual Link IDentifier | 16 位虚拟链路标识，编码在目的 MAC 后 2 字节 |
| BAG | Bandwidth Allocation Gap | VL 相邻两帧发送的最小间隔 |
| SN / PSN | Sequence Number / Previous Seq. No. | 帧尾 1 字节序列号 / 接收端记录的上一正确序列号 |
| IC | Integrity Check | 完整性检查（丢帧、乱序判决） |
| RM | Redundancy Management | 余度管理（双网去重） |
| Lmax | Maximum frame length | 该 VL 允许的最大帧长 |
| SkewMax | — | RM 判决中两网副本允许的最大时间差 |
| SAP | Service Access Point | 服务访问点端口，用于管理/文件类业务 |
| ES | End System | 端系统，本作品对象 |
| PMEM | Packet Memory | 包存储区，收发帧数据共用的一块 BRAM |

### 1.4 参考资料

ARINC 664 Part 7、IEEE 802.3-2018、RFC 791、RFC 768、RFC 1350、RFC 1157、RFC 3416（SNMPv3 仅作对照）；《2026 FPGA 创新设计赛道选题指南（中科亿海微）》第 2~4 页；eLinx 用户手册（随工具发放）；QQ 群 1107062816 的技术答复（记录在附录 D）。

---

## 2 需求分析

### 2.1 功能需求分解

赛题指南给出的功能条目共 5 项，分解为可实现的硬件功能点如下。

| 编号 | 赛题功能 | 分解后的实现点 | 归属模块 |
|---|---|---|---|
| F1 | 基于以太网 MAC 总线实现 AFDX 通信 | MAC 字节流适配（ready 包络 + valid 选通）、线速节拍整形、IFG 保证 | `mac_tx_if` `mac_rx_if` |
| | | 帧构造与解析：MAC/IPv4/UDP 首部、校验和、填充、SN、FCS | `tx_frame_builder` `rx_ip_udp_parse` `crc32_check` |
| | | 通信端口（采样 / 队列 / SAP）与包缓冲 | `tx_port_buf` `rx_port_buf` |
| | | 128 条发送 VL 的 BAG 调度与仲裁 | `tx_vl_scheduler` |
| | | 4096 条接收 VL 的过滤与查找 | `rx_flt` `rx_vl_lookup` |
| F2 | 高可靠性通信 | 每 VL 的 SN 生成与回绕 | `tx_sn_gen` |
| | | 双网（A/B）复制发送与按 VL 的网络选择 | `tx_rm` |
| | | IC：每网每 VL 独立 PSN，SN=0 复位与连续窗口判决 | `rx_ic` |
| | | RM：先到有效 + SkewMax 去重 | `rx_rm` |
| F3 | SNMP 网络管理 | 精简 BER 编解码、GET/GETNEXT/SET、MIB 表 | `snmp_lite` |
| | | 计数器与状态寄存器、可读可写配置项 | `stats_regs` `host_if` |
| F4 | ARINC 615A 数据加载 | TFTP 引擎（RRQ/WRQ/DATA/ACK/ERROR、超时重传、块号回绕） | `a615a_tftp` |
| | | Find/Information/Upload 会话与状态文件 | `a615a_tftp` |
| F5 | RTC 时钟同步 | μs 时基与分数微调、硬件时间戳、偏移估计与收敛 | `rtc_sync` `timebase` |

### 2.2 指标需求与依据

| 项目 | 要求值 | 来源 | 依据条款 | 当前状态 |
|---|---|---|---|---|
| 链路速率 | 100 Mbps | 指南 | 全双工、MAC 字节接口 8 bit | 未测（设计目标） |
| 帧长 | 64~1518 B（不含前导码与 FCS 的以太帧） | 指南 / IEEE 802.3 / XAPP1130 | `802.3 §4.2.5`；XAPP1130 v1.0.1「AFDX – The Details / Frame Format」同口径，另计 7 B 前导码 + 1 B SFD + 12 B IFG | 算式已核（14+20+8+1471+1+4=1518） |
| 载荷 | ≤1471 B | 指南 / XAPP1130 | 1518 − 14(ETH) − 20(IP) − 8(UDP) − 1(SN) − 4(FCS) = 1471；XAPP1130 同节写 1~1471 B，且要求载荷不足 17 B 时补齐 | 算式已核，未测 |
| SN | 1~255 循环，复位后为 0，255 之后回到 1 | 指南 | A664P7 §5.2.2 | 规则已写入 §6.6，未测 |
| VL 规模 | TX 128 / RX 4096 | 指南 | A664P7 系统配置上限 | 表容量与地址已核算（§9/§7.14），未测 |
| BAG | 1/2/4/8/16/32/64/128 ms | 指南 | A664P7 Table 5-1 | 支持任意 μs 粒度（见 §7.2），未测 |
| 端到端时延 | 1~2 ms | 指南 | 含交换网络；ES 自身预算见 §8.3 | 预算已重算（轻载 0.25 ms / 饱和 0.35 ms），未测 |
| 抖动 | 几十 μs 量级 | 指南 | 与 BAG 预算校验式一并给出（§8.2） | 上界 22.4 μs 仅在饱和组 T05b 成立，未测 |

指南原文对抖动与时延的表述是"最大技术时延约 1~2 ms""抖动可以控制在几十微秒以内"，属于典型配置下的量级描述而非硬阈值。本设计把它们拆成两层承诺，避免答辩时被抓：ES 自身引入的时延与抖动由 RTL 与测试环境实测（目标见 §8.2、§8.3），端到端数值按配置线性外推并在文档中列出计算过程。指南没有列资源占用与上板类要求，所以全部指标的取证手段都是仿真：数字来自波形与 `timing_monitor` 统计，不来自综合报告。

1471 B 的推导：以太帧 1518 = 14（DMAC+SMAC+Type）+ 20（IPv4）+ 8（UDP）+ L（载荷）+ 1（SN）+ 4（FCS）得 L = 1471。这个算式必须出现在设计文档中，因为它同时是 `tx_frame_builder` 的长度约束和 `tb` 的随机化上界。

### 2.3 编码规范需求

指南要求信号名小写、参数名大写、必须有注释。项目在此基础上加码（§10）：注释不是装饰，而是第 4 周之后交接与答辩的准备手段。

### 2.4 非功能需求

- 可裁剪：`NUM_TX_VL`、`NUM_RX_VL`、`NUM_PORTS`、`PMEM_KB`、双网使能、各管理功能使能均为参数，缩配用于加速仿真、满配用于出指标。
- 可观测：每一个丢弃/判决/溢出/违规事件都有独立计数器，寄存器可读、TB 可自动比对。
- 可移植：与工具绑定处（BRAM、FIFO 的 IP 例化）通过 `common/` 一层封装，仿真侧用行为模型、综合侧用 eLinx 生成的 IP，切换不侵入功能代码；不假设任何具体器件的容量与块尺寸。
- 单时钟域：全部逻辑在 `clk` 同域，避免 CDC 议题（`pps_in` 是唯一异步输入，走 2 级同步 + 打拍捕获）。

### 2.5 约束与假设

1. 模板顶层 `AFDX_top` 的 8 个端口不得改名、改位宽、改方向；其余端口以扩展形式追加（§5.2）。
2. `tx_ready` 为输出、`rx_ready` 为输入，与常规 valid/ready 语义方向相反。本设计解释为帧包络（§5.3），此为全文档唯一的接口解释性假设，第 0 周必须在群内确认。
3. 时钟与 MAC 接口口径：**已答复，不再是假设**。组委会《问题汇总》对「给 MAC 层的接口是 rgmii 还是 gmii」答复 **GMII**，即 8 bit 字节口 + 125 MHz 采集时钟。据此本文取 `CLK_FREQ_HZ = 125 MHz`、`BYTE_SLOT_CYC = 125e6 × 8 / 100e6 = 10`（每 10 拍放 1 字节，平均 100 Mbps，链路上 90% 是空闲拍）。字节节奏 10 × 8 ns = 80 ns 与原先假设的 8 × 10 ns 相同，所以由线速决定的 μs 级指标（单帧 22.4 μs、pass1 117.7 μs）不变；只有「拍数锁定」的量（主机写口握手、`udp_csum` 每拍 1 字节）时间缩短为 0.8 倍，逐条换算见 §4.1 清单，v0.6 落地到各节。
4. MAC 提供前导码/SFD；FCS 归属由 `FCS_MODE` 参数决定（§5.5）。
5. 无硬件验证、无器件映射要求：技术指标一律以仿真测量结果为准，因此测试环境本身就是被评分对象之一（40%），投入不低于 RTL；综合只在需要自证可综合性与时序余量时补做（§11），不进主线计划。
6. 因为没有板卡，IO 时序、管脚分配、功耗与信号完整性都不在设计范围内，相关约束一律不设。

---

## 3 总体方案

### 3.1 设计思路

ES 的本质是两条流水加一块包存储：发送流水把"主机消息"变成"符合 A664P7 的以太帧并按 BAG 送出去"，接收流水把"MAC 字节流"变成"落到正确通信端口的一条消息，或者被丢弃并计数"。管理面复用同一对流水（走 SAP 端口），不额外开网络通道。

据此定三条实现原则：

- 判决全部按帧、状态全部进 BRAM。4096 条 VL 的状态不可能放寄存器阵列，因此过滤/查找/IC/RM 都设计成"读表 → 判决 → 写回表"的固定节奏，避免大 mux 和大扇出。
- 帧数据只存一份。收发共用一块 32 KB PMEM，帧构建的两遍扫描、接收侧的 RM 等待都靠指针 + 描述符实现，不做数据复制。
- 时间语义唯一。调度、抖动统计、RM 的 SkewMax、SN 复位判决都用同一个 μs 时基（`timebase`），仿真里可通过 `TICK_US` 参数整体缩放，缩放对所有模块同时生效，指标测量时用真实时基。

### 3.2 分层架构

```
                ┌──────────────────────────── AFDX_top ────────────────────────────┐
  主机侧        │  管理面                                                            │
┌──────────┐    │  ┌──────────────────────────────────────────────────────────┐    │
│ host_bfm │◄───┼──┤ host_if ──► regs / tables / stats_regs                    │    │
│ (或软核) │    │  │            ┌──────────────┬──────────────┬────────────┐   │    │
└──────────┘    │  │            │ rtc_sync     │ snmp_lite    │ a615a_tftp │   │    │
                │  └────────────┴──────┬───────┴──────┬───────┴─────┬──────┴   │    │
                │        端口读写/SAP   │              │             │           │    │
                │  ┌───────────────────┴──────────────┴─────────────┴────────┐ │    │
                │  │            port_buf (TX)            port_buf (RX)       │ │    │
                │  └───────────────┬───────────────────────────▲─────────────┘ │    │
                │        PMEM 32KB │ 读                        │ 写   PMEM      │    │
                │  ┌───────────────▼───────────┐   ┌───────────┴───────────────▼┐│   │
                │  │ TX 流水                    │   │ RX 流水                    ││   │
                │  │ scheduler → frame_builder  │   │ mac_rx_if → rx_flt         ││   │
                │  │    → tx_sn_gen → tx_rm     │   │ → rx_vl_lookup → rx_ic     ││   │
                │  │    → mac_tx_if             │   │ → rx_rm → rx_ip_udp_parse  ││   │
                │  └───────────────┬────────────┘   └────────────▲───────────────┘│   │
                └──────────────────┼─────────────────────────────┼────────────────┘   │
                                   ▼                             ▼                    ┌┘
                             MAC A / MAC B 字节流总线（8 bit + valid + ready）
```

### 3.3 数据通路

发送（单帧视角，标注周期数 @100 MHz）：

| 阶段 | 动作 | 周期 |
|---|---|---|
| 1 | 主机写完载荷并写 `MSG_WR`，port 描述符 `tx_ready` 置位 | 2 |
| 2 | `tx_vl_scheduler` 命中（`now ≥ next_tx_time`），仲裁选中 | 1~16 |
| 3 | `tx_frame_builder` pass1：读 PMEM 算长度与 UDP 校验和，填 `hdr[0:63]` 并写回校验和字段 | L×8 |
| 4 | 从 VL 表取 SN 并递增回绕，写 `hdr[62:63]` | 2 |
| 5 | pass2：线速输出 64~1518 字节（含填充、SN，以及可选 FCS） | F×8 |
| 6 | 更新 `next_tx_time`、`last_tx_time`、统计计数 | 2 |

L 为载荷字节数，F 为总帧长。轻载（无排队）时阶段 1~4 与阶段 5 头部可重叠，ES 自身引入的时延约 0.2~1.5 μs（下限为调度 3 拍 + 首部组装 12 拍 + 回填 4 拍 ≈ 20 拍 = 0.2 μs），其余都是线上时间。

接收：`mac_rx_if` 收帧写 PMEM 并生成描述符 → `rx_flt`（首部 14 字节判定 + 长度 + 可选 CRC）→ `rx_vl_lookup`（2 拍）→ `rx_ic`（4 拍）→ `rx_rm`（4 拍 + 可能的等待）→ `rx_ip_udp_parse`（UDP 长度、校验和、端口查找）→ `rx_port_buf` 写描述符与数据 + 中断。判决链共约 20 拍，与帧长无关，这是"100% 线速最小帧不丢帧"的依据（64 B 帧到达间隔 5.12 μs = 512 拍）。

管理面：SNMP/TFTP/RTC 报文以 SAP 端口进出，RX 方向在 `rx_port_buf` 处分流到 `mgmt/`，TX 方向由管理模块直接调用 builder 的"注入通道"（与主机写端口相同的接口，见 §7.14）。这样管理报文与数据报文共用封装与调度，保证 SNMP 的 UDP 报文在格式上与真实栈一致，方便用 Python 的 `scapy` 独立复核。

### 3.4 模块清单

| 层 | 模块 | 职责（一句话） | 估行数 |
|---|---|---|---|
| 顶层 | `AFDX_top` | 连线、参数下发、端口映射 | 260 |
| 发送 | `tx_port_buf` | 端口缓冲与消息描述符、写覆盖/入队规则 | 320 |
| | `tx_vl_scheduler` | BAG 许可判定、最小到期优先仲裁、子 VL 轮询 | 420 |
| | `tx_frame_builder` | 两遍扫描、首部合成、填充、SN 拼接、线速输出 | 640 |
| | `tx_sn_gen` | 每 VL 的 8 位 SN 存储与回绕 | 90 |
| | `tx_rm` | 按 VL 网络配置复制到 A/B | 180 |
| | `mac_tx_if` | 线速节拍、ready 包络、IFG、FCS 生成 | 210 |
| 接收 | `mac_rx_if` | 帧边界检测、PMEM 写入、时间戳 | 200 |
| | `rx_flt` | 长度/类型/VLID 合法性、CRC32 | 330 |
| | `rx_vl_lookup` | VLID→索引 双路哈希 | 240 |
| | `rx_ic` | PSN 窗口判决与回写 | 280 |
| | `rx_rm` | 双网去重、SkewMax、等待队列 | 320 |
| | `rx_ip_udp_parse` | IP/UDP 校验与端口查找 | 340 |
| | `rx_port_buf` | 端口写入、新鲜度、中断 | 300 |
| 管理 | `host_if` | 地址译码、表访问、突发搬运 | 480 |
| | `rtc_sync` | 时间戳锁存、偏移滤波、跳变/平滑 | 260 |
| | `snmp_lite` | BER 解析、MIB 查找、响应合成 | 560 |
| | `a615a_tftp` | TFTP 状态机 + 615A 会话 | 520 |
| | `stats_regs` | 计数事件汇聚、满配统计 RAM | 240 |
| 公共 | `timebase` | μs tick、`TICK_US` 缩放、24 bit 时戳 | 140 |
| | `crc32_check` / `ip_checksum` / `udp_checksum` | 校验和/ FCS | 300 |
| | `sync_fifo` / `rr_arbiter` / `bram_sdp` | 存储与 FIFO 封装（仿真行为模型 / 综合 IP） | 260 |
| **合计** | 22 个模块 | — | ≈ 7.4 k |

合计约 7.4K 行。分组小计：顶层 260、发送 1860、接收 2010、管理面 2060、公共 700，逐行相加 6890；代码本体 6.9K 行，加注释、端口表和文件头按 7.4K 估。分组小计由 `tools/verify_all.py` 从模块清单现算校验，改表就重跑，别手改这里的数字；行数只用于分工，不作为考核。

### 3.5 设计决策记录

| # | 决策 | 备选 | 理由 |
|---|---|---|---|
| D1 | `*_ready` 作帧包络、`*_valid` 作字节选通 | 按标准 valid/ready 握手解释 | 模板端口方向反常，按握手解释时 `tx_ready`（输出）无法表达发送许可；包络解释对双方都可实现，且隔离在 2 个适配模块中（待出题方确认） |
| D2 | 收发共用一块 32 KB PMEM，用描述符引用 | 每方向独立 4 KB 帧缓存 ×N | 满配 RX 若每网缓存 2 帧需 2×4 KB×深度，且 RM 等待会放大；共用池 + 链表只需一套读写仲裁 |
| D3 | 调度器用「最早到期优先」（最小 `next_tx_time` 归约树） | 分桶轮询（按 BAG 档位分 8 桶） | 分桶实现省 ~1.4K LUT，但同档位 VL 之间抖动上界不优于轮询；归约树 3 级流水后时序无压力，优先选指标 |
| D4 | UDP 校验和采用两遍扫描（pass1 累加，pass2 发送） | 边发边算、最后回填 | 回填需要随机访问输出流且破坏线速节拍；两遍扫描代价是每帧多 L×8 周期，落在 150 μs 预算内 |
| D5 | 管理面用 RTL 状态机做固定协议子集 | Microblade 软核 + lwIP | 软核路线要在 eLinx SDK 上耗 ≥1 周且仿真慢一个量级；子集方案可测、可证、可控 |
| D6 | FCS 由 ES 生成/校验（默认），保留交予 MAC 的参数 | 完全依赖 MAC | 仿真里 MAC 是自建 BFM，自校验能让 T08/T17 的错误注入可控；`FCS_MODE` 保留两种 |
| D7 | RX VLID 查找用双路哈希 + 配置期选种子 | 4096 项直接映射（16 bit→12 bit 表） | 直接映射只要 4096×13 bit ≈ 53 Kbit，比哈希省一大截，但它要求 VL 索引就是 VLID（必须连续紧凑编号），而 A664P7 的 VLID 是任意 16 位；哈希把任意 VLID 压到 `NUM_RX_VL` 个稠密索引上，代价是 15 块存储。配置期离线选种子，运行时不做冲突处理 |
| D8 | 抖动直方图只对前 8 条 VL 做硬件统计 | 全 VL 直方图 | 全量需 128×32×32 bit，硬件成本换来的是重复测量；其余 VL 由 TB 的 `timing_monitor` 统计 |
| D9 | 满配与缩配各存一份配置（同一套回归、同一套指标口径） | 只交满配 | 万一满配仿真过慢或综合不过，缩配那套能立刻接手；两份数据并列也顺带说明架构的代价结构（§9、§11.4） |

---

## 4 时钟、复位与参数

### 4.1 时钟

组委会答复 MAC 层接口为 GMII（附录 D），因此 `clk` 取 125 MHz——GMII 的 8 bit 口本身有 1 Gbps 能力，靠 90% 空闲拍压到 100 Mbps，不需要第二个时钟域、不做 CDC，全文仍只有一个 `clk`。凡按字节节拍的量一律写成 `BYTE_SLOT_CYC`（每字节占用周期数）：

```
BYTE_SLOT_CYC = CLK_FREQ_HZ × 8 / 100_000_000
```

上面这条式子在 125 MHz 下给出 `BYTE_SLOT_CYC = 10`。凡以「字节 × 80 ns」定价的量（判决式 §8.2、单帧线上时间、pass1/pass2、BAG 相关抖动上界）一个都不变；以「时钟拍数」定价的量要按 20 ns → 8 ns/… 即 ×0.8 换算。本轮不偷偷改数字，先把清单钉在这里，v0.6 逐条回写，任何一处没换算都算未闭环：

| 量 | 现写值（按 100 MHz，20 ns/拍） | 125 MHz 下 | 锁定方式 |
|---|---|---|---|
| 主机标准写全表 `34 688 字 × 2 拍` = 0.694 ms | 693.8 μs | 555.0 μs | 握手拍数 |
| 突发口 `2 168 组 × 18 拍` = 0.390 ms | 390.2 μs | 312.2 μs | 突发拍数 |
| RX 配置表灌入 163.8 μs（单字）/ 92.2 μs（突发） | 见左 | ×0.8 = 131.0 / 73.8 μs | 拍数 |
| `udp_csum` 严格模式 1518 拍 = 15.2 μs | 15.2 μs | 12.1 μs | 每拍 1 字节 |
| TX 首字节轻载 349 拍 = 3.5 μs | 3.5 μs | 2.8 μs | 拍数 |
| 单帧线上时间 22.4 μs、pass1 11 768 拍 = 117.7 μs | 由 80 ns/字节得出 | 不变——前提是 PMEM 读口跟着改成 1 字节/10 拍；若仍按 1 字节/8 拍，pass1 缩到 94.1 μs，但线速不变，只是留出更多空闲 | 字节节拍 |

综合时按 `clk` = 125 MHz 设 create_clock；不需要 PLL，除非 `CLK_FREQ_HZ ≥ 200 MHz` 时用 eLinx PLL 生成 μs tick 的低频副本（本项目默认不使用，保持单域）。125 MHz（8 ns）仍属低频，但比原估的 10 ns 紧，§11 的「组合逻辑级数 ≤ 8 级」预算要按这个周期重看一遍。

### 4.2 复位

模板 `reset` 为高有效，按同步复位实现：

```verilog
always @(posedge clk) begin
    if (rst_sync) begin ... end
end
```

内部把 `reset` 打 3 拍生成 `rst_sync`（防抖，兼容异步释放的 BFM）。BRAM 与表项不复位，复位后由 `valid` 位判定内容无效：`tx_vl_cfg.valid`、`rx_vl_hash.valid`、`port_cfg.valid` 全 0，`psn[*]=0`（用复位后的 0 值语义即"未收到过任何帧"，与 SN=0 复位规则一致）。计数器全部复位。

约束：`set_false_path` 只用于 `pps_in` 异步输入，`reset` 按同步处理不设 async 约束，避免 eLinx STA 漏报。

### 4.3 参数表

| 参数 | 默认 | 允许范围 | 说明 |
|---|---|---|---|
| `NUM_TX_VL` | 128 | 1~128 | 发送 VL 数，直接决定调度器规模 |
| `NUM_RX_VL` | 4096 | 1~4096 | 接收 VL 数，决定哈希表与状态 RAM 深度 |
| `RX_HASH_SLOTS` | 2×`NUM_RX_VL` | ≥2 | 哈希桶数（2 路，每桶 2 表项） |
| `NUM_PORTS` | 256 | 8~256 | 通信端口数 |
| `PMEM_KB` | 32 | 16~128 | 包存储区容量（KB）：发送 8 KB 顺序区 + 8 KB 块区，接收 16 KB 块区 |
| `MAX_FRAME` | 1518 | 固定 | 最大帧长，最小帧 64 |
| `CLK_FREQ_HZ` | 100_000_000 | 任意 | 系统时钟 |
| `BYTE_SLOT_CYC` | 8 | 计算 | 每字节周期数 |
| `IFG_BYTES` | 12 | 5~20 | 帧间时隙（字节） |
| `DUAL_NET_EN` | 1 | 0/1 | 双余度网络 |
| `FCS_MODE` | 2 | 0/1/2 | 0=MAC 处理，1=ES 生成+MAC 透传，2=ES 生成并自校验 |
| `IC_EN` / `RM_EN` / `SNMP_EN` / `TFTP_EN` / `RTC_EN` | 1 | 0/1 | 功能裁剪开关（缩配仿真时关） |
| `SUBVL_MAX` | 8 | 1~256 | 每条 VL 子 VL 数（P2） |
| `TICK_US` | 1 | 1~1024 | 时基缩放（仅仿真用，1=真实时基） |
| `STATS_EN` | 1 | 0/1 | 统计 RAM 使能 |

综合时满配取 `NUM_TX_VL=128`、`NUM_RX_VL=4096`、`PMEM_KB=32`、全部 `*_EN=1`；日常回归取 `NUM_RX_VL=64`、`PMEM_KB=8`、管理面全开但 `STATS_EN=0`，仿真速度约差 6~10 倍。

---

## 5 接口定义

### 5.1 顶层端口总表

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | in | 1 | 系统时钟，100 MHz |
| `reset` | in | 1 | 高有效同步复位 |
| `tx_data` | out | 8 | 网络 A 发送数据 |
| `rx_data` | in | 8 | 网络 A 接收数据 |
| `tx_valid` | out | 1 | 发送字节选通 |
| `rx_valid` | in | 1 | 接收字节选通 |
| `tx_ready` | out | 1 | 发送帧包络：本端准备好被送入整帧 |
| `rx_ready` | in | 1 | 接收帧包络：对端本帧有效（见 §5.3） |
| `tx_data_b` / `tx_valid_b` / `tx_ready_b` | out | 8/1/1 | 网络 B 发送 |
| `rx_data_b` / `rx_valid_b` / `rx_ready_b` | in | 8/1/1 | 网络 B 接收 |
| `host_cs` | in | 1 | 主机访问片选 |
| `host_we` | in | 1 | 写使能 |
| `host_addr` | in | 16 | 字地址（32 bit 对齐，addr[1:0] 忽略） |
| `host_wdata` | in | 32 | 写数据 |
| `host_rdata` | out | 32 | 读数据 |
| `host_ack` | out | 1 | 访问完成（固定 2 拍，无等待状态；突发模式见 §7.14 的 `BURST_*`） |
| `host_irq` | out | 1 | 中断请求，高有效，`INT_STATUS` 非 0 且未被屏蔽 |
| `pps_in` | in | 1 | 外部秒脉冲（可选时基对齐） |
| `pps_out` | out | 1 | 本端秒脉冲输出（由 RTC 生成，供 TB 测精度） |
| `rtc_time_us` | out | 64 | 当前时基，μs |
| `dbg_frame_event` | out | 4 | 调试观测：0=tx_frame_start，1=rx_frame_ok，2=rx_drop，3=mgmt_activity |

`dbg_*` 不接任何物理接口，纯粹给仿真和记分板挂钩子用（综合时可 tie off，不影响功能）。

### 5.2 与模板的兼容性说明

模板给出的 8 个端口全部保留原样，包括方向与位宽。扩展端口一律追加在模板端口之后，因此把模板工程文件里的端口表整体复制过来仍然能例化成功（未连接的扩展端口悬空即可，`DUAL_NET_EN=0` 时网络 B 端口无影响）。

若出题方要求顶层必须与模板逐字一致（不允许增端口），退化方案是：主机接口改用 `rx_data`/`tx_data` 复用的一帧配置报文（OOB 配置帧），扩展端口全部取消，代价是主机访问带宽降到 12.5 MB/s（与线速同量级）——配置够用，但表写入会很难看：满配 RX 配置 + 哈希 ≈ 408 KB，逐项 2 拍要 65 k 拍以上，所以必须走突发口（§5.4），这一条也写进配置脚本的验收。该退化版本记为 `AFDX_top_min`，第 4 周前保留，第 2 周末决定是否启用。

### 5.3 MAC 字节流接口时序约定

```
tx_ready ─────┐        ┌────────────────────────┐
              └────────┘                        └──────────
tx_valid  ───┐ ┌─┐ ┌─┐ ┌─┐ ... ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌──────────
             └─┘ └─┘ └─┘       └─┘ └─┘ └─┘ └─┘
tx_data   XX |P|5|5|0| ... |SN|FCS| XX
             └──────── 8 cycles per byte ────────┘
```

规则（TX 方向，ES 为源；RX 方向语义镜像，由对端 BFM 驱动）：

1. `tx_ready` 高电平覆盖整帧：在帧首字节对应的 `tx_valid` 之前 ≥2 拍拉高，在末字节之后 1 拍拉低。低电平表示"正在构建下一帧或对端不可收"。
2. `tx_valid` 是字节选通，只在 ready 包络内出现；两拍连续 `tx_valid` 之间固定间隔 `BYTE_SLOT_CYC` 拍（线速，不突发）。
3. 帧间至少 `IFG_BYTES × BYTE_SLOT_CYC` 拍的包络低电平。
4. 数据在 `tx_valid=1` 的上升沿同拍有效，接收方在 `valid=1 && clk` 上升沿采样。
5. 一旦 `tx_valid` 出现帧首字节，本端不会中途撤销整帧（帧级原子性）；若对端中途把 `rx_ready` 拉低（背压），本端在字节边界暂停并保持 `tx_valid=0`、包络维持。
6. 接收侧 `rx_ready` 由对端拉高表示"该帧有效，本端已完整写入"；`rx_valid=0` 且 `rx_ready=0` 表示无帧。ES 只在 `rx_ready=1` 期间采样 `rx_data`/`rx_valid`。

### 5.4 主机接口时序

标准 2 拍非突发：第 1 拍 `host_cs` 与地址/数据有效，第 2 拍 `host_ack` 高同时 `host_rdata` 有效。表项与 PMEM 用 `BURST_LEN` + `BURST_ADDR` 批量搬运（§7.14）：RX 配置表 4096 项 × 2 字 = 8192 字，单字写 2 拍/字 = 16 384 拍 = 163.8 μs；按 16 字突发、每笔 18 拍（2 拍起址+长度、16 拍数据）算 = 512 × 18 = 9216 拍 = 92.2 μs，只省 1.8 倍而不是 16 倍——突发省的是每笔的握手开销，不是数据本身。全表（TX VL 640 + RX 配置 8192 + 哈希 16384 + 端口 1024 + 描述符 256 + PMEM 初值 8192 = 34 688 字）单字写 69 376 拍 = 0.694 ms，突发 0.390 ms。

### 5.5 FCS 归属

| `FCS_MODE` | TX | RX | 用途 |
|---|---|---|---|
| 0 | 不生成 | 不校验，依赖 BFM 的 `err` 标记 | 若 MAC 自己加 FCS |
| 1 | 生成并附加 | 校验（丢弃时计数） | ES 负责，MAC 透传 |
| 2 | 生成并附加 | 校验 | 默认：同上，且 TB 可按位翻转注入 |

CRC 参数：IEEE 802.3 CRC-32，`G(x)=x^32+x^26+x^23+x^22+x^16+x^12+x^11+x^10+x^8+x^7+x^5+x^4+x^2+x+1`，初始值 0xFFFFFFFF、输入输出按位反转、末尾异或 0xFFFFFFFF（即 Ethernet FCS，反射多项式 0xEDB88320）。按字节推进的实现见 §8.1。

---

## 6 帧格式

### 6.1 完整帧布局

| 偏移 | 长度 | 字段 | 值 / 约束 |
|---|---|---|---|
| −8 | 7+1 | Preamble + SFD | 由 MAC 生成，`FCS_MODE≠0` 时 TB 不计入帧长 |
| 0 | 6 | DMAC | `03-00-00-00-VLID[15:8]-VLID[7:0]` |
| 6 | 6 | SMAC | `02-00-00-UDI-IFID-00`（见 §6.2） |
| 12 | 2 | EtherType | `0x0800`（IPv4）；`0x86DD` 预留但不实现 |
| 14 | 20 | IPv4 | 见 §6.3 |
| 34 | 8 | UDP | 见 §6.4 |
| 42 | L | Payload | 8 ≤ L ≤ 1471（8 是最小 AFDX 载荷，非硬性） |
| 42+L | 1 | SN | 1~255，见 §6.6 |
| 43+L | 0~58 | Pad | 不足 64 字节（DMAC 起算）时补 0 |
| 末尾 | 4 | FCS | `FCS_MODE≥1` 时附加，覆盖 DMAC..FCS 之前 |

约束校验（`tx_frame_builder` 与 `rx_flt` 都要查）：`14+20+8+L+1+4 ≤ 1518` ⇒ `L ≤ 1471`；帧总长（不含 FCS，DMAC 起算）≥ 64 − 4 = 60 由填充保证。

### 6.2 MAC 地址

- DMAC：`0x03` 高字节保证 bit0=1（组播，符合 A664P7 的 VL 组播寻址）、bit1=1（本地管理）；`0x00 0x00 0x00` 固定；后 2 字节是 VLID 大端。`rx_flt` 只查前 4 字节等于 `32'h0300_0000`，因为 VLID 变化范围大，逐 bit 比较 6 字节会拖长过滤流水。
- SMAC：`0x02`（单播 + 本地管理），`0x00 0x00`，随后 1 字节 `UDI[7:0]`（User Defined ID，接口级），1 字节 `IFID[3:0]<<4 | net_id`（`net_id`：A 网 = 1，B 网 = 2），末 2 字节 0。`UDI`/`IFID` 来自 VL 表项与全局寄存器 `SMAC_CFG`。

### 6.3 IPv4 首部（20 字节，固定无选项）

| 字段 | 取值 |
|---|---|
| Version/IHL | `0x45` |
| TOS/DSCP | 可配（`VL_CFG.w1.tos`），默认 0 |
| Total Length | 20 + 8 + L + 1 |
| Identification | 每 VL 独立 16 位计数器，可选关闭递增（默认递增，便于 TB 交叉验证） |
| Flags/Frag | `DF=1`、MF=0、偏移 0（不分片；分片重组是 P2） |
| TTL | 255（默认），每 VL 可配 |
| Protocol | 17（UDP） |
| Header Checksum | 在线计算，见 §8.4 |
| Src IP | `VL_CFG.w2.dst_ip` 同表提供 `src_ip`（本端 IP，全局 `IP_CFG`） |
| Dst IP | `VL_CFG.w2.dst_ip` |

### 6.4 UDP 首部（8 字节）

| 字段 | 取值 |
|---|---|
| Src Port | 由端口表 `port_cfg.w0.sp` 给出（默认 = 49152 + port_id） |
| Dst Port | 由 VL/端口表 `dp` 给出；接收侧按 dp 查端口表 |
| Length | 8 + L + 1（含 SN） |
| Checksum | 按 `UDP_CSUM_MODE` 决定（见下）；为 0 时按规范表示"未计算" |

端口分配约定：管理面 SAP 端口占用 `dp` = 161（SNMP）、69（TFTP）、63（TFTP 备用）、49400~49415（自定义 RTC 同步）；数据端口 `dp` 从 49152 起。冲突检查在配置阶段由脚本完成，硬件也查（写入 `CFG_ERR`）。

`UDP_CFG.UDP_CSUM_MODE`（寄存器 `0x0070` 位 1）：0=发送置 0 且接收不校验，1=发送计算并校验（默认）。取 1 是为了让 T03 有可测内容；0 用于缩配仿真提速。

### 6.5 校验和细节

- IP 头校验和：20 字节 16 位反码和取反。发送侧在构建 header buffer 时随写随累加（10 个 16 位项，1 级加法树 2 拍完成），只在写完后回填。
- UDP 校验和：伪首部（src IP 2 字、dst IP 2 字、0、17、UDP 长度）+ UDP 首部 + 载荷 + SN + 零填充到偶数字节，反码和取反。发送侧 pass1 完成（§8.4），接收侧在 `rx_ip_udp_parse` 内按流累加，帧尾比较。
- 反码和实现：32 位累加器 + 折叠（`sum = sum[31:16] + sum[15:0]` 两轮 + 末轮进位加一），避免每字节一次折叠。

### 6.6 SN 规则

`tx_sn_gen` 每 VL 保存 8 位。复位后为 0；复位释放后的第一帧发 SN=1；随后每帧 +1；255 之后回到 1，**永不使用 0**（0 是接收侧的"复位 PSN"信号）。实现上：

```
sn_next = (sn_cur == 8'd255) ? 8'd1 : sn_cur + 8'd1;
sn_tx   = (sn_cur == 8'd0)   ? 8'd1 : sn_cur;   // 复位后首帧
```

`sn_cur` 在帧构建 pass2 末字节写完后更新（避免被丢弃/覆盖的帧浪费 SN），这与 A664P7"发送成功才递增"一致；实现时把更新点放在 `mac_tx_if` 反馈的 `frame_done` 上。

---

## 7 模块详细设计

以下每个模块统一按「功能 → 端口 → 内部结构 → 状态机/算法 → 资源 → 验证要点」写。端口表中除特殊说明，均在 `clk`/`rst_sync` 下工作。

### 7.1 `tx_port_buf`

功能：容纳主机写入的消息，向调度器提供"该端口有数据"的事实，向帧构建器提供读端口。

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `wr_en` | in | 1 | 主机写 PMEM（来自 `host_if`） |
| `msg_commit` | in | 1 | 主机写 `MSG_WR[port]`，提交一条消息 |
| `port_id` | in | 8 | 端口号 |
| `len` | in | 16 | 提交消息的字节数 |
| `sch_req` | out | `NUM_PORTS` | 位图：该端口有待发数据 |
| `sch_ptr` | out | 4 | 被询问端口消息所在的 PMEM 块号 |
| `sch_free` | in | 1 | 发送完成后释放 |
| `buf_full` | out | `NUM_PORTS` | 队列端口满 |

内部结构：

- 描述符 RAM：256 × 32 bit（字地址 `0x8180`）。字段 `{valid, q_full, fresh, blk[3:0], len[12:0], age[7:0]}`：`blk` 是 PMEM 块号（16 块池，§8.6），`len` 是消息字节数，`age` 是 commit 时刻的 `tb_us[7:0]`。
- 采样端口（`type=0`）：单槽。新消息 commit 时若已有未发送消息，覆盖（`ptr` 改写、`fresh=1`），`ovr_cnt` +1。调度器读走时 `valid=0`、`fresh=0`。
- 队列端口（`type=1`）：per-port 环形 FIFO，条目存 `{blk, len}`，深度来自 `port_cfg.w3.depth`（1~8 消息，受 TX 池 6 块限制，配置脚本按端口数校核总深度 ≤ 池容量）。commit 时若满则拒写并 `q_ovf` +1，`host_ack` 上返回 `STATUS.BUF_FULL`。
- SAP 端口（`type=2`）：语义同队列端口，但只允许 `mgmt/` 模块写入（`host_if` 译码保护：`port_id ≥ SAP_BASE` 且来源非 mgmt 时写无效并置 `ERR`）。
- `age`：commit 时记录 `tb_us[7:0]`，用于主机侧算"消息在 ES 内的滞留时间"（T13 的时延测量取 `frame_tx_time − age`，与 TB 记录互为交叉验证）。

PMEM 布局：32 KB 划成 16 个 2 KB 块，起始字地址 `0x8800`（地址空间按 32 bit 字编号，一块 2 KB = 512 字，但地址按字节口径折算，故一块跨 `0x400` 个字地址；块基址 = `0x8800 + blk×0x400`）。不做"每端口一个固定小槽"的顺序区——256 端口 × 128 B 恰好把 32 KB 吃光，而采样消息本身可达 1471 B，固定小槽必然逼出「短消息内联、长消息走块」两套存储路径，复杂度不值得。统一按块分配：

| 池 | 字地址范围 | 块数 | 用途 |
|---|---|---|---|
| TX | `0x8800~0x9FFF` | 6 | 队列端口、大采样消息、管理面发送 |
| RX | `0xA000~0xB7FF` | 6 | 在途接收帧（1 正在写 + 1 判决链 + 1 RM 等待） |
| 公共 | `0xB800~0xC7FF` | 4 | 任一池耗尽时借用，借出记 `pmem_borrow` |

空闲块用 `free_head` + `next[16]` 单向链管理；描述符里 `blk[3:0]` 即块号（块基址 = `0x8800 + blk×0x400`），块内偏移由读地址低位给出。深度是算出来的：接收判决链恒定 20 拍，同刻在途最多 3 帧，6 块含 2 倍余量；发送侧同刻最多 1 帧在建 + 2 条待发，也够。`PMEM_KB=16` 时两池各 4 块、公共池取消，此时必须保证接收在途 ≤4，由 `pmem_exhaust` 计数验证（T21 两种参数都跑）。

验证要点：T11（覆盖/新鲜度/溢出计数）、T17（写口与读口同拍冲突仲裁——commit 与 `sch_free` 同拍时以 commit 优先并置 `pending` 位）。

### 7.2 `tx_vl_scheduler`

功能：在 128 条 VL 中选出"已获 BAG 许可且最老"的一条，把它的 `port_id`/`vl_id` 交给帧构建器，并在发送结束时更新时间戳。

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `tb_us` | in | 24 | 当前 μs（低位截断，见 §8.2） |
| `vl_valid` | out | 128 | 该 VL 配置有效 |
| `port_ready` | in | `NUM_PORTS` | 来自 `tx_port_buf.sch_req` |
| `vl_port_mask` | in | 128×4 | 每 VL 的候选端口数（P0：1 个端口/VL；P2 子 VL 时 8 个） |
| `pick_vl` | out | 8 | 选中的 VL |
| `pick_port` | out | 8 | 选中的端口 |
| `pick_start` | out | 1 | 启动帧构建 |
| `busy` | in | 1 | 构建器忙 |
| `done` | in | 1 | 帧已完整送出（来自 `mac_tx_if.frame_done`） |
| `bag_viol` | out | 1 | 本次判决被绕过（自检，仅 `CFG_ERR` 时可能） |

判决逻辑（组合，128 路并行）：

```
due[i]  = vl_valid[i] && port_ready[p0[i]] && (tb_us - next_tx[i]) < 2^23   // 模 2^24 有符号差 ≥ 0
ready[i] = due[i] && !stale[i]
```

`(tb_us - next_tx[i])` 用 24 位无符号减后判高位（`diff < 2^23` 表示已到期，可容忍 8.4 s 时间回绕），避免 40 位比较器。`next_tx[i]` 存 24 位。

仲裁（最早到期优先）：

```
// Stage A：分组归约，16 个一组，组内取 min(next_tx) 与其下标
grp_min[g] = min{ next_tx[i] | ready[i], i ∈ group g }
// Stage B：8 组结果再取 min，得到全局最早 next_tx
// Stage C：在等于全局最早 next_tx 的候选中，用 last_served 之后的轮询优先编码器选一个
```

三级流水（每组一个 `min_idx` 单元，128 项共需 128 个 24 位比较器 + 128 个选择器 ≈ 1.4K LUT），从 `pick_start` 到 `pick_vl` 有效共 3 拍。回退模式 `SCHED_MODE=0` 时只用 `rr_arbiter`（省资源，抖动略大），配置寄存器切换，便于对照实验。

时间戳更新（在 `done` 拍）：

```
next_tx[i] = max(tb_us, last_tx[i]) + bag_ticks[i];   // bag_ticks = BAG_us，BAG 档位见 VL 表
last_tx[i] = tb_us;
```

若 `next_tx` 更新落后于 `tb_us`（配置超额或 VL 长时间饿死），置 `bag_viol` 并 `vl_stats[i].bag_ovf` +1，不强行提前发送——绝不违反 BAG，这是判决优先级。

子 VL（P2）：`vl_port_mask` 扩到 8 位，选中 VL 后按 `subvl_rr[i]` 轮询取下一个端口，`next_tx` 仍按 VL 维护（符合 A664P7：同一 VL 的所有子 VL 共享 BAG）。

资源：`next_tx`/`last_tx` 各 128×24 bit 寄存器阵列（6.1 Kbit，记在 §9 的逻辑侧，因为 128 路每拍都要并行读，RAM 做不到）；比较器 256 个、优先级编码器 2 组、`min` 归约树，估 2.2K LUT + 6.1K FF。

验证要点：T04（每 VL 相邻帧间隔 ≥ BAG，违规数 = 0）、T05（128 VL 满载抖动）、`SCHED_MODE` 两种模式的抖动对比数据（测试报告的加分项）。

### 7.3 `tx_frame_builder`

功能：把一条端口消息变成完整帧并线速送出，同时完成首部合成、填充、SN 与 FCS。

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `start_vld` | in | 1 | 调度器启动 |
| `start_vl` / `start_port` | in | 8/8 | 目标 VL 与源端口 |
| `snap_req` | out | 1 | 向 `tx_sn_gen` 申请下一个 SN |
| `snap` | in | 8 | SN 值 |
| `rd_en` / `rd_addr` | out | 1/16 | PMEM 读（`{blk, offset}` 拼成字地址） |
| `rd_data` | in | 8 | PMEM 读数据（固定 1 拍延迟） |
| `out_byte` / `out_vld` | out | 8/1 | 送 `mac_tx_if` |
| `out_rdy` | in | 1 | `mac_tx_if` 允许（其内部受字节节拍与 IFG 控制） |
| `busy` | out | 1 | |
| `frame_done` | in | 1 | 末字节已被 MAC 接收 |
| `hdr_wr` | out | 1 | 写 header buffer 的 SN/校验和字段 |

Header buffer：64 × 16 bit（128 B），放寄存器阵列（约 1.0K FF）。内容 = 以太网 + IPv4 + UDP 首部 + 预留的填充与 SN 位置。设计成"先写完整首部（除 SN/UDP 校验和/IP 校验和），pass1 结束后回填三个计算字段"，避免在字节流上做随机写。

状态机：

| 状态 | 动作 | 周期 |
|---|---|---|
| `IDLE` | 等待 `start_vld` | 1 |
| `HDR_INIT` | 从 `VL_CFG`/`PORT_CFG` 组装首部 42 字节写入 hb，同时累加 IP 校验和、UDP 伪首部和 | 12 |
| `P1_FETCH` | 按 8 拍/字节读 PMEM，累加反码和，计 `L`，`byte_cnt++`；结束条件 `byte_cnt == L` | L×8 |
| `P1_CSUM` | 反码折叠，写 `hb[32]`（UDP 校验和）、`hb[24]`（IP 校验和）、`hb[62:63]` 保留 SN、长度字段 | 4 |
| `P2_EMIT` | 逐字节发：64 B 首部 + L 载荷（重读 PMEM）+ 填充到 60 B + SN + FCS（`FCS_MODE≥1`） | (F+4)×8 |
| `DONE` | 发 `frame_done`，交还控制权 | 1 |

`P2_EMIT` 期间 PMEM 读带宽 1 字节/8 拍 = 12.5 MB/s，与写口 12.5 MB/s 冲突时按"写优先"（主机不能饿死），构建器有 4 深度字节缓冲吸收。

填充规则：`pad = (60 − (42 + L))`，若 `L ≥ 18` 则 `pad = 0`。载荷区之后是 SN，填充只作用于载荷区（A664P7：填充在 SN 之前，属于 UDP 载荷的一部分，接收侧按 UDP 长度剥离）。这一条容易被做错，T02 里专门放 `L=8` 的极短帧用例验证填充位置。

资源：状态机 + 首部组装 mux + 两个反码和累加器 + 64×16 寄存器 ≈ 1.6K LUT。

验证要点：T02/T03/T06/T08（长度边界：L=8、L=1471、L=18 恰好不填充、L=17 需填充 1 字节）。

### 7.4 `tx_sn_gen`

功能与端口：`snap_req/snap/snap_ack`、`init_all`（复位后清 0）、`host_override`（调试强制设值，配合 T09 注入）。128×8 bit 寄存器阵列，每 VL 一个；`sn_next = (sn==255) ? 1 : sn+1`。更新只在 `frame_done` 时提交（见 §6.6），因此 `snap` 需要在构建器内暂存一拍，模块提供 2 位 `sn_pend[1:0]` 防止同一 VL 未提交又被申请（构建器保证串行，属防御性检查，置 `ERR`）。

资源：1.0K FF + 128 个 8 位加比较器 ≈ 0.5K LUT。

### 7.5 `tx_rm`

功能：把 builder 送出的整帧按 VL 的 `net_mode` 复制成 1 或 2 份，分别送 A/B 的 `mac_tx_if`，两份只改 SMAC 最后一字节的 `net_id`。

实现：帧构建器输出同时进两个 32×8 的 skid FIFO；`net_mode` 决定另一路是复制还是关闭。改 `net_id` 的做法是在 `P2_EMIT` 首字节阶段对 SMAC 最后一字节按目标网络做替换（在 builder 内 mux 完成，不在 `tx_rm` 里回改），使 `tx_rm` 退化为纯分发器——省一个随机访问。因此 `tx_rm` 的真实工作是：两路 FIFO、两路 `ready` 的与/或合成（`busy = busy_a | busy_b`，`frame_done = done_a & done_b`）、单网 VL 的 `net_id` 选择。

关键时序：两路的 `frame_done` 必须同一拍对齐，否则 `next_tx` 更新时刻抖动。做法：A/B 两个 `mac_tx_if` 共享同一个 `IFG`/节拍计数器（由 `mac_tx_if` 的父级 `tx_pace` 提供），使两路帧起始与结束天然对齐。

验证要点：T07（两网逐字节比对，仅 SMAC 差 1 bit）；`net_mode=A` 时 B 路无任何活动（功耗与波形检查）。

### 7.6 `mac_tx_if`

功能：字节节拍、`tx_ready` 包络、IFG、FCS 附加、对端背压处理。

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `in_byte` / `in_vld` | in | 8/1 | 来自 `tx_rm` |
| `in_rdy` | out | 1 | 允许输入（内部 FIFO 未满） |
| `tx_data` / `tx_valid` / `tx_ready` | out | 8/1/1 | 对 MAC |
| `frame_start` / `frame_done` | out | 1 | 给 builder/scheduler |
| `pace_en` | in | 1 | 来自共享 `tx_pace`（每 `BYTE_SLOT_CYC` 拍一拍） |

行为：`tx_ready` 在 FIFO 有 ≥1 字节且 `pace` 允许时于帧首前 2 拍拉高；帧内每 `BYTE_SLOT_CYC` 拍出一个字节；末字节之后下一拍拉低。`rx_ready` 类背压来自对端 `rx_ready`（网络侧接收能力）时，在字节边界暂停并保持包络。FCS 由 `crc32_check` 在发送链路上按字节累加，末字节后附加 4 字节（注意反射：附加顺序为 CRC[31:24] 逐字节，实现按 §8.1 的反射域直接输出寄存器值小端序，与 802.3 一致）。

资源：FIFO 32×8 ×2 + 节拍计数器 + CRC 寄存器，估 0.5K LUT。

### 7.7 `mac_rx_if`

功能：从字节流恢复帧，写入 PMEM，生成描述符；打时间戳；统计帧长。

| 信号 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `rx_data` / `rx_valid` / `rx_ready` | in | 8/1/1 | 来自 MAC |
| `pmem_wr_en` / `pmem_wr_addr` / `pmem_wr_data` | out | 1/16/8 | |
| `desc_vld` | out | 1 | 一帧结束 |
| `desc_ptr` / `desc_len` / `desc_ts` | out | 10/11/24 | 块号、字节数、`tb_us[23:0]` |
| `err_cnt` | out | 32 | 非法帧头（valid 未在包络内等）计数 |

行为：检测 `rx_ready` 上升沿开帧 → 取一个空闲 2 KB 块 → 每字节写 PMEM 并 `len++` → `rx_ready` 下降沿或 `len==1518` 关帧，产生描述符进 4 深描述符 FIFO。若 `rx_ready` 在帧中撤销，该帧标记 `desc_truncated` 并丢弃；若 `len>1518` 立即丢弃并计数（超长帧防御）。PMEM 块回收由下游（`rx_port_buf` 写完后）释放。

带宽：12.5 MB/s @100 MHz，1 字节/拍写入能力足够。资源：写地址生成 + FIFO，估 0.4K LUT。

验证要点：T08（截断帧、超长帧）；`desc_ts` 与 TB 注入时刻一致（T16 依赖它）。

### 7.8 `rx_flt`

功能：帧头与合法性初筛，给 `rx_vl_lookup` 交 VLID。

流水线（每帧固定 8 拍，与帧长无关，仅 CRC 模式例外）：

| 阶段 | 动作 |
|---|---|
| S1 | 从 PMEM 读 DMAC+SMAC+Type（14 B，14 拍）；查 `DMAC[31:0]==32'h0300_0000`、`Type==16'h0800`；`len` 在 [64−4, 1518] 内；`len ≤ Lmax[vl]`（Lmax 在 S2 才知，故本检查放 S3） |
| S2 | 读 IP 头前 20 字节首 4 字节：`version==4`、`IHL==5`、`protocol==17`、`total_len == len−14−4(FCS)`；抽 `dst_ip`、`src_ip` 备用 |
| S3 | 拿 `rx_vl_lookup` 结果，查 `Lmax`；提取 VLID（DMAC[15:0]） |
| S4 | `FCS_MODE≥1` 时 CRC32 按拍推进，末 4 字节比较 |

`FCS_MODE≥1` 时 CRC 校验需要读完整个帧（最多 1518 拍，12.1 μs），与后续判决并行：模块在 S3 后就把描述符放行，CRC 结果以"迟到标记"方式写回描述符；若 CRC 错且该帧已被端口接受，则撤销（置 `crc_late_drop` 并回收 PMEM 块）。

这是一个明确的设计折中，理由：把 CRC 放进判决链会引入帧长相关延迟，破坏"判决链恒定 20 拍"的性质（§3.3），影响 T17。代价是极少数错误帧可能已交给主机又被撤销，因此把撤销做成"丢弃 + 计数 + 中断错误位"，并在设计文档写明：若应用不允许迟到撤销，把 `FCS_MODE` 设为 0 并把 CRC 检查交给外部 MAC。**默认配置取 `FCS_MODE=1` 且允许撤销**，理由是本赛题无真实 MAC、错误注入全部由 TB 控制，撤销不会造成不可恢复后果；同时提供 `FCS_LATE_DROP_DIS` 开关供配置成严格模式（严格模式下判决链延迟 = 帧长，T17 指标单列）。这个开关在 T08/T17 都要跑一遍，两条数据都进测试报告。

资源：14 字节头 + 20 字节 IP 头的读取器、常量比较器、CRC32 引擎，估 1.2K LUT，不另占 RAM（读的就是 PMEM）。

### 7.9 `rx_vl_lookup`

功能：`VLID[15:0]` → `vl_idx[11:0]`。

哈希函数（12 位桶号 + 1 位 way）：

```
slot = vlid[11:0] ^ {vlid[15:12], vlid[11:8]} ^ HASH_SEED;   // 12 bit
way  = vlid[12];                                             // 1 bit
```

表项：`RX_HASH[slot] = {way1, way0}`，每个 way 是 `{valid, vlid[15:0], idx[11:0]}`（29 bit），一次读 64 bit（低 58 bit 有效）拿到两 way；共 4096 槽、每槽两 way 各占一个 32 bit 字（有效位 29 bit + 3 bit 填充），8192 × 32 = 256 Kbit、15 个 18 Kbit 块（§9）。比较与选择在 1 拍内完成，查找合计 2 拍：命中给 `idx`，未命中置 `flt_miss`。运行期表只读，综合时可让工具推成 ROM 模式。

配置期种子搜索（`sw/golden/hash_seed.py`）。下面两个数是实测得到的，不是估的：脚本对给定 VLID 集合遍历 `HASH_SEED`（抽样 16 个种子取最优），统计冲突槽数与最长链。

· VLID 连号（0..4095，仿真与常见配置）：该折叠式恰好是双射，冲突槽 0，一次命中；
· VLID 随机（4096 个随机 16 位值）：约 350 个槽两 way 占满仍有新键落入，最长链实测到 6。

所以运行时不能赌概率，探测要做实：`rx_vl_lookup` 固定 3 级串行读（`slot`、`slot+1`、`slot+2`，2 拍/级，最坏 6 拍，仍远小于 512 拍的最小帧间隔），三级都不中才判 `flt_miss` 并把该 VLID 记入 `CFG_ERR`；`hash_seed.py` 的职责是把最长链压到 3 以内，做不到就报错要求把 `RX_HASH_SLOTS` 加倍（4096 槽 → 8192 槽（16384 个 32 bit 字 = 512 Kbit、30 块，多占 15 块））。配置表必须由脚本生成、不允许手写，这条写进使用约束。

资源：15 个 18 Kbit 块、600 LUT（3 级探测只多两个比较器和一个循环计数）。

### 7.10 `rx_ic`

功能：每网每 VL 独立 PSN 判决与回写。

| 信号 | 方向 | 说明 |
|---|---|---|
| `in_vld`/`in_ptr`/`in_vl`/`in_sn`/`in_net` | in | 来自 `rx_flt` |
| `out_vld`/`out_accept`/`out_reason` | out | 判决结果 |
| `dbg_wr`/`dbg_vl`/`dbg_net`/`dbg_psn` | in | 调试强制（`DEBUG_EN`） |

算法（`psn` 为该网该 VL 的上一正确 SN，复位为 0）：

```
if (sn == 0)            accept=1, new_psn=0,      reason=SN_RESET      // 复位判决
else if (psn == 0)      accept=(sn==1), new_psn=1 // 首帧判决：只接受 1
else begin
    exp1 = (psn==255)?1:psn+1;  exp2 = (psn>=254)?psn-253:psn+2;
    if (sn==exp1)       accept=1, new_psn=sn,     reason=OK
    else if (sn==exp2)  accept=1, new_psn=sn,     reason=LOST_ONE
    else                accept=0, new_psn=psn,    reason=OUT_OF_ORDER  // 含重复与前跳>1
end
```

A664P7 允许接受"丢失 1 帧"（`exp2`），丢失 ≥2 帧一律丢弃——这条判决必须与 Python 模型逐位一致，T09 就是它。`psn==0` 的首帧判决按"只接受 SN=1"实现（严格），同时提供 `UDP_CFG.IC_FIRST_ANY`（`0x0070` 位 0，=1 时接受任意首帧），两个配置各跑一遍回归并在报告里说明差异；默认严格，理由：容错首帧会掩盖配置错误。

存储：`psn` 表 8192×8 bit = 64 Kbit，4 个 18 Kbit 块；A 网占低 4096 项、B 网占高 4096 项，判决是「读—判决—写回」错拍的半双工节奏，单口够用。流程 4 拍：R(1)→cmp(1)→W(1)→out(1)，帧间不重叠（最小帧间隔 512 拍）。

资源：4 个 18 Kbit 块，900 LUT。

### 7.11 `rx_rm`

功能：双网去重。

| 信号 | 方向 | 说明 |
|---|---|---|
| `in_*` | in | 单网判决后的描述符（A、B 两个入口） |
| `out_*` | out | 转发给 `rx_ip_udp_parse` |
| `drop_dup` / `drop_skew` | out | 事件脉冲 |

状态（每 VL）：`last_ts[23:0]` 与 `last_sn[7:0]` 打包成一个 32 bit 表项，8 个 18 Kbit 块（4096 项，§9）。`pending`（另一网有一帧压在等待队列里）是 4096 bit 位图寄存器，不进 BRAM——两侧判决每拍都要读它，放 RAM 会把判决链从 4 拍拖到 8 拍。

算法：

```
ts = in_ts;
if (!rm_en[vl])           forward;                       // 单网 VL 或 RM 关闭
else if (sn == last_sn[vl]) begin
    if ((ts - last_ts[vl]) <= skewmax) drop_dup;          // 重复副本
    else forward;                                        // 超 SkewMax 视为新帧（异常）
end else                  forward;
// forward 时：last_sn=sn; last_ts=ts
```

两网并行输入的处理：A、B 各有 2 深度等待队列（只放描述符，帧体仍在 PMEM）。仲裁按 `in_ts` 先到先服务，同拍到达时 A 优先并把 B 的 `ts` 视为 +1。等待队列的意义在于避免"两网同时到、都判 forward、端口写两遍"：仲裁后 B 在判决时已能看到 A 更新的 `last_sn`，因此会正确 `drop_dup`。这是本模块唯一的微妙点，T10 用 0 时差同拍到达专门验证。

SkewMax：编码 `4<<skewmax_exp`，`skewmax_exp ∈ [0,15]` ⇒ 4 μs ~ 131 ms，默认档 `exp=5`（128 μs）。注意 SkewMax 必须大于"帧长差 + 链路偏斜"，否则合法副本会被误判为新帧；判决用的时间戳统一取帧首字节到达时刻（A664P7 对 skew 的定义即基于帧首/帧尾的边界约定，取帧首后两网帧长不同也对称可算），因此下界为 `(Lmax_A + Lmax_B) × 80 ns` 折算的 μs 加上链路偏斜估计；配置脚本算一遍并给提示，硬件只在 `skewmax < 4` 时置 `CFG_ERR`。

资源：8 个 18 Kbit 块（状态）+ 4 深描述符 FIFO + 比较器，1.1K LUT。

### 7.12 `rx_ip_udp_parse`

功能：IP/UDP 校验与端口查找，产出 `{port_id, payload_off, payload_len}`。

| 阶段 | 动作 | 拍 |
|---|---|---|
| P1 | 读 IP 头 20 B：重算校验和、总长度一致性、DF/MF、protocol | 20 |
| P2 | 读 UDP 头 8 B：`length == L+9`（含 SN）、`dst_port` | 8 |
| P3 | 端口表查找（BRAM 直接映射，1 拍读 + 1 拍比较）；类型/`vl` 一致性检查（端口表里记 `expect_vl`） | 2 |
| P4 | UDP 校验和（`UDP_CSUM_MODE=1`）：从 `payload_off` 起累加到帧尾，1 字节/拍 | L+1 |
| P5 | 结果下发 `rx_port_buf` | 1 |

P4 与 P1~P3 并行（同一 PMEM 读口分时，优先级 P1>P4），因此帧长相关的总耗时 ≤ 1518 拍 = 12.1 μs，与 `rx_flt` 的 CRC 读并行不冲突（PMEM 有 2 读口：`bram_sdp` 真双口，读口 A 给 flt/parse 控制流，读口 B 给 CRC/校验和）。分片重组（P2）在 P1 后插入 `frag` 状态 RAM（4096 项 ×{src ip, id, offset}），本设计不展开。

错误分支：IP 校验和错 → `drop(ip_csum)`；UDP 长度与帧长不符 → `drop(len)`；端口未配置 → `drop(port)`；校验和不符 → `drop(udp_csum)`。全部独立计数。

### 7.13 `rx_port_buf`

功能：把通过判决的消息落到端口，维护新鲜度与中断。

- 采样端口：写 PMEM 顺序区，更新描述符 `{valid=1, fresh=1, ptr, len, ts=tb_us}`；若 `valid=1` 未读则覆盖并 `ovr_cnt`++。
- 队列端口：入队（消息描述符进 per-port 环，数据指针指向 PMEM 块），满则丢弃并 `q_ovf`++，并向对端不可见（AFDX 队列端口无流控反馈，符合规范）。
- SAP 端口：转交 `mgmt/`（写 `mgmt_rx_fifo`），不经主机。
- 中断：`host_irq = |（INT_ENABLE & INT_STATUS）`；`INT_STATUS` 位 = 新采样消息、队列非空、溢出、CRC 迟到撤销、判决丢弃突增（阈值 `DROP_IRQ_THRESH`）。
- 回收：主机读完整帧后 `buf_free[port]` 释放 PMEM 块（队列端口按条目）；未读满 32 块时 `pmem_exhaust` 置位，`mac_rx_if` 反压（拉低对端可见的 `rx_ready` 语义由 TB 处理：本端丢弃并计数，不阻塞线上）。

端口描述符表 256×32 bit（BRAM，1 块），读清 `fresh` 与 `valid`（寄存器阵列 shadow + 写回，避免"读后不知是否要清"的歧义，采用"读即清"）。

### 7.14 `host_if`

地址空间按 32 bit 字组织，`host_addr[15:0]` 是字地址，可寻址范围 64 K 字 = 256 KB。下表 14 行（含空洞外的全部区段）合计 53408 字 = 209 KB，占 81.5%，其中空洞 `0x0480~0x1D7F` 另计；剩下 `0xEC20~0xFFFF`（8128 字）留给 P2 与将来。下表按「项数 × 每项字数」连续排布（`0x0480`~`0x1D7F` 是故意留的空洞，放后来追加的表项；PMEM 起始自动 2 KB 对齐），`tools/check_addr.py` 会逐行复核容量声明并检查重叠：

| 区间（字地址） | 容量 | 内容 | 访问 |
|---|---|---|---|
| `0x0000`~`0x00FF` | 256 字（1 KB） | 全局寄存器：`ID`、`REV`、`CTL`、`STATUS`、`ERR`、`INT_*`、`DROP_CNT[0..11]`、`TB_CNT`、`CFG_SUM`、`CFG_ERR`、`SMAC_CFG`、`IP_CFG`、`UDP_CFG`、`BURST_*`、`DBG_CTRL` | R/W |
| `0x0100`~`0x01FF` | 256 字（1 KB） | 全局统计：帧/字节/丢弃计数、抖动最大/均值、前 8 VL 直方图 | R / W1C |
| `0x0200`~`0x047F` | 640 字（2.5 KB） | TX VL 表：128 项 × 5 字（附录 B 的 w0~w4 静态配置；动态三项不在这张表里，见附录 B 说明） | R/W（`CFG_MODE=1`） |
| `0x1D80`~`0x3D7F` | 8192 字（32 KB） | RX VL 配置表：4096 项 × 2 字 | R/W（`CFG_MODE=1`） |
| `0x3D80`~`0x7D7F` | 16384 字（64 KB） | RX 哈希表：4096 槽 × 2 way = 8192 表项，每 way 1 字：`{valid, vlid[15:0], idx[11:0]}` + 3 bit 填充（地址 = 槽基址 + way×4096） | W（`CFG_MODE=1`） |
| `0x7D80`~`0x817F` | 1024 字（4 KB） | 端口表：256 项 × 4 字 | R/W（`CFG_MODE=1`） |
| `0x8180`~`0x827F` | 256 字（1 KB） | 端口描述符：256 项 × 1 字 | R |
| `0x8280`~`0x857F` | 768 字（3 KB） | 端口消息操作：`MSG_WR[256]`、`MSG_RD[256]`、`MSG_CNT[256]` | R/W |
| `0x8800`~`0xA7FF` | 8192 字（32 KB） | PMEM：32 KB = 16 块 × 2 KB（TX 6 / RX 6 / 公共 4），块基址 = PMEM 行起始 + blk×0x400 | R/W（数据段仅 `mac_rx_if` 与主机可写） |
| `0xA800`~`0xA80F` | 16 字（64 B） | IC/RM 状态窗口：`DBG_SEL`（页 + 项偏移）/ `DBG_RDATA` / `DBG_WDATA` | R / W（`DEBUG_EN`） |
| `0xA810`~`0xAC0F` | 1024 字（4 KB） | 每 VL 统计：128 项 × 8 字 | R |
| `0xAC10`~`0xAC1F` | 16 字（64 B） | 管理面窗口：`MGMT_SEL` / `MGMT_WIN`，RTC、SNMP、TFTP 的寄存器映射在窗口内 | R/W |
| `0xAC20`~`0xCC1F` | 8192 字（32 KB） | 保留：IP 分片表（P2）、子 VL 表（P2） | — |
| `0xCC20`~`0xEC1F` | 8192 字（32 KB） | TFTP 加载区：32 KB，`a615a_tftp` 独占 | R/W |

两条约束：加载区紧跟保留区放在 `0xCC20`，与 PMEM 同处地址高位，译码只看高 4 位；IC/RM 状态不单独占 8 页地址，改成 `DBG_SEL`/`DBG_WIN` 窗口，省下的地址留给 P2。PMEM 起始由 `tools/fix_addr.py` 自动 2 KB 对齐，`tools/check_addr.py` 每次重排后复核容量与重叠。

未列出的地址返回 `host_rdata=32'hDEAD_BEEF` 并置 `ERR.ACC`；所有 W-only/R-only 违规访问同样置 `ERR.ACC`。表写入时同步做约束检查：`UDP 目的端口` 与 SAP 冲突、`Lmax < 64`、`Lmax > 1518`、`BAG=0`、`skewmax=0` 都置 `ERR` 位并回读确认。

**`CTL` / `STATUS` / `ERR`（`0x0008` / `0x000C` / `0x0010`）**：逐位定义见附录 A.1~A.3，那张表与 `doc/regs.yaml` 同源、由 `tools/gen_regs.py` 生成，本节不再抄一遍——上一版这里抄了一份 CTL 位表，结果 §7.14 与附录 A 两处各改各的，`STATUS` 的 `OVF_CNT_MAX` 一度写成 `[11:12]` 而没人发现。设计要点只有三条：`CFG_MODE`（bit13）是写配置表的唯一入口，运行中必须为 0；`DEBUG_EN`（bit15）放开 IC/RM 状态的强制写（T09/T10 注错）；`RTC_HOLD`（bit11）冻结时基，让判决链与统计停在可观察的一拍上。`STATUS.PMEM_FREE` 只给 6 bit 是因为块数上限 16；`ALIVE`（bit31）每 2^24 拍翻转供 SNMP `sysUpTime` 与健康检查。

寄存器位域详表见附录 A（本文档只列设计意图，逐位定义以附录 A 为准，两者由脚本从同一 YAML 生成，避免漂移）。

### 7.15 `rtc_sync`

功能：维护全局时基并实现与主时钟的同步。

- `timebase` 产生 `tick_us`（`CLK_FREQ_HZ/1e6` 分频；`TICK_US` 用于仿真缩放）。RTC 计数器 `rtc64[63:0]`（μs）+ 分数累加器 `frac[15:0]`：每拍 `frac += FREQ_ADJ`，溢出则 `rtc64++`。`FREQ_ADJ` 初值 = `2^16 × (100e6/CLK_FREQ_HZ)` 的整数化，提供 ±200 ppm 微调（16 bit，中心值 + 偏移）。
- 同步报文：专用 VL（`SYNC_VL`）的采样端口，报文 32 B = `{tag 0x41464458 "AFDX", master_ts[63:0], seq, flags, reserved}`。硬件在帧首字节到达时锁存 `tb_us`（`t1`）与 SN（`seq`），主时钟时间戳记为 `t0`，偏差 `d = t0 − t1 − est_path`。`est_path` 用 `RTC_PATH_EST` 配置（ES 侧固定延迟补偿，数值取自 T13 端到端回环实测的接收链延迟，与综合无关）。
- 收敛：`|d| > TH_JUMP`（默认 50 μs）则当拍直接跳变（不进入平滑）；否则 `rtc64 -= d >> LOG2_AVG`（默认 `LOG2_AVG=6`，即按 64 帧平滑，等效一阶低通）；同时用 `d` 的滑动平均调节 `FREQ_ADJ`（比例系数 `Kp=64`、积分系数 `Ki=4096`，均为配置寄存器，整数定点实现，不使用浮点）。
- 输出：`rtc_time_us`、`pps_out`（`rtc64[0]==0 && rtc64_prev[0]==1` 时拉高一拍）；`SYNC_LOSS` 在连续 `SYNC_TIMEOUT`（默认 4 个 BAG）无报文时置位，置位后停止平滑只保留自由运行。

仿真精度目标：稳定后 `|d| ≤ 1 μs`（时基分辨率即为 1 μs，因此该指标的含义是"不出现 ±1 以上的持续偏差"，不宣称亚 μs）。要提精度需把 `timebase` 提到 ns，代价是 24 bit 窗口不够用（ns 时戳需 34 bit），P2 可选。

### 7.16 `snmp_lite`

功能：SAP 端口收 SNMP 请求，解析 GET/GETNEXT/SET，查 MIB，组响应。

支持的 PDU：`get-request(0xA0)`、`get-next-request(0xA1)`、`set-request(0xA3)`、`response(0xA2)`；版本只认 v1(0)/v2c(1)，其余 `version-not-in-version-list`（v1 下回 `genErr`）。不支持 trap/inform/GETBULK。

BER 解析为单遍状态机（最大 VarBind 数 8，超范围回 `tooBig`/`genErr`）：`SEQUENCE` → `INTEGER(version)` → `OCTET STRING(community)`（与 `SNMP_COMMUNITY` 寄存器比较，长度 ≤16，不符回 silently discard）→ `PDU`：`INTEGER(req-id)`、`INTEGER(err-status)`、`INTEGER(err-index)`、`SEQUENCE(VarBindList)`：每项 `OID` + `NULL`(GET/GETNEXT) 或 类型值(SET)。

MIB 表：`mib_rom`（128 项 × 32 bit）+ 4 个可读可写对象。

| OID（前缀 `1.3.6.1.4.1.4444.1.1`） | 名称 | 访问 | 实现 |
|---|---|---|---|
| .1.0 | `afdxEsDescr` | RO OCTET STRING(16) | 常量 `"AFDX-ES eLinx v1"` |
| .2.0 | `afdxEsUpTime` | RO Counter32 | `rtc64[63:32]`（1/100 s 换算后 ×100） |
| .3.0 | `afdxNumTxVl` | RO INTEGER | 参数 |
| .4.0 | `afdxNumRxVl` | RO INTEGER | 参数 |
| .5.0 | `afdxVlBag` | RW INTEGER（索引 vl） | 写需 `CFG_MODE=1` |
| .6.0 | `afdxVlLmax` | RO INTEGER（索引 vl） | 表读 |
| .7.0 | `afdxVlTxFrameCnt` | RO Counter32 | 统计 RAM |
| .8.0 | `afdxVlRxAcceptCnt` | RO Counter32 | 统计 RAM |
| .9.0 | `afdxVlDropCnt` | RO Counter32 | 统计 RAM（各原因合计） |
| .10.0 | `afdxEsRxMaxJitterUs` | RO INTEGER | `STATS` 高水位 |
| .11.0 | `afdxEsCtl` | RW INTEGER | 映射 `CTL` 低 16 位 |
| .12.0 | `afdxEsDropCnt` | RO Counter32 | `DROP_CNT` 合计 |
| .13.0 | `afdxEsBufUtil` | RO Gauge32 | `PMEM_FREE` 反算百分比 |

GETNEXT 语义：在已排序的 OID 列表中查第一个大于目标项（列表按索引展开，`vl` 维度在 MIB 中按 `idx = vl*2` 方式线性编码，实现用二分，log2(128)=7 拍）。GET 不存在的 OID 回 `noSuchName`（v1）；SET 到 RO 回 `readOnly`，类型/范围不符回 `badValue`（`error-index` = 该项下标）。响应封装为 `SEQUENCE{version, community, {request-id, 0, 0, VarBindList}}`。

响应发送：调用 builder 注入通道，目的 IP/端口从请求报文的源地址反转（`snmp_peer_ip`/`snmp_peer_port` 记录最近一次合法请求）。

资源：状态机 + BER 编码器 + MIB ROM，估 2.4K LUT + 1 BRAM（MIB ROM 64×32 用 LUTRAM）。响应一帧最坏 300 字节 = 24 μs 线上时间，SNMP 会话吞吐足够（10 分钟更新周期，或压力测试 T14 用背靠背请求测冲突处理）。

### 7.17 `a615a_tftp`

TFTP（RFC 1350，无选项扩展为 P2）：

| opcode | 方向 | 本端动作 |
|---|---|---|
| 1 RRQ / 2 WRQ | 收 | 校验文件名（`"UPLOAD"`/`"DATASET_001"` 白名单，`TFTP_TIMEOUT` 默认 5 s）、源端口记为 TID；回 OACK(6)（若协商 blksize/timeout）或首 ACK(4) |
| 3 DATA | 收 | 校验块号（`expected`，0~65535 回绕），写目标区（`TFTP_DEST_BASE=0xCC20`，即加载区首地址，PMEM 块池之外的独立 32 KB RAM），回 ACK |
| 4 ACK | 发方向 | 块号匹配则发下一块 |
| 5 ERROR | 收 | 状态机复位，`TFTP_ERR_CODE` 记录 |
| 6 OACK / 7 ACK-with-opt | 双向 | blksize 支持 512/1024（≤1456 B 帧载荷限制），timeout 2~10 s |

块号回绕、重复包（同块号重传）按"回 ACK 不重复写"处理；超时重传计数 `RETRY_MAX`（默认 3）超限回 ERROR(4)。

615A 精简流程（`a615a_sm`）：

```
IDLE --Find 0x0001--> FIND_RSP(0x0002) --> [Upload 0x0031] --> UPLOAD_RSP(0x0032)
     --> [DataReq 0x0033] --> 通过 TFTP 收数据 --> 写加载区
     --> [StatusFile 上传 0x0012] --> [Done 0x0037] --> IDLE
```

报文头 8 B：`msg_id(2) + length(2) + type(1) + subtype(1) + sequence(2)`；消息类型：`0x11`=管理/上传，`0x13`=数据。加载区写入后由 `host_if` 的 `LOADED_OK` 位通知主机（或 BFM）"假装执行加载"，仿真里用 CRC32 比对源文件与加载区内容作为验收。

资源：ROM 消息表 + 32 KB 加载区 BRAM + 状态机，估 1.6K LUT + 15 个 18 Kbit 块（加载区 32 KB，见 §9）。

### 7.18 `stats_regs`

事件脉冲（单拍）到寄存器的累加：`vl_stats` RAM（128 项 × 64 bit：`tx_cnt[16]`、`rx_accept[20]`、`rx_drop[20]`、`max_jit[8]`）读改写会阻塞，因此先入 4 深事件 FIFO，由空闲拍串行回写（统计允许 2 帧滞后，文档注明）。全局 32 bit 计数器直接寄存器累加，`max/mean` 抖动高水位用组合比较更新。

丢弃原因位宽 12 位：`len, dmac, ethtype, ip_ver, ip_csum, udp_len, udp_csum, crc, unconf, lmax, ic, rm`；每类一个 32 bit 计数器 + 1 个合计。

### 7.19 公共模块

| 模块 | 实现 |
|---|---|
| `timebase` | 分频 + `TICK_US` 缩放；输出 `tick_us`、`tb_us[23:0]`、`tb_us_full[63:0]` |
| `crc32_check` | 反射 CRC32，按字节 8 级 XOR 展开（不查表），1 拍/字节；发送与接收共用一个引擎（时分复用，见 §8.1） |
| `ip_checksum` / `udp_checksum` | 32 bit 反码累加器 + 折叠单元，1 字（16 bit）/拍 |
| `sync_fifo` | 自研格雷码跨深 FIFO 不需要（单时钟域），故只做同步 FIFO + `afull`，eLinx IP 通过 `bram_sdp` 同层替换 |
| `rr_arbiter` | 参数化 N 路，`last_grant` 屏蔽 + 双优先级编码器 |
| `bram_sdp` | 简单双口 BRAM 封装：`eLinx BRAM IP`（综合）/ 行为模型（仿真），用 `ifdef ELINX_SYNTH` 选择 |

---

## 8 关键算法与实现细节

### 8.1 CRC32 按字节展开

不查表（表需 256×32 ROM，BRAM 留给状态表），把每个输入字节对 CRC 的贡献写成 XOR 树：

```
crc_next[31:0] = crc[31:0] >> 8
               ^ XOR_{j=0..7} ( (byte[j] ^ crc[j]) ? POLY_SHIFT[k] : 0 )
```

`POLY_SHIFT[k]`（k=0..7）是常数矩阵，代码里直接展开成 `assign`（由 `sw/gen/crc_gen.py` 生成 40 行，不手写，避免抄错）。生成脚本随仓库提交，`tools/selftest_crc.py` 用 1000 组随机数据把生成的 Verilog 常数与 Python `zlib.crc32` 对齐（这一步是真跑过的检查，纳入回归 `T00`）。

### 8.2 时间回绕与抖动上界

所有判决用 24 bit μs（周期 16.78 s），比较一律 `(a - b) < 2^23`（模减），不使用绝对大小比较。BAG 最大 128 ms，SkewMax 最大 255 μs，`max_jit` 最大 25.5 ms，均在窗口内。

抖动上界推导（写进文档，答辩必问）：调度器每周期至多构建 1 帧，帧占用线上时间 `T(F) = F × 80 ns`。若 VL i 与其他 VL 在同一时刻到期，其等待时间 ≤ Σ_{j≠i} T(F_j,max)。配置合法性要求（A664P7）：

```
Σ_j (20 + Lmax_j + 4) × 8 / BAG_j  ≤  100 Mbps
```

硬件实现为 `CFG_SUM`：每条 VL 存 `ceil((Lmax_j+24) × 80 ns / BAG_j)`，即该 VL 占链路的比例，Q20 定点；求和后与 `20_000`（Q20 下 1.0 = 满负荷 100 Mbps）比较，超出置 `ERR.BAG_OVF` 并在 `STATUS` 反映。同一式子由 `tools/bag_budget.py` 用浮点独立复核，硬件取整只会偏保守，不会放过配置。在该约束成立时，任一 VL 的单次等待上界 ≤ 该 VL 自身的最大帧时间（因为它在一个 BAG 窗口内最多被其他 VL 占用的字节数受配置和限制），即

```
jit_max ≤ T(Lmax_i) + T_sched_overhead ≤ (Lmax_i+24) × 80 ns + 0.2 μs
```

两组测试用例由 `tools/bag_budget.py` 现算，不手填：

```
T05a 轻载回归组   32 VL / Lmax=256 B（帧 280 B = Lmax+24）/ BAG=8 ms
                  ⇒ 8.96 Mbps，链路占用 8.96%，CFG_SUM=93 952/2^20，单帧 22.4 μs，判决：合法（非饱和）
T05b 饱和组       32 VL / Lmax=256 B（帧 280 B）/ BAG=718 μs
                  ⇒ 99.83 Mbps，链路占用 99.83%，CFG_SUM=1 046 824/2^20，单帧 22.4 μs，判决：合法
T05c 超载判定组   128 VL / Lmax=1471 B（帧 1 495 B）/ BAG=8 ms
                  ⇒ 191.36 Mbps 的需求，链路占用 1.9136 倍，CFG_SUM=2 006 555/2^20，判决：超限→ERR.BAG_OVF
```

上一版这里写的是「32 条 VL、BAG=8 ms、Lmax=256 B ⇒ 99.84 Mbps」，把每帧 22.4 μs 的链路占用当成饱和流量了：按自己的判决式算，这组配置只占 8.96%，差 11.1 倍；相应地，「抖动 22.4 μs」在这组里根本测不出来（每条 VL 每 8 ms 只有一帧，链路空着，抖动是亚微秒级）。所以抖动指标必须挂在 T05b 上做：链路占用接近 1 时，某条 VL 的单次等待上界 ≤ 一条前序帧的线上时间，即 22.4 μs，实测目标 ≤ 30 μs。注意这个上界只在占用≈1 时成立，它是排队论意义上的「队尾恰好挡一帧」，不是对任意配置的保证——`jit_max ≤ T(Lmax_i)+0.2 μs` 那一行的前提就是它。T05c 才是用来证明判决有效的：它要求 191.36 Mbps，是线速的 1.91 倍，而且构建器在 1 B/拍的口径下最多只能供到 12.5 MB/s（=100 Mbps），所以判决必须先把这组配置挡在 `CFG_ERR` 之外；否则测到的「失败」是能力不够，而不是判决失效。调度器在判决关掉后仍要能跑 T05b，这条写进 T05 的判据。

### 8.3 时延预算（ES 自身）

| 环节 | 典型 | 最坏 |
|---|---|---|
| 主机写 → 描述符有效 | 2 拍 | 4 拍 |
| 调度判决 | 3 拍 | 3 级流水 + IFG 等待 ≤12 拍（builder 空闲）；builder 忙时等 `frame_done`，属排队而非判决延迟 |
| pass1（读 PMEM 算长度+校验和，1 B/拍） | L×8 拍 | 1471×8 拍 = 11 768 拍 = 117.7 μs |
| 首部回填 + SN | 8 拍 | 10 拍 |
| pass2 启动（含 IFG 等待） | 12 拍 | 96 拍 = 0.96 μs |
| **TX 合计（主机写完 → 线上首字节）** | **轻载小帧：2+3+（64−28）×8+10+12 = 349 拍 = 3.5 μs** | **满载最大帧：117.7 + 0.96 ≈ 118.7 μs（pass1 是串在发送前的）** |
| RX：包络结束 → 判决链 | 20 拍 = 0.2 μs | 0.2 μs（CRC 整帧读完的最坏 1518 拍 = 121.4 μs 与判决并行，只延迟 `ERR` 位，不延迟端口可读） |
| RX：端口写 + 中断置位 | 6 拍 | 30 拍（同拍冲突仲裁） |
| RX：`udp_csum` 累加（严格模式，与逐字节解析并行） | — | 1518 拍 = 15.2 μs（在帧尾后完成，不额外拉长判决链） |
| **RX 合计（末字节收完 → 端口可读）** | **0.4 μs** | 0.4 μs；若严格模式下 `udp_csum` 未完成而丢弃判决链需要它，则 ≤ 15.2 μs |

指标承诺按「轻载 + 典型帧」与「饱和 + 最大帧」两档给：轻载 TX 首字节 3.5 μs、RX 0.4 μs；饱和最大帧时 TX 首字节 118.7 μs（pass1 决定），RX 0.4 μs。加上线上传输（1518 B = 121.4 μs）与 TB 中 1 跳交换机模型（固定 10 μs）后，端到端轻载 ≤ 0.25 ms、饱和 ≤ 0.35 ms，远优于 1~2 ms。同时报告给出满载最坏值，说明"时延主要来自线速本身，不是 ES 逻辑"。这是把模糊的 1~2 ms 变成可测数据的关键手法。

### 8.4 反码和与两遍扫描

pass1 读 PMEM 时同时累加 UDP 反码和（含伪首部与 SN 位置预留 0），L 为奇数时末字节按高 8 位对齐补 0（RFC 768 规则），累加结果折叠成 16 位后取反写回 `hb[32]`；若结果为 0 则按规范改成 0xFFFF（0 表示无校验）。IP 头校验和只需 10 个 16 位项，在 `HDR_INIT` 内完成。

### 8.5 4096 项状态表与 BRAM 调度

所有 per-VL 状态放在"读 1 写 1"的简单双口 BRAM：`rx_vl_cfg`（4096 项 × 64 bit，即附录 C 的两个字）、`rx_hash`（8192 项 × 32 bit，两 way 各占一字、一次读 64 bit）、`psn`（8192×8）、`rm_state`（4096×32）。判决链每帧占用同一地址（先读后写），因此不需要旁路逻辑；但若相邻两帧属于同一 VL（最小帧背靠背），后一帧的读必须在写之后——判决链 4 拍 < 帧间隔 512 拍，天然满足，故**不加旁路**，在文档与断言中把"链长 < 最小帧间隔"作为前提条件写成 assertion（A8）。

### 8.6 PMEM 分配与回收

| 区域 | 范围 | 单位 | 管理 |
|---|---|---|---|
| TX 池 | `0x8800~0x9FFF` | 2 KB ×6 | 空闲链；管理面发送复用同池 |
| RX 池 | `0xA000~0xB7FF` | 2 KB ×6 | 空闲链；管理面接收在配置期固定占 1 块 |
| 公共池 | `0xB800~0xC7FF` | 2 KB ×4 | 任一池耗尽时借用，`pmem_borrow` 计数 |
| 加载区（TFTP） | 字地址 `0xCC20~0xEC1F` | 32 KB | `a615a_tftp` 独占，与 PMEM 池分离 |

写侧（RX 写入 + 主机写 TX）与读侧（builder、parse、主机读）各自仲裁；32 KB 由 16 个 16 Kbit×8 RAM 实例拼成，实例号 = 块号，所以写侧和读侧永远落在同一实例的两个口上，跨块不会互相抢口。

访问冲突的做法：每个 2 KB 实例只有一个写口一个读口，写侧（`mac_rx_if`、主机写 TX）与读侧（builder、`rx_ip_udp_parse`、主机读）各经一层 3 级优先仲裁后，按块号路由到自己那一侧的实例口。由于块号决定实例号，同一块上的读写天然落到一对端口、互不阻塞；只有两条写访问命中同一块（例如 RX 正在写某块、同时主机也往该块发数据）或两条读访问命中同一块时才会真冲突，此时后者延后一拍、写入 `pmem_conf` 计数器。满载 T17 就是专门把这一计数打到可见的压力用例，实测若长期 >1% 就说明块数不足，处理办法是把 `PMEM_KB` 翻倍（16→32 实例、+15 块）而不是加逻辑。

### 8.7 反压与丢弃策略

- 发送：任何情况下不违反 BAG；builder 忙则候选 VL 顺延（计入抖动，不丢消息）。消息不被丢弃（采样端口覆盖语义除外），队列端口满时拒写主机（不丢线上数据）。
- 接收：判决链不阻塞、不回头。任何丢弃都在描述符层面完成，PMEM 块立即回收。`pmem_exhaust` 时新帧直接丢弃并计数（不产生背压），因为 AFDX 端系统不向交换机反压（全双工、无流控）。

### 8.8 断言清单（`bind` 到各模块，仿真专用，`ifndef SYNTHESIS`）

| # | 断言 | 级别 |
|---|---|---|
| A1 | `tx_valid` 相邻两次有效之间间隔 == `BYTE_SLOT_CYC` | error |
| A2 | `tx_ready=0` 时 `tx_valid=0` | error |
| A3 | 帧长 ∈ [60, 1518]（DMAC 起算，不含 FCS） | error |
| A4 | SN ∈ [1,255]（`FCS_MODE≥1` 时按帧长偏移采样 SN 字段） | error |
| A5 | 同一 VL 的 `done` 间隔 ≥ BAG − 1 μs | error |
| A6 | PMEM 块不双重分配/双重释放 | fatal |
| A7 | `host_cs && !CFG_MODE && 写表区间` → 必须置 `ERR.ACC` | warning |
| A8 | `rx` 判决链占用拍数 ≤ 最小帧到达间隔 − 16 | error |
| A9 | `rx_rm` 对同一 `{vl, sn}` 不产生两次 `forward`（SkewMax 内） | error |
| A10 | `ic` 的 `new_psn` 单调（除 SN=0 复位） | error |
| A11 | 每帧 `drop` 事件必伴随 `DROP_CNT` 对应位 +1 | error |
| A12 | `FCS_MODE=1` 时发送帧末 4 字节 == 自算 CRC（TB 独立复算） | error |

A 系断言全部在回归里统计触发次数，任何非预期触发即 FAIL，比只看最终数据更容易定位。

---

## 9 存储开销预算

先说清这一章的定位：赛题不指定器件、不上板，因此不存在「占器件百分之几」这种指标。本章只回答一个问题——满配设计的结构性开销有多大、花在哪。数字按 `NUM_TX_VL=128`、`NUM_RX_VL=4096`、`NUM_PORTS=256`、`PMEM_KB=32` 计，块尺寸以通用的 18 Kbit 简单双口 RAM 为度量单位（只为方便比较规模，不代表任何具体器件的块结构）。这部分即使只做仿真也必须算：它决定 ModelSim 里 BRAM 行为模型的内存占用与初始化时间，也决定 `sw/golden` 生成配置表要花多久（满配各表数据量约 230 KB：RX 配置 32 KB + 哈希 64 KB + PMEM 初始化 32 KB + TX VL 表 2.5 KB + 端口表 4 KB，加上 `.mem` 文件里的地址与注释，见 §7.14）。

结论先放前面：满配（不含 P2）1.26 Mbit、79 个 18 Kbit 块；其中 4096 条接收 VL 的配置 + 哈希 + PSN/RM 状态占 704 Kbit，也就是 54%。这是「支持 4096 条接收 VL」这条要求的直接代价，而且和帧缓冲无关——吃存储的是状态表，不是数据。

| 用途 | 表 | 规模（项×位） | Kbit | 18Kbit 块 | 端口 / 实现 |
|---|---|---|---|---|---|
| 配置 | TX VL 表 | 128 × 160（附录 B 的 w0~w4） | 20 | 2 | 1 读 1 写：读口由调度器与构建器分时，写口仅 `CFG_MODE=1` 开放；w5~w7 是寄存器与 `VL_STATS`，不占这张表 |
| 配置 | RX VL 配置 | 4096 × 64（2 字） | 256 | 15 | 1 读 1 写 |
| 配置 | 端口表 | 256 × 128（4 字） | 32 | 2 | 1 读 1 写 |
| 配置 | IP 分片表（P2） | 4096 × 16 | 64 | 4 | `FRAG_EN=1` 才生成 |
| 查找 | RX 哈希 | 8192 × 32（4096 槽 × 2 way，低 29 bit 有效） | 256 | 15 | 运行期只读，可推成 ROM 模式，省掉写口开销 |
| 状态 | PSN（2 网） | 8192 × 8 | 64 | 4 | 半双工：读 1 拍、写回 1 拍错开，1 口即可 |
| 状态 | RM 状态 | 4096 × 32 | 128 | 8 | 同上，半双工 |
| 状态 | 子 VL 轮询指针（P2） | 128 × 16 | 2 | — | 寄存器，不占块（128 项各 16 bit） |
| 缓冲 | PMEM | 32 KB = 16×2 KB | 256 | 15 | 1 写（RX/主机）+ 1 读（builder/parse/主机） |
| 缓冲 | 端口描述符 | 256 × 32 | 8 | 1 | 1 读 1 写 |
| 统计 | vl_stats | 128 × 64 | 8 | 1 | 半双工，事件 FIFO 串行回写 |
| 统计 | 时间戳/抖动表 | 256 × 32 | 8 | 1 | 只给 8 条 VL（`DBG_SEL.vl = i[7:5]`）× 32 桶 = 256 项；缩到 8 VL × 8 桶 × 8 bit 后是 2 Kbit，受 `STATS_EN` 控制 |
| 加载 | TFTP 加载区 | 32 KB | 256 | 15 | 1 写 1 读 |
| **合计** | 不含 P2（11 行） | | **1.26 Mbit**（1292 Kbit） | **79** | 含 P2 两张表 1.33 Mbit / 83 块；每行 = 项 × 位 ÷ 1024，块数 = ⌈项 × 位 ÷ 18432⌉ |

口径说明（Kbit = 项 × 位 ÷ 1024，块数 = ⌈位 × 项 ÷ 18432⌉，每行都可复核）：TX VL 表里的 `next_tx`/`last_tx` 不占 BRAM，是 128×48 bit 寄存器阵列（128 路每拍并行读，RAM 做不到），6.1 Kbit 记在逻辑侧；PSN/RM/统计这类状态表因为「读—判决—写回」错拍，可按半双工单口计块；PMEM 32 KB 按 16 个 2 KB 实例实现，折算 18 Kbit 块是 15 块（最后一块只用 1/16）；若工具支持 16 Kbit 配置则刚好 16 块。

逻辑量（结构估算，与器件无关；全设计不用乘法器，DSP 需求为 0）：

| 分组 | LUT | FF | 备注 |
|---|---|---|---|
| 发送流水 | 4.9K | 3.1K | 调度器 2.2K 为主 |
| 接收流水 | 3.8K | 2.3K | |
| 主机接口 + 寄存器 | 1.5K | 1.4K | |
| 管理面 | 4.2K | 2.6K | snmp 2.4K 为主 |
| 公共/顶层/时钟复位 | 1.1K | 0.9K | |
| 合计 | **15.5K** | **10.3K** | 综合前的结构估算；若做了 §11 就换成报告实测值，没做则明确标注「未实测」 |

因此 P2 增强项取决于时间，不取决于片内容量：ns 级时基（+0.4K LUT，状态从 24 bit 加到 40 bit，PSN/RM/时间戳三张表加宽约 +22 块）、子 VL 轮询（128×8 寄存器，0 块）、IP 分片重组（+4 块、+1.2K LUT）、每 VL 抖动直方图全量（128×32×32 = 131 Kbit，+8 块）。

缩配档（按 D9 常备）：`NUM_RX_VL=1024`（RX 配置 64 K、哈希 2048 槽 × 2 way × 32 bit = 128 K、PSN 16 K、RM 状态 32 K）、`PMEM_KB=16`、加载区 16 KB、`STATS_EN=0`，存储 0.54 Mbit / 36 块，约为满配的 43%，回归时间约快 2.5~3 倍。若满配仿真跑不动或综合不过，直接切这一档出指标，两套数据并列写进测试报告，并注明哪些数字随 `NUM_RX_VL` 线性变化、哪些不受影响。

---

## 10 代码与工程规范

目录结构：

```
afdx-es/
├── rtl/{top,tx,rx,mgmt,common}/          # 全部 Verilog-2001，可综合
├── sim/{tb,bfm,chk}/                       # ModelSim：顶层 TB、BFM、断言/覆盖
├── sw/{golden,gen,report}/                 # Python：黄金模型、常数生成、报告绘图
├── elinx/{prj,sdc,ip}/                     # eLinx 工程与约束（可选综合自证）
├── doc/{design,test_report,regs.yaml}      # 本文档、测试报告、寄存器单一来源
└── tools/{lint.sh,gen_regs.py,fix_addr.py,check_addr.py,check_s9_final.py,verify_all.py}
```

命名与书写：

- 信号、端口、实例小写下划线；参数大写下划线；宏 `AFDX_` 前缀；常量 `localparam`。
- 每模块文件头注释块：功能、作者、时钟复位域、握手协议、依赖表项（哪些寄存器位域被本模块读写）、已知限制。这一段是给评审查代码用的，按 10 行写足。
- 状态机三段式（状态寄存器 / 次态组合 / 输出寄存），状态名 `ST_*`；每个状态注释"进入条件、退出条件、异常出口"。
- 禁止 latch（综合选项开 warning 当 error）；组合逻辑内不用 `always @(*)` 之外的敏感表；`case` 必带 `default`。
- 复位：仅 `rst_sync` 允许出现在 `always` 的 if 条件里；BRAM 内容不复位，靠 `valid`。
- 一个 always 一个功能，不跨模块共享寄存器；模块间只用 `vld/rdy` 或 `pulse` 两种握手，不许有"猜对方什么时候采样"的隐式约定（评审最容易挑的刺）。
- 数值：位宽显式（`8'd255`）、大数用 `100_000_000`；禁止裸 magic number，一律 `localparam` 并在注释写来源条款。

质量门（每次合主干必须过）：

```
tools/lint.sh      # Verilator --lint-only -Wall + 自研规则脚本（注释覆盖率、端口表完整、前缀规范）
sim/regress.tcl    # 全量回归（缩配）
python3 tools/gen_regs.py --emit   # doc/regs.yaml → doc/regs_pkg.svh + 附录 A 表格，并反向核对（默认无参即只校验）
python3 tools/verify_all.py   # 全文一致性与机器可查的口径检查（章节、表格、地址、规模、路径）
```

版本策略：`main` 只接受带回归通过标签的合并；第 6 周起 `frozen` 分支（11-01），只修 bug，P2 增强留在 `enhance`，重跑全量回归才允许替换提交包。

---

## 11 综合与时序自证（可选）

定位：指南「测评标准」四项里没有资源占用，也没有上板要求，本选题不给器件，所以综合不是交付必需项。做它只有两个理由：一是证明这套 RTL 确实可综合（无 latch、无非法结构、表项能映射进片内 RAM），二是为「满配 4096 VL 在 100 MHz 下跑得动」提供旁证。排在第 5 周、P1 之后，时间紧张时整段跳过，不影响其它指标；文档与报告里也不写「占器件 X%」这类无从验证的话。

### 11.1 流程

顶层 `AFDX_top`，器件用 eLinx 安装自带的默认工程（题目未指定，不为此改设计，也不在文档里写死型号）。命令以工具自带示例为准，统一封装在 `elinx/run.tcl`，跑 `elaborate → synthesize → STA`，输出 `rpt/area.rpt`、`rpt/timing.rpt`；是否再走布局布线看时间，只做到综合也足以达到自证目的。

### 11.2 SDC

```tcl
create_clock -name clk -period 10.000 [get_ports clk]
set_clock_uncertainty 0.45 [get_clocks clk]
set_clock_transition   0.30 [get_clocks clk]
set_input_delay  -clock clk -max 3.2 [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay -clock clk -max 3.2 -min 0.5 [all_outputs]
set_false_path -from [get_ports pps_in]
set_max_fanout 32 [current_design]
group_path -name rx_chain -weight 2 -from [get_pins mac_rx_if/*] -to [get_pins rx_port_buf/*]
group_path -name tx_pace  -weight 2 -to [get_pins mac_tx_if/tx_valid]
report_timing -delay_type max -max_paths 20 > rpt/timing.rpt
```

无板卡 ⇒ IO 时序不参与评分：`set_input_delay`/`set_output_delay` 只在模板里留注释、默认注掉（不写这两条不会漏掉功能问题，只会让工具按内部路径判）。`set_false_path` 只留给 `pps_in`。若后续真要求映射，再按「片内 MAC 相邻、3.2 ns」补上，功能逻辑一行不动。

### 11.3 关键路径与对策

| 路径 | 预估 | 对策 |
|---|---|---|
| 调度器 128 路 `min` 归约 → 优先级编码 | 7.8 ns | 已 3 级流水（§7.2）；若仍紧，把组内 16→8 个一组，多加一级 |
| `rx_ic` 读表 → 判决 → 写表 | 6.9 ns | 判决只用 8 bit 比较 + 2 个加 1，链长 4 拍天然有 8 拍余量，必要时插拍 |
| PMEM 读口仲裁 mux → builder 字节输出 | 7.4 ns | 仲裁结果提前 1 拍寄存（描述符决定地址，无需当拍算） |
| CRC32 XOR 树（8 级） | 6.5 ns | 拆两拍：`crc_mid` 寄存（每字节本就有 8 拍空闲） |
| SNMP BER 解析的组合链 | 8.1 ns | 解析器改为 1 字节/拍的显式状态机（当前设计如此），把 OID 比较放 2 拍 |

100 MHz（10 ns）属低频，风险主要在互连而非逻辑级数，因此一律用"每字节 8 拍"的空闲拍插寄存，不改变任何对外时序。上表「预估」列是综合前的设计预算：v1.0 前若做了 §11.1 就替换成 `rpt/timing.rpt` 实测数据，没做则保留预算值并在表头写明「未实测」。不许拿估算冒充实测。

### 11.4 面积优化选项

`STATS_EN=0` 省 1 个 18 Kbit 块 + 0.9K LUT；`SCHED_MIN_EN=0`（退回轮询）省约 1.4K LUT；`RX_VL_CFG` 删掉 `expect_vl` 字段（表项 64→32 bit，256 Kbit→128 Kbit，省 8 个块；地址表里 `0x1D80~0x3D7F` 那行随之从 8192 字缩到 4096 字，若真要开这个开关，由 `tools/fix_addr.py` 重排、`tools/check_addr.py` 复核，别手改区间），代价是 `parse` 少一项一致性检查（保留在 P2 配置里）。这些开关的用途是生成一张敏感性表（同一套代码、不同参数 → 开销与仿真速度），不做综合也成立，比单给一个数字更能说明架构的代价结构。

---

## 12 验证计划

### 12.1 环境结构

```
sim/tb/tb_afdx_top.sv
 ├─ host_bfm      : 表项配置、端口读写、突发搬运、中断响应（任务级 API）
 ├─ mac_bfm_a/b   : 字节流，可注入 CRC 错、丢帧、乱序、重复、A/B 偏斜、IFG 抖动、截断
 ├─ net_model     : 2 台"理想交换机" + 固定 10 μs 链路延迟，构成端到端回环
 ├─ timing_monitor: 每 VL 帧首时间戳、BAG 间隔、抖动、时延；dump CSV
 ├─ scoreboard    : 发送帧与黄金帧逐字节比对；接收判决与原因比对；端口内容比对
 └─ covergroups   : 见 §12.3
sw/golden/afdx_model.py    帧构造 / 校验和 / IC / RM / 配置合法性 / 结果绘图
sw/gen/regs.yaml → RTL     寄存器单一来源
sim/regress.tcl            一键回归，输出 pass/fail + 指标表
```

TB 与 RTL 的唯一接口是顶层端口 + 附录 A 的寄存器，任何"为了测试加的内部信号"必须走 `dbg_*` 端口或 `bind` 文件（不改 RTL 内部逻辑可见性），避免"测试依赖实现细节"。

黄金模型独立性要求：`afdx_model.py` 不读 RTL 常量，帧格式与判决逻辑由 `regs.yaml` + 本文档 §6 的表独立实现，且 `tools/model_selftest.py` 用 1000 组随机帧与 `scapy`/`zlib` 交叉验证（先保证裁判没错）。

### 12.2 用例矩阵

| # | 用例 | 配置 | 检查 | 归属 |
|---|---|---|---|---|
| T00 | 黄金模型自检 + CRC 常数一致性 | — | 与 Python 标准库一致 | 公共 |
| T01 | 复位与寄存器/表项读写 | 默认 | 复位值、R/W 属性、`ERR.ACC` | host |
| T02 | 单 VL 采样端口发送 | L=8/17/18/240/1471 | 与黄金帧逐字节 | builder |
| T03 | IP/UDP 校验和 | 奇偶 L 各 200 组 | 与 `scapy` 一致 | checksum |
| T04 | BAG 全档位合规 | 1/2/4/…/128 ms | 间隔 ≥ BAG，`bag_ovf=0` | sched |
| T05 | 满载抖动与判决 | T05b（32 VL/Lmax 256 B/718 μs，链路占用 99.83%）测抖动；T05a 轻载组做对照；T05c（128 VL/Lmax 1471 B/8 ms，链路占用 1.9136 倍）测 `CFG_SUM` 拒绝 | T05b：max ≤ 30 μs、mean ≤ 10 μs；T05a：抖动 ≪ 1 μs 且与占用线性；T05c：`ERR.BAG_OVF`+`CFG_ERR` 置位、VL 不降速但持续顺延 | sched |
| T06 | SN 递增/回绕/复位 | 255→1、复位后 0 | SN 序列 | sn_gen |
| T07 | A/B 双网复制 | 200 帧 | 两网内容差仅 SMAC net_id；`done` 同拍 | tx_rm |
| T08 | 接收过滤 | 错 VLID/超 Lmax/错类型/CRC 错/截断/超长 | 丢弃原因计数逐项匹配 | flt |
| T09 | IC 判决 | 丢 1 帧、丢 2 帧、乱序、SN=0、`psn=0` 首帧（含 `IC_FIRST_ANY` 两版） | 判决与模型一致 | ic |
| T10 | RM | A/B 同拍、偏斜 50/99/100/101 μs、A 丢 B 补、超 SkewMax | 无重复投递、无漏投 | rm |
| T11 | 端口行为 | 采样覆盖、队列满、`commit` 与 `free` 同拍 | 覆盖计数、溢出、不丢序 | port_buf |
| T12 | 4096 RX VL 压力 | 满配哈希 + 随机 VLID 10 万帧 | 查找正确、探测统计 | lookup |
| T13 | 端到端回环时延 | 满载/轻载各 1000 帧 | 轻载 TX 首字节 ≤4 μs、RX ≤0.5 μs、总 ≤0.25 ms；饱和最大帧 TX 首字节 ≤125 μs、总 ≤0.35 ms | sys |
| T14 | SNMP | GET/GETNEXT/SET、RO 写、类型错、community 错、长 OID | 响应 BER 与 `pysnmp` 解析一致 | snmp |
| T15 | TFTP/615A | 上/下载、超时重传、块号 65535→0、重复块 | 加载区 CRC 与源文件一致 | tftp |
| T16 | RTC 同步 | 初始偏 1 ms / 30 μs，中途失步 | 收敛 ≤1 μs、`SYNC_LOSS` 行为 | rtc |
| T17 | 线速最小帧冲击 | 64 B 帧背靠背 10 万帧，双网 | 无丢帧无溢出、A6~A12 断言 0 触发 | sys |
| T18 | 随机约束长时回归 | 8 h 缩配 + 30 min 满配 | 与模型逐帧一致 | sys |
| T19 | 子 VL 轮询 | P2 | BAG 按 VL 生效、子 VL 公平 | sched |
| T20 | IP 分片重组 | P2 | 分片乱序/丢片行为 | parse |
| T21 | 反压与丢弃 | 强制 `pmem_exhaust` | 计数正确、恢复后正常 | sys |
| T22 | 上电配置全流程（模拟真实使用） | 脚本生成配置→开流 | 端到端无错 | sys |

T21/T22 是本次设计新增（相对上一版计划），因为评审看的是"能不能真用"，配置流程与耗尽恢复是最容易漏的两条。

### 12.3 功能覆盖点

- 帧长边界：L ∈ {8, 17, 18, 19, 1470, 1471}；填充 {0, 1, 42} 字节。
- SN：{1, 2, 254, 255→1}，PSN 回绕组合 {255/1, 254/255}。
- IC：`reason ∈ {OK, LOST_ONE, SN_RESET, OUT_OF_ORDER, FIRST_STRICT_REJECT}` × 两网。
- RM：`skew ∈ {0, 1, skewmax−1, skewmax, skewmax+1}` × `sn 相同/不同`。
- 端口：采样覆盖 1 次 / N 次；队列深度 {1, 2, max, max+1}；SAP 并发。
- 资源：`pmem_free ∈ {0, 1, 2, >2}`；描述符 FIFO 满。
- 管理：BER 长度异常 4 类；TFTP `blksize` {512,1024}、超时 0~`RETRY_MAX`。
- 交叉：`vl_id × 丢弃原因`、`net_id × IC 结果`、`帧长区间 × 是否填充`、`端口类型 × 是否发生覆盖`。

目标：行覆盖 ≥ 95%，分支 ≥ 90%，FSM 状态/转移 100%，上述功能组 ≥ 95%；未覆盖点在报告里逐条说明原因（如 `IC_FIRST_ANY=1` 分支只在专项用例触发）。

### 12.4 回归与报告

`sim/regress.tcl` 顺序执行 T00~T22（缩配），每条用例独立 `vsim` 会话，超时 600 s；满配只跑 T04/T05/T12/T13/T17/T18。全表配置一次是 0.694 ms（34 688 字 × 2 拍，§5.4），在仿真里是 7×10^5 拍，因此每条用例必须从同一份「已配置」快照 `save`/`restore`，否则回归时间的 40% 会花在重复灌表上——这条由 `sim/regress.tcl` 的 `save -scope` 步骤实现，T22 专门测「冷启动灌表」以给出这个开销的实测值。输出 `out/regress.csv`（用例、配置、通过、最大偏差、耗时）与 `out/metrics/*.csv`，`sw/report/make_report.py` 生成抖动直方图、时延 CDF、丢弃原因饼图和指标达成表（PDF/PNG 直接进测试报告）。任何 FAIL 不允许"看波形后改期望值"，必须写明原因分类（RTL 错 / 模型错 / 用例错）并留 commit 记录。

---

## 13 进度与分工

| 周 | 日期 | RTL | 验证 | 文档/综合 | 出口条件 |
|---|---|---|---|---|---|
| 0 | 09-21~22 | 定题目、装 eLinx+ModelSim 跑通样例 | — | 接口确认问题清单 | **报名完成**、群里 ready/valid 语义已答复 |
| 1 | 09-23~29 | 参数体系、公共模块（timebase/fifo/checksum）；`regs.yaml` 与 `tools/gen_regs.py` 已在设计阶段先落地（`doc/regs.yaml` 23 项、附录 A 与 A.1~A.3 同源），本周只需随接口答复补字段 | TB 骨架 + 回归脚本 | 本文档 v0.5 | 空壳 `AFDX_top` 能在 ModelSim 与 eLinx 双双通过 |
| 2 | 09-30~10-06 | `tx_port_buf`/`tx_sn_gen`/`tx_frame_builder` | 黄金模型帧构造 + T00~T03、T06 | 帧格式章节 | 发送单元用例全绿 |
| 3 | 10-07~13 | `tx_vl_scheduler`/`tx_rm`/`mac_tx_if`；`mac_rx_if`/`rx_flt`/`rx_vl_lookup` | T04~T08、BFM 故障注入 | — | 双向单链路打通 |
| 4 | 10-14~20 | `rx_ic`/`rx_rm`/`rx_ip_udp_parse`/`rx_port_buf`/`host_if`/`stats_regs` | T09~T13、T17、T21 | 设计文档 v1.0（含 T13 时延数字）；eLinx 综合自证有余力才做 | **P0 闭环** |
| 5 | 10-21~27 | `rtc_sync`/`snmp_lite`/`a615a_tftp`（精简） | T14~T16（含 T15）、T18（8 h） | 敏感性表；（可选）eLinx 综合与 STA | P1 完成，随机回归 0 FAIL；`a615a_tftp` 时间不够就整块挪到 `enhance` 分支，主线只保留加载区与 `UDP_CFG` 钩子 |
| 6 | 10-28~11-03 | bug fix、`sw/report` 出图表、答辩材料 | T22、覆盖率冲刺、全量复跑 | 测试报告、演示脚本、打包 | 11-01 冻结；11-03 打包提交包（11-04 18:00 截止，不押当天） |
| 决赛 | 11-05~22 | `enhance` 分支：子 VL、IP 分片、ns 时基 | 增强用例 | 答辩 PPT、演示波形讲稿 | 11-20~22 答辩 |

分工（3 人）：

| 人 | 负责 | 交付 |
|---|---|---|
| A（队长） | 架构、`host_if`、发送流水、调度器 | 设计文档 §3~§8、调度器单元报告 |
| B | 接收流水、`bram_sdp`/存储封装、eLinx 工程与可选综合 | 存储开销与实现说明、指标达成表 |
| C | TB/BFM/记分板、黄金模型、管理面（SNMP/RTC/TFTP） | 测试报告、覆盖率、回归脚本 |

两人版本：A 兼 C 的 TB，B 兼管理面；砍 P2 全部 + SNMP 的 SET（只留 GET/GETNEXT）。

---

## 14 风险登记与验证矩阵

| ID | 风险 | 概率 | 影响 | 应对 | 触发后动作 |
|---|---|---|---|---|---|
| R1 | 接口语义与出题方预期不符 | 中 | 高 | 第 0 周群内确认；适配层隔离 | 改 `mac_*_if`，重跑 T01~T03、T08、T17 |
| R2 | 6 周做不完 P0 | 中 | 高 | 出口条件硬约束；单元用例先行 | 砍 SNMP SET → 砍 TFTP → 砍 RTC 平滑（只跳变） |
| R3 | 4096 满配仿真/综合撑不住 | 中 | 中 | 满配缩配双档常备；§11.4 开关 | 切缩配出指标，敏感性表说明线性关系（综合本身是可选项，失败不致命） |
| R4 | 拿不到 A664P7 原文，细节被判不符 | 中 | 中 | 每条判决写明依据（本文 §6/§7 已标条款） | 允许实现细节回退为指南原文描述 |
| R5 | ms 级 BAG 使仿真过长 | 高 | 中 | `TICK_US` 缩放 + 满配只跑指标用例 | 报告区分"功能（缩放）/指标（真实）" |
| R6 | eLinx 工具链问题（崩溃/文档缺） | 中 | 中 | 第 1 周跑通全流程；工程与 IP 分离 | 退回纯 ModelSim + 用工具旧版，报告说明 |
| R7 | PMEM 读写冲突导致丢帧 | 低 | 中 | 块号即实例号，读写各走一侧；`pmem_conf` 计数器做哨兵 | `PMEM_KB` 翻倍到 64 KB（+15 块），重跑 T17 |
| R8 | CRC 迟到撤销被质疑 | 低 | 低 | `FCS_LATE_DROP_DIS` 双配置都测 | 默认改严格模式，单列时延 |
| R9 | 报名/提交时间错过 | 低 | 致命 | 9-22 当天完成报名（明天就是截止日）；作品提交平台截止按通知核为 11-04 18:00，故 11-03 完成打包上传、11-04 只留核验与重传余量，截止时刻列入附录 D 待确认 | 无 |

需求追溯矩阵（评审对照用）：

| 指南要求 | 设计章节 | 模块 | 用例 |
|---|---|---|---|
| A664P7 通信 | §6, §7.3 | `tx_frame_builder`/`rx_ip_udp_parse` | T02, T03, T08 |
| 帧格式与 VLID/SN | §6.1, §6.6 | `tx_sn_gen` | T02, T06 |
| 载荷 ≤1471、帧 ≤1518 | §6.1, §2.2 | `tx_frame_builder` | T02, T08 |
| 端到端时延 / 抖动 | §8.2, §8.3 | `tx_vl_scheduler` | T04, T05, T13 |
| 128 TX VL | §7.2, §9 | `tx_vl_scheduler` | T05 |
| 4096 RX VL | §7.9, §9 | `rx_vl_lookup` | T12 |
| 高可靠性（IC/RM/双网） | §7.5, §7.10, §7.11 | `tx_rm`/`rx_ic`/`rx_rm` | T07, T09, T10 |
| SNMP 网管 | §7.16 | `snmp_lite` | T14 |
| ARINC 615A 加载 | §7.17 | `a615a_tftp` | T15, T22 |
| RTC 同步 | §7.15 | `rtc_sync` | T16 |
| 编码规范 | §10 | 全部 | lint 门 |
| 顶层模板 | §5.1, §5.2 | `AFDX_top` | T01, T22 |

---

## 15 交付物与评分对应

| 评分项 | 权重 | 交付 | 本文对应 |
|---|---|---|---|
| 代码及仿真环境 | 40% | `rtl/` 全部（≈7.4K 行，含注释与端口表）、`sim/` TB+BFM+记分板+断言、`sw/golden/` 模型、`tools/` 回归与脚本、`doc/regs.yaml` 与生成的 `doc/regs_pkg.svh`、README | §7、§8.8、§10、§12.1 |
| 设计文档 | 20% | 本文档定稿（方案与架构框图、接口时序、帧格式、寄存器与表项、模块详设、关键算法、开销与实现说明） | 全文 |
| 测试（仿真）报告 | 20% | 用例矩阵与通过率、覆盖率、关键波形（含 T10 同拍、T08 迟到撤销、T05 直方图）、指标达成表、FAIL 分类记录 | §12、§8.3 |
| 技术指标 | 20% | 指标达成表（速率、帧格式与 VLID/SN、BAG 合规、抖动、时延、VL 规模、IC/RM 正确性）+ 测量脚本与原始 CSV + 图表；敏感性表（满配/缩配）；做了 §11 才附综合与时序报告 | §2.2、§8.2、§8.3、§12 |
| 附加（非评分但决定答辩） | — | 演示脚本（10 分钟：配置→发送→满载→IC/RM 错注→SNMP 查询→加载）、`tools/` 一键复现说明 | §13 决赛行 |

---

## 附录 A 寄存器位域（与 `doc/regs.yaml` 同步）

| 地址 | 名称 | 位域 |
|---|---|---|
| `0x0000` | `ID` | [31:16]=`0xAF07`（AFDX Part7），[15:0]=`NUM_RX_VL` |
| `0x0004` | `REV` | [31:16]=主版本，[15:8]=次版本，[7:0]=build |
| `0x0008` | `CTL` | 见 A.1 |
| `0x000C` | `STATUS` | 见 A.2 |
| `0x0010` | `ERR` | 见 A.3，W1C |
| `0x0014` | `INT_ENABLE` | 8 位（新采样、队列非空、溢出、CRC 撤销、丢弃突增、TFTP 完成、SNMP 请求、RTC 失步） |
| `0x0018` | `INT_STATUS` | 同上，W1C |
| `0x001C` | `DROP_CNT` | 合计丢弃帧数 |
| `0x0020`~`0x004C` | `DROP_CNT_K` | 12 类原因各 32 bit |
| `0x0050` | `TB_CNT_US` | `tb_us[31:0]` |
| `0x0054` | `TB_CNT_US_HI` | `tb_us[63:32]` |
| `0x0058` | `CFG_SUM` | [31:0] 配置带宽和，Q20 定点（1.0 ≡ 100 Mbps 满负荷） |
| `0x005C` | `CFG_ERR` | [7:0] 违规项位图（超额、端口冲突、Lmax、BAG、SkewMax） |
| `0x0060` | `SMAC_CFG` | [31:24]=UDI，[23:20]=IFID，[19:16]=net_id_A，[15:12]=net_id_B |
| `0x0064` | `IP_CFG` | [31:0]=本端 IP |
| `0x0068` | `TFTP_PEER_PORT` | [15:0]=最近 TFTP 会话 TID |
| `0x006C` | `SNMP_PEER_IP` | [31:0]=最近合法请求方 IP，RO |
| `0x0070` | `UDP_CFG` | [1]=`UDP_CSUM_MODE`（1=计算并校验），[0]=`IC_FIRST_ANY`，[7:4]=`LOG2_AVG`，[15:8]=`TH_JUMP`（μs） |
| `0x00F0` | `BURST_ADDR` | 突发搬运目标字地址，写 `BURST_DATA` 后自动递增 |
| `0x00F4` | `BURST_LEN` | 突发长度 1~16 字，超 16 截断并置 `ERR.ACC` |
| `0x00F8` | `BURST_DATA` | 读写都走这里：一次突发最多 16 字，用于整表搬运（全表 0.694 ms → 0.390 ms，见 §5.4） |
| `0x00FC` | `DBG_CTRL` | [3:0]=IC/RM 窗口页选（写回需 `DEBUG_EN`），[4]=强制 PSN 写使能，[5]=对下一收帧注入 CRC 错，[6]=冻结统计更新，[7]=TB 钩子使能 |
| `0x0100`~`0x01FF` | `STATS_BLOCK` | 全局帧数/字节数/最大抖动/均值/直方图 8×32 |

> 本表与 `doc/regs.yaml` 由 `tools/gen_regs.py` 单向生成（YAML 是唯一来源），RTL 里的地址 localparam 同源；生成后 `tools/verify_all.py` 会核对表里出现的寄存器名与 YAML 完全一致，正文不许手写偏移。

### A.1 `CTL`（`0x0008`）位域

| bit | 名称 | 默认 | 含义 |
|---|---|---|---|
| 0 | `TX_EN` | 0 | 发送流水使能，0 时调度器停摆 |
| 1 | `RX_EN` | 0 | 接收流水使能，0 时 `mac_rx_if` 丢弃并计数 |
| 2 | `IC_EN` | 1 | IC 判决使能 |
| 3 | `RM_EN` | 1 | RM 去重使能 |
| 4 | `SCHED_MODE` | 1 | 1=最早到期优先，0=轮询（对应 D3、§11.4 `SCHED_MIN_EN`） |
| 5 | `RSVD_5` | 0 | UDP 校验和模式改由独立寄存器 `UDP_CFG`（`0x0070`）承担，避免与 §6.4 的表项配置重复 |
| 6 | `FCS_LATE_DROP_DIS` | 0 | 1=CRC 结果进入判决链（严格模式） |
| 7 | `SUBVL_EN` | 0 | 子 VL 轮询（P2） |
| 8 | `SNMP_EN` | 1 | SNMP 精简代理使能 |
| 9 | `TFTP_EN` | 0 | 615A/TFTP 加载使能 |
| 10 | `RTC_EN` | 1 | RTC 同步使能 |
| 11 | `RTC_HOLD` | 0 | 1=冻结时基，判决链与统计不推进（仅测试用） |
| 12 | `RSVD_12` | 0 | 写 1 无效，读回恒 0 |
| 13 | `CFG_MODE` | 0 | 1=允许写配置表与哈希表；运行中置 0，避免表与状态不一致 |
| 14 | `IRQ_SW` | 0 | 1=软件触发 `host_irq`（自测 T01 用） |
| 15 | `DEBUG_EN` | 0 | 1=允许强制写 IC/RM 状态，用于错误注入（T09/T10） |

### A.2 `STATUS`（`0x000C`）位域

| bit | 名称 | 含义 |
|---|---|---|
| [0] | `SCHED_BUSY` | 调度器有在途仲裁 |
| [1] | `BUILDER_BUSY` | 构建器正在组帧 |
| [7:2] | `PMEM_FREE` | 空闲块数（0~16，6 bit） |
| [8] | `DROP_STORM` | 丢弃速率超阈（连续 2^12 拍内 >16 帧） |
| [9] | `BAG_VIOL` | 出现违反 BAG 的发送（只应由 `CFG_SUM` 判决防住） |
| [10] | `CRC_ERR` | 最近一帧 CRC 不符 |
| [12:11] | `OVF_CNT_MAX` | 观察窗口内单端口最大连续溢出档位（0=无，1=<16，2=<256，3=≥256） |
| [31] | `ALIVE` | 每 2^24 拍翻转，供健康检查与 SNMP `sysUpTime` |

### A.3 `ERR`（`0x0010`）位域（W1C）

| bit | 名称 | 触发条件 |
|---|---|---|
| [0] | `ACC` | 访问了未映射地址、或 R/W 属性违规（§7.14） |
| [1] | `BAG_OVF` | `CFG_SUM` 判决：配置带宽和 >1.0 |
| [2] | `PMEM_EXH` | 分配 PMEM 块时空闲链为空 |
| [3] | `HASH_CONF` | 哈希 3 级探测仍未命中且槽位被占（§7.9） |
| [4] | `PORT_CONFLICT` | 两个 VL 落到同一 `(port_base / port_mask)` 组合 |
| [5] | `FRAME_OVERLONG` | 收到 >1518 B 的帧 |
| [6] | `FRAME_TRUNC` | 收到 <64 B 的帧（不含前导码） |
| [7] | `SN_DOUBLE` | 同一 VL 收到重复 SN（IC 窗口内 SN 回退） |

## 附录 B TX VL 表项位域（8 字，其中 w0~w4 入 RAM，w5~w7 不入）

| 字 | 位域 |
|---|---|
| w0 | [31] `valid`，[30] `subvl_en`，[29:24] `n_sub`，[23:12] `lmax`，[11:4] `bag_exp`（log2 ms），[3:0] `net_mode` |
| w1 | [31:8] `bag_us`（μs，1000×2^bag_exp），[7:5] `ip_id_mode`，[4:0] `tos` |
| w2 | [31:16] `udp_dp`，[15:0] `udp_sp` |
| w3 | [31:0] `dst_ip` |
| w4 | [31:16] `port_base`，[15:8] `port_mask`，[7:0] `user_vl_tag` |
| w5 | [23:0] `next_tx`，[31:24] 保留 |
| w6 | [23:0] `last_tx`，[31:24] 保留 |
| w7 | [31:16] `max_jit_us`，[15:8] `mean_jit`，[7:0] `bag_ovf` |

w0~w4 是静态配置，存在 `TX_VL_TAB`（128 × 5 字 = 2.5 KB，§7.14、§9）；w5/w6 的 `next_tx`/`last_tx` 每拍都要被调度器并行读改，RAM 做不到，做成 128 × 48 bit 寄存器阵列（6.1 Kbit，记在逻辑侧）；w7 属每 VL 统计，落在 `VL_STATS`（`0xA810`，128 项 × 8 字）。附录列全 8 个字是为了说明一张 VL 的完整状态构成，RAM 里只有前五个——别按 8 字去算地址。

## 附录 C RX VL 表项位域（每项 2 字）

| 表 | 字 | 位域 |
|---|---|---|
| `RX_VL_CFG` | w0 | [31] `valid`，[30] `rm_en`，[29:28] `net_mode`，[27:24] `skewmax_exp`（0~15 ⇒ 4<<exp μs），[23:12] `port_base`，[11:0] `lmax` |
| | w1 | [31:0] `expect_vl`（4 字节，含 VLID 校验用） |
| `RX_HASH` | way | [31:29] 填充（恒 0），[28] `valid`，[27:12] `vlid`，[11:0] `idx`；一个槽两 way 各占一个字，读口一次取 64 bit（§7.9） |
| `PSN` | — | [7:0] 上一正确 SN |
| `RM_ST` | — | [31:8] `last_ts[23:0]`，[7:0] `last_sn`（共 32 bit，不留冗余字段）；`pending` 不占表位，见 §7.11 |

## 附录 D 待出题方确认清单

1. `tx_ready`/`rx_ready` 的方向与语义（本文按帧包络解释，§5.3）；若为流控握手，请给出帧边界由谁提供。
2. ~~`clk` 频率与 `rx_data` 有效节拍是否严格线速~~ **部分已答复**：接口为 GMII（见 D.1），本文据此取 `clk` = 125 MHz、`BYTE_SLOT_CYC` = 10；仍未答复的是「ES 能否在字节之间插空闲拍」——本文按可以插实现（否则 125 MHz 下无法降速到 100 Mbps），第 0 周确认。
3. 前导码/SFD 与 FCS 由 MAC 还是 ES 产生，错误帧是否由 MAC 置标志。
4. 顶层是否允许增加端口（`DUAL_NET_EN` 双网、主机接口）；若不允许，是否接受 `AFDX_top_min` 的带内配置方案。
5. 仿真评测是否要求提交 `vsim` 脚本与波形文件，评分是否看覆盖率报告——D.1 第 5 条已答复「要求基于 FPGA 做仿真」，但未说明是否收波形文件与覆盖率，仍要问。
6. 是否完全不要求器件映射与上板（本设计按「不要求」推进，综合仅自证）；若要求，指定哪个器件与 eLinx 版本、允许使用哪些片内 RAM IP。
7. 128/4096 VL 是否要求满配综合，还是"支持能力"即可（影响 §9、D9 的报告口径）。
8. ~~ARINC 615A 与 SNMP 的验收深度~~ **已答复**：「参考协议规范要求」（见 D.1 第 4 条），即无附加细则。本文据此把 SNMP 定为 `GET`/`GETNEXT`/`SET` 最小子集 + `STATS_BLOCK` 只读对象组，615A 定为 UDP/TFTP 装载与 Find/Information/Upload 流程；互操作证据不承诺，只保证与自研 `tb/` 侧的协议检查器逐字段对齐。

答复记录进本附录，作为 §2.5 假设的替换依据。下面 D.1 是已经拿到答复的部分，D.2 登记同批材料里与选题一无关的东西，免得下次又当悬念查一遍。

### D.1 组委会《问题汇总》中与选题一有关的答复（逐条摘录，未改写）

来源：赛方材料 `FPGA创新大赛问题汇总 (1).xlsx`，单页 13 行 × 3 列，本文经隧道取回后就地转成 CSV 阅读（原表未改动），逐条摘录同步存为 `doc/组委会问答.md`，远端副本名 `doc_组委会问答.md`。

| 询问时间 | 问题 | 答复 |
|---|---|---|
| 2026.09.04 | 请问 AFDX 的仿真结果验收是要自己写回环吗？还是说要和赛方的仿真模型或其余验证模块或手段做通信 | 需要参赛者自己编写仿真激励（文件）并验证内容。 |
| | 给 mac 层的接口是啥 rgmii 还是 gmii | GMII |
| | 是否有仿真文件和参考测试环境？ | 需要参赛者自己编写仿真激励（文件）并验证内容。 |
| | 请问选题 1 有题目具体细则吗，比如 snmp 具体要管理哪些东西，615A 数据逻辑要加卸载什么东西 | 参考协议规范要求。 |
| | 想请教一下选题一的仿真环境测试要求：仿真是否必须基于 FPGA 做波形仿真，还是允许搭建其他软件运行环境完成功能测试？ | 要求基于 FPGA 做仿真。 |

四条答复逐条落到位：

1. **激励与检查器全部自建**（第 1、3 条）。赛方不给激励、不给参考模型，所以「对错由谁判」必须在文档里写明：本文的答案是 §8.2 的判决式与 `tools/bag_model.py` 这份黄金模型，仿真器里每条判决结论都要与它逐帧对齐；`tb/` 下的 BFM、记分板与错误注入器本身就是被评分的交付物（40% 那一档）。
2. **接口是 GMII**（第 2 条）。§2.5 第 3 条与 §4.1 已按 8 bit + 125 MHz 回写，「拍数锁定」的量按 §4.1 清单换算；第 1 项待确认清单（`tx_ready`/`rx_ready` 语义）不受影响，仍然要问。
3. **SNMP/615A 没有更细题面**（第 4 条）。答复是「参考协议规范要求」，那就不猜范围：SNMP 只按「指南要求支持网管 + 协议规范」自界定为 `GET`/`GETNEXT`/`SET` 最小子集 + 把 `STATS_BLOCK` 映射成只读对象组（§7 的 `snmp_lite`）；615A 按 ARINC 615A 的加载流程做 UDP/TFTP 装载与 Find/Information/Upload 三步（§7 的 `a615a_tftp`）。本清单第 8 条据此关闭。
4. **必须基于 FPGA 做波形仿真**（第 5 条）。这条把「软件模型跑功能测试」从验收手段里排除掉：`tools/*.py` 与 `sw/golden/` 只作自校对参考，交付证据必须是 eLinx 编译产物加 ModelSim 对 RTL（有余力时含综合后网表）的波形与 log，见 §12.1。

### D.2 同批材料中与选题一无关的部分

`pmux_case (1).rar` 解压后是 `competition_case\test1~4\test*.v` 四个 Verilog 小模块（test1：8 通道 12 bit 寄存交换状态机，16 bit 输入取 [15:4]；test2：one-hot 4 选 1 多路器；test3：串入并出移位 + GPIO 译码；test4：5b/6b 编码查找表）。它们对应《问题汇总》里「选题二的测试用例集……已上传到 qq 群 4 个 case」与「选题二……统一映射为 cycloneiv 系列网表」那几条，属**选题二**材料，与选题一没有接口关系，此处登记结论以免后续误当成选题一的要求。`xapp1130 (1).pdf` 是 AMD/Xilinx 公开应用笔记 XAPP1130 v1.0.1（2009-05-22，《Architecting ARINC 664, Part 7 (AFDX) Solutions》），本文按节引用其帧格式与 SN 语义（§2 口径表、§3 的 `tx_sn_gen`/`rx_ic`），其中 Virtex-4/5 器件映射与 Tri-Mode Ethernet MAC IP 的内容不采用。

## 附录 E 工具脚本清单

| 脚本 | 作用 |
|---|---|
| `sw/gen/crc_gen.py` | 生成 CRC32 按字节 XOR 常数（§8.1） |
| `tools/gen_regs.py` | `regs.yaml` → RTL localparam + 附录 A/B/C 表格 |
| `sw/golden/hash_seed.py` | 配置期哈希种子搜索与探测长度统计 |
| `sw/golden/afdx_model.py` | 帧构造、校验和、IC/RM 参考判决、配置合法性检查 |
| `sw/report/make_report.py` | CSV → 直方图/CDF/指标达成表（PNG+LaTeX 表格） |
| `sim/regress.tcl` | 全量回归调度与超时、结果汇总（§12.4） |
| `tools/lint.sh` | Verilator lint + 规范检查（命名、注释、端口表完整性） |
| `tools/bag_budget.py` | 给定 VL 集合算配置和、抖动上界，输出 T05 配置建议 |
| `tools/fix_addr.py` / `tools/check_addr.py` | §7.14 地址表按「项数 × 每项字数」连续重排（PMEM 起始 2 KB 对齐）/ 复核容量声明与重叠 |
| `tools/check_s9_final.py` | §9 逐行反算 Kbit 与 18 Kbit 块数，并核对合计行 |
| `tools/run_all.py` | 一条命令跑完 5 个校验器（verify_all / check_addr / check_s9_final / gen_regs / check_doc_numbers），提交前必须 5/5 全绿 |
| `tools/bag_model.py` | §8.2 判决式的唯一实现，`bag_budget.py` 与 `check_doc_numbers.py` 共用 |
| `tools/check_doc_numbers.py` | 把 §8.2 正文写死的 T05a/b/c 数字逐条重算对账（占用、Mbps、CFG_SUM、单帧时间、合法/超限口径） |
| `tools/gen_regs.py` | `doc/regs.yaml` → 附录 A 表格 + `doc/regs_pkg.svh`（地址 localparam 与访问位图），并反向核对文档：偏移递增/4 字节对齐/access 合法/`CTL` 复位值由位域默认值推得/寄存器名与文档一一对应 |
| `tools/verify_all.py` | 全文一致性校验：章节编号、交叉引用、表格列数、用例/决策/风险编号、模块行数小计、脚本路径、口径与两文档数字对账 |
| `elinx/run.tcl` | 综合/P&R/STA 一键，输出 `rpt/*.rpt` |

## 附录 F 版本记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v0.1 | 2026-09-21 | 架构基线：需求分解、接口解释与假设、模块划分、地址空间、开销与验证计划 |
| v0.2 | 2026-09-21 | 按赛题实际口径修订：无器件、无板卡、纯软件仿真评测。§9 改为存储开销预算（删去器件占比口径），§11 降级为可选自证，技术指标只以仿真测量取证 |
| v0.3 | 2026-09-21 | 自查修正：§9 每行改为按「项×位」现算（先写的 1.61/1.78/1.30 Mbit 都不对，重算后为 1.26 Mbit/79 块、含 P2 1.33 Mbit/83 块；缩配 0.54 Mbit/36 块；哈希表项从 29 bit 改成每 way 一个 32 bit 字，与主机写宽一致）；**v0.3.1**：§7.14 地址表由 `tools/fix_addr.py` 按「项数×每项字数」连续重排并强制 PMEM 2 KB 对齐，PMEM 基址落到 `0x8800`、加载区落到 `0xCC20`（原先的 `0x6C00`/`0xE000` 一带是拼出来的区间，逐项核算后既互相重叠又与声明容量不符），§7.1/§8.6 的池区间与描述符地址同步回填，`tools/check_addr.py` 复核 14 行无重叠、合计 209 KB；② PMEM「每端口 128 B 顺序区」与 32 KB 总量矛盾（256×128 B 正好等于整个 PMEM），改为 TX/RX/公共三池的 16×2 KB 块分配；③ 哈希 4096 槽 vs 8192 项、2 块 vs 14 块前后不一致，统一为 4096 槽×2 way，并把探测做成固定 3 级（实测连号 VLID 零冲突、随机 VLID 最长链 6，不能赌概率）；④ 附录 C 的 `RM_ST` 位域重叠（[23:0] 与 [15:8] 打架）改为 24+8；⑤ SkewMax 的 3~255 μs 与 `4<<exp` 编码不一致；⑥ `CFG_SUM` 单位统一为 Q20；⑦ 各模块「资源」行的 RAM 口径统一到 18 Kbit 块，调度器时间戳明确为寄存器 |
| v0.4 | 2026-09-21 | 全文再验证（`tools/verify_all.py`，含表规模对账、模板端口对账、脚本路径唯一性、分组行数和）：① 标题与抬头去掉「FPGA 设计」字样，改为 eLinx 软件编译 + 仿真口径，并回填指南原话「无需硬件平台」复核时又发现自己把 T05 用例块的帧长写成 264 B、正文却仍是 280 B 口径，已统一为「Lmax=载荷、帧长=Lmax+24」，并由新增的 `tools/check_doc_numbers.py` 逐条重算；`tools/bag_budget.py` 改成直接解析 §8.2 用例块，不再自带一份会飘的硬编码；② §3.4 模块清单合计行列数与分组小计修正（原文把 `host_if` 同时算进「主机接口 560」和「管理面 1580」）；③ 附录 B「每项 8 字」与 §7.14/§9「128 × 5 字」的矛盾说清（w0~w4 入 RAM，w5/w6 为寄存器、w7 属 `VL_STATS`）；④ 附录 C `RX_HASH` 位域补上 3 bit 填充与两 way 排布；⑤ 附录 A 寄存器偏移改为严格递增并补 `BURST_*` 的位域列；⑥ §11.4 `expect_vl` 删除的省量按现算改为 4 块；⑦ 寄存器位域小节并入 §7.14，避免出现 §7.14.1 这种与模块清单冲突的编号；⑧ §8.5 仍写着 `rx_vl_cfg` 4096×32、`rx_hash` 8192×29 的旧口径，按 §9 现算改为 4096×64 与 8192×32；⑨ §13 第 5/6 周把 `a615a_tftp` 与 T15 重复排到两周，现统一放第 5 周、第 6 周只留 bug fix 与打包，提交节奏与简介文档一致（11-03 打包、11-04 18:00 截止）；⑩ 补齐 `doc/regs.yaml` 与 `tools/gen_regs.py`（附录 A 与 RTL 地址 localparam 同源，§7.14 里那份重复的 CTL 位表删除，只留设计要点——之前两处各改各的，`STATUS.OVF_CNT_MAX` 一度写成 `[11:12]` 没人发现）；⑪ 附录 E 的 `tools/regress.tcl` 与 §10/§12.4 的 `sim/regress.tcl` 路径打架，目录树里的 `hash_seed.py` 也统一成 `sw/golden/`；⑫ 本文档 v0.4 之后又发现 §8.2 用例块的帧长被写成 264 B、正文仍是 280 B 口径，已统一为「Lmax=载荷、帧长=Lmax+24」，并新增 `tools/check_doc_numbers.py` 逐条重算 |
| v0.5 | 2026-09-21 | 用 `tools/selfcheck_claims.py`、`tools/bag_budget.py` 复核自己写的数字，改掉三处硬错：① §8.2 的 T05 用例「32 VL/8 ms/Lmax 256 B ⇒ 99.84 Mbps」按自己的判决式算实际只有 8.96 Mbps（差 11.1 倍），且该配置下测不出 22.4 μs 抖动，现拆成 T05a 轻载（8.96 Mbps）/ T05b 饱和（BAG=718 μs，链路占用 99.83%）/ T05c 超载判定（128 VL/Lmax 1471 B/8 ms ⇒ 需求 191.36 Mbps，占用 1.9136 倍，同时超构建器能力）三组；② §8.3 把「拍」当「μs」用（1471×8 拍写成 11.8 μs，实为 117.7 μs；RX csum 1518 拍写成 12.1 μs，实为 15.2 μs），全表按 100 MHz/8 拍每字节重算：TX 首字节轻载 3.5 μs、饱和 118.7 μs，端到端改为轻载 ≤0.25 ms、饱和 ≤0.35 ms，T13 判据同步；③ §5.4 的突发收益写成 65 k→4 k 周期（实为 16 384→9 216 拍，只省 1.8 倍），全表灌入 0.694 ms/0.390 ms 写进 §12.4，要求回归用 `save`/`restore` 复用已配置快照、由 T22 实测该开销。另：§2.2 指标表加「当前状态」列区分已核算式与设计目标；新增 `tools/bag_model.py`（判决式唯一实现，`bag_budget.py` 直接解析 §8.2 用例块，不再自带硬编码）与 `tools/run_all.py`（一键跑 5 个校验器） |
| v0.5.1 | 2026-09-21 | 并入赛方原始材料：① 组委会《问题汇总》5 条与选题一有关的答复逐条落到 §2、§2.5、§12 与附录 D.1（接口确认为 GMII、激励自建、必须 HDL 波形仿真、SNMP/615A 按「参考协议规范」自界定范围）；② 接口口径确认后把 `clk` 定为 125 MHz，`BYTE_SLOT_CYC` 由 8 改 10，§4.1 新增「拍数锁定 vs 字节节拍锁定」换算表并列出待逐条换算的 5 处数字；③ 引用 XAPP1130 v1.0.1 的 Frame Format 节核对帧长 64~1518 B、载荷 1~1471 B 与 SN=0 复位语义，§2 依据列回填；④ 附录 D.2 登记 `pmux_case (1).rar` 解压内容为选题二材料，与选题一无关 |
| v0.6（计划） | 10 月初 | 并入组委会《问题汇总》答复：接口按 GMII/125 MHz 回写 §2.5 与 §4.1（含拍数换算表），验收口径改为「激励自建 + HDL 波形仿真」，附录 D 关闭第 2/8 条；余下把 §4.1 清单里的拍数数字逐条换算到 125 MHz，并补 pass1/pass2 实测波形引用 |
| v1.0（计划） | 10-20 | P0 闭环，T01~T13 实测数据与（若做了）综合报告写入，作为提交版设计文档底稿 |

