<!-- rendered from AFDX端系统_设计文档.md using C:/Workspace/diansai/out/p8_freeze_225cd91/metrics.json commit=225cd91be4f6a4b332db1674b44761bca367bd67 -->

# AFDX 端系统设计文档（提交版）

> 数字一律 metrics 锚点（键见 `out/p8_freeze_225cd91/metrics.json`），定稿由 `tools/render_doc_metrics.py` 填充。正文不写开发编年史。  
> 冻结：`225cd91be4f6a4b332db1674b44761bca367bd67` · 全量 `144`/`144`。  
> 对错按 `doc/验收尺子.md`：S/N/T；宣称 P/I/F。每个 P 句后跟「不能推出」。

---

## 1. 赛题与范围

实现 AFDX（ARINC 664 Part 7）端系统（ES）。评分项对应：代码及仿真环境、设计文档、测试报告、技术指标（选题指南）。

### 1.1 五类功能

| # | 功能 | 本设计落点 | 代表 T |
|---|---|---|---|
| 1 | 发送调度与流量整形 | `tx_port_buf` → `tx_vl_scheduler`（BAG）→ `tx_frame_builder`/`tx_sn_gen` → `tx_rm` → `mac_tx_if` | T04 / T05b / T27 / T34p |
| 2 | 接收过滤与 IC/RM | `gmii_rx_strip` → `mac_rx_if` → `rx_vl_lookup` → `rx_flt` → `rx_ic` → `rx_rm` → 解析/端口 | T08* / T09 / T10 |
| 3 | 主机接口与存储 | `host_*` 前门译码（在 `AFDX_top`）；PMEM 块池；端口消息队列 | T01 / T11 / T22 |
| 4 | 管理面 SNMP / 615A·TFTP | `snmp_lite`；`a615a_tftp` / fetch / LUR 子集 | T43 / T27 旁证；演示场 T88 |
| 5 | 时间同步 RTC/PPS | `rtc_sync` + `timebase`；`pps_in`/`pps_out`/`rtc_time_us` | T16a |

### 1.2 四项指标（口径分列）

| 指标 | 官方（S）口径 | 工程计量（本仓） | 等级提示 |
|---|---|---|---|
| 吞吐 | 有效载荷 ≥100 Mbps；RX 侧 A/B **去重后只计一次**；须千兆 GMII 拍 | T42；T90 r6：128 TX / RX126+2unconf / SAP 开 | 场景内可 P；T90 rx_dedup ≥100 Mbps（`p_c1_t90_r6`） |
| 时延 | 官方字面：单帧 GMII **SFD→同帧 SFD** ≤2 ms（单 ES 回环无网络段→**I**）；跨多 BAG 多帧不受此限 | **ES 贡献**：commit→TX SFD、RX SFD→host、`es_total`=二者 max 之和≤2 ms（T89 Questa `p_c0_t89_questa_20261024_170643` **L33**：3384/2592/5976 ns）；另有工程 commit→eof / sof→host（T42：`16.08` / `12.936` μs） | 禁止「官方 2 ms 实测 0 ns」「SFD→SFD 已 P」 |
| 抖动 | 同 VL 多帧端到端时延 **max−min**；「几十微秒」**无硬数字** | 同统计量；项目自设 50 μs 判据。T42：`5.016` μs；T89：`72` ns，本场景 40+Σ=`141` μs | 勿写「官方上限 50 μs」 |
| 规模能力 | 128 TX / 4096 RX 为能力声明；后仿可切片 | 默认参数满配综合；门级为 T88b 切片 | 门级全量 F |

### 1.3 协议子集与答疑依据

- **物理口**：GMII（PHY）；MAC 可用 eLinx IP，**无强制**——本仓自研 `mac_tx_if`/`mac_rx_if`（`doc/赛方答疑原文_20261009.txt` L107–109；对照报告 §1.2）。
- **ready**：可不用；`tx_valid=1`/`rx_valid=1` 即有效，不要求 valid∧ready（原文 L75、L111–119；契约 §2）。
- **615A/665**：交付物为 AFDX 协议实现；615A 数据加载及 665 解析**非硬要求**（对照报告 §1.4）。本仓披露现测 TFTP 子集与边界，**不写「管理面可省略」**。
- **SNMP / RTC**：参考规范；本仓 SNMP **v1 only**（GET/GETNEXT/SET），RTC 接 PPS/FLL。
- **模板口答辩句**：网络公开口 = GMII A/B；主机 = 扩展 `host_*`；与答疑「模块在内部、可加端口」一致（对照报告 §3.3）。

不宣称：完整 A664 认证、交换机、对端真 ES 闭环、完整 615A 认证、官方 SFD→SFD 已 P、官方 2 ms 实测 0 ns、128 VL 任意配置均达标、4096 路同时收、门级全量、Fmax≥125 已签。

---

## 2. 总体架构

数据流见图 1。

![图1 总体数据流](figs/fig1_dataflow.png)

源：`doc/figs/fig1_dataflow.mmd`（已渲 PNG）。默认：`IF_MODE=2`、`DUAL_NET_EN=1`、`NUM_TX_VL=128`、`NUM_RX_VL=4096`、`CLK_FREQ_HZ=125_000_000`。单时钟参数声明，**不是**时序收敛结论。

### 2.1 模块清单（生产主链）

| 模块 | 文件 | 职责 | 关键参数 |
|---|---|---|---|
| `AFDX_top` | `rtl/top/AFDX_top.v` | 顶层；主机译码；流水互联 | 见 §9 |
| `rst_sync` | `rtl/common/rst_sync.v` | 异步复位同步 | — |
| `timebase` | `rtl/common/timebase.v` | μs 时基 | `TICK_US` |
| `init_sweep` | `rtl/top/init_sweep.v` | 上电清表至 `INIT_DONE` | — |
| `tx_port_buf` | `rtl/tx/tx_port_buf.v` | TX 端口队列 / PMEM 写块 | `NUM_PORTS` |
| `tx_vl_scheduler` | `rtl/tx/tx_vl_scheduler.v` | BAG 调度、最早到期优先 | `NUM_TX_VL`；8 路/拍、16 拍扫满 128 |
| `tx_sn_gen` | `rtl/tx/tx_sn_gen.v` | 每 VL SN | — |
| `tx_frame_builder` | `rtl/tx/tx_frame_builder.v` | Eth/IP/UDP/SN 组帧 | `L_MAX` 载荷 |
| `tx_rm` | `rtl/tx/tx_rm.v` | 双网字节复制 | `DUAL_NET_EN` |
| `tx_pace` | `rtl/tx/tx_pace.v` | 共享发拍 | `IF_MODE` |
| `mac_tx_if` | `rtl/tx/mac_tx_if.v` | 前导/SFD/FCS/IFG；GMII 出 | `IF_MODE`/`FCS_MODE`/`IFG_BYTES` |
| `gmii_rx_strip` | `rtl/rx/gmii_rx_strip.v` | 剥前导/SFD | — |
| `mac_rx_if` | `rtl/rx/mac_rx_if.v` | MAC 校验、写 PMEM、出描述符 | `MAX_FRAME` |
| `rx_pmem_queue` | `rtl/rx/rx_pmem_queue.v` | 每网好帧描述符队列 | — |
| `rx_vl_lookup` | `rtl/rx/rx_vl_lookup.v` | 双表×2-way 哈希查 VL 索引 | `HASH_BUCKETS`/`NUM_RX_VL` |
| `rx_flt` | `rtl/rx/rx_flt.v` | valid/VLID/网/Lmax 过滤 | — |
| `rx_ic` | `rtl/rx/rx_ic.v` | SN 完整性 | `IC_EN`；`IC_FIRST_ANY` |
| `rx_rm` | `rtl/rx/rx_rm.v` | SkewMax 去重 + hist 窗 | `RM_EN` |
| `rx_ip_udp_parse` | `rtl/rx/rx_ip_udp_parse.v` | IP/UDP 解析、交付类型 | — |
| `rx_port_buf` | `rtl/rx/rx_port_buf.v` | RX 端口消息队列 | — |
| `rx_block_pool` | `rtl/rx/rx_block_pool.v` | RX 块 6..15 分配/回收 | — |
| `mgmt_sap_rx` | `rtl/mgmt/mgmt_sap_rx.v` | 管理 SAP 分流 | `SNMP_SAP_PORT`/`TFTP_SAP_PORT` |
| `snmp_lite` | `rtl/mgmt/snmp_lite.v` | SNMP v1 子集 | `SNMP_EN` |
| `a615a_tftp` | `rtl/mgmt/a615a_tftp.v` | TFTP 服务端加载/卸载 | `TFTP_EN`/`LOAD_WORDS` |
| `a615a_fetch_engine` | `rtl/mgmt/a615a_fetch_engine.v` | 主动取件（含 1350 客户端核） | `A615A_EN` |
| `a615a_lur_*` | `rtl/mgmt/a615a_lur_*.v` | LUR 控制文件/编排（子集） | `A615A_EN` |
| `rtc_sync` | `rtl/mgmt/rtc_sync.v` | PPS/FLL | `RTC_EN` |
| `stats_regs` | `rtl/top/stats_regs.v` | 统计页 | `STATS_EN` |

可选链（默认关）：`TX_MESSAGE_CHAIN_BLOCKS=4` 启用 `tx_message_store`/`tx_fragment_*`；`RX_REASM_CHAIN_BLOCKS=5` 启用链式重组。`host_if.v` 为空壳、**未例化**。

---

## 3. 接口

### 3.1 顶层端口（摘自 `rtl/top/AFDX_top.v`）

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `clk` | in | 1 | 系统时钟（仿真默认 125 MHz） |
| `reset` | in | 1 | 异步复位，经 `rst_sync` |
| `tx_data` / `tx_valid` / `tx_ready` | out/out/out | 8/1/1 | 网 A GMII 发送（模板 8 口） |
| `rx_data` / `rx_valid` / `rx_ready` | in/in/in | 8/1/1 | 网 A GMII 接收 |
| `tx_data_b` / `tx_valid_b` / `tx_ready_b` | out/out/out | 8/1/1 | 网 B 发送 |
| `rx_data_b` / `rx_valid_b` / `rx_ready_b` | in/in/in | 8/1/1 | 网 B 接收 |
| `host_cs` / `host_we` / `host_addr` / `host_wdata` | in | 1/1/16/32 | 主机片选/写/字地址/写数据 |
| `host_rdata` / `host_ack` / `host_irq` | out | 32/1/1 | 读数据/应答/中断 |
| `pps_in` / `pps_out` | in/out | 1/1 | PPS |
| `rtc_time_us` | out | 64 | RTC 微秒计数 |
| `dbg_frame_event` | out | 4 | 调试事件（可 tie） |
| `rx_error` / `rx_error_b` | in | 1/1 | PHY RX_ER（`IF_MODE=2` 须驱动） |

**答辩句**：网络公开口 = GMII A/B；主机 = 扩展 `host_*`；与答疑「模块在内部、可加端口」一致。

### 3.2 GMII 时序（`IF_MODE=2`）

```
拍:     0  1  2  3  4  5  6  7  8  9 ...
tx_valid: 1  1  1  1  1  1  1  1  1  1 ...
tx_data:  55 55 55 55 55 55 55 D5 DA .. FCS
          |<- 7×0x55 + SFD ->|<- DA..SN+FCS ->|
帧间 tx_valid=0 至少 IFG_BYTES(=12) 拍；帧内每拍 1 B，valid 连续为 1。
```

RX 对称：自前导起 `rx_valid` 连续 1，下降沿结束帧。证据场：T41（前导/SFD/FCS/IFG/ready 忽略/RX_ER）。

### 3.3 主机总线

- 字地址 `host_addr[15:0]`；数据 32 bit；须等 `host_ack`（存储可多拍）。
- 寄存器页由 `doc/regs.yaml` 定义（附录）；表区/PMEM 基址由 `tools/form_addr.py` 生成、`tools/check_addr.py` 复核。

### 3.4 ready 语义（答疑）

外部 `rx_ready` 可固定 0/1，**不暂停**模式 2 发送；`tx_ready` **不作为**外部采样条件。网络按 `valid=1` 判定。内部 FIFO 仍用 vld/rdy。  
**不能推出：** 板级 PHY 异步跨域或 IO 时序已验证。

---

## 4. TX 通路

顺序：端口缓冲 → BAG 调度 → 帧构建 → SN → 双网复制 → MAC（前导/FCS/IFG）。

| 级 | 行为 | 流水/拍 | 背压 |
|---|---|---|---|
| `tx_port_buf` | 主机写 PMEM + `MSG_WR` 入队 | 描述符握手 1 拍量级 | 池满/队满拒写，置 ERR |
| `tx_vl_scheduler` | `age = cycle + PREPARE − next_tx`；8 路并行，128 VL **16 拍**扫一轮；选 age 最大且 due | 扫描 16 拍；grant/ack | 下游未 ack 则 inflight 占位；`frame_permit` 卡原始 BAG 截止 |
| `tx_frame_builder` | pass1 UDP csum + pass2 出字节 | 与载荷长度成比例；头字段 mux | `vld/rdy` 对 `tx_rm` |
| `tx_sn_gen` | 帧起始取 SN，成功发送后递增 | 与 builder 并行耦合 | — |
| `tx_rm` | A/B 各一份字节流 | 1:1 复制 | 任一侧背压可停 |
| `mac_tx_if` | 7×55+D5、FCS、IFG；`IF_MODE=2` 连续 1 B/拍 | 帧长+8+12 字节时 | 内部 FIFO；公开口忽略外部 ready |

BAG 截止以**线上 MAC 帧起始**为锚；`PREPARE_CYCLES`（顶层按 `IF_MODE`）可提前准备构帧，不缩短合法 BAG 下限（`doc/接口契约.md`）。  
BAG 合法间隔：T27/T34p 等。**不能推出：** 任意 128 VL 同相满载抖动均 ≤500 μs。

---

## 5. RX 通路

顺序：前导剥离 → MAC 校验/入池 →（A 优先串行）查表 → 过滤 → IC → RM → 解析 → 端口交付（SAP 旁路）。

| 级 | 丢弃/拒绝条件 | 计数 |
|---|---|---|
| `gmii_rx_strip` | 前导/SFD 错、过早结束 | 入口丢弃（不入池） |
| `mac_rx_if` | 长度/DMAC/Ethertype/IP/UDP/FCS/`rx_error` | `DROP_CNT_K` 前 8 类（len…crc） |
| `rx_vl_lookup` | 未命中 → 下游 UNCONF | 随 FLT |
| `rx_flt` | UNCONF / VLID / NET / LMAX | `0x0040` unconf、`0x0044` lmax；合计 `DROP_CNT` |
| `rx_ic` | SN 失序/首帧策略失败等；**拒绝不改 PSN** | `0x0048` ic |
| `rx_rm` | 窗内同 SN/hist 命中 → 不 forward | `0x004C` rm；skew 事件另计 |
| 解析/端口 | 类型不符、队满覆盖 | 端口溢出相关 STATUS |

判断链固定：**过滤 → IC → RM**（设计书/工程口径）。T09 accept/reject：`1759` / `4248`。T10：fwd/dup/skew = `56` / `46` / `3`。  
**不能推出：** 任意拓扑下 SkewMax 配置均最优；4096 VL 同时有帧在途已测。

---

## 6. 存储与块所有权

见图 2。

![图2 RX 块所有权](figs/fig2_block_owner.png)

源：`doc/figs/fig2_block_owner.mmd`。

### 6.1 PMEM 预算（默认 `PMEM_KB=32`）

| 池 | 块号 | 每块 | 用途 |
|---|---|---|---|
| TX | 0..5 | 2048 B（512×32-bit） | 主机写、构帧读 |
| RX | 6..15 | 同上 | `mac_rx_if` 分配；过滤/IC/RM/交付路径释放 |

主机字地址形如 `0x8800 + block×512 + word`（与 `tools/form_addr.py` 一致）。默认单块消息；`TX_MESSAGE_CHAIN_BLOCKS=4` 时一消息最多 4 块（仍用 TX 池 0..5）。

### 6.2 所有权不变量

块 6..15 每一拍只在 `free_map` 或唯一持有者中；同拍单口归还；归还下一拍才回空闲。释放优先级（顶层 `free_pipe`）：RM 重复 > IC 拒绝 > FLT 拒绝 > drain。  
**不能推出：** 形式化块守恒已全覆盖（BMC 仅局部）；8 KiB 链式路径为默认生产配置。

---

## 7. 管理面

### 7.1 SNMP（`snmp_lite`）

- **版本**：仅 SNMPv1（version≠0 或 community≠`public` → 静默丢弃）。无 TRAP、无 GETBULK、无 v3。
- **操作**：GET / GETNEXT / SET。
- **MIB**（企业前缀 `1.3.6.1.4.1.4444.1`）：
  - 组 1 标量：`afdxEsDescr`、`afdxEsUpTime`、`afdxNumTxVl`、`afdxNumRxVl`、`afdxEsRxMaxJitUs`、`afdxEsCtl`(RW)、`afdxEsDropCnt`、`afdxEsBufUtil`；
  - 组 2：`STATS_BLOCK` 只读字；
  - 另有按 VL 索引的只读实例（模块头注释）。

### 7.2 615A / TFTP

见图 3。答疑：**非硬要求**；本仓交 TFTP 子集证据。

![图3 TFTP/615A 子集](figs/fig3_tftp_615a.png)

源：`doc/figs/fig3_tftp_615a.mmd`。

- 服务端：`a615a_tftp`，512 B 块、octet、无 OACK；WRQ 加载进独立 `LOAD` 区。
- 客户端核：`a615a_tftp_client_1350`（经 fetch）；初始化 9 B 源见契约。
- LUR：控制文件 TFTP 接收 + 受限清单取件；完整 615A/665 **OPEN**，不宣称认证。

### 7.3 RTC

`rtc_sync`：PPS 输入驯服 FLL；`rtc_time_us` 可读；失步判据与 `RTC_SYNC_TO_US` 相关。T16a：`True`。报文网络授时口顶层仍接 0——**不宣称**网络授时已实现。

---

## 8. 关键算法

### 8.1 BAG 与错相

- 判决：`due = valid ∧ ¬inflight ∧ port_ready ∧ ¬age[31]`；选最大 age（最早到期）。
- 发送成功后 `next_tx ← frame_start_cycle + bag_cycles`。
- **错相（D10）**：多 VL 同相会使队尾排队下界过大；由配置/激励在提交与首帧相位上错开（TB 如 T05b），调度器本身按到期选路。硬件无单独「相位寄存器」字段时，错相体现在各 VL 的 `next_tx` 初值与消息到达时刻。

### 8.2 哈希查表（双表 4-way 比较）

流水：IDLE 捕获 → `HASH_ADD` → `HASH_MUL` → `RAM_READ` → `COMPARE`（与 `sw/golden/hash_seed.py` 一致）。

```
sum0 = (vlid + seed0 + 0x9E37)[15:0]
sum1 = (vlid + seed1 + 0x1F5B)[15:0]
mixed = sum ^ (sum >> 7)
product0 = mixed0 * 0x9E37 ; product1 = mixed1 * 0x45D9
hash = product ^ (product >> 9)   → 桶号取低 HASH_BITS
```

每表 2-way，两表并行读，共 **4** 次 `valid_match`；命中取对应 `idx[11:0]`。冲突由**离线摆放**解决（换种子/重排映像）；运行期无探测驱逐。主机提交 `HASH_IMAGE` 后才允许 `RX_EN`。

### 8.3 RM 与 SkewMax

- `Skew = 4 << skewmax_exp` μs（exp 0..15 → 4 μs..131 ms）。
- 窗内同 SN 或 hist 命中 → 丢弃副本；窗外同 SN → forward + skew 事件。
- 表项含 `seen` 与 8-deep hist，缓解「只记最后 SN」漏删旧副本。

### 8.4 IC 的 SN 判据

每 VL×网一份 PSN。接受：SN=0（复位）；PSN=0 时 SN=1 或 `IC_FIRST_ANY`；SN=PSN+1；SN=PSN+2（丢 1 帧）。否则拒绝且**不写** PSN。

### 8.5 时延界（规范式 + 代入）

规范（L158 / 摘录）：  
`J = min(40 + Σ_j (20+Lmax_j)·8/Nbw , 500)` μs；  
`MAX_Latency_i ≤ BAG_i + Max_jitter + Technological_Latency`。

工具：`tools/afdx_delay_bound.py`。  
**代入例（T13w 注释代数，Nbw=100 Mbps）**：3×1518 + 3×356 →  
`J = 40 + (3×1538+3×376)×0.08 = 499.36` μs（与自检一致）。  
T89 本场景 40+Σ 实测键：`141` μs。工程总时延（非官方 SFD）例：T13 worst `243416` ns；T13w `453752` ns。  
**不能推出：** 已按官方 SFD→SFD 验收 2 ms；J 式等于仿真线速 1 Gbps 的介质定义。

---

## 9. 时钟、复位与参数

| 项 | 说明 |
|---|---|
| 时钟 | 单域 `clk`；仿真 `CLK_FREQ_HZ=125_000_000`（与 GMII 8 bit×125 MHz 匹配）。**Fmax 板级见 §10，I** |
| 复位 | `reset` → `rst_sync`；`INIT_DONE` 前禁止开流 |

### 顶层参数表（默认 / 可选 / 证据 T）

| 参数 | 默认 | 可选/备注 | 对应 T（代表） |
|---|---|---|---|
| `NUM_TX_VL` | 128 | chipsim 缩配 | T34p / T42 |
| `NUM_RX_VL` | 4096 | 缩配 | T08 / T10 |
| `NUM_PORTS` | 256 | — | T11 |
| `PMEM_KB` | 32 | 未参数化减池前勿砍 | — |
| `IF_MODE` | 2 | 0/1 历史回归 | T41 / T42 / T89 |
| `FCS_MODE` | 2 | — | T41 |
| `DUAL_NET_EN` | 1 | — | T10 |
| `IC_EN` / `RM_EN` | 1 | CTL 亦可关 | T09 / T10 |
| `SNMP_EN` / `TFTP_EN` / `RTC_EN` | 1/1/1 | CTL 位 | T43 / T16a |
| `HASH_BUCKETS` | 2048 | chipsim 缩 | T12f |
| `LOAD_WORDS` | 8192 | TFTP_EN=0 不例化 | T43 |
| `A615A_EN` | 1 | 0 关取件 | 615A 子集 TB |
| `RX_REASM_CHAIN_BLOCKS` | 1 | 5=8 KiB 链 | 可选场 |
| `TX_MESSAGE_CHAIN_BLOCKS` | 1 | 4=多块 TX | T82 等 |
| `IFG_BYTES` | 12 | — | T41 |
| `CLK_FREQ_HZ` | 125e6 | — | 仿真拍 |

---

## 10. 综合与实现

代理器件（Quartus/eLinx 路径，非板卡签核）。数字唯一来源：冻结 metrics。

| 项 | 值 | 等级 |
|---|---|---|
| cells | 106241 | P |
| altsyncram | 507 | P |
| post-fit Fmax (MHz) | 41.66 | **I** |
| Setup (ns) | -16.005 | **I** |
| 门级 VO sha256 | 2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46 | P（切片） |
| 门级 T88b S1/S2/S3 | PASS / PASS / PASS | P（切片） |

**为何约 41.66 MHz：** 约束目标周期 8 ns（125 MHz）；post-fit 最差 setup slack = `-16.005` ns → 受限 Fmax = `41.66` MHz。  
**关键路径（STA）：** `tx_vl_scheduler:u_sched|group_idx[3]` → `tx_vl_scheduler:u_sched|go_viol`（Slow 900mV 85C；数据延迟约 23.6 ns）。报告：`out/p8_clean_20261022_191733/out/p8_fit_sta_20261022_221328/sta/post_fit_setup.rpt`（汇总亦见同目录 `post_fit_fmax.rpt`、`logs/sta_detail.log`）。  
**不能推出：** Fmax 已签到线速 125 MHz；GUI LUT；板卡/IO 时序闭合；门级 full 回归（仅 T88b S1–S3）。

功能全量：`144`/`144`（`True`）。  
**不能推出：** 历史 140/140 与本冻结 N 可拼接；变异/lint 本轮已重测（冻结键可为 null）。

---

## 11. 设计取舍与已知边界

| 做了什么 | 没做什么 | 为什么 | 证据 |
|---|---|---|---|
| 自研双网 MAC + PHY GMII | 强制 eLinx Tri_Mode×2 | 答疑后期无强制 MAC IP | 契约；T41/T42 |
| 模板 8 口作 GMII，扩展 host/PPS/B 网 | 把模板当纯应用口 | 可加端口 + GMII=PHY | 对照报告 §3.3 |
| SNMP v1 GET/GETNEXT/SET | TRAP、v2c/v3、完整 MIB | 子集可测；G4 不加 TRAP | `snmp_lite`；T43 |
| TFTP 512 B 子集 + 部分 615A 编排 | 完整 615A/665 认证 | 答疑非硬要求 | 图3；披露边界 |
| IC→RM 顺序、SkewMax hist | 任意网络偏斜下最优 | 规范窗口 + 工程可配 | T10 |
| 仿真 125 MHz 功能全量 | post-fit 125 MHz 闭合 | STA 关键在调度器扫描 | §10 metrics I |
| 门级 T88b 三步 | 门级全量 144 | 实例/墙钟；答疑允许后仿切片 | gate metrics |
| 自建 TB + 独立 Python/golden | 官方 A664 实验室套件 | 评测用参赛者 TB | 尺子；manifest |
| 默认单块消息 | 默认开 8 KiB 分片 | G3：参数化可选 | `TX/RX_*_CHAIN_BLOCKS` |
| 单 ES 回环 + 默认 CTL（SAP 开，口 6/7） | 同芯片上 128 TX + 128 RX 全配 | 端口预算 `NUM_PORTS=256 = 128 TX + 126 RX + 2 SAP`；VL126/127 不配 RX 表则 FLT unconf | T90 r6 P；契约 L95 |
| `tx_vl_scheduler` 配置后使能 | 假定 `next_tx[]`/`bag_arr[]` 上电即合法 | 两数组**不随复位清零**；VL 须先配置再使能 | 配置时序：T04 / T05c；形式侧见 `bag_bmc40_CE_ANALYSIS.md` (b) |

---

## 12. 附录

### 12.1 寄存器

单一来源：`doc/regs.yaml`。生成/校验：`tools/gen_regs.py`（默认校验；`--emit`/`--write` 出头文件或回写设计书附录）。提交包附 YAML；下列为寄存器页摘要（完整位域以 YAML 为准）。

| 名称 | 字地址 | 访问 | 说明 |
|---|---|---|---|
| ID | 0x0000 | ro | `[31:16]=0xAF07`，`[15:0]=NUM_RX_VL` |
| REV | 0x0004 | ro | 版本 |
| CTL | 0x0008 | rw | TX/RX/IC/RM/SNMP/TFTP/RTC/CFG 等 |
| STATUS | 0x000C | ro | INIT_DONE、BUSY、CFG_OVER 等 |
| ERR | 0x0010 | w1c | ACC/BAG_OVF/PMEM_EXH 等 |
| INT_ENABLE / INT_STATUS | 0x0014 / 0x0018 | rw / w1c | 中断 |
| DROP_CNT | 0x001C | ro | 合计丢弃 |
| DROP_CNT_K | 0x0020..0x004C | ro | 12 类原因 |
| TB_CNT_US(_HI) | 0x0050 / 0x0054 | ro | 时基 |
| CFG_SUM / CFG_ERR | 0x0058 / 0x005C | ro | Q20 份额和与超额 |
| SMAC_CFG / IP_CFG | 0x0060 / 0x0064 | rw | 源 MAC 字段 / 本端 IP |
| UDP_CFG | 0x0070 | rw | UDP csum、`IC_FIRST_ANY` 等 |
| HASH_SEED0/1 / HASH_IMAGE | 0x0078 / 0x007C / 0x0080 | rw | 哈希映像提交 |
| DBG_CTRL | 0x00FC | rw | 调试注入 |
| STATS_BLOCK | 0x0100.. | ro | 统计页 |

表区（TX_VL_TAB、TX_Q20_SHARE、RX_VL_CFG、RX_HASH、PORT_TAB、VL_STATS、PMEM、LOAD）基址见 `tools/form_addr.py` 产出与设计书 §7.14，不在 YAML 手填。

### 12.2 VL 表项格式

**TX_VL_TAB**（每 VL 5 字入 RAM；动态 `next_tx` 在调度器阵列）：

| 字 | 位域 |
|---|---|
| w0 | `[31] valid`，`[23:12] lmax`（含 FCS），`[11:4] bag_exp`，`[3:0] net_mode` 等 |
| w1 | `[31:8] bag_us`，TOS/ip_id_mode |
| w2 | UDP sport/dport |
| w3 | `dst_ip` |
| w4 | `port_base` / `port_mask` / tag |

独立 **Q20 份额**表：`0x0480+VL`，`[20:0]`。

**RX_VL_CFG**（每项 2 字）：

| 字 | 位域 |
|---|---|
| w0 | `valid`，`rm_en`，`net_mode`，`skewmax_exp`，`port_base`，`lmax` |
| w1 | `expect_vl` |

**RX_HASH** way 字：`{pad[2:0], valid, vlid[15:0], idx[11:0]}`；地址 `base + table×4096 + bucket×2 + way`。

---

*文档版本随冻结 `225cd91be4f6a4b332db1674b44761bca367bd67`；指标数字不得手填，须经 metrics 渲染。*
