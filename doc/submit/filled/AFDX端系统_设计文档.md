<!-- rendered from AFDX端系统_设计文档.md using C:/Workspace/diansai/out/p9_freeze_dfac58a/metrics.json commit=098efc98d379c29b113d52dfccb24cdf36be7391 -->

# AFDX 端系统设计文档（提交版）

> 数字一律 metrics 锚点（键见 `out/p9_freeze_dfac58a/metrics.json`），定稿由 `tools/render_doc_metrics.py` 填充。面向评委阅读；开发编年史不写入正文。  
> 冻结：`098efc98d379c29b113d52dfccb24cdf36be7391` · 全量 `145`/`145`。  
> 结论附适用边界：可核对测试编号的写实测；仅有实现无专用测试的注明边界；未测的不写进成果句。

---

## 1. 赛题与范围

实现 AFDX（ARINC 664 Part 7）端系统（ES）。评分项对应：代码及仿真环境、设计文档、测试报告、技术指标（选题指南）。

### 1.1 五类功能

| # | 功能 | 本设计落点 | 代表 T |
|---|---|---|---|
| 1 | 发送调度与流量整形 | `tx_port_buf` → `tx_vl_scheduler`（BAG）→ `tx_frame_builder`/`tx_sn_gen` → `tx_rm` → `mac_tx_if` | T04 / T05b / T27 / T34p |
| 2 | 接收过滤与 IC/RM | `gmii_rx_strip` → `mac_rx_if` → `rx_vl_lookup` → `rx_flt` → `rx_ic` → `rx_rm` → 解析/端口 | T08* / T09 / T10 |
| 3 | 主机接口与存储 | `host_*` 前门译码（在 `AFDX_top`）；PMEM 块池；端口消息队列 | T01 / T11 / T22 |
| 4 | 管理面 SNMP / 615A·TFTP | `snmp_lite`；`a615a_tftp` / fetch / LUR 子集 | T43 / T27；演示场 T88 |
| 5 | 时间同步 RTC/PPS | `rtc_sync` + `timebase`；`pps_in`/`pps_out`/`rtc_time_us` | T16a |

### 1.2 四项指标（口径分列）

| 指标 | 官方（S）口径 | 工程计量（本仓） | 等级提示 |
|---|---|---|---|
| 吞吐 | 有效载荷 ≥100 Mbps；RX 侧 A/B **去重后只计一次**；须千兆 GMII 拍 | T42 等场景按有效载荷；A/B 各自 TX ≥100 为工程加严 | 场景内可核对；128 VL 同时活动见 T90 |
| 时延 | 官方字面：单帧 GMII **SFD→同帧 SFD** ≤2 ms（单 ES 回环无网络段→**I**）；跨多 BAG 多帧不受此限 | **ES 贡献**：commit→TX SFD、RX SFD→host、`es_total`（T89）；另有工程 commit→eof / sof→host（T42：`16.08` / `12.936` μs） | 官方字面 SFD→SFD 不在单 ES 验收范围 |
| 抖动 | 同 VL 多帧端到端时延 **max−min** | 同统计量。T42：`5.016` μs；T89：`72` ns，本场景 40+Σ=`141` μs | 「几十微秒」无硬性官方上限数字 |
| 规模能力 | 128 TX / 4096 RX 为能力声明；后仿可切片 | 默认参数满配综合；门级为 T88b 切片 | 门级全量矩阵不在本作品证据范围 |

### 1.3 协议子集与答疑依据

- **物理口**：GMII（PHY）；MAC 可用 eLinx IP，**无强制**——本仓自研 `mac_tx_if`/`mac_rx_if`（赛方答疑确认；出处见附录 A）。
- **ready**：可不用；`tx_valid=1`/`rx_valid=1` 即有效，不要求 valid∧ready（原文 L75、L111–119；契约 §2）。
- **615A/665**：交付物为 AFDX 协议实现；615A 数据加载及 665 解析**非硬要求**（赛方答疑：非硬性要求）。本仓披露现测 TFTP 子集与边界。
- **SNMP / RTC**：参考规范；本仓 SNMP **v1 only**（GET/GETNEXT/SET），RTC 接 PPS/FLL。
- **模板口答辩句**：网络公开口 = GMII A/B；主机 = 扩展 `host_*`；与答疑「模块在内部、可加端口」一致（出处见附录 A）。

本作品范围之外还包括：完整 A664 认证、交换机、对端真 ES 闭环、完整 615A 认证、官方 SFD→SFD 已 P、官方 2 ms 实测 0 ns、128 VL 任意配置均达标、4096 路同时收、门级全量、时序签核/板级验证（赛题未要求）。

---

## 2. 总体架构

数据流见图 1。

![图1 总体数据流](figs/fig1_dataflow.png)

源：`doc/figs/fig1_dataflow.mmd`（已渲 PNG）。默认：`IF_MODE=2`、`DUAL_NET_EN=1`、`NUM_TX_VL=128`、`NUM_RX_VL=4096`、`CLK_FREQ_HZ=125_000_000`。单时钟参数用于功能仿真（与 GMII 速率匹配），非板级结论。

### 2.1 模块清单（生产主链）

| 模块 | 文件 | 职责 | 关键参数 |
|---|---|---|---|
| `AFDX_top` | `rtl/top/AFDX_top.v` | 顶层；主机译码；流水互联 | 见 §10 |
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
| `rx_vl_lookup` | `rtl/rx/rx_vl_lookup.v` | 双表×2-way（共 4-way）哈希查 VL 索引 | `HASH_BUCKETS`/`NUM_RX_VL` |
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

### 2.2 关键通路要点

#### 2.2.3 块池释放（`free_pipe`）

RX 块 6..15 由 `rx_block_pool` 分配；顶层 **唯一** `free_pipe` 口按拍互斥归还（`AFDX_top.v` L1752–L1753、L1786–L1787、L2106–L2110）：

**优先级：** RM 输出（`rm_dup_fire`） > IC 拒绝（`ic_rej_fire`） > FLT 拒绝（`flt_free`） > drain（`lookup_drain`）。

未获准占用 `free_pipe` 的上游 **不是一拍脉冲**：用 valid/ready 反压保持到握手，释放请求不会因仲裁落选而丢失。关键 ready 门控（`AFDX_top.v`）：

| 源 | ready / 门控表达式 | 行号 |
|---|---|---|
| IC 出口 | `ic_out_ready = ic_out_accept ? rm_in_ready : !rm_out_vld` | L1794 |
| FLT 出口 | `flt_out_ready = !ic_out_vld && (flt_to_ic ? ic_in_ready : flt_to_rm ? rm_in_ready : !rm_out_vld)` | L1797–L1799 |
| RM 出口 | `rm_out_ready = rm_out_fwd ? (reasm_en ? reasm_in_ready : prs_in_ready) : 1'b1` | L2010 |
| 查表出口 | `out_ready` ← `flt_in_ready`（例化） | L1770 |

证据：`formal/` 块池有界 BMC（`ENV_STATUS` 块 2b，等级 **I**）；功能回环 T22 族。  
**适用边界：** 有界 BMC ≠ 无限深度证明；不宣称任意拓扑下块永不泄漏。

---

## 3. 创新点与工程特色

本设计的特色体现在可复核的工程取舍，而非空泛的先进性宣称。每条按同一结构说明：做了什么、与常规做法相比、实现位置、证据、文献依据、本作品贡献、适用边界。文献编号见文末参考文献；采用方式分为「规范/标准原样采用（设计依据）」「改造到本 FPGA 实现」「多文献方法组合」。

### 3.1 全硬件管理面

- **做了什么：** SNMP v1 子集、TFTP/615A 加卸载子集与 RTC/PPS 驯服均在 FPGA 内完成，不依赖片上软核或外挂协议栈。
- **与常规做法相比：** 常见方案把管理面放在 CPU/软核（如 LwIP）或主机侧守护进程。
- **实现位置：** `rtl/mgmt/snmp_lite.v`、`a615a_tftp.v` / `a615a_fetch_engine.v` / `a615a_lur_*.v`、`rtc_sync.v`；经 `mgmt_sap_rx` 与数据面分流（`AFDX_top`）。
- **证据：** T88 演示步骤 5–7（`t88_steps_ok`=`8`，`t88_pass`=`True`）；T16a `t16a_pass`=`True`（FLL 最大绝对误差 `t16a_fll_max_abs_err_us`=`1` μs）。
- **文献依据：** L116 提供 SNMP SET PDU 语义（规范原样采用）；L074、L072 描述航电侧 SNMP/615A 软件管理范围，用于划定本作品子集边界。
- **本作品贡献：** 将上述子集收进同一 FPGA、与数据面旁路共存，并以 T88/T16a 自建测试闭环验证。
- **适用边界：** 覆盖已实现的 SNMP v1 / TFTP·615A 子集与 RTC 驯服；不含完整协议认证，也不含对端真装载设备或网络授时口闭环（顶层网络授时仍接 0）。

### 3.2 4096 RX 哈希双表 4-way 流水查表

- **做了什么：** 在 `NUM_RX_VL=4096` 下，VLID→索引用双表并行、每表 2-way，COMPARE 共 4 路匹配；流水为 HASH_ADD→HASH_MUL→RAM_READ→COMPARE→OUTPUT。
- **与常规做法相比：** 见下表（本方案周期与 RAM 映射可复核；线性/CAM 为估算）。
- **实现位置：** `rtl/rx/rx_vl_lookup.v`（`HASH_BUCKETS=2048`）；对照黄金 `sw/golden/hash_seed.py`；算法摘要见 §9.2。
- **查表时延（三个量，勿混）：**
  1. **无反压时结果延迟：** 输入接受后 **5** 个时钟边沿完成首次输出握手（`rx_vl_lookup.v` L8）。
  2. **下游反压下的交付时间：** 卡在 `OUTPUT` 直至 `out_ready`（L180–182），**不固定**。
  3. **两次查询最小间隔：** `in_ready` 仅当 `state==IDLE`（L133–134）；**不是每拍可接收一次**。无反压时相邻两次接受间隔为 **6** 拍（L8 五拍至握手 + L180–182 回 IDLE 后下一拍才 `in_ready`）。
- **方案对比：**

| 方案 | 查找周期 | 资源 | 配置限制 |
|---|---|---|---|
| 本方案（双表 4-way 流水） | 无反压首次握手 **5** 拍（RTL L8）；最小再接受间隔 **6** 拍（RTL L8+L180–182+L133–134） | eLinx 综合分层：`elinx/gui_afdx/AFDX_top.runs/synth_1/AFDX_top.map.rpt`（页眉 eLinx 64-Bit Version 3.0）§7 Resource Utilization by Entity，`rx_vl_lookup:u_rxlookup` 逻辑 cells **604**；其子 `table0/1way0/1` 共 **4** 个 `altsyncram`（各 65536 bit，合计 memory bits 262144） | 配置期离线摆放；运行期无插入/驱逐；须先装 `HASH_IMAGE` 再 `RX_EN` |
| 线性扫描（估算） | 最坏 **4096** 拍/次 | 约 1 路比较器 + 计数器（估算） | 表越大延迟线性涨 |
| 全并联 CAM（估算） | **1** 拍匹配（理想） | 4096×(16+12+1)≈**118784** bit 内容寻址（估算） | 面积/布线通常不可接受 |

- **证据：** 冻结 Questa 全量：**T12c** `lookups=100000`（hits=61638 / misses=38362，N=4096，buckets=2048，`ways=1111`）；**T12f**；规模相关 `t35p_pass`=`True`、`t34p_pass`=`True`。
- **文献依据：** L109–L113（C 级二手摘要）给出多 way / FPGA 查表可行性。
- **本作品贡献：** 动态 cuckoo 改为离线摆放 + 固定深度流水比较；满配查表由 T12c/T12f 自证。
- **适用边界：** 验表项与查表正确性，不是同时收满 4096 VL；**禁止**写成「任何情况下固定拍数交付」。

### 3.3 共享块池与所有权不变量

- **做了什么：** TX/RX 共用 PMEM；RX 块 6..15 由 `rx_block_pool` 分配/回收；顶层 `free_pipe` **单口**按优先级互斥归还（详 §2.2.3），维持每块唯一持有者；未获准来源用 valid/ready 反压保持到握手。
- **与常规做法相比：** 常见为每端口或每 VL 独立缓冲，面积大且回收路径分散。
- **实现位置：** `rtl/rx/rx_block_pool.v`；释放优先级与 ready 门控见 `AFDX_top.v` L1786–L1800、L2010、L2106–L2110；所有权关系见 §7。
- **证据：** T22 族；全量 `full_pass`/`full_n`=`145`/`145`；综合 `cells`/`altsyncram`=`106241`/`507`；块池有界 BMC（**I**，`formal/ENV_STATUS` 块 2b）。
- **文献依据：** L010、L044；L121–L123（多文献组合）。
- **本作品贡献：** 固定 16 块 PMEM + `free_pipe` 优先级与反压保持。
- **适用边界：** 默认单块消息路径；块守恒形式证明仅为有界局部；BAG 形式结论见 `bmc_bag_grade`=`F`（**F**，与块池 BMC 分列）。

### 3.4 时延可预算（界 vs 实测）与 BAG 预算

- **做了什么：** 用规范抖动/时延关系给出场景上界，再用测试台实测 ES 贡献（commit→TX SFD、RX SFD→host 等）对照；BAG/份额超额由配置判决拒收，界与实测分列。
- **与常规做法相比：** 常见只报平均时延或单次示波器读数，缺少可复核的代数对照。
- **实现位置：** `tools/afdx_delay_bound.py`、`tools/bag_budget.py`；调度在 `tx_vl_scheduler.v`；计量场 T05c／T13／T13w／T42／T89。
- **证据：** 界代入见 §9.5；T89 `t89_es_total_max_ns`=`5976`、`t89_bound_40sig_us`=`141`；T42 `t42_tx_commit_to_eof_max_us`/`t42_rx_sof_to_host_max_us`=`16.08`/`12.936`；T13/T13w worst `t13_worst_total_ns`/`t13w_worst_total_ns`=`243416`/`453752`。
- **文献依据：** L158（2005）§3.2.4.3 抖动双式与 BAG 语义作为规范依据（引用标版本）；L096、L104 提供网络级时延上界与 VL/BAG 配置方法学出处；本工程判决式以设计书与工具脚本为准。
- **本作品贡献：** 将网络级分析方法收成 **ES 内** commit/SFD/host 实测键，并与代数界分列；BAG 预算落到 T05c 拒载与 Q20 份额。
- **适用边界：** 结论限于单 ES 仿真场景，不含交换机与官方字面 SFD→同帧 SFD 端到端验收；网络级论文数字不替代本 ES 实测。

### 3.5 验证方法学与 IC/RM 窗口结构

- **做了什么：** 同一结论可追溯到独立黄金模型、双仿真器一致、变异分列、形式 BMC 边界、单一 `metrics.json` 与 P/I/F 分级；IC/RM 判据与抗重放历史窗可复核。
- **与常规做法相比：** 常见仅依赖自研测试台一次通过，或把覆盖率/BMC 空真表述为「已证明」。
- **实现位置：** `sw/golden/`；`sim/tests.manifest` 与 Questa/ModelSim SE；新增变异汇总；`formal/` BAG BMC；`rx_ic`／`rx_rm`（hist／SkewMax）。
- **证据：** `dual_sim_match`=`145`（`full_pass`=`145`，`se_full_pass`=`145`）；新增变异 `c3_mutants_killed`/`c3_mutants_total`=`23`/`28`（历史 57/57 另列）；`bmc_bag_grade`=`F`；T09/T10 `t09_accept`/`t09_reject`/`t10_fwd`/`t10_dup`/`t10_skew`=`1759`/`4248`/`56`/`46`/`3`；覆盖率见测试报告 §7.1。
- **文献依据：** L158 给出 IC/RM 窗口与 First-Valid 语义（规范依据）；L137（RFC 4303 ESP 抗重放滑动窗口）提供「最高序列＋窗口」的结构借鉴；L071／L087、L117、L153、L136 分别支撑自动化测试、变异、覆盖率表述与小模块形式验证方法（多文献组合）。
- **本作品贡献：** 将 L158 规则落实到 `rx_ic`/`rx_rm`，把 L137 结构借鉴落到工程 hist／SkewMax（冲突时以 L158 为准）；验证侧用自建清单、双仿真器、新增变异与 BMC 边界分列报告。
- **适用边界：** PASS 仅覆盖对应测试标题；不是认证实验室结论；覆盖率统一表见测试报告 §7.1；L137 不是 A664 强制条款；本作品不声明任何 DAL／DO-254 等级。
- **验证剩余项（同步官方模板 §3.3 / `doc/学习/08_验证剩余项一页.md`）：** 新增变异存活 5 体分类与 BAG BMC（cover 可达 / bmc20 空真 / bmc40 反例；环境约束不完整最可能，真实反例未排除）见该页；**不影响**已冻结仿真证据（`full_pass`/`dual_sim_match`）。

### 3.6 `IF_MODE` 三模式复用

- **做了什么：** 同一套 TX/RX MAC 与上层协议，用参数 `IF_MODE=0/1/2` 切换历史口与公开 GMII PHY 字节节拍，避免维护三套顶层。
- **与常规做法相比：** 常见为板级与仿真各复制一份 MAC 或顶层。
- **实现位置：** `rtl/tx/mac_tx_if.v`、`rtl/rx/mac_rx_if.v`、`tx_pace.v`；顶层参数与 `PREPARE_CYCLES`（`AFDX_top.v`）。
- **证据：** T41（GMII PHY 检查）／T42（吞吐与工程时延，`t42_tx_a_mbps`=`131.072`）／T89（`t89_pass`=`True`）；提交默认 `IF_MODE=2`。
- **文献依据：** L001 提供 ES／GMII 参考分层；L088、L089 提供以太网口与 FPGA 接口时序方法。赛题公开口为 GMII。
- **本作品贡献：** 以单一 RTL 参数切换三模式，公开交付默认 `IF_MODE=2`，历史模式保留回归。
- **适用边界：** 未做板级 PHY 异步跨域或 IO 签核；不同 `IF_MODE` 的指标分列报告，不混写成同一条现行数字。

---

## 4. 接口

### 4.1 顶层端口（摘自 `rtl/top/AFDX_top.v`）

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

### 4.2 GMII 时序（`IF_MODE=2`）

```
拍:     0  1  2  3  4  5  6  7  8  9 ...
tx_valid: 1  1  1  1  1  1  1  1  1  1 ...
tx_data:  55 55 55 55 55 55 55 D5 DA .. FCS
          |<- 7×0x55 + SFD ->|<- DA..SN+FCS ->|
帧间 tx_valid=0 至少 IFG_BYTES(=12) 拍；帧内每拍 1 B，valid 连续为 1。
```

RX 对称：自前导起 `rx_valid` 连续 1，下降沿结束帧。证据场：T41（前导/SFD/FCS/IFG/ready 忽略/RX_ER）。

### 4.3 主机总线

- 字地址 `host_addr[15:0]`；数据 32 bit；须等 `host_ack`（存储可多拍）。
- 寄存器页由 `doc/regs.yaml` 定义（附录）；表区/PMEM 基址由 `tools/form_addr.py` 生成、`tools/check_addr.py` 复核。

### 4.4 ready 语义（答疑）

外部 `rx_ready` 可固定 0/1，**不暂停**模式 2 发送；`tx_ready` **不作为**外部采样条件。网络按 `valid=1` 判定。内部 FIFO 仍用 vld/rdy。  
**适用边界：** 板级 PHY 异步跨域或 IO 时序已验证。

---

## 5. TX 通路

顺序：端口缓冲 → BAG 调度 → 帧构建 → SN → 双网复制 → MAC（前导/FCS/IFG）。

| 级 | 行为 | 流水/拍 | 背压 |
|---|---|---|---|
| `tx_port_buf` | 主机写 PMEM + `MSG_WR` 入队 | 描述符握手 1 拍量级 | 池满/队满拒写，置 ERR |
| `tx_vl_scheduler` | `age = cycle + PREPARE − next_tx`；8 路并行，128 VL **16 拍**扫一轮；选 age 最大且 due；`pop` 时 `next_tx ← cycle_count + BAG`（L207，非 `+=`） | 扫描 16 拍；grant/ack | 下游未 ack 则 inflight 占位；`frame_permit` 卡原始 BAG 截止 |
| `tx_frame_builder` | pass1 UDP csum + pass2 出字节 | 与载荷长度成比例；头字段 mux | `vld/rdy` 对 `tx_rm` |
| `tx_sn_gen` | 帧起始取 SN，成功发送后递增 | 与 builder 并行耦合 | — |
| `tx_rm` | A/B 各一份字节流 | 1:1 复制 | 任一侧背压可停 |
| `mac_tx_if` | 7×55+D5、FCS、IFG；`IF_MODE=2` 连续 1 B/拍 | 帧长+8+12 字节时 | 内部 FIFO；公开口忽略外部 ready |

BAG 截止以**线上 MAC 帧起始**为锚；`PREPARE_CYCLES`（顶层按 `IF_MODE`）可提前准备构帧，不缩短合法 BAG 下限（`doc/接口契约.md`）。  
BAG 合法间隔：T27/T34p 等。**适用边界：** 任意 128 VL 同相满载抖动均 ≤500 μs。

---

## 6. RX 通路

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
**适用边界：** 任意拓扑下 SkewMax 配置均最优；4096 VL 同时有帧在途已测。

---

## 7. 存储与块所有权

见图 2。

![图2 RX 块所有权](figs/fig2_block_owner.png)

源：`doc/figs/fig2_block_owner.mmd`。

### 7.1 PMEM 预算（默认 `PMEM_KB=32`）

| 池 | 块号 | 每块 | 用途 |
|---|---|---|---|
| TX | 0..5 | 2048 B（512×32-bit） | 主机写、构帧读 |
| RX | 6..15 | 同上 | `mac_rx_if` 分配；过滤/IC/RM/交付路径释放 |

主机字地址形如 `0x8800 + block×512 + word`（与 `tools/form_addr.py` 一致）。默认单块消息；`TX_MESSAGE_CHAIN_BLOCKS=4` 时一消息最多 4 块（仍用 TX 池 0..5）。

### 7.2 所有权不变量

块 6..15 每一拍只在 `free_map` 或唯一持有者中；同拍 **单口** `free_pipe` 归还；归还下一拍才回空闲。  
释放优先级（`AFDX_top.v` L1786、L2106–L2110）：**RM 输出 > IC 拒绝 > FLT 拒绝 > drain**。未获准来源经 valid/ready 反压保持到握手（L1794、L1797–L1799、L2010），不是一拍脉冲，不会因仲裁落选丢失。详 §2.2.3。  
证据：块池有界 BMC（**I**）；T22 族。  
**适用边界：** 有界 BMC ≠ 无限深度；8 KiB 链式路径非默认生产配置。

---

## 8. 管理面

### 8.1 SNMP（`snmp_lite`）

- **版本**：仅 SNMPv1（version≠0 或 community≠`public` → 静默丢弃）。无 TRAP、无 GETBULK、无 v3。
- **操作**：GET / GETNEXT / SET。
- **MIB**（企业前缀 `1.3.6.1.4.1.4444.1`）：
  - 组 1 标量：`afdxEsDescr`、`afdxEsUpTime`、`afdxNumTxVl`、`afdxNumRxVl`、`afdxEsRxMaxJitUs`、`afdxEsCtl`(RW)、`afdxEsDropCnt`、`afdxEsBufUtil`；
  - 组 2：`STATS_BLOCK` 只读字；
  - 另有按 VL 索引的只读实例（模块头注释）。

### 8.2 615A / TFTP

见图 3。答疑：**非硬要求**；本仓交 TFTP 子集证据。

![图3 TFTP/615A 子集](figs/fig3_tftp_615a.png)

源：`doc/figs/fig3_tftp_615a.mmd`。

- 服务端：`a615a_tftp`，512 B 块、octet、无 OACK；WRQ 加载进独立 `LOAD` 区。
- 客户端核：`a615a_tftp_client_1350`（经 fetch）；初始化 9 B 源见契约。
- LUR：控制文件 TFTP 接收 + 受限清单取件；完整 615A/665 认证不在本作品交付范围。

### 8.3 RTC

`rtc_sync`：PPS 输入驯服 FLL；`rtc_time_us` 可读；失步判据与 `RTC_SYNC_TO_US` 相关。T16a：`True`。报文网络授时口顶层仍接 0——**不宣称**网络授时已实现。

---

## 9. 关键算法

### 9.1 BAG 与错相

- 判决：`due = valid ∧ ¬inflight ∧ port_ready ∧ ¬age[31]`；选最大 age（最早到期）。
- **锚定（禁止写成 `next_tx += bag`）：** 线上帧起始 `pop` 时  
  `next_tx[pop_vl] ← cycle_count + bag_arr[pop_vl]`（`tx_vl_scheduler.v` **L207**）。  
  含义：以**实际上线时刻**为锚再加一整 BAG；任何下游延迟后，同 VL 相邻帧间隔仍 ≥ BAG，**不会追赶发送**。  
  「长阻塞后恢复」专用场景：**未单独测**；由该锚定方式保证。相关测试：T05b/T05c/T27（合法 BAG / 抖动 / 预算），不覆盖任意长阻塞剧本。
- **错相（D10）**：多 VL 同相会使队尾排队下界过大；由配置/激励在提交与首帧相位上错开（TB 如 T05b），调度器本身按到期选路。硬件无单独「相位寄存器」字段时，错相体现在各 VL 的 `next_tx` 初值与消息到达时刻。

### 9.2 哈希查表（双表 4-way 比较）

流水：IDLE 捕获 → `HASH_ADD` → `HASH_MUL` → `RAM_READ` → `COMPARE` → `OUTPUT`（与 `sw/golden/hash_seed.py` 一致）。  
时延三分法见 §3.2（无反压 5 拍握手 / 反压不固定 / 非每拍可接收）。

```
sum0 = (vlid + seed0 + 0x9E37)[15:0]
sum1 = (vlid + seed1 + 0x1F5B)[15:0]
mixed = sum ^ (sum >> 7)
product0 = mixed0 * 0x9E37 ; product1 = mixed1 * 0x45D9
hash = product ^ (product >> 9)   → 桶号取低 HASH_BITS
```

每表 2-way，两表并行读，共 **4** 次 `valid_match`；命中取对应 `idx[11:0]`。冲突由**离线摆放**解决（换种子/重排映像）；运行期无探测驱逐。主机提交 `HASH_IMAGE` 后才允许 `RX_EN`。

### 9.3 RM 与 SkewMax

- `Skew = 4 << skewmax_exp` μs（exp 0..15 → 4 μs..131 ms）。
- 窗内同 SN 或 hist 命中 → 丢弃副本；窗外同 SN → forward + skew 事件。
- 表项含 `seen` 与 8-deep hist，缓解「只记最后 SN」漏删旧副本。

### 9.4 IC 的 SN 判据

每 VL×网一份 PSN。接受：SN=0（复位）；PSN=0 时 SN=1 或 `IC_FIRST_ANY`；SN=PSN+1；SN=PSN+2（丢 1 帧）。否则拒绝且**不写** PSN。

### 9.5 时延界（规范式 + 代入）

规范（L158 / 摘录）：  
`J = min(40 + Σ_j (20+Lmax_j)·8/Nbw , 500)` μs；  
`MAX_Latency_i ≤ BAG_i + Max_jitter + Technological_Latency`。

工具：`tools/afdx_delay_bound.py`。  
**代入例（T13w 注释代数，Nbw=100 Mbps）**：3×1518 + 3×356 →  
`J = 40 + (3×1538+3×376)×0.08 = 499.36` μs（与自检一致）。  
T89 本场景 40+Σ 实测键：`141` μs。工程总时延（非官方 SFD）例：T13 worst `243416` ns；T13w `453752` ns。  
**适用边界：** 已按官方 SFD→SFD 验收 2 ms；J 式等于仿真线速 1 Gbps 的介质定义。

---

## 10. 时钟、复位与参数

| 项 | 说明 |
|---|---|
| 时钟 | 单域 `clk`；仿真 `CLK_FREQ_HZ=125_000_000`（与 GMII 8 bit×125 MHz 匹配） |
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

## 11. 综合与实现

eLinx 综合规模（数字唯一来源：冻结 metrics）。本作品不做时序签核与板级验证（赛题未要求）。

| 项 | 值 | 等级 |
|---|---|---|
| cells | 106241 | P |
| altsyncram | 507 | P |

门级切片（综合后仿真，见测试报告 §6）：VO `2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46`；T88b S1/S2/S3 = `PASS` / `PASS` / `PASS`。  
功能全量：`145`/`145`（`True`）。  
**适用边界：** GUI LUT；门级 full 回归；历史 140/140 与本冻结 N 可拼接。

---

## 12. 设计取舍与已知边界

| 做了什么 | 没做什么 | 为什么 | 证据 |
|---|---|---|---|
| 自研双网 MAC + PHY GMII | 强制 eLinx Tri_Mode×2 | 答疑后期无强制 MAC IP | 契约；T41/T42 |
| 模板 8 口作 GMII，扩展 host/PPS/B 网 | 把模板当纯应用口 | 可加端口 + GMII=PHY | 赛方答疑（附录 A） |
| SNMP v1 GET/GETNEXT/SET | TRAP、v2c/v3、完整 MIB | 子集可测；G4 不加 TRAP | `snmp_lite`；T43 |
| TFTP 512 B 子集 + 部分 615A 编排 | 完整 615A/665 认证 | 答疑非硬要求 | 图3；披露边界 |
| IC→RM 顺序、SkewMax hist | 任意网络偏斜下最优 | 规范窗口 + 工程可配 | T10 |
| 仿真 125 MHz 功能全量（GMII 速率匹配） | 布局布线后时序签核 / 板级 | 赛题要求综合后仿真，未要求时序签核 | §11；测试报告 §6 |
| 门级 T88b 三步 | 门级全量 144 | 实例/墙钟；答疑允许后仿切片 | gate metrics |
| 自建 TB + 独立 Python/golden | 官方 A664 实验室套件 | 评测用参赛者 TB | 尺子；manifest |
| 默认单块消息 | 默认开 8 KiB 分片 | G3：参数化可选 | `TX/RX_*_CHAIN_BLOCKS` |
| 单 ES 回环 + 默认 CTL（SAP 开，口 6/7） | 同芯片上 128 TX + 128 RX 全配 | 端口预算 `NUM_PORTS=256 = 128 TX + 126 RX + 2 SAP`；VL126/127 不配 RX 表则 FLT unconf | T90 r5；契约 L95 |
| `tx_vl_scheduler` 配置后使能 | 假定 `next_tx[]`/`bag_arr[]` 上电即合法 | 两数组**不随复位清零**；VL 须先配置再使能 | 配置时序：T04 / T05c；形式侧见 `bag_bmc40_CE_ANALYSIS.md` (b) |

---

## 13. 附录

### 13.1 寄存器

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

### 13.2 VL 表项格式

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

### 附录 A. 内部追溯（评委可不读）

| 正文位置 | 内部索引（工程台账） |
|---|---|
| §1.3 答疑依据 | 赛方答疑原文；`doc/赛方答疑口径对照报告_20261023.md` |
| §3 管理面子集 | 工程追踪 `REQ-MGMT-*`（完整协议未作为交付承诺） |
| §3 查表／时延／IC·RM | `doc/AFDX文献工程映射.md` 对应行 |
| §12 取舍表 | 对照报告模板口章节 |

---

## 14. 参考文献（正文实际引用）

> 编号同 `doc/AFDX文献目录.md`。下列仅列 §3 实际引用者；完整题录见该目录。C 级只作方法出处，不供指标数字。

| ID | 题名／作者（短） | 证据级 | 在本文用途 |
|---|---|---|---|
| L001 | Architecting ARINC 664 P7 (AFDX) / Xilinx XAPP1130 | A | §3.6 GMII／ES 分层参考 |
| L010 | 基于共享内存的 AFDX 航空网络交换机 / 胡靖飞 | D | §3.3 共享存储线索 |
| L044 | AFDX 端系统通信端口的设计与实现 / 武华等 | A | §3.3 端口路径线索 |
| L071 | 基于协议符合性的端系统自动化测试 / 黎万山 | A | §3.5 自动化测试思路 |
| L072 | 一种航电系统 AFDX 网络管理技术 / 王纯委 | A | §3.1 管理面范围（软件侧） |
| L074 | 基于 AFDX 的网络管理与数据加载协议 / 黄玉港 | A | §3.1 SNMP+615A 子集边界 |
| L087 | ARINC664 终端测试系统软件 / 王传霸 | A | §3.5 测试框架思路 |
| L088 | 基于 FPGA 的百兆以太网 RGMII 接口设计 / 石华 | B | §3.6 接口方法（辅助） |
| L089 | 芯片测试平台 FPGA 时序分析与接口测试 / 鲍瑞 | A | §3.6 接口时序方法 |
| L096 | Bounding end-to-end delays on AFDX / Charara 等 | C | §3.4 网络级时延上界**方法学** |
| L104 | Optimal design of virtual links in AFDX / Al Sheikh 等 | C | §3.4 BAG／VL 配置方法出处 |
| L109 | Cuckoo hashing / Pagh, Rodler | C | §3.2 查表基础 |
| L110 | Tightly packed constant size bins / Dietzfelbinger, Weidling | C | §3.2 多 way 负载率背景 |
| L111 | Cuckoo hashing with a stash / Kirsch 等 | C | §3.2 摆放稳健性背景 |
| L112 | Fast lookup for dynamic packet filtering in FPGA / Kekely 等 | C | §3.2 FPGA 查表方法 |
| L113 | FPGA-based cuckoo hashing for NIDS / Tran, Kittitornkun | C | §3.2 同上 |
| L116 | RFC 3416 SNMPv2 PDU §4.2.5 | A | §3.1 SET 语义（原样采用） |
| L117 | Mutation testing survey / Jia, Harman | C | §3.5 变异方法学 |
| L121 | Dynamic queue length thresholds… / Choudhury, Hahne | C | §3.3 公共池配额方法 |
| L122 | Tighter buffer dimensioning in AFDX / Benammar 等 | C | §3.3 缓冲上界方法 |
| L123 | FPGA-based queue management… / Nikologiannis 等 | C | §3.3 空闲块管理方法 |
| L136 | Formal Verification… / Seligman 等 | C | §3.5 小模块 FPV 工具书 |
| L137 | RFC 4303 ESP §3.4.3 抗重放滑动窗口 / Kent | B | §3.5 RM hist **结构借鉴**（非 A664 强制） |
| L153 | FAA DOT/FAA/TC-14/41 Advanced Verification… / Butka | B | §3.5 覆盖率表述口径（非 DAL） |
| L158 | ARINC 664 Part 7（2005 初版） | A | §3.4／§3.5 BAG·抖动·IC/RM **规范原文**（原样采用；须标版本） |

工程映射总表：`doc/AFDX文献工程映射.md`。

---

*文档版本随冻结 `098efc98d379c29b113d52dfccb24cdf36be7391`；指标数字由 metrics 渲染填充。*
