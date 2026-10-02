# AFDX 端系统 — 测试仿真报告历史基线

> **这不是当前版结论。** 墙钟 613.5 s 及以下逐项数字属于 Continue12 之前的冻结版本。当前版见 [测试仿真报告](../AFDX端系统_测试仿真报告.md) 第 0～6 节。

## 1. 结论

| 项 | 结果 |
|---|---|
| 回归用例总数 | **56 项** |
| 通过 | **56 项（100%）** |
| 失败 | 0 |
| 累计仿真墙钟 | 613.5 s |
| 编译错误 | 0 |
| Verilator lint | PASS（0 `%Error`） |
| 文档/地址/寄存器一致性门 | PASS（5/5 + selfcheck） |

设计书测试矩阵 **T00–T23 全部覆盖并通过**，其中每个顶层用例均在两种接口档位下各跑一遍：

- `IF_MODE=0`：每 10 拍一字节，对应 **100 Mbps** 线速（选题指南规定的技术指标）
- `IF_MODE=1`：每拍一字节（GMII），对应约 1 Gbps 接口能力（超出指南要求的额外验证）

### 本报告不宣称的事（证据边界）

为避免指标越界，以下内容**不在本报告结论范围内**：

1. 本报告只提供**功能仿真**证据，不构成综合、时序或 ARINC 664 P7 认证结论。
2. 代码覆盖率为**含 TB 实例的分支 + 语句**覆盖率，不是 RTL-only，也不是 covergroup 功能覆盖率。
3. 时序收敛另见综合与 STA 报告；本报告的 PASS 不蕴含时序收敛。
4. 所有 PASS 均绑定下文的源码/清单 SHA-256；脱离该哈希的结论不可复用。

---

## 2. 验证方法

### 2.1 三层证据结构

| 层次 | 手段 | 作用 |
|---|---|---|
| 单元层 | 模块级 TB + Python 黄金模型逐位对拍 | 定位算法正确性（CRC32、IC PSN 判决、哈希查表） |
| 集成层 | `AFDX_top` 顶层 TB，激励从 MAC 引脚注入、结果从主机前门读出 | 证明整条数据通路接通，而非模块孤立可用 |
| 变异层 | 故障注入（mutation testing），共 9 套 | 证明测试**有能力发现错误**，而不是恒真通过 |

### 2.2 黄金模型对拍

`sw/golden/` 下的 Python 模型独立生成激励与期望值，与 RTL 结果逐字节比对。模型**不参与** RTL 实现，仅作独立参照物；模型自身用 `zlib.crc32` 等标准库交叉验证。

### 2.3 故障注入（关键可信度证据）

向 RTL 注入单点缺陷，要求对应测试**必须转为 FAIL**。未被检出的变异即为测试盲区。

| 变异集 | 注入点 | 检出率 |
|---|---|---|
| `test_t11_mutants.py` | 接收端口投递语义 | **13/13** |
| `test_t11i_mutants.py` | RX 事件中断 / W1C | **9/9** |
| `test_t10_mutants.py` | RM 双网去重 | **7/7** |
| `test_t08e_mutants.py` | IC 完整性判决 | **7/7** |
| `test_t22_mutants.py` | TX→RX 冷启动回环 | **6/6** |
| `test_t12_mutants.py` / `test_t12_top_mutants.py` | 哈希查表 | 全数检出 |
| `test_t08c_mutants.py` | 主机争用仲裁 | 全数检出 |
| `test_t09_mutants.py` | IC 单元 | 全数检出 |
| `test_t21_mutants.py` | 块池耗尽 | 全数检出 |

### 2.4 可复现性

每次全量回归产出 `sim/out/regress_*.csv` 与 `test_evidence_*.json`，后者登记本次运行涉及的**全部 RTL / TB / 向量 / 日志文件的 SHA-256**。复现时先校验哈希再执行，确保结论与源码版本严格绑定。

---

## 3. 测试矩阵与结果（T00–T23）

下表每行对应设计书的一个目标用例；「用例」列列出实际执行的测试 ID（含 `g` 后缀的 GMII 档）。

| 目标 | 名称 | 验证目的 | 用例 | 结果 | 耗时 |
|---|---|---|---|:--:|---:|
| **T00** | 黄金模型与公共模块 | crc32 / sync_fifo / bram_sdp 位级对拍 | `T00` | ✅ PASS | 4.6 s |
| **T01** | 复位与寄存器/表项 | 上电复位、寄存器页读写、表项清扫、主机流水时序 | `T01` | ✅ PASS | 271.4 s |
| **T02** | TX 端口缓冲与序列号 | 采样/队列端口语义、SN 1–255 回绕 | `T02` | ✅ PASS | 4.0 s |
| **T03** | AFDX 帧构造 | 802.3+ARINC664 帧格式、填充、校验和、双网 | `T03` | ✅ PASS | 5.1 s |
| **T04** | BAG 带宽调度合规 | 单 VL 帧间隔落在 BAG 窗口内 | `T04 / T04g` | ✅ PASS | 19.7 s |
| **T05b** | 满载抖动 | 32 VL 同时激活下的抖动上界 | `T05b / T05bg` | ✅ PASS | 19.1 s |
| **T05c** | Q20 配置判决 | 份额表边界、缺项、超配拒绝 | `T05c` | ✅ PASS | 5.1 s |
| **T08a** | RX 入口解析 | 流式 FCS/IP/UDP/格式检查 | `T08a / T08ag` | ✅ PASS | 7.0 s |
| **T08b** | RX 顶层入口 | 双网同拍、块池、PMEM 字节使能、主机仲裁 | `T08b / T08bg` | ✅ PASS | 8.5 s |
| **T08c** | 主机争用仲裁 | RX 优先时主机写延后与 ACK 契约 | `T08c / T08cg` | ✅ PASS | 10.2 s |
| **T08d** | 语义过滤 FLT | 未配置/错网/VLID/Lmax/CRC 五类拒绝 | `T08d / T08dg` | ✅ PASS | 10.2 s |
| **T08e** | IC 顶层集成 | PSN 判决、块守恒、skew 扫描 | `T08e / T08eg` | ✅ PASS | 19.4 s |
| **T08f** | 全表 scoreboard | 4096 键全表灌装 + 逐笔比对 | `T08f / T08fg` | ✅ PASS | 11.5 s |
| **T09** | IC 单元与压力 | PSN 槽全覆盖、背压、回绕 | `T09 / T09s / T09p / T09ps` | ✅ PASS | 12.6 s |
| **T10** | RM 双网冗余消除 | A/B 副本只转发一次、SkewMax 窗口 | `T10 / T10g` | ✅ PASS | 9.2 s |
| **T11** | 接收端口投递 | 采样/队列语义、溢出、逐字节读回 | `T11 / T11g` | ✅ PASS | 8.1 s |
| **T11i** | RX 事件中断 | INT_STATUS W1C、屏蔽、同拍竞争 | `T11i / T11ig` | ✅ PASS | 6.6 s |
| **T12** | 4096 VL 查表压力 | 哈希查表命中/未命中/重散列 | `T12c / T12r / T12s / T12h / T12f / T12fg` | ✅ PASS | 31.3 s |
| **T13** | 端到端时延 | TX→RX 闭环时延测量 | `T13 / T13g` | ✅ PASS | 6.8 s |
| **T14** | 统计计数器 | 帧/字节/丢弃分类/直方图、W1C、冻结 | `T14 / T14g` | ✅ PASS | 11.6 s |
| **T15** | SNMP 网络管理 | 真实 BER PDU GET/GETNEXT/SET | `T15 / T15g` | ✅ PASS | 12.8 s |
| **T16** | 615A 数据加卸载 + RTC | TFTP WRQ/DATA/重传、RTC 锁定/丢失 | `T16 / T16g` | ✅ PASS | 10.1 s |
| **T17** | 线速最小帧冲击 | 512 对最小帧背靠背 | `T17 / T17g` | ✅ PASS | 13.4 s |
| **T18** | 长时随机回归 | 随机长度/间隔/并发事务 | `T18 / T18g` | ✅ PASS | 66.4 s |
| **T21** | 反压与块池耗尽 | 块池耗尽 → NO_BLK → 归还恢复 | `T21 / T21g` | ✅ PASS | 7.0 s |
| **T22** | 上电全流程回环 | 冷启动配置 → 发送 → 回灌 → 主机读回 | `T22 / T22g` | ✅ PASS | 10.6 s |
| **T22a** | TX 前门切片 | 初始化 + 表/PMEM 前门 | `T22a` | ✅ PASS | 3.4 s |
| **T23** | 管理 SAP 最小通路 | SAP 描述符与块归还 | `T23 / T23g` | ✅ PASS | 7.8 s |

**合计 56 项，56 项 PASS，0 项 FAIL。**

---

## 4. 逐项测试详情

每项给出验证目的、执行配置与实测结果摘要；摘要直接摘自回归 CSV 的 `summary` 字段，未经改写。

### T00 — 黄金模型与公共模块

**验证目的**：crc32 / sync_fifo / bram_sdp 位级对拍

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T00` | `default` | `tb_t00_common` | ✅ PASS | 4.6 s |

**实测结果摘要**：

> T00 COMMON PASS (crc32 x9 vectors; fifo 4000; bram 1W2R 8192 + BE)

### T01 — 复位与寄存器/表项

**验证目的**：上电复位、寄存器页读写、表项清扫、主机流水时序

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T01` | `default` | `tb_t01_reset_regs` | ✅ PASS | 271.4 s |

**实测结果摘要**：

> T01 INIT/REG PASS (25344 writes + re-reset + table R/W + pipeline + timebase)

### T02 — TX 端口缓冲与序列号

**验证目的**：采样/队列端口语义、SN 1–255 回绕

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T02` | `default` | `tb_t02_tx_buf_sn` | ✅ PASS | 4 s |

**实测结果摘要**：

> T02 TXBUF PASS (tx_sn_gen wrap/override/init; tx_port_buf smp/queue/exhaust/T17-pending/random)

### T03 — AFDX 帧构造

**验证目的**：802.3+ARINC664 帧格式、填充、校验和、双网

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T03` | `default` | `tb_t03_frame_builder` | ✅ PASS | 5.1 s |

**实测结果摘要**：

> T03 BUILDER PASS (16 golden frames x 3 rdy modes; L=8..1471; pad/SN/csum/B-net; stall=0 at line rate)

### T04 — BAG 带宽调度合规

**验证目的**：单 VL 帧间隔落在 BAG 窗口内

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T04` | `default` | `tb_t04_tx_chain` | ✅ PASS | 10.3 s |
| `T04g` | `gmii` | `tb_t04g_tx_chain` | ✅ PASS | 9.4 s |

**实测结果摘要**：

> T04 TXCHAIN PASS (IF_MODE=0; 138 frames; BAG/FCS/SN/payload/dual-net/IFG ok; single-VL gap 4220..4360 cyc)

> T04 TXCHAIN PASS (IF_MODE=1; 140 frames; BAG/FCS/SN/payload/dual-net/IFG ok; single-VL gap 4229..4674 cyc)

### T05b — 满载抖动

**验证目的**：32 VL 同时激活下的抖动上界

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T05b` | `saturated-jitter` | `tb_t05b_jitter` | ✅ PASS | 10.1 s |
| `T05bg` | `saturated-jitter-gmii` | `tb_t05bg_jitter` | ✅ PASS | 9 s |

**实测结果摘要**：

> T05b SATURATED JITTER PASS (IF_MODE=0 VLs=32 frames=96 startup_jitter=4us steady_max_jitter=3us avg_steady_jitter=2us link_load=99.86%)

> T05b SATURATED JITTER PASS (IF_MODE=1 VLs=32 frames=96 startup_jitter=4us steady_max_jitter=3us avg_steady_jitter=3us link_load=99.86%)

### T05c — Q20 配置判决

**验证目的**：份额表边界、缺项、超配拒绝

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T05c` | `default` | `tb_t05c_cfg_budget` | ✅ PASS | 5.1 s |

**实测结果摘要**：

> T05c CFGBUDGET PASS (Q20 32/128 VL; exact-boundary/burst/missing/over/reset; frontdoor)

### T08a — RX 入口解析

**验证目的**：流式 FCS/IP/UDP/格式检查

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T08a` | `default` | `tb_t08a_rx_ingress` | ✅ PASS | 3.3 s |
| `T08ag` | `gmii` | `tb_t08ag_rx_ingress` | ✅ PASS | 3.7 s |

**实测结果摘要**：

> T08a RXINGRESS PASS (IF_MODE=0; 22 model/zlib frames; bad frame isolation/PMEM BE)

> T08a RXINGRESS PASS (IF_MODE=1; 22 model/zlib frames; bad frame isolation/PMEM BE)

### T08b — RX 顶层入口

**验证目的**：双网同拍、块池、PMEM 字节使能、主机仲裁

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T08b` | `default` | `tb_t08b_top_rx` | ✅ PASS | 4.2 s |
| `T08bg` | `gmii` | `tb_t08bg_top_rx` | ✅ PASS | 4.3 s |

**实测结果摘要**：

> T08b RX-TOP-INGRESS PASS (IF_MODE=0; dual net; BE; ACK priority; bad FCS)

> T08b RX-TOP-INGRESS PASS (IF_MODE=1; dual net; BE; ACK priority; bad FCS)

### T08c — 主机争用仲裁

**验证目的**：RX 优先时主机写延后与 ACK 契约

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T08c` | `host-arb` | `tb_t08c_host_arb` | ✅ PASS | 5.3 s |
| `T08cg` | `host-arb-gmii` | `tb_t08cg_host_arb` | ✅ PASS | 4.9 s |

**实测结果摘要**：

> T08c HOST-ARBITRATION PASS (IF_MODE=0 real_dual_frames=56 host_writes=40 deferred=40 held=20 pulse=20 commits=40 max_wait=2 reset_abort=1)

> T08c HOST-ARBITRATION PASS (IF_MODE=1 real_dual_frames=56 host_writes=40 deferred=40 held=20 pulse=20 commits=40 max_wait=2 reset_abort=1)

### T08d — 语义过滤 FLT

**验证目的**：未配置/错网/VLID/Lmax/CRC 五类拒绝

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T08d` | `flt` | `tb_t08d_top_flt` | ✅ PASS | 5.1 s |
| `T08dg` | `flt-gmii` | `tb_t08dg_top_flt` | ✅ PASS | 5.1 s |

**实测结果摘要**：

> T08d TOP FLT PASS (IF_MODE=0 verdicts=7 pass=3 drop=4 unconf/net/vlid=3 lmax=1 crc=1)

> T08d TOP FLT PASS (IF_MODE=1 verdicts=7 pass=3 drop=4 unconf/net/vlid=3 lmax=1 crc=1)

### T08e — IC 顶层集成

**验证目的**：PSN 判决、块守恒、skew 扫描

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T08e` | `ic-top` | `tb_t08e_top_ic` | ✅ PASS | 13.3 s |
| `T08eg` | `ic-top-gmii` | `tb_t08eg_top_ic` | ✅ PASS | 6.1 s |

**实测结果摘要**：

> T08e TOP IC PASS (IF_MODE=0 ic=468 accept=463 reject=5 flt_reject=143 drain_overlap=5 skew=0..9 rxen_sweep=169 wrap/first_any/bypass/reset ok)

> T08e TOP IC PASS (IF_MODE=1 ic=468 accept=463 reject=5 flt_reject=145 drain_overlap=5 skew=0..9 rxen_sweep=169 wrap/first_any/bypass/reset ok)

### T08f — 全表 scoreboard

**验证目的**：4096 键全表灌装 + 逐笔比对

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T08f` | `full-table-scoreboard` | `tb_t08f_full_scoreboard` | ✅ PASS | 6.4 s |
| `T08fg` | `full-table-scoreboard-gmii` | `tb_t08fg_full_scoreboard` | ✅ PASS | 5.1 s |

**实测结果摘要**：

> T08 FULL SCOREBOARD PASS (IF_MODE=0 hash=8192W/8192R rx_cfg=8192W/8192R keys=4096 ways=1111 delivery=1 payload=8B)

> T08 FULL SCOREBOARD PASS (IF_MODE=1 hash=8192W/8192R rx_cfg=8192W/8192R keys=4096 ways=1111 delivery=1 payload=8B)

### T09 — IC 单元与压力

**验证目的**：PSN 槽全覆盖、背压、回绕

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T09` | `full` | `tb_t09_rx_ic` | ✅ PASS | 3 s |
| `T09s` | `small` | `tb_t09s_rx_ic` | ✅ PASS | 3.1 s |
| `T09p` | `full` | `tb_t09p_rx_ic` | ✅ PASS | 3.5 s |
| `T09ps` | `small` | `tb_t09ps_rx_ic` | ✅ PASS | 3 s |

**实测结果摘要**：

> T09 RX-IC PASS (N=4096; 6007 descriptors incl 5632 Python golden; accept=1759 reject=4248; strict/first-any/reset/loss/wrap/banks/backpressure)

> T09 RX-IC PASS (N=16; 6009 descriptors incl 5632 Python golden; accept=1756 reject=4253; strict/first-any/reset/loss/wrap/banks/backpressure)

> T09p RX-IC PRESSURE PASS (N=4096; frames=10240; covered=8192/8192; accept=9134 reject=1106; in_stall=69386 out_stall=38669 max_hold=57; bins=411/189/375/8159/2/1104/0; seed=9E3779B9)

> T09p RX-IC PRESSURE PASS (N=16; frames=2080; covered=32/32; accept=966 reject=1114; in_stall=14032 out_stall=7795 max_hold=56; bins=373/197/342/54/44/1020/50; seed=9E3779B9)

### T10 — RM 双网冗余消除

**验证目的**：A/B 副本只转发一次、SkewMax 窗口

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T10` | `rm-top` | `tb_t10_top_rm` | ✅ PASS | 4.9 s |
| `T10g` | `rm-top-gmii` | `tb_t10g_top_rm` | ✅ PASS | 4.3 s |

**实测结果摘要**：

> T10 TOP RM PASS (IF_MODE=0 rm=84 fwd=48 dup=36 skew=1 pairs=37 ic_rej=1 bypass=2 first0/window/disable/pollution/reset ok)

> T10 TOP RM PASS (IF_MODE=1 rm=84 fwd=48 dup=36 skew=1 pairs=36 ic_rej=1 bypass=2 first0/window/disable/pollution/reset ok)

### T11 — 接收端口投递

**验证目的**：采样/队列语义、溢出、逐字节读回

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T11` | `rx-port-top` | `tb_t11_top_port` | ✅ PASS | 4.1 s |
| `T11g` | `rx-port-top-gmii` | `tb_t11g_top_port` | ✅ PASS | 4 s |

**实测结果摘要**：

> T11 TOP PORT PASS (IF_MODE=0 deliver=14 ovr=4 qovf=2 port_drop=4 rm_dup=23 sampling/pin/queue/parse-drop/err/reset ok)

> T11 TOP PORT PASS (IF_MODE=1 deliver=14 ovr=4 qovf=2 port_drop=4 rm_dup=23 sampling/pin/queue/parse-drop/err/reset ok)

### T11i — RX 事件中断

**验证目的**：INT_STATUS W1C、屏蔽、同拍竞争

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T11i` | `int-top` | `tb_t11i_top_int` | ✅ PASS | 3.2 s |
| `T11ig` | `int-top-gmii` | `tb_t11ig_top_int` | ✅ PASS | 3.4 s |

**实测结果摘要**：

> T11i TOP INT PASS (sw IRQ; mask/level; sample/queue/ovf; crc bit3; event>W1C; W1C semantics)

### T12 — 4096 VL 查表压力

**验证目的**：哈希查表命中/未命中/重散列

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T12c` | `full-contiguous` | `tb_t12c_lookup` | ✅ PASS | 6.9 s |
| `T12r` | `full-random` | `tb_t12r_lookup` | ✅ PASS | 7.3 s |
| `T12s` | `small-collision` | `tb_t12s_lookup` | ✅ PASS | 3.9 s |
| `T12h` | `small-rehash` | `tb_t12h_lookup` | ✅ PASS | 4.1 s |
| `T12f` | `frontdoor-ingress` | `tb_t12f_top_lookup` | ✅ PASS | 4.3 s |
| `T12fg` | `frontdoor-gmii` | `tb_t12fg_top_lookup` | ✅ PASS | 4.8 s |

**实测结果摘要**：

> T12 LOOKUP PASS (case=0; N=4096; buckets=2048; image=4096/8192; lookups=100000; hits=61638 misses=38362; all_idx=4096 ways=1111; in_stall=530931 out_stall=330933 max_hold=73; seed=172d/ab61)

> T12 LOOKUP PASS (case=1; N=4096; buckets=2048; image=4096/8192; lookups=100000; hits=61638 misses=38362; all_idx=4096 ways=1111; in_stall=530931 out_stall=330933 max_hold=73; seed=172d/ab61)

> T12 LOOKUP PASS (case=2; N=16; buckets=32; image=16/128; lookups=20000; hits=12006 misses=7994; all_idx=16 ways=1111; in_stall=106300 out_stall=66303 max_hold=73; seed=172d/ab61)

> T12 LOOKUP PASS (case=3; N=16; buckets=32; image=16/128; lookups=20000; hits=12006 misses=7994; all_idx=16 ways=1111; in_stall=106300 out_stall=66303 max_hold=73; seed=b564/f13a)

> T12f TOP LOOKUP PASS (IF_MODE=0 image=4096/8192 frontdoor=8192W+8192R ways=1111 real_lookup=4 hit=3 miss=1 badCRC=1 seed=172d/ab61)

> T12f TOP LOOKUP PASS (IF_MODE=1 image=4096/8192 frontdoor=8192W+8192R ways=1111 real_lookup=4 hit=3 miss=1 badCRC=1 seed=172d/ab61)

### T13 — 端到端时延

**验证目的**：TX→RX 闭环时延测量

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T13` | `latency` | `tb_t13_latency` | ✅ PASS | 3.2 s |
| `T13g` | `latency-gmii` | `tb_t13g_latency` | ✅ PASS | 3.6 s |

**实测结果摘要**：

> T13 END-TO-END LATENCY PASS (IF_MODE=0 cases=3)

> T13 END-TO-END LATENCY PASS (IF_MODE=1 cases=3)

### T14 — 统计计数器

**验证目的**：帧/字节/丢弃分类/直方图、W1C、冻结

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T14` | `stats-page` | `tb_t14_stats_regs` | ✅ PASS | 5.9 s |
| `T14g` | `stats-page-gmii` | `tb_t14_stats_regs_gmii` | ✅ PASS | 5.7 s |

**实测结果摘要**：

> T14 STATS PASS (unit: frame/byte/drop12/hist8+vl8/W1C/read-clear/freeze/reset; top: page RW; 1 real frame; bytes=64; scoreboard match)

### T15 — SNMP 网络管理

**验证目的**：真实 BER PDU GET/GETNEXT/SET

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T15` | `snmp-lite` | `tb_t15_snmp` | ✅ PASS | 5.2 s |
| `T15g` | `snmp-lite-gmii` | `tb_t15_snmp_gmii` | ✅ PASS | 7.6 s |

**实测结果摘要**：

> T15 SNMP PASS (unit: 12 real BER PDUs; GET/GETNEXT/SET; STATS_BLOCK; noSuchName/readOnly/badValue/community-drop; OCTET STRING; multi-varbind; top: 12 on-wire SAP frames decoded; 11 answered; 1 dropped on community)

### T16 — 615A 数据加卸载 + RTC

**验证目的**：TFTP WRQ/DATA/重传、RTC 锁定/丢失

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T16` | `tftp-rtc` | `tb_t16_tftp_rtc` | ✅ PASS | 5.5 s |
| `T16g` | `tftp-rtc-gmii` | `tb_t16_tftp_rtc_gmii` | ✅ PASS | 4.6 s |

**实测结果摘要**：

> T16 TFTP/RTC PASS (unit tftp: WRQ/DATA/dup/final/CRC/whitelist/mode/RRQ/ACK/illegal/retry; unit rtc: period/jump/smooth/lock/loss/hold; top: 8 on-wire SAP frames; load area verified; pps fired)

### T17 — 线速最小帧冲击

**验证目的**：512 对最小帧背靠背

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T17` | `min-frame-dual-net-512` | `tb_t17_min_frame_stress` | ✅ PASS | 8.3 s |
| `T17g` | `min-frame-dual-net-512-gmii` | `tb_t17g_min_frame_stress` | ✅ PASS | 5.1 s |

**实测结果摘要**：

> T17 MIN-FRAME STRESS PASS (IF_MODE=0 pairs=512 host_writes=4096 reads=256 deferred=4096 max_wait=2 crc_reject=1 free=FFC0)

> T17 MIN-FRAME STRESS PASS (IF_MODE=1 pairs=512 host_writes=4096 reads=256 deferred=4096 max_wait=2 crc_reject=1 free=FFC0)

### T18 — 长时随机回归

**验证目的**：随机长度/间隔/并发事务

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T18` | `random-stress` | `tb_t18_random_stress` | ✅ PASS | 47.5 s |
| `T18g` | `random-stress-gmii` | `tb_t18g_random_stress` | ✅ PASS | 18.9 s |

**实测结果摘要**：

> T18 RANDOM STRESS PASS (IF_MODE=0 rounds=25 frames=102 pair_inflight=2 seed=51c0ffee min=17 max=1471 stalls=97 spaced=100 tx_overlap=1 rx_stall=756)

> T18 RANDOM STRESS PASS (IF_MODE=1 rounds=25 frames=102 pair_inflight=2 seed=51c0ffee min=17 max=1471 stalls=97 spaced=100 tx_overlap=1 rx_stall=71)

### T21 — 反压与块池耗尽

**验证目的**：块池耗尽 → NO_BLK → 归还恢复

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T21` | `block-pool-exhaust` | `tb_t21_block_pool` | ✅ PASS | 4 s |
| `T21g` | `block-pool-exhaust-gmii` | `tb_t21g_block_pool` | ✅ PASS | 3 s |

**实测结果摘要**：

> T21 BLOCK-POOL PASS (IF_MODE=0 filled=10 no_blk=1 exhaust=1 borrow=4 returned=10 recovery=1 deliver=11 no_pmem_empty=0)

> T21 BLOCK-POOL PASS (IF_MODE=1 filled=10 no_blk=1 exhaust=1 borrow=4 returned=10 recovery=1 deliver=11 no_pmem_empty=0)

### T22 — 上电全流程回环

**验证目的**：冷启动配置 → 发送 → 回灌 → 主机读回

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T22` | `loopback` | `tb_t22_top_loopback` | ✅ PASS | 5.8 s |
| `T22g` | `loopback-gmii` | `tb_t22g_top_loopback` | ✅ PASS | 4.8 s |

**实测结果摘要**：

> T22 TOP LOOPBACK PASS (IF_MODE=0 cold init + 2 looped frames; byte-exact payload; IC dedup; INT bit0)

> T22 TOP LOOPBACK PASS (IF_MODE=1 cold init + 2 looped frames; byte-exact payload; IC dedup; INT bit0)

### T22a — TX 前门切片

**验证目的**：初始化 + 表/PMEM 前门

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T22a` | `default` | `tb_t22a_frontdoor_tx` | ✅ PASS | 3.4 s |

**实测结果摘要**：

> T22a FRONTDOOR-TX PASS (init + table/PMEM frontdoor + A/B FCS/SN/payload)

### T23 — 管理 SAP 最小通路

**验证目的**：SAP 描述符与块归还

| 测试 ID | 配置 | Testbench | 结果 | 耗时 |
|---|---|---|:--:|---:|
| `T23` | `sap-minimal` | `tb_t23_sap_min` | ✅ PASS | 3.8 s |
| `T23g` | `sap-minimal-gmii` | `tb_t23g_sap_min` | ✅ PASS | 4 s |

**实测结果摘要**：

> T23 SAP MINIMAL PASS (IF_MODE=0 accept=2 return=2 SN=0;1 port=5 plen=8 pmem=8B pb1_collisions=2 overlap=0 max_wait=0 disabled_rsap=1)

> T23 SAP MINIMAL PASS (IF_MODE=1 accept=2 return=2 SN=0;1 port=5 plen=8 pmem=8B pb1_collisions=2 overlap=1 max_wait=0 disabled_rsap=1)

---

## 5. 技术指标达成情况

对照选题指南「AFDX 技术指标」逐条核对：

| 指南要求 | 设计实现 | 验证证据 |
|---|---|---|
| 传输速率 100 Mbps | `IF_MODE=0`，125 MHz 时钟 / `BYTE_SLOT_CYC=10` = 12.5 MB/s | T04、T17 线速最小帧无停顿 |
| IEEE 802.3 + ARINC 664 扩展帧格式 | `tx_frame_builder` 按规范组帧 | T03 16 组黄金帧逐字节比对 |
| 虚拟链路标识符 VLID | 目的 MAC 内嵌 VLID，RX 侧哈希查表 | T12 4096 VL 全表 |
| 序列号 1–255 | `tx_sn_gen` 回绕跳过 0 | T02 回绕/覆盖/初始化 |
| 有效载荷 ≤ 1471 B，总帧长 ≤ 1518 B | `MAX_FRAME=1518` 参数化，超限帧被 FLT 拒绝 | T03（L=8..1471）、T08d Lmax 拒绝 |
| 端到端时延 < 1–2 ms | TX→RX 闭环实测 | T13 端到端时延 3 组用例 |
| 抖动 ≤ 几十微秒 | BAG 调度 + 起始相位控制 | T04 BAG 窗口、T05b 32 VL 满载抖动 |
| 最多 128 发送 VL | `NUM_TX_VL=128` | T05c 128 VL 份额表 |
| 最多 4096 接收 VL | `NUM_RX_VL=4096` | T12 4096 键全表、T08f 全表 scoreboard |
| 高完整性数据通信 | `rx_ic`（PSN 完整性检查）+ `rx_rm`（双网冗余消除） | T09 PSN 槽全覆盖、T10 A/B 只转发一次 |
| SNMP 网络管理 | `snmp_lite`（622 行） | T15 12 个真实 BER PDU |
| 615A 数据加卸载 | `a615a_tftp`（336 行） | T16 WRQ/DATA/重传/白名单 |
| RTC 时钟同步 | `rtc_sync`（132 行） | T16 周期/跳变/平滑/锁定/丢失 |

顶层模块端口严格保留指南规定的 8 端口模板（`clk / reset / tx_data / rx_data / tx_valid / rx_valid / tx_ready / rx_ready`），双网 B 路、主机接口等扩展端口一律**追加在模板之后**，方向与位宽不动。

---

## 6. 代码覆盖率

| 指标 | 数值 |
|---|---|
| 采样方式 | Questa `+cover=sb`，逐用例 UCDB 后 `vcover merge` |
| 实例数 | 1440 |
| 分支覆盖率 | 36788 / 58849 = **62.51%** |
| 语句覆盖率 | 65555 / 89642 = **73.12%** |
| 合计 | **67.82%** |

**口径声明**：该数值**包含 testbench 实例**，且仅统计分支与语句，**不是** RTL-only 覆盖率，**不是**功能（covergroup）覆盖率。RTL-only 过滤与功能覆盖率为后续工作项。

---

## 7. 复现步骤

```powershell
# 项目根目录，Windows PowerShell
# 1) 静态检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools_lint.ps1

# 2) 文档 / 地址 / 寄存器 / 算术一致性门
python tools/run_all.py --strict

# 3) 全量回归（一次重新编译，按 manifest 顺序串行执行）
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_regress.ps1

# 4) 故障注入（会占用同一套 Questa 许可，需串行）
python sim/test_t11_mutants.py
python sim/test_t10_mutants.py
python sim/test_t22_mutants.py
```

**注意**：回归脚本会终止同名仿真器进程；运行前确认无其他仿真任务，且不要并行运行两份回归。

---

## 8. 证据索引

| 文件 | SHA-256 |
|---|---|
| `sim/out/regress.csv`（本报告数据源，56 项） | `F4EEE57D0A4F266DCAC482F44A16EB332566802FAA8DA90505345E073A8A9B0C` |
| `sim/tests.manifest`（56 项清单） | `659F8D30920BF7F979C97BE6A74B6DC6E7684F0B62BEB59B179B094EF5F92F1B` |
| `rtl/top/AFDX_top.v` | `FD674BEE7F29B2C1FFCF874B06DE8E3EA91428D0BF086F826890CE71E436D23F` |

- 全量 console 日志、UCDB、合并覆盖率报告：`out/arena-debug/`
- 综合与 STA 证据：`out/arena-debug/continue2/`、`continue7/`
- 历史回归归档：`sim/out/regress_full_*.csv` 与配套 `test_evidence_*.json`

---

*本报告所有数值均直接取自回归输出文件，未经人工修改。测试结果与上述 SHA-256 绑定。*