# AFDX 项目应用追踪

更新：2026-09-26

> 本文件是面向当前工程实施、验证和答辩的主入口。文献是设计依据之一，不是当前实现证据；当前状态必须回到 RTL、TB、manifest、日志、综合和 STA 报告核对。

## 1. 赛方边界与项目子集

| 项目 | 当前约束/选择 | 证据与边界 |
|---|---|---|
| MAC 接口 | GMII；125 MHz；8 bit 字节口 | 赛方问答明确 GMII；MII/其他模式是项目仿真兼容模式，不替代 GMII 主证据 |
| 仿真环境 | 参赛者自建激励、回环、检查器和参考模型 | 赛方不提供参考仿真环境；Python 黄金模型只作辅助，最终以 RTL/Questa 波形和日志为准 |
| 主体目标 | AFDX End System，不是交换机或真实 PHY 产品 | 设计书与赛题边界 |
| SNMP/615A/RTC | 采用项目限定子集；当前已有 SAP 最小 handoff，完整协议仍是 OPEN_SPEC_GAP | 赛方仅答“参考协议规范要求”，未给字段级细则 |
| 官方认证 | 不声称完整 ARINC 664/615A 认证，不声称通过官方一致性套件 | 项目自建验证矩阵和 golden vectors |

## 2. 状态枚举

- `PROPOSED`：方案提出，尚未冻结。
- `ACCEPTED`：方案已选定，但未形成充分实现证据。
- `IMPLEMENTED`：RTL/脚本已有实现。
- `TOP_LEVEL_VERIFIED`：顶层 RTL 有针对性证据。
- `SYNTHESIS_VERIFIED`：当前顶层有可审阅综合证据。
- `STA_VERIFIED`：明确器件/约束下有时序报告。
- `OPEN_SPEC_GAP`：项目子集或标准边界尚未确定。
- `HISTORICAL`：旧快照，不作为当前状态。

## 3. 需求追踪主表

证据中的 `T*` 指 `sim/tests.manifest` 测试；`L*` 指 [AFDX文献目录](AFDX文献目录.md)；`OPEN` 表示尚未证实。

| ID | 工程问题/需求 | 来源与文献 | RTL/脚本 | 测试/证据 | 状态 | 未覆盖边界 | 下一步 |
|---|---|---|---|---|---|---|---|
| REQ-FRAME-01 | 64–1518 B 帧、FCS、UDP/IP、padding、SN 位置 | 设计书；L001/L008 | `tx_frame_builder.v`、`mac_tx_if.v`、`mac_rx_if.v` | T03、T08a、T22 | TOP_LEVEL_VERIFIED | 仅项目帧格式，不是官方互操作认证 | 固化 frame scoreboard |
| REQ-FRAME-02 | 赛方主接口为 GMII，125 MHz | 赛方问答；L088/L089 | `mac_tx_if.v`、`mac_rx_if.v` | T04g、T08ag、T22g | TOP_LEVEL_VERIFIED | PHY/板级 IO 时序未签核 | 补 GMII 约束与说明 |
| REQ-TX-01 | 最多 128 条 TX VL，按 BAG 整形 | 设计书；L001/L041/L063/L064 | `tx_vl_scheduler.v`、`tx_port_buf.v` | T02、T04/T04g、T05b | TOP_LEVEL_VERIFIED | 合法 BAG 全档和长期公平性仍需统一报告 | 完成全档 T05 矩阵 |
| REQ-TX-02 | SN 提交式递增与 1–255 回绕 | 设计书；L001/L008/L064 | `tx_sn_gen.v` | T02、T03、T22 | TOP_LEVEL_VERIFIED | 多 VL 长时回绕统计 | 增加长时 SN 断言 |
| REQ-TX-03 | 双网复制与网络标识 | 设计书；L001/L005 | `tx_rm.v`、`mac_tx_if.v` | T04/T04g、T22 | TOP_LEVEL_VERIFIED | 真实 PHY 不在项目范围 | 保持 A/B scoreboard |
| REQ-RX-01 | 双网入口、CRC/IP/UDP/长度检查、坏帧隔离 | L001/L002/L007 | `mac_rx_if.v`、`rx_pmem_queue.v` | T08a/T08ag/T08b/T08bg | TOP_LEVEL_VERIFIED | 完整全错误矩阵仍需合并 | 补统一 RX scoreboard |
| REQ-RX-02 | 4096 RX VL 配置、哈希读写和提交门 | 设计书；L039/L045/L047 | `rx_vl_lookup.v`、`AFDX_top.v` | T08f/T08fg、T12 全系列 | TOP_LEVEL_VERIFIED | 全表逐帧收发未证明 | 补全表 live-frame 测试 |
| REQ-RX-03 | FLT 对未配置、VLID、NET、LMAX 做判决 | 设计书；L002/L039/L045 | `rx_flt.v` | T08d/T08dg | TOP_LEVEL_VERIFIED | 配置读口 BRAM 化待定；统计归类需冻结 | 收敛配置读口和计数语义 |
| REQ-REL-01 | IC 维护每 VL/每网 PSN，拒绝错误序列 | L001/L007/L008/L077 | `rx_ic.v` | T08e/T08eg、T09/T09p | TOP_LEVEL_VERIFIED | 顶层全错误组合仍需 scoreboard | 补 IC/RM 联合断言 |
| REQ-REL-02 | RM A/B 去重、SkewMax、首个有效副本交付 | L077/L078/L079/L080；RM 形式化资料 | `rx_rm.v` | T10/T10g、T22 | TOP_LEVEL_VERIFIED | 多帧迟到副本、两网交替领先、network babbling 仍需专门验证 | 明确历史窗口/迟到策略 |
| REQ-RX-04 | 解析后进入采样/队列端口并主机读回 | L007/L044/L049 | `rx_ip_udp_parse.v`、`rx_port_buf.v` | T11/T11g、T21、T22 | TOP_LEVEL_VERIFIED | 完整 T08 逐帧 scoreboard 尚未完成 | 统一端口/块所有权检查 |
| REQ-HOST-01 | RX/主机 PMEM 争用、延迟 ACK、复位取消 | 设计书；L009/L044 | `AFDX_top.v`、`host_if.v` | T08c/T08cg、T17/T17g | TOP_LEVEL_VERIFIED | 持续满载等待上界和混合读写仍需扩大 | 长时主机/RX 交错测试 |
| REQ-HOST-02 | 块池耗尽不写空块，释放后恢复 | L010/L016；项目决策 | `rx_block_pool.v`、`rx_pmem_queue.v` | T21/T21g、T22 | TOP_LEVEL_VERIFIED | 长时多端口所有权仍需验证 | 做全链路 block conservation |
| REQ-MGMT-01 | SAP descriptor handoff 和管理块归还 | 设计书；L044/L074 | `mgmt_sap_rx.v`、`AFDX_top.v` | T23/T23g | TOP_LEVEL_VERIFIED | 不等于 SNMP/615A/RTC 完整实现 | 固化 SAP 子集说明 |
| REQ-MGMT-02 | SNMP 项目子集（至少状态读取/错误处理边界） | 赛方；RFC1157/RFC3416；L046/L074 | `snmp_lite.v` | T14（当前不作为完成证据） | OPEN_SPEC_GAP | BER、GET/SET/Trap、MIB 范围未冻结 | 决定子集并写测试 |
| REQ-MGMT-03 | 615A/TFTP 项目子集（加载/块/校验/提交） | 赛方；L074 | `a615a_tftp.v` | T15（当前不作为完成证据） | OPEN_SPEC_GAP | 完整协议报文和重传未实现 | 定义最小配置加载子集 |
| REQ-MGMT-04 | RTC/PPS 同步和失步状态 | 赛方；L006/L075 | `rtc_sync.v` | T16（当前不作为完成证据） | OPEN_SPEC_GAP | 同步协议、收敛和统计未冻结 | 明确是否纳入交付 |
| REQ-PERF-01 | 合法 BAG 全档启动/稳态 jitter | L001/L006/L067/L084 | `tx_vl_scheduler.v`、仿真脚本 | T05b/T05bg | TOP_LEVEL_VERIFIED | 当前为特定压力配置；不能外推所有档位 | 完成 1–128 ms 全档矩阵 |
| REQ-PERF-02 | 端到端硬件回环时延 | L006/L018/L068/L084 | `sim/tb`、`AFDX_top.v` | T13/T13g、T22 | TOP_LEVEL_VERIFIED | 样本量、P99、背压场景需正式报告 | 输出指标 CSV/报告 |
| REQ-PERF-03 | 长时/高负载随机压力 | L068/L070/L071/L081 | `sim/tb`、回归脚本 | T17/T18 | TOP_LEVEL_VERIFIED | 不能外推 10 万帧、长时和 4 端口持续并发 | 统一样本量和持续时间 |
| REQ-IMPL-01 | 当前顶层可综合 | L085/L089（方法参考） | eLinx 工程 | 局部子模块综合；顶层状态以最新进度为准 | OPEN | 顶层综合网表/资源报告冲突或未形成 | 重新建立 active revision |
| REQ-IMPL-02 | 125 MHz STA/CDC/复位签核 | L088/L089、TI PHY 手册 | eLinx/约束/报告 | 无完整顶层 STA 证据 | OPEN | WNS/TNS/Fmax/关键路径未知 | 先冻结时钟和 IO 约束 |
| REQ-QUAL-01 | lint、回归、日志和输入输出可复现 | 赛方；L070/L071 | `tools/`、`sim/` | lint、`run_all.py --strict`、最新回归快照 | PARTIAL | 覆盖率口径含 TB；清洁环境归档未完全封存 | 固化 manifest/工具/哈希清单 |

## 4. 架构决策状态

| 决策 | 当前状态 | 当前采用/事实 | 主要依据 | 未覆盖边界 |
|---|---|---|---|---|
| D10 发送起始错相 | IMPLEMENTED / TOP_LEVEL_VERIFIED | 按 VL/BAG 进行错相提交，T05b 有特定压力证据 | L001/L064/L067/L084 | 全 BAG 档、STA、标准认证 |
| D11 块所有权与释放 | IMPLEMENTED / TOP_LEVEL_VERIFIED | RX block pool、端口读回、耗尽/恢复和 SAP handoff 已有局部证据 | L010/L016/L044；T21/T22/T23 | 完整 T08 全链路长期守恒 |
| D12 双网 RM 仲裁 | IMPLEMENTED / TOP_LEVEL_VERIFIED | IC 后 RM、A/B 去重、SkewMax/seen 状态 | L077-L080；T10/T22 | 迟到历史窗口、network babbling、形式化验证 |
| D13 PMEM/主机仲裁 | IMPLEMENTED / TOP_LEVEL_VERIFIED | RX 优先、pending/延迟 ACK、主机写读回 | L009/L044；T08c/T17 | 无限时长公平性、完整混合事务 |

## 5. 当前证据边界

### 可以直接用于项目/答辩的内容

- 赛方明确 GMII、自建激励、自建回环和自建验证环境；
- TX/RX 主要 RTL 路径和 50/50 manifest 回归快照；
- T08e/T10/T11/T21/T22/T23 等定向测试；
- L077-L080 的 RM/SkewMax 论文和形式化建模资料；
- L071/L087 的端系统符合性/自动化测试方法；
- L084 的确定性仿真外部对照；
- L089、TI PHY 手册的 GMII/RGMII/接口时序参考。

### 仍不能宣称完成的内容

- 完整 ARINC 664 Part 7 官方认证；
- 完整 ARINC 615A、SNMP、RTC；
- 官方一致性测试套件或官方 golden vector 通过；
- 全表逐帧 T08/T22；
- 10 万帧/长时/持续 4 端口压力；
- 当前顶层完整综合、资源和 125 MHz STA；
- 完整 RTL-only 覆盖率签核。

### 仅作背景、不能直接作为 AFDX 合规证据

- 普通千兆以太网/图像传输论文 L090-L094；
- 特定商业 FPGA、MAC、PHY、PCIe、Linux 或 RTOS 平台方案；
- 论文作者声称的“通过测试/满足指标”；
- D 级 CAJ 题名线索。

## 6. 下一步验收顺序

1. 冻结项目子集：GMII、支持的 SNMP/615A/RTC 范围和不支持项。
2. 完成 T08/T22 统一逐帧 scoreboard。
3. 按 L077-L080 复核 RM 多帧迟到、历史窗口和 network babbling 边界。
4. 完成合法 BAG 全档、T13 指标 CSV、T17/T18 样本量与持续时间说明。
5. 重新建立顶层综合 active revision、资源报告、CDC/复位检查和 125 MHz STA。
6. 固化 manifest、工具版本、源码/向量/日志哈希和清洁环境复跑包。
7. 管理面若不纳入本阶段，明确写成项目限定子集和 OPEN_SPEC_GAP，不用 T23 冒充 T14–T16。

## 7. 2026-09-28 设计优化待办（OPT-1~12，状态：PROPOSED，未实施）

> 依据：[第三轮文献补充与设计优化建议](AFDX端系统_第三轮文献补充与设计优化建议_20260928.md)。下表只登记问题和方案，**不改变 §3/§4 的现有状态**；任一项实施后须全量 56 项回归＋同器件 post-fit STA，才能改为 IMPLEMENTED。
>
> **与同日文档的分工**：A01–A05（SNMP 事务/请求覆盖/时序、T13、判决门）已由 [文献依据与修复建议](AFDX_文献依据与修复建议_20260928.md)、[三篇文献正文复核与修复映射](AFDX_三篇文献正文复核与修复映射_20260928.md) 及 [文献落地验证清单 CSV](AFDX_文献落地验证清单_20260928.csv) 细化到用例级；OPT-2~5 **以该 CSV 为验收用例来源**，此处只登记对应关系，不另立判据。OPT-1、OPT-6~10 为本轮新增、上述文档未覆盖的项。

| 编号 | 优先级 | 问题（证据） | 方案 | 文献 | 状态 |
|---|---|---|---|---|---|
| OPT-1 | P1 | RM 只记 last_sn，迟到副本会重复交付（`rx_rm.v:110`；`tb_t10_top_rm.v:282-285` 自认 limitation）→ REQ-REL-02／D12 缺口 | RM_ST 33→41 bit，加 8 bit 已交付位图；超出窗口由策略位决定；配置检查 `SkewMax < 127·BAG` | L105/L107/L137 | PROPOSED |
| OPT-2 | P1 | SNMP SET 非原子（A01，`snmp_lite.v:532-537`） | P_RESOLVE2 只校验和暂存；新增 P_COMMIT，仅在 err_st==0 时统一写入 | L116；CSV `SET_ATOMIC_1/N`、`SET_PRECHECK` | PROPOSED |
| OPT-3 | P1 | 请求覆盖（A02，`snmp_lite.v:367-375`） | `!have_pkt` 门控＋`snmp_busy_drop` 计数 | L116；CSV `REQ_BURST/REQ_CONTEXT/QUEUE_BOUNDARY/RESET_RECOVERY` | PROPOSED |
| OPT-4 | P1 | 回归假绿（A04）、T13 无断言（A03） | 每个 TB 输出唯一 VERDICT 行，runner 严格判定；T13 加时延阈值；为 OPT-1~3 各配 1 个变异体 | L117/L001；CSV `VERDICT_GATE`、`LATENCY_GATE` | PROPOSED |
| OPT-5 | P2 | WNS −1.735 ns，最差路径 `oid_len→vl_stat_mem`（A05） | OID 逐字节增量求 pfx_ok 和 g/l/i；walk() 单独占一拍 | L115；CSV `GETNEXT_PIPE`、`POSTFIT_CHECK` | PROPOSED |
| OPT-6 | P2 | 0924 文档写 D10“调度器内置 26 μs×i 偏置”，RTL 无此逻辑（`tx_vl_scheduler.v:18`），实际为主机错相提交（T05b `:162`） | A：定义为主机契约并修正 0924 文档（推荐）；B：phase_lock 硬件相位栅格 | L099–L101/L135 | PROPOSED |
| OPT-7 | P2 | 设计书 §8 写“任一池可借公共池”，TX 未实现（`tx_port_buf.v:19`）；RX 借用无上限 | 文档对齐为“仅 RX 借用”；RX 加 `borrow_cap`；日后 TX 借用采用 DT 阈值 | L121/L122 | PROPOSED |
| OPT-8 | P3 | RTC 仅 P 环（`rtc_sync.v:79`），频偏 f ppm 时稳态误差约 f·2^log2_avg μs；设计书 F5“分数微调”未兑现 | PI 伺服＋分数累加器；SYNC_LOSS 时 holdover | L133/L134 | PROPOSED |
| OPT-9 | P3 | `pps_in` 未做 CDC 签核（`rtc_sync.v:15`） | SDC／同步器识别＋MTBF 计算＋最小脉宽约束 | L132 | PROPOSED |
| OPT-10 | P3 | 覆盖率 67.82%，无形式证据 | SymbiYosys 有界证明：块池守恒、RM 不重复、IC 拒绝不写 RM | L136 | PROPOSED |
| OPT-11 | — | 调度器顺序扫描 1.02 μs／轮 | 不实施；VL ≥ 1024 时改时间轮 | L135 | DEFERRED |
| OPT-12 | — | 配置 FF 阵列 | 待 post-fit 资源报告确认是瓶颈后，再做 BRAM 化 | L125–L127 | DEFERRED |

**文档与代码不一致（待收口）**：D10 描述（0924 两份文档）；公共池借用（设计书 §8 第 490/972 行）；F5 分数微调（设计书 §2.1）；RM 迟到副本（§7.11／REQ-REL-02）。
