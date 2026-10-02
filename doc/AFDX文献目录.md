# AFDX 文献目录

更新：2026-09-28（新增 §12：L096–L137；新增 §13：本地库清理与 L138–L157）

> 文献登记的单一来源。当前实现状态、需求状态和下一步以 [AFDX项目应用追踪](AFDX项目应用追踪.md) 为准；主题比较见 [AFDX文献主题矩阵](AFDX文献主题矩阵.md)；来源到工程问题映射见 [AFDX文献工程映射](AFDX文献工程映射.md)。
>
> 本文按**项目用途域**组织，不再按下载批次堆叠。每条保留稳定 ID、证据等级、主题标签和支持的 `REQ-*` 域。
>
> **⚠️ 文献保留纪律（2026-09-28 确立）**：`文献/` 与 `AFDX_补充文献/` 下的全部文件**一律保留，不再做任何清理或删除**。这批文献是后续撰写**设计文档与答辩材料**的引用来源，需要随时回查原文页码与条款。9 月 28 日那轮去重（DELETED=31 / MOVED=6）**是一次性动作，已结束**；此后只允许新增与登记，不允许再删。无关文献也只移入 `out/lit_unrelated/` 存档，不物理删除。

## 1. 证据等级与状态

- **A**：正文可读，有可复核页码/章节。
- **B**：正文可读，页数/实验条件不完整，或为方法参考。
- **C**：只有摘要、局部提取或二手信息。
- **D**：仅凭题名/文件名登记，不得据此形成正文结论。

正文状态：`全文可读`、`部分可读`、`待解析`、`仅线索`。
`[LIT]` 表示文献观察结论；是否转化设计/验证以项目应用追踪为准。

## 2. 域 A：协议基线、帧格式与 AFDX 总览（REQ-FRAME / 宏架构）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L001 | Architecting ARINC 664, Part 7 (AFDX) / Xilinx | `xapp1130.pdf`；（1）副本 | A | VL/BAG/SN/IC/RM/端口总体基线；帧格式、冗余发送 0.5ms 窗口 |
| L008 | 基于 FPGA 的 AFDX 协议处理芯片设计 / 尹路 | `基于FPGA的AFDX协议处理芯片设计_尹路.caj` | A | 端系统分层、VL/BAG/Lmax/抖动、SN/冗余 |
| L015 | AFDX 构架及协议分析 / 钟杰 | `AFDX构架及协议分析_钟杰.caj` | D | 协议栈收发流程、IC/RM 阶段（正文待解析） |
| L033 | AFDX 在航空通信系统中的应用 / 校莉 | `AFDX在航空通信系统中的应用_校莉.caj`；`_校莉.pdf` | D/B | VL、BAG、Lmax、冗余和端口概览 |
| L034 | AFDX 网络协议研究 / 赵永库 | `AFDX网络协议研究_赵永库.caj` | D | 协议研究线索 |
| L036 | AFDX 网络总线设计 / 樊明柯 | `AFDX网络总线设计_樊明柯.caj` | D | 总线设计线索 |
| L042 | AFDX 在航空通信系统中的应用 / 校莉（PDF） | `AFDX在航空通信系统中的应用_校莉.pdf` | B | 与 L033 同源 PDF 版，VL/BAG/冗余概览 |
| L043 | AFDX 构架及协议分析 / 钟杰等 | `AFDX构架及协议分析-钟杰何民王怀胜郑力.pdf` | A | 帧管理流程、完整性与冗余阶段 |
| L075 | AFDX 网络应用关键技术分析与研究 / 赵永库 | `AFDX网络应用关键技术分析与研究_赵永库.pdf` | B | 网络拓扑、时统、加载、管理、配置、监控 |
| L083 | 大型客机航电系统综合集成关键技术综述 / 周贵荣 | `大型客机航电系统综合集成关键技术综述_周贵荣.pdf` | B | IMA/航电综合集成背景 |

**补充参考（已下载，非 AFDX 官方标准）：**
- `AFDX_中文快速使用手册_clvtech.pdf`：B，32 页，中文 VL/BAG/冗余/帧格式手册。
- `AFDX_Modeling_Simulation_Atlantis.pdf`：C，AFDX 网络建模与仿真。

## 3. 域 B：TX 调度、BAG、帧构造与端系统收发（REQ-TX-*）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L005 | AFDX 网络端系统芯片设计与实现 / 张荣华 | `AFDX网络端系统芯片设计与实现_张荣华.caj` | A | 端系统 SoC、双 MAC、BAG、测试矩阵 |
| L009 | 基于 FPGA 的 AFDX 软硬件协同设计 / 段晓峰 | `基于FPGA的AFDX软硬件协同设计_段晓峰.caj` | A | 软硬件划分、调度、DMA/descriptor、SoPC/PCIe |
| L014 | AFDX 交换机的硬件设计及端系统调度 / 牛冰 | `AFDX交换机的硬件设计及端系统调度_牛冰.caj` | D | 调度与交换线索 |
| L025 | 基于时间窗的 AFDX 端系统调度策略设计实现 / 范毓洋 | `基于时间窗的AFDX端系统调度策略设计实现_范毓洋.caj` | D | 时间窗调度线索 |
| L031 | 保证轮询时延上界的 AFDX VL 最优设计 / 吕经纬 | `保证轮询时延上界的AFDX网络VL最优设计_吕经纬.caj` | D | 时延上界、VL 优化线索 |
| L041 | AFDX 交换芯片调度设计与系统测试 / 柴明 | `AFDX交换芯片调度设计与系统测试-柴明.pdf`；（1）副本 | A | 接收/发送调度、配置表测试、功能/性能测试 |
| L050 | 基于 FPGA 的 AFDX 端系统协议芯片 / 张志 | `基于FPGA的AFDX端系统协议芯片的设计与实现_张志.pdf` | A | FPGA 端系统、VL/BAG/抖动约束 |
| L052 | 基于 FPGA 的 AFDX 端系统设计 / 罗西 | `基于FPGA的AFDX端系统设计_罗西.pdf`；`-罗西.pdf` | A | 软件调度 + 硬件协议处理划分 |
| L063 | AFDX 网络端系统的设计 / 罗帅 | `AFDX网络端系统的设计-罗帅.pdf` | A | FPGA 端系统收发帧 + 优先级调度与比较 |
| L064 | AFDX 端系统协议栈虚拟链路层 / 许燕婷 | `AFDX端系统协议栈虚拟链路层分析及仿真研究-许燕婷.pdf`（多副本） | A | 静态优先级综合调度、流量整形 |
| L067 | 飞机航空电子系统总线技术与调度策略 / 徐媛媛 | `飞机航空电子系统总线技术与调度策略研究-徐媛媛.pdf` | A | 总线调度策略 |
| L069 | 分布式综合航电任务调度 / 韩朴杰 | `分布式综合航电任务调度系统的分析与优化方法研究-韩朴杰.pdf` | B | 分布式任务调度背景 |

**补充参考：**
- `AFDX_TSN_BLS_Finzi_Thesis_ISAE.pdf`：B，191 页，AFDX+TSN/BLS 整形与帧建模（提取含乱码，需页面对照）。

## 4. 域 C：RX、IC、RM、SkewMax 与双网冗余（REQ-RX-*/REQ-REL-*）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L007 | AFDX 网络终端系统设计研究 / 郭丰玮 | `AFDX网络终端系统设计研究_郭丰玮.caj` | A | RX 路径、IC/RM、采样/队列端口 |
| L016 | AFDX 端系统协议栈分析与设计 / 刘瑞旸 | `AFDX端系统协议栈分析与设计_刘瑞旸.caj` | D | 协议栈、队列线索 |
| L045 | AFDX 网络关键技术研究 / 姜丽云 | `AFDX网络关键技术研究-姜丽云.pdf`；`_姜丽云.pdf` | A | 协议栈、端口查找、IC/RM、配置不匹配过滤、系统测试目录 |
| L049 | 基于 AFDX 端系统的网络层验证研究 / 宋汐瑾等 | `基于AFDX端系统的网络层验证研究-宋汐瑾苏稳吕岩松张赫白楠.pdf` | A | 接收顺序：SN 完整性→冗余过滤→IP 校验 |
| L077 | AFDX 端系统中冗余管理的研究和实现 / 李大鹏 | `AFDX端系统中冗余管理的研究和实现_李大鹏.pdf` | A | 冗余管理调度、完整性检测、SkewMax、FPGA 实现 |
| L078 | AFDX 网络冗余管理技术分析 / 徐进、黄玉港 | `AFDX网络冗余管理技术分析_徐进.pdf` | A | 冗余管理算法 + 仿真验证，SkewMax 配置 |
| L079 | 航空全双工交换以太网冗余管理机制研究 / 陈昕 | `航空全双工交换以太网冗余管理机制研究_陈昕.pdf` | A | 13 种 RM 算法、UPPAAL/TLA、network babbling 假复位 |
| L080 | AFDX 网络中 SkewMax 的研究 / 李哲 | `AFDX网络中SkewMax的研究_李哲.pdf`；`(1)` 副本 | A | 多 VL/多 SN 余度帧 SkewMax 测量 |
| L082 | AFDX 核心交换技术的研究与实现 / 王绮卉 | `AFDX核心交换技术的研究与实现_王绮卉.pdf` | A | 交换机过滤/警管、交换调度与核心设计需求 |
| L086 | AFDX 网络中 SkewMax / 李哲（重复） | `AFDX网络中SkewMax的研究_李哲 (1).pdf` | A | 与 L080 重复，不新增证据 |

**补充参考（已下载，RM 直接依据）：**
- `RM_AFDX_MengLi_Thesis_PolyMTL.pdf`：A，153 页，SN 回绕公式、SkewMax 超窗、FVW 先到有效、IC→RM、A/B 抖动公式。当前 `rx_rm` 最直接依据。
- `AFDX_FrameManagement_UPPAAL_UPenn.pdf`：A，7 页，UPPAAL 建模、假复位与复位消息冗余副本处理。
- `DDS_and_AFDX_Integration_UCrea.pdf`：B/A，AFDX 与 DDS 对照，迟到/乱序死锁场景。
- `AFDX_Emulation_Model_Thales.pdf`：B，AFDX 仿真/注入与验证方法。

## 5. 域 D：端口、主机接口、PMEM 与块所有权（REQ-RX-04/REQ-HOST-*）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L003 | AFDX 应用程序设计与实现 / 陈冬英 | `AFDX应用程序设计与实现_陈冬英.caj` | A | VL 配置、UDP/端口映射、应用层测试 |
| L010 | 基于共享内存的 AFDX 航空网络交换机 / 胡靖飞 | `基于共享内存的AFDX航空网络交换机设计_胡靖飞.caj`；（1）副本 | D | 共享内存交换/PMEM 线索 |
| L017 | AFDX 端系统协议软件设计与实现 / 刘芸 | `AFDX端系统协议软件设计与实现_刘芸.caj` | D | 协议软件、主机接口线索 |
| L019 | AFDX 端系统的 Linux 驱动程序 / 冯海云 | `AFDX端系统的Linux驱动程序设计与实现_冯海云.caj` | D | 驱动与主机接口线索 |
| L020 | AFDX 网络 TAP 卡的设计与实现 / 楼晓强 | `AFDX网络TAP卡的设计与实现_楼晓强.caj` | D | 旁路采集、主机接口线索 |
| L029 | CentOS 下 AFDX 端系统驱动 / 郑涛 | `CentOS下AFDX端系统驱动设计与实现_郑涛.caj` | D | Linux 驱动线索 |
| L030 | 一种 PCIe 接口 AFDX 端系统 / 王晨博 | `一种PCIe接口AFDX端系统的设计与实现_王晨博.caj` | D | PCIe 主机接口线索 |
| L039 | AFDX 交换机及交换芯片中关键模块 / 王鹏 | `AFDX交换机及交换芯片中关键模块的设计-王鹏.pdf`；（1）副本 | A | CAM/VL 过滤、警管、交换机测试 |
| L040 | AFDX 交换机的硬件设计与应用研究 / 陈杰群 | `AFDX交换机的硬件设计与应用研究-陈杰群.pdf` | A | 交换机状态、故障检测、系统测试 |
| L044 | AFDX 端系统通信端口的设计与实现 / 武华等 | `AFDX端系统通信端口的设计与实现-武华马捷中翟正军.pdf` | A | 端口配置→创建→收发→驱动/应用可见性 |
| L047 | 基于 AFDX 协议的端系统配置模块 / 刘天宇 | `基于AFDX协议的端系统配置模块研究_刘天宇.pdf` | A | 配置文件描述固定路径和确定性参数 |
| L048 | 基于 AFDX 总线的总线融合技术 / 王慧慧 | `基于AFDX总线的总线融合技术研究_王慧慧.pdf` | B | 总线转换、配置映射、故障诊断 |

## 6. 域 E：管理面（SNMP / 615A / RTC / SAP）（REQ-MGMT-*）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L046 | SNMP 协议在 AFDX 网络中的应用 / 张晓明 | `SNMP协议在AFDX网络中的应用_张晓明.pdf`；（1）副本 | A | MIB、配置/故障管理、状态监控、事件上报 |
| L072 | 一种航电系统 AFDX 网络管理技术 / 王纯委 | `一种航电系统AFDX网络管理技术的研究与实现_王纯委.pdf`；（1）副本 | A | 构型/故障/配置管理、VxWorks653、级联双 CPU |
| L073 | 一种机载 AFDX 网络管理系统 / 逯计划 | `一种机载AFDX网络管理系统的研究与实现_逯计划.pdf` | B | 机载网络管理系统 |
| L074 | 基于 AFDX 网络的网络管理与数据加载协议 / 黄玉港 | `基于AFDX网络的网络管理与数据加载协议研究及应用_黄玉港.pdf` | A | SNMP + ARINC615A 数据加载软件与测试 |
| L076 | AFDX 交换机内嵌 ES / 张明 | `AFDX交换机内嵌ES的设计与验证_张明.pdf` | A | 交换机内嵌 ES、配置管理、协议栈、FPGA 验证 |
| L085 | AFDX 网络交换机芯片的设计与验证 / 张占锋 | `AFDX网络交换机芯片的设计与验证_张占锋.pdf` | A | 24 端口、主机/MAC/交换调度/端口模块 |
| L095 | 与 L085 同名记录（同源） | `AFDX网络交换机芯片的设计与验证_张占锋.pdf` | A | 与 L085 合并，按一次证据计 |

**补充参考：**
- `RFC1157_SNMPv1.txt`：A，SNMPv1 五种 PDU + BER。
- `RFC3416_SNMPv2.txt`：A，SNMPv2 Get/GetNext/GetBulk/Set/Inform/Response/Trap PDU。
- `RFC3417_SNMP_transport.txt`：A，SNMP over UDP/IP 承载。
- `Kaliski_ASN1_BER_DER_guide.html`：A，ASN.1 / BER / DER 编码指南。

## 7. 域 F：验证、测试、故障注入与符合性（REQ-PERF-*/REQ-QUAL-*）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L004 | AFDX 网络数据分析系统设计 / 赵瑨 | `AFDX网络数据分析系统设计_赵瑨.caj` | A | 双冗余拓扑、流量/错误统计、测试观测点 |
| L002 | AFDX 交换机的 ASIC 设计 / 沈磊 | `AFDX交换机的ASIC设计和实现_沈磊.caj`；（1）副本 | A | store-and-forward、VL 过滤、BAG/Jitter policing、可测试性 |
| L006 | AFDX 网络系统监控设计与实现 / 王竹清 | `AFDX网络系统监控设计与实现_王竹清.caj` | A | BAG/Jitter/完整性/交换延迟监控 |
| L018 | AFDX 端系统技术时延测试方法 / 李雯 | `AFDX端系统技术时延测试方法设计与实现_李雯.caj`；（1）副本 | D | 时延测量线索 |
| L022 | AFDX 网络端系统测试方法 / 袁万腾 | `AFDX网络端系统测试方法设计及实现_袁万腾.caj` | D | 测试方法线索 |
| L026 | 基于故障注入的 AFDX 网络监测 / 周丽华 | `基于故障注入的AFDX网络监测系统软件设计与实现_周丽华.caj` | D | 故障注入线索 |
| L027 | 面向民机 AFDX 交换机的敏捷测试 / 张玉杰 | `面向民机AFDX交换机的敏捷测试技术研究_张玉杰.caj` | D | 敏捷测试线索 |
| L032 | 基于 AFDX 交换机数据捕获的状态监控 / 于德良 | `基于AFDX交换机数据捕获的状态监控系统设计_于德良.caj` | D | 状态监控线索 |
| L068 | AFDX 网络传输特性测试技术 / 施太平 | `AFDX网络传输特性测试技术研究_施太平.pdf`；（1）副本 | A | 一致性/功能/性能/被动测试分类、测试流程 |
| L070 | AFDX 网络交换机验证测试平台 / 王世奎等 | `AFDX网络交换机验证测试平台的设计与实现-王世奎李雯王建宇.pdf` | A | 交换机验证平台、功能与性能测试集合 |
| L071 | 基于协议符合性的端系统自动化测试 / 黎万山 | `基于协议符合性的AFDX端系统自动化测试软件设计-黎万山.pdf` | A | 采样/队列/SAP/余度/时间同步/安全/可靠性自动化测试 |
| L081 | AFDX 总线传输特性测试标准指标体系 / 朱晓飞 | `AFDX总线传输特性测试要求标准指标体系的确定_朱晓飞.pdf` | A | 基于传输流程与协议的测试标准指标体系 |
| L084 | 一种 AFDX 端系统确定性仿真方法 / 于峰 | `一种AFDX网络端系统确定性仿真方法_于峰.pdf` | A | 44.16 Mbps / VL 最大抖动 379 μs 外部对照 |
| L087 | ARINC664 终端测试系统软件 / 王传霸 | `ARINC664终端测试系统软件的设计与开发_王传霸.pdf` | A | 端系统测试软件与自动化测试框架 |

**补充参考：**
- `CDC_TMR_sync.pdf`：B，DO-254 方向 CDC 同步参考。

## 8. 域 G：GMII/PHY/时序/综合/STA（REQ-IMPL-*）

| ID | 题名/作者 | 本地文件 | 证据 | 主要结论/用途 |
|---|---|---|---|---|
| L088 | 基于 FPGA 的百兆以太网 RGMII 接口设计 / 石华 | `基于FPGA的百兆以太网RGMII接口设计_石华.pdf` | B | RGMII、PHY 参考时钟、前导码、抓包验证 |
| L089 | 芯片测试平台 FPGA 时序分析与接口测试 / 鲍瑞 | `芯片测试平台中的FPGA时序分析及芯片接口测试方法研究_鲍瑞.pdf` | A | GMII/S3MII/RGMII 时序约束、时钟裕量/应力/异常测试 |
| L090 | 基于 FPGA 的千兆以太网控制器 / 巩峰 | `基于FPGA的千兆以太网控制器的设计与实现_巩峰.pdf` | B | MAC、PHY、Nios/LwIP/UDP 通路 |
| L091 | 基于 FPGA+MAC+PHY 的数传系统 / 侯义合 | `基于FPGA+MAC+PHY的千兆以太网数传系统设计_侯义合.pdf` | B | AX88180/88E1111、UDP/IP、RGMII、乒乓缓存 |
| L092 | 基于 FPGA 多接口千兆以太网 IP / 李岚 | `基于FPGA多接口的千兆以太网IP核设计_李岚.pdf` | B | 多接口以太网 IP 结构 |

**补充参考：**
- `TI_DP83867IR_PHY_datasheet.pdf`：A，RGMII/GMII 时序、MAC/PHY 时钟关系。
- `IMA_State_of_Art_DLR.pdf`：C，IMA/航电综述背景。

## 9. 域 H：普通高速以太网 / 低相关背景（不作为 AFDX 合规证据）

| ID | 题名/作者 | 本地文件 | 证据 | 用途 |
|---|---|---|---|---|
| L011 | 基于 FPGA 的 AFDX 端系统协议芯片 / 张志（CAJ） | `基于FPGA的AFDX端系统协议芯片的设计与实现_张志.caj` | D | 与 L050 同题名 CAJ 线索 |
| L013 | AFDX 交换机的硬件设计与应用研究 / 陈杰群（CAJ） | `AFDX交换机的硬件设计与应用研究_陈杰群.caj` | D | 与 L040 PDF 同源线索 |
| L012 | AFDX 交换机及交换芯片关键模块 / 王鹏（CAJ） | `AFDX交换机及交换芯片中关键模块的设计_王鹏.caj`；（1）副本 | D | 与 L039 PDF 同源线索 |
| L021 | AFDX 网络协议交换设备的软件 / 苏稳 | `AFDX网络协议交换设备的软件设计与实现_苏稳.caj` | D | 交换设备软件线索 |
| L024 | AFDX 端系统芯片虚拟仿真平台 / 陆维杰 | `AFDX网络端系统芯片虚拟仿真平台的设计与实现_陆维杰.caj`；（1）副本 | D | 虚拟仿真平台线索 |
| L035 | AFDX 网络协议栈分析和设计 / 田泽 | `AFDX网络协议栈分析和设计_田泽.caj` | D | 协议栈线索 |
| L037 | AFDX 数据加卸载设备可靠性 / 贾世伟 | `一种AFDX网络数据加卸载设备可靠性设计与改进_贾世伟.caj` | D | 可靠性线索 |
| L038 | IMA 航电中 AFDX 远程数据集中器 / 严希青 | `IMA航电系统中基于AFDX网络的远程数据集中器的设计与实现_严希青.caj` | D | IMA/数据集中器线索 |
| L051 | 基于 FPGA 的 AFDX 端系统的设计与实现 / 黄劲松 | `基于FPGA的AFDX端系统的设计与实现_黄劲松.caj`（实际 PDF） | A | 端系统协议栈 + 虚拟链路层硬件实现范围 |
| L053 | 基于 FPGA 的 ARINC664/AFDX 端系统 / 王伟鹏 | `基于FPGA的ARINC664_AFDX端系统设计_王伟鹏.pdf`；`AFDX端系统设计-王伟鹏张延园姚进华.pdf` | A | VL 队列、BAG、TRC/RRM 模块划分 |
| L054 | AFDX 交换机硬件设计应用（PDF导出） / 陈杰群 | `AFDX交换机的硬件设计与应用研究-陈杰群.pdf` | A | 与 L040 同源 PDF 拉取，按一次证据计 |
| L055 | AFDX 交换机及交换芯片关键模块（PDF导出） / 王鹏 | `AFDX交换机及交换芯片中关键模块的设计-王鹏.pdf` | A | 与 L039 同源 PDF 拉取，按一次证据计 |
| L056 | AFDX 端系统协议栈虚拟链路层 / 许燕婷（CAJ） | `AFDX端系统协议栈虚拟链路层分析及仿真研究_许燕婷.caj` | D | 与 L064 同题名 CAJ 线索 |
| L057 | 基于 FPGA 的 AFDX 端系统协议栈虚链路层 / 任向隆 | `基于FPGA的AFDX端系统协议栈虚链路层的研究与实现_任向隆.caj` | D | FPGA/VL 线索 |
| L058 | AFDX 终端系统实现方案 / 牛仕奇 | `AFDX终端系统实现方案研究_牛仕奇.caj` | D | 终端系统实现线索 |
| L059 | 基于 miniVPX 的 AFDX 数据采集设备 / 刘旭东 | `基于miniVPX的AFDX数据采集设备的研制_刘旭东.caj` | D | 采集设备线索 |
| L060 | 与 L024 同题名副本 / 陆维杰 | `AFDX网络端系统芯片虚拟仿真平台的设计与实现_陆维杰 (1).caj` | D | 副本，不新增证据 |
| L061 | 千兆 AFDX 端系统芯片 FPGA 原型验证 / 李智伟 | `千兆AFDX网络端系统芯片的FPGA原型验证研究与实现_李智伟.caj` | D | FPGA 原型验证线索 |
| L062 | 面向 AFDX 网络可靠性的故障注入 / 余海燕 | `面向AFDX网络可靠性的故障注入技术研究_余海燕.caj` | D | 故障注入、可靠性线索 |
| L065 | 航空全双工以太网交换机若干关键技术 / 王斌文 | `航空全双工以太网交换机若干关键技术研究与实现-王斌文.pdf` | A | 接收→外部存储→发送缓存、调度、Jitter 来源 |
| L066 | 基于 FPGA 高速实时以太网数据传输 / 唐君妍 | `基于FPGA的高速实时以太网数据传输模块的设计与实现-唐君妍.pdf` | B | 高速以太网数据通路背景 |
| L093 | 基于 FPGA 千兆以太网 CMOS 图像传输 / 俞鹏炜 | `基于FPGA的千兆以太网CMOS图像数据传输系统设计_俞鹏炜.pdf` | C | 普通高速以太网，不支撑 AFDX 合规 |
| L094 | 基于 FPGA 千兆以太网相机传输 / 沈淦松 | `基于FPGA的千兆以太网相机的传输系统研究_沈淦松.pdf` | C | 普通高速以太网，不支撑 AFDX 合规 |

## 10. 统计

- 独立登记条目：L001–L137（L096–L137 为 2026-09-28 在线检索补充，见 §12）。
- 明确重复/同源，不重复计证：L086=L080，L095=L085，L054→L040，L055→L039，L060=L024，L025 等 CAJ+PDF 同题名。
- **可形成正文结论的 A/B 级资料**：分布于域 A–G，约 40+。
- **D 级题名线索**：域 H 中以 `D` 标注的 CAJ 条目；正文未取得前不支撑设计决策。
- 明确不支撑 AFDX 合规：L093、L094（普通千兆以太网）、L083/IMA 综合（背景）、特定平台/IP/器件文献。

## 11. 复现

```bash
find /c/Users/tortl/Downloads -maxdepth 1 -type f \( -iname '*.caj' -o -iname '*.pdf' \) -printf '%f\t%s\n' | sort
file /c/Users/tortl/Downloads/*.caj
sha256sum /c/Users/tortl/Downloads/*.caj
```

PDF 型 CAJ 可用 PyMuPDF/`pdftotext` 提取；`AFDX_补充文献/` 下已下载的英文/规范参考亦可用同一方式复查。CAJ 正文解析状态以文件头和专用阅读器结果为准，不能仅凭扩展名判断。

## 12. 2026-09-28 补充登记（L096–L137，在线检索，无本地全文）

> 来源：三份 2026-09-28 报告 ——[架构梳理与文献加强](AFDX端系统_架构梳理与文献加强_20260928.md)（L096–L120）、[存储子系统文献补充](AFDX端系统_存储子系统文献补充_20260928.md)（L121–L131）、[第三轮文献补充与设计优化建议](AFDX端系统_第三轮文献补充与设计优化建议_20260928.md)（L132–L137）。
> 均为在线检索登记（DOI／出版信息已核对），**未下载到 `AFDX_补充文献/`**。证据等级按本文 §1 口径：只看到摘要／二手信息的记为 C，读过标准原文的记为 A／B。每条的使用边界见对应报告。

| ID | 题名/作者 | 出处 / DOI | 证据 | 用途（域 / 支撑项） |
|---|---|---|---|---|
| L096 | Methods for bounding end-to-end delays on an AFDX network / Charara 等 | ECRTS 2006；10.1109/ECRTS.2006.15 | C | 网络级时延上界方法（背景，不替代 ES 内时延） |
| L097 | Optimized trajectory approach for AFDX worst-case delay / Bauer 等 | IEEE TII 6(4):521–533, 2010；10.1109/TII.2010.2055877 | C | 轨迹法最坏时延 |
| L098 | Probabilistic analysis of end-to-end delays on AFDX / Scharbarg 等 | IEEE TII 5(1):38–49, 2009；10.1109/TII.2009.2016085 | C | T13 报告 P99 的方法依据 |
| L099 | Integrating offsets in worst-case analysis / Li, Scharbarg, Fraboul | ETFA 2010 | C | **D10 错相的直接依据** |
| L100 | Existing offset assignments are near optimal / Li 等 | ACM SIGBED Rev. 8(4):49–54, 2011；10.1145/2095256.2095263 | C | D10 偏移分配启发式 |
| L101 | Integrating end-system frame scheduling / Boyer 等 | ERTS 2014；hal-02272276 | C | 发送端调度纳入时延分析 |
| L102 | Using network calculus to optimize AFDX / Francés 等 | ERTS 2006；hal-02270458 | C | TX 优先级讨论 |
| L103 | Network Calculus / Le Boudec, Thiran | Springer LNCS 2050, 2001；10.1007/3-540-45318-0 | B | 到达曲线/服务曲线定义 |
| L104 | Optimal design of virtual links in AFDX / Al Sheikh 等 | Real-Time Syst. 49(3):308–336, 2013；10.1007/s11241-012-9171-z | C | `bag_budget.py`、T05c 配置判决 |
| L105 | Formal specification and analysis of AFDX RM algorithms / Täubrich, von Hanxleden | SAFECOMP 2007, LNCS 4680:436–450；10.1007/978-3-540-75101-4_42 | C | RM 算法取舍（D12、OPT-1） |
| L106 | Formal modeling of AFDX frame management / Anand 等 | ISORC 2006:393–399 | C | network babbling、RM 形式化 |
| L107 | Reliability enhancement of RM in AFDX / Meng Li 等 | IEEE TII 13(5):2118–2129, 2017；10.1109/TII.2017.2732345 | C | RM 失效与 A/B 抖动、SN 窗口（OPT-1） |
| L108 | Determinism enhancement via frame insertion and sub-VL aggregation / Meng Li 等 | IEEE TII 10(3):1684–1695, 2014 | C | Sub-VL（P2） |
| L109 | Cuckoo hashing / Pagh, Rodler | J. Algorithms 51(2):122–144, 2004；10.1016/j.jalgor.2003.12.002 | C | `rx_vl_lookup` 基础（每桶 1 项） |
| L110 | Tightly packed constant size bins / Dietzfelbinger, Weidling | TCS 380(1–2):47–68, 2007 | C | 多 way 桶负载率（ℓ=2 时写 0.829–0.981 区间，不写单值） |
| L111 | Cuckoo hashing with a stash / Kirsch 等 | SIAM J. Comput. 39(4):1543–1561；10.1137/080728743 | C | 小 stash 降低摆放失败 |
| L112 | Fast lookup for dynamic packet filtering in FPGA / Kekely 等 | DDECS 2014:219–222；10.1109/DDECS.2014.6868793 | C | FPGA 布谷鸟实现（方法借鉴） |
| L113 | FPGA-based cuckoo hashing for NIDS / Tran, Kittitornkun | APNOMS 2007, LNCS 4773:334–343 | C | 同上 |
| L114 | Parallel CRC realization / Campobello 等 | IEEE TC 52(10):1312–1319, 2003；10.1109/TC.2003.1234528 | C | §8.1 CRC32 按字节展开 |
| L115 | Retiming synchronous circuitry / Leiserson, Saxe | Algorithmica 6:5–35, 1991；10.1007/BF01759032 | C | A05／OPT-5 时序切分 |
| L116 | RFC 3416 SNMPv2 PDU §4.2.5 | IETF 标准原文（已 grep 核对） | A | A01／OPT-2 SET 原子性 |
| L117 | Mutation testing survey / Jia, Harman | IEEE TSE 37(5):649–678, 2011；10.1109/TSE.2010.62 | C | 变异体方法论（A03/A04/OPT-4） |
| L118 | Functional Verification Coverage Measurement / Piziali | Springer 2004；10.1007/b117979 | C | 功能覆盖 covergroup |
| L119 | AFDX software network stack — lessons learned / Khazali 等 | DASC 2009 | C | D5 软硬划分 |
| L120 | NC timing analysis of AFDX with SP and TSN/BLS / Finzi 等 | SIES 2018；10.1109/SIES.2018.8442080 | C | 演进背景 |
| L121 | Dynamic queue length thresholds for shared-memory switches / Choudhury, Hahne | IEEE/ACM ToN 6(2):130–140, 1998；10.1109/90.664262 | C | 公共池 DT 配额（OPT-7） |
| L122 | Tighter buffer dimensioning in AFDX / Benammar 等 | ACM SIGBED Rev. 13(4):37–42, 2016；10.1145/3015037.3015043 | C | RX 块池容量上界 |
| L123 | FPGA-based queue management system / Nikologiannis 等 | Microproc. Microsyst. 28(5–6):223–236, 2004；10.1016/j.micpro.2004.03.014 | C | 链表空闲块管理 |
| L124 | Designing packet buffers for router linecards / Iyer 等 | IEEE/ACM ToN 16(3):705–717, 2008；10.1109/TNET.2008.923720 | C | 包缓冲下界（背景） |
| L125 | Efficient multi-ported memories for FPGAs (LVT) / LaForest, Steffan | FPGA 2010:41–50；10.1145/1723112.1723122 | C | PMEM 1W2R、配置表 BRAM 化 |
| L126 | Multi-ported memories via XOR / LaForest 等 | FPGA 2012；10.1145/2145694.2145730 | C | 同上 |
| L127 | Composing multi-ported memories on FPGAs / LaForest 等 | ACM TRETS 7(3):16, 2014；10.1145/2629629 | C | 同上 |
| L128 | Packet transactions / Sivaraman 等 | SIGCOMM 2016:15–28；10.1145/2934872.2934900 | C | 读—判—写原子状态更新（RM/IC） |
| L129 | AFDX 网络关键协议分析与研究 / 田泽，姜丽云，陈伟 等 | 电子技术应用 2016, 42(4):7–10,14 | B | 采样/队列端口语义（与 L045 同团队） |
| L130 | 基于自研 AFDX 端系统芯片的模块设计与实现 / 夏大鹏 等 | 电子技术应用 2016, 42(4):15–17；10.16157/j.issn.0258-7998.2016.04.004 | B | 128 TX / 4096 RX VL 同规模国产芯片对照 |
| L131 | SEU recovery mechanism for SRAM-based FPGAs / Legat 等 | IEEE TNS 59(5):2562–2571, 2012 | C | ECC／scrubbing（扩展项，非交付要求） |
| L132 | Metastability and Synchronizers: A Tutorial / Ginosar | IEEE D&T 28(5):23–35, 2011；10.1109/MDT.2011.113 | C | `pps_in` CDC／MTBF（OPT-9） |
| L133 | RFC 5905 NTPv4，附录 A.5.5.6 clock discipline / Mills 等 | IETF 标准，2010 | B | RTC 相位＋频率环、step 阈值（OPT-8） |
| L134 | IEEE 1588 PI 时钟伺服（例：Fuzzy-PI Clock Servo with Window Filter，2024，PMC11014061） | 开放获取 | C | OPT-8 旁证（偏移＋频率补偿），不引用其精度数字 |
| L135 | Hashed and hierarchical timing wheels / Varghese, Lauck | IEEE/ACM ToN 5(6):824–834, 1997；10.1109/90.650142 | C | 调度器扩容路径（OPT-11，现阶段不实施） |
| L136 | Formal Verification: An Essential Toolkit for Modern VLSI Design / Seligman 等 | Morgan Kaufmann 2015（第 2 版 2023）；10.1016/C2013-0-18672-2 | C | 小模块 FPV（OPT-10） |
| L137 | RFC 4303 ESP，§3.4.3 抗重放滑动窗口 / Kent | IETF 标准，2005 | B | RM 的“最高 SN＋位图”判重结构（OPT-1） |

补充统计：L096–L137 共 42 条，其中 A 1 条（L116），B 5 条（L103、L129、L130、L133、L137），其余 36 条为 C。**C 级条目只用来说明“方法出处／问题定位”，不作为指标数字的来源。**

## 13. 2026-09-28 本地库清理与第四轮补充（L138–L157）

> 详情见 [第四轮文献补充](AFDX文献补充_第四轮_20260928.md) 与 [本地文献库索引](../文献/README.md)。

### 13.1 本地 `文献/` 目录清理

- 按逐文件 SHA-256 去重：**90 → 53 个文件**，删除 31 份字节完全相同的副本（清单 `out/lit_delete.txt`，哈希表 `out/lit_hashes.txt`）。**未删除任何唯一内容。**
- 6 份与 AFDX 无关的材料移入 `文献/_无关/`（未删除，不登记、不计入统计）。
- **L086** 对应的 `AFDX网络中SkewMax的研究_李哲 (1).pdf` 是 L080 的同哈希副本，文件已删除；L086 原本就登记为“不新增证据”，正文结论不变，仍由 L080 支撑。
- 保留文件名优先采用本目录已引用的写法；L033/L042、L039/L055、L040/L054 等同源条目的首选文件名未变。
- 待办：域 E 的 `SNMP…_张晓明 (1).pdf`、`…王纯委 (1).pdf` 及 `AFDX端系统通信端口的设计与实现_武华.pdf` 与本目录首选件**字节不同**，均予保留，待比对版本后再合并登记。

### 13.2 新增登记

| ID | 题名/作者 | 出处 / 本地文件 | 证据 | 用途 |
|---|---|---|---|---|
| L138 | 基于 AFDX 的航空电子通信网络的设计 / 叶佳字 | `文献/基于AFDX的航空电子通信网络的设计_叶佳字.pdf` | D | 域 A 背景，正文待解析 |
| L139 | Computation of tight bounds for the worst-case end-to-end delay on AFDX | J. Syst. Archit. 2024 | C | 网络级时延界最新进展（背景） |
| L140 | WCD analysis for an AFDX evolution network（μAFDX） | IEEE 2021 | C | 演进背景 |
| L141 | Exact worst-case communication delay analysis of AFDX / Adnan | 博士论文 hal `tel-04312707` | C | ES 端 offset 调度纳入精确分析，**D10 的独立佐证** |
| L142 | Optimal VL paths via modified ant colony optimization | Expert Syst. Appl. 2023 | C | VL 路由规划，本项目不实施 |
| L143 | Modeling of Data Link Redundancy and Network Failure Recovery in AFDX | 2024-12，**出处待核实** | C | 仅线索，核实前不得引用 |
| L144 | Method of data integrity control in an AFDX network | 专利 US 7,817,565 B2 | C | `rx_ic` 语义的工业侧旁证 |
| L145 | A Hash Table for Line-Rate Data Processing / István 等 | ACM TRETS 8(2):13, 2015；10.1145/2629582 | C | 查表时延与报文时间预算匹配（RX 查表流水） |
| L146 | FASTHash: FPGA-Based High Throughput Parallel Hash Table | ISC HPC 2020 | C | 片上多 way 哈希表流水深度与时序取舍 |
| L147 | High-Throughput and Memory-Efficient Pipeline KVS on FPGA | Micromachines 16(12):1398, 2025；10.3390/mi16121398 | C | **配置表 BRAM 化 + 读延迟适配最贴题依据** |
| L148 | TcbTree: FPGA 可更新包分类（TSS + 集中哈希表） | 会议论文 | C | 集中式表的资源组织 |
| L149 | Fast and scalable packet classification using perfect hash functions | FPGA 2009:229–236 | C | 完美哈希备选方案，现阶段不实施 |
| L150 | AN 903: Accelerating Timing Closure（Quartus Prime **Pro**） | Intel 应用笔记 | C | 高扇出与寄存器复制 assignment |
| L151 | Register Duplication for Timing Closure | Intel FPGA Wiki | C | `maxfan`／`dont_merge`／手工复制的收益对比 |
| L152 | Quartus Prime **Standard** Edition UG: Design Optimization（ug-qps-05，UG-20177，Quartus 18.1） | **本地全文** `AFDX_补充文献/L152_Quartus_Standard_DesignOptimization_ug-qps-05.pdf`（**167 页，2026-09-28 下载归档**） | **B** | **与本项目工具链直接对应**：§6.1 物理综合（6.1.3 Perform Register Retiming / 6.1.4 Preventing Register Movement）、§6.2 网表优化、关键路径与 slack 分析、非全局高扇出报告。**125 MHz 未收敛（WNS −5.037 ns）攻关的首选手册。** 按 §1「方法参考」归 B，不作指标来源 |
| L153 | Advanced Verification Methods for Safety-Critical Airborne Electronic Hardware / Butka（Embry-Riddle） | FAA **DOT/FAA/TC-14/41**，2015-01 Final Report；**本地全文** `AFDX_补充文献/L153_FAA_TC-14-41_AdvancedVerification.pdf`（**70 页，2026-09-28 下载归档**，SHA-256 前 16 位 `e48f411b37c6b8ab`） | **B** | 官方报告，**三类覆盖率（code / assertion / functional）并用**，按 DAL A/B/C 给覆盖率目标；明确形式方法应与仿真并行、断言本身也要形式验证。支撑本项目覆盖率章节的**表述口径**。⚠️ **本项目非 DO-254 项目，引用其口径不得声称任何 DAL 等级。** 按 §1「方法参考」归 B |
| L154 | Coverage-Driven Verification Methodology | Doulos Easier UVM | C | 功能覆盖 vs 代码覆盖的流程口径 |
| L155 | ARINC 664 Part 7: End System Design & Parameters | Logic Fruit 博客 | C | 二手综述，冲突时以 L001 为准 |
| L156 | iW-ARINC-664/AFDX FPGA IP Core | iWave 产品资料 | C | 商用 IP 规模对照（8 VL），与 L130 并用 |
| L157 | AFDX Data Bus / Yanik | MGEO TR-05-0001 | C | VLID/端口教学综述，不作合规证据 |
| **L158** | **ARINC SPECIFICATION 664 PART 7（AFDX 规范原文，2005 初版，145 页）** | `AFDX_补充文献/ARINC664P7_spec.pdf` | **A** | **规范原文，本目录最高等级证据**。§3.2.6.1 SN、§3.2.6.2.1 IC 窗口与 PSN、§3.2.6.2.2 RM/SkewMax/First-Win、§3.2.4.3 抖动双式与 500 μs、§3.2.2 BAG=2^k、§3.3.1.1 采样/队列端口语义。摘录与工程对照见 [ARINC664P7 条款摘录](ARINC664P7_条款摘录_20260928.md)。**注意为 2005 初版，现行 664P7-1(2009) 未持有，引用须标版本** |

补充统计：L138 为本地新登记（D）；L139–L157 中 **L152、L153 已于 2026-09-28 下载全文并归档，升级为 B**，其余 17 条仍为 C——
均为联网检索、**未下载全文**，只用于说明方法出处与问题定位，**不作为任何指标数字的来源**。

**下载受阻记录（2026-09-28，勿重复尝试同一入口）**：

| ID | 入口 | 结果 |
|---|---|---|
| L141 Adnan 博士论文 | `theses.hal.science/tel-04312707v1/file/adnan.pdf` | HAL 的 **Anubis 机器人挑战**页（返回 12 KB HTML）；OATAO 镜像 `oatao.univ-toulouse.fr` TLS 握手失败 |
| L147 Micromachines 2025 | `mdpi.com/2072-666X/16/12/1398/pdf` | **Cloudflare 拦截**（返回 410 B HTML） |
| L150 Intel AN 903 | `intel.com/programmable/technical-pdfs/683664.pdf` | 重定向页（421 B）；`manuals.plus` 镜像返回 HTML |

以上三条**需人工用浏览器下载**后放入 `AFDX_补充文献/` 并回本表升级。L150 与 L152 内容高度重叠且 L150 是 **Pro** 版（语法与本项目 Standard 工具链不通用），**优先级最低**。