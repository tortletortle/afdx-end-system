# AFDX 文献工程映射

更新：2026-09-24

本文把文献结论映射到当前仓库的 RTL、脚本和验证项。它不是实现状态的替代品：实现状态必须回到源码、测试清单、日志和报告核对。

## 1. 追溯矩阵

| 工程主题 | RTL/脚本/TB | 相关文献 | 文献支持内容 | 当前状态 | 已有证据 | 尚未证明 |
|---|---|---|---|---|---|---|
| RX 帧接收与完整提交 | `rtl/rx/mac_rx_if.v`、`rtl/rx/rx_pmem_queue.v` | L001、L002、L007 | 完整性检查后形成可供后级处理的帧/descriptor | 已实现局部 | T08a/T08ag/T08b | 长时间压力、所有错误类别闭环 |
| RX 块池和 PMEM 所有权 | `rtl/rx/rx_block_pool.v`、`rx_pmem_queue.v` | L001、L010、L016 | FIFO/共享存储支撑双网帧缓存 | 已实现局部 | T08c/T08cg | 全链路唯一释放、耗尽恢复 |
| VL 查找和过滤 | `rtl/rx/rx_vl_lookup.v`、`rx_flt.v` | L001、L002、L005、L008 | 静态 VL 表、配置过滤、错误统计 | 已实现局部 | T08d/T08dg、T12 系列 | 配置 BRAM 化、完整后级接线 |
| IC/PSN | `rtl/rx/rx_ic.v` | L001、L007、L008 | 每 VL 序列状态和完整性检查 | 单元已验证 | T09/T09s/T09p/T09ps | 顶层接入、与 FLT/RM 的状态边界 |
| RM 去重 | `rtl/rx/rx_rm.v` | L001、L005、L007、L008 | A/B 副本只交付一份，考虑 skew | 空壳/P0 | 无顶层证据 | 同拍、先到、SkewMAX、timeout、背压 |
| IP/UDP/通信端口解析 | `rtl/rx/rx_ip_udp_parse.v` | L003、L007、L016、L017 | VL/UDP/通信端口关联和字段检查 | 空壳/P0 | 无 | 长度、端口映射、管理 SAP |
| 采样端口 | `rtl/rx/rx_port_buf.v` | L007、L016、L028 | 最新值覆盖和 freshness | 空壳/P0 | 无 | 覆盖语义、读回和释放 |
| 队列端口 | `rtl/rx/rx_port_buf.v` | L001、L007、L016、L028 | 顺序积压、深度和溢出处理 | 空壳/P0 | 无 | FIFO、分片、端口满和块所有权 |
| TX VL 调度/BAG | `rtl/tx/tx_vl_scheduler.v` | L001、L002、L008、L014、L025、L031 | VL 级整形和最小发送间隔 | 局部实现 | T04/T04g、T05c | 全 BAG 档、同相/错相满载、jitter |
| TX 帧封装 | `rtl/tx/tx_frame_builder.v`、`mac_tx_if.v` | L001、L005、L008 | IP/UDP/SN/FCS 和双网发送 | 局部已验证 | T03/T04/T04g | 顶层端到端接收闭环 |
| 主机前门和 descriptor | `rtl/top/AFDX_top.v`、`host_if.v` | L003、L005、L009、L019、L029、L030 | 配置、数据搬运、DMA/中断边界 | 局部实现 | T08c/T08cg、T22a | 持续双网负载、RX 读回、混合读写 |
| 监控统计/时间戳 | `rtl/top/stats_regs.v`、`sim/out/*` | L004、L006、L018、L020、L032 | 帧/字节/错误/BAG/Jitter/时标观测 | 局部/规划 | 局部 DROP/统计日志 | 端到端时间戳、每 VL 指标、长时证据 |
| 故障注入和验证 | `sim/tests.manifest`、`tools/`、`sim/tb/` | L002、L004、L005、L022、L026、L027 | 正常、错误、冗余、压力和故障注入 | 局部已建立 | 26 项快照及 mutant 证据 | T08/T22 完整闭环、长期随机 |
| 可靠性/复位 | `AFDX_top.v`、各 block pool/状态 RAM | L001、L005、L006、L008、L037 | 双网、错误隔离、初始化和可恢复性 | 局部实现 | 初始化/IC/过滤测试 | 全状态复位、块守恒和恢复压力 |
| 管理面 | `rtl/mgmt/` | L005、L009、L017、L021 | 高层协议、配置、驱动和管理职责 | 未完整交付 | 无完整闭环 | RTC、SNMP、615A/TFTP、真实中断 |

## 2. 本批新增映射

| 新增文献 | 直接对应工程问题 | 当前处理 |
|---|---|---|
| L044、L045 | 通信端口配置、端口查找、收发和驱动接口 | `rx_ip_udp_parse`、`rx_port_buf` 需要明确配置到投递的 descriptor 契约 |
| L047 | 配置表描述固定路径和确定性参数 | 保持配置映像、提交门和运行态 gate 分离，并补配置模块测试 |
| L049 | 接收顺序：SN 完整性 → 冗余过滤 → IP 校验 | 将其作为 RX 集成 scoreboard 的候选检查顺序，最终以规范/设计书为准 |
| L041、L050、L052、L053 | 调度器、BAG、抖动、TRC/RRM 模块划分 | 补 T05/T13 的调度选择、线上时间和双网发送观测 |
| L039 | CAM/VL 过滤、警管和测试向量 | 继续强化 `rx_vl_lookup`/`rx_flt` 的表项和拒绝原因覆盖 |
| L040、L045 | 故障检测和系统测试 | 增加故障注入、恢复和错误统计，不把正常帧测试当可靠性证明 |
| L046 | SNMP MIB、配置/故障管理、事件上报 | 为 `stats_regs`、SNMP 和管理面定义事件来源边界 |
| L050-L053 | FPGA 低层硬件与 IP/UDP/端口软件划分 | 作为架构参考，不替代当前综合、CDC 和 STA |

## 2.1 五篇核心 PDF 的直接落点

| 文献 | 关键页码/范围 | 对当前工程的落点 |
|---|---|---|
| L045 | PDF p.3 摘要；目录约 p.20–32 | 将端系统协议栈、主机驱动端口查找、IC/RM、配置不匹配过滤和系统级测试列为独立闭环 |
| L041 | PDF 摘要约 p.17；调度约 p.23–38；测试约 p.39–68 | 为 TX/RX 调度、配置表测试、功能测试和性能测试建立分层验证计划 |
| L049 | PDF p.1–2 | RX scoreboard 候选顺序：SN 完整性 → 冗余过滤 → IP 校验；作为文献建议，不覆盖正式规格 |
| L044 | PDF p.1–2 | 端口配置 → 创建 → 收发 → 应用/驱动可见性，直接对应 `rx_port_buf` 和主机读回契约 |
| L047 | PDF p.1–2 | 配置文件描述固定路径和确定性参数，直接对应配置映像、提交门和运行态 gate |

## 3. 直接影响当前 P0 的文献依据

### P0-01：统一 IC、RM 和块所有权

L001、L007、L008 共同支持“完整性检查”和“冗余去重”是两个连续但不同的阶段。由此建议：

1. `rx_ic` 成为 PSN 状态的唯一拥有者；
2. `rx_rm` 只处理通过 IC 的帧；
3. duplicate、IC reject、FLT reject 和端口丢弃都必须有唯一 block release；
4. 直到采样/队列端口或主机读回完成，payload block 不得提前归还。

这些是微架构建议，仍需与总体设计书的接口和释放契约核对。

### P0-02：完成 RX 端到端最小闭环

文献共同指向以下最小可验证路径：

```text
TX VL 配置 → TX 帧/SN/BAG → A/B 回环
→ RX MAC/PMEM → VL/FLT → IC → RM
→ UDP/端口解析 → sampling/queue → 主机读回
```

当前仓库只完成到 RX 前半段和独立 IC，不能把已有单元测试拼接成整机验收。应新增逐帧 scoreboard，检查：

- 好帧只交付一次；
- 坏帧不更新 PSN/RM；
- A/B duplicate 只保留首个合法副本；
- 端口载荷无误；
- block allocation/release 守恒；
- 主机读回与配置的 VL/端口匹配。

### P1-01：BAG、时延和监控

L001、L006、L018、L025、L031 的主题线索支持把 BAG、调度等待、端到端时延和 jitter 分开量测。当前建议观测：

```text
t_tx_frame_start
→ t_rx_frame_commit
→ t_lookup_done
→ t_flt_done
→ t_ic_done
→ t_rm_selected
→ t_port_visible
→ t_host_read
```

必须注明 IF_MODE、125 MHz 时钟、帧长、BAG、是否同相启动、样本量和统计口径。解析预算或论文实验结果不能替代 RTL/STA 证据。

## 3. 不应直接迁移的文献实现

以下内容可作为方法参考，但不自动成为当前项目约束：

- Xilinx/Altera 特定 FPGA IP、PowerPC、EDK、PLB、PCIe 和 vxWorks；
- 特定 ASIC 工艺、封装、功耗和商业 MAC；
- 论文采用的端口数量、VL 数量、缓存容量和物理拓扑；
- 论文报告的“通过协议测试”或“满足性能指标”；
- 仅由 D 级题名线索推断的模块行为。

当前项目仍以 `AFDX端系统_总体设计书.md`、`doc/regs.yaml`、当前 RTL/TB、manifest、日志、综合和 STA 报告为准。

## 4. 追溯规则

- 文献 ID 只标识资料来源，不代表需求 ID 或验证 ID；
- “文献支持”不等于“当前实现”；
- “单元测试通过”不等于“顶层闭环通过”；
- 任何映射变更应同时写明源码路径、测试 ID、运行配置和未覆盖边界；
- 文献之间冲突时，记录冲突并回到规范/总体设计书，不静默选取有利结论。
