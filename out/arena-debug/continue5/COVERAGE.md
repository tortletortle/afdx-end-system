# 覆盖率报告 —— continue5（2026-09-26）：全 53 项回归基线 UCDB 深度解析

## 1. 概述与口径说明

本报告基于 `out/arena-debug/continue5/` 下已完成的 **53 项基线回归用例** 采集并合并的统一覆盖率数据库（UCDB）进行统计与分析。

### 强制口径区分（严禁混淆）
- **全量（含 TB 实例）覆盖率**：统计整个仿真层次结构（包含 Testbench 激励、Scoreboard、监测器与辅助验证逻辑），分母包含 TB 内部的大量代码。
- **RTL-only 覆盖率**：通过源文件路径严格过滤，排除 `sim/tb/` 等测试平台代码，仅统计 `rtl/` 目录下的硬件实现模块。
- **覆盖类型**：仅包含 **分支覆盖（Branch Coverage）** 与 **语句覆盖（Statement Coverage）** 两类结构化代码覆盖率（`+cover=sb`）。本工程**未定义 covergroup 功能覆盖率**，亦未开启条件/表达式/FSM/toggle 覆盖。**任何百分比数字均不是"功能覆盖率"或认证指标**。
- **排除规则**：未配置任何人为覆盖率豁免（Exclusion Rules），所有未命中代码均真实体现。

---

## 2. 覆盖率核心指标汇总

合并 UCDB 文件：`out/arena-debug/continue5/coverage_merged_completed53.ucdb`（输入用例数：53）

| 统计范围 | 覆盖类型 | 总 Bins / 语句数 | 命中数 (Hits) | 未命中数 (Misses) | 覆盖率 (%) |
|---|---|---:|---:|---:|---:|
| **含 TB 全量** (All Details) | **语句 (Statement)** | 138,059 | 83,960 | 54,099 | **60.81%** |
| **含 TB 全量** (All Details) | **分支 (Branch)** | 67,673 | 35,542 | 32,131 | **52.52%** |
| **RTL-only** (纯硬件模块) | **语句 (Statement)** | 125,961 | 74,233 | 51,728 | **58.93%** |
| **RTL-only** (纯硬件模块) | **分支 (Branch)** | 66,092 | 34,117 | 31,975 | **51.62%** |

*注：Questa `vcover report -summary -branch` 按例化实例加权汇总值为 49.50%（Instances: 1714）；按源文件 details 逐行归并后的 RTL 纯分支覆盖率为 51.62%。*

---

## 3. Top-15 未覆盖 RTL 模块分析（按未命中总数降序）

数据源自 `coverage_metrics.json` 之 `top_uncovered_rtl` 字段：

| 排名 | RTL 源文件 | 分支命中 / 总数 (未命) | 语句命中 / 总数 (未命) | 主要未覆盖原因与代码特征分析 |
|:---:|---|:---:|:---:|---|
| 1 | `rtl/mgmt/snmp_lite.v` | 1,484 / 10,984 (9,500) | 4,720 / 19,002 (14,282) | **协议大表与异常分支**：SNMP 包含大量 MIB OID 解析分支、ASN.1/BER 解码错误容错、只读违例、不支持类型保护等防御性分支；当前 TB 主要覆盖了标准 GET/GETNEXT/SET 及 STATS_BLOCK 基础查询，深层异常分支未全遍历。 |
| 2 | `rtl/mgmt/a615a_tftp.v` | 520 / 5,086 (4,566) | 2,168 / 10,002 (7,834) | **状态机容错与重传机制**：TFTP 包含多次超时重传上限退出、非法操作码/非法模式报错、乱序包拒绝等状态分支；用例侧重于标准 WRQ/DATA/ACK/RRQ 流程。 |
| 3 | `rtl/tx/tx_sn_gen.v` | 10,995 / 16,663 (5,668) | 11,393 / 17,185 (5,792) | **多 VL 序列号并发与回绕**：全表 4096 VL 独立序列号管理中，部分非常规配置分支及极端溢出回绕边界未全部被激发。 |
| 4 | `rtl/tx/tx_frame_builder.v` | 1,615 / 3,012 (1,397) | 5,252 / 9,677 (4,425) | **帧长边界垫片与异常中止**：不同帧长（64~1518 字节）的填充垫片状态分支、各层报头拼装中的罕见中止路径。 |
| 5 | `rtl/top/AFDX_top.v` | 3,905 / 8,120 (4,215) | 2,241 / 3,496 (1,255) | **全局地址空间解码缺省分支**：顶层 Host 访问包含大面积未映射地址空间，未映射访问时的缺省 trap 与错误标志分支占比较大。 |
| 6 | `rtl/rx/rx_vl_lookup.v` | 1,552 / 1,998 (446) | 10,578 / 14,626 (4,048) | **Cuckoo 冲突置换深层路径**：虽然 T12 全面测试了冲突与重哈希，但 Cuckoo 极深的多级置换搬移与最终放弃的死分支仍有留存。 |
| 7 | `rtl/tx/mac_tx_if.v` | 914 / 2,212 (1,298) | 3,584 / 5,260 (1,676) | **PHY 模式对齐与 IFG 边界**：MII 4-bit 与 GMII 8-bit 发送对齐逻辑、前导码插入时序与跨时钟域握手分支。 |
| 8 | `rtl/tx/tx_port_buf.v` | 852 / 1,349 (497) | 3,798 / 5,951 (2,153) | **缓冲满/空反压控制**：发送端口多通道写满反压、读空、高低水位标记及异常复位清空逻辑。 |
| 9 | `rtl/rx/mac_rx_if.v` | 3,868 / 4,400 (532) | 11,520 / 13,518 (1,998) | **PHY 接收畸变与错误信号**：物理层非对齐半字节、RX_ER 错误注入、前导码缺失等异常物理帧容错。 |
| 10 | `rtl/mgmt/mgmt_sap_rx.v` | 432 / 1,440 (1,008) | 1,596 / 2,812 (1,216) | **PMEM 仲裁与载荷截断**：最低优先级 PMEM 读仲裁争用、超长载荷截断报警以及未分配端口过滤分支。 |
| 11 | `rtl/rx/rx_port_buf.v` | 240 / 834 (594) | 1,378 / 3,002 (1,624) | **接收队列拥塞与丢包**：接收端口 FIFO 溢出、丢包计数器自增及极限并发写入条件。 |
| 12 | `rtl/top/stats_regs.v` | 1,292 / 1,830 (538) | 3,040 / 4,600 (1,560) | **常零计数通道与特殊模式**：部分目前硬件无独立判决源的常零丢弃计数通道（dmac/ip_csum/udp_csum）分支、读清使能组合分支。 |
| 13 | `rtl/mgmt/rtc_sync.v` | 312 / 822 (510) | 1,230 / 2,034 (804) | **报文对时通路与秒相位突变**：顶层 `sync_vld` 硬接 0（仅在 T16 单元测试中驱动），报文平滑对时通道在全集成模式下未被激活。 |
| 14 | `rtl/common/bram_sdp.v` | 1,018 / 1,018 (0) | 1,763 / 3,072 (1,309) | **通用 RAM 字节写使能未完全利用**：分支覆盖率达到 100%，未覆盖语句来自部分例化未开启全部字节使能组合。 |
| 15 | `rtl/rx/rx_ic.v` | 910 / 1,062 (152) | 1,956 / 2,440 (484) | **完整性校验极限滑动窗口**：序列号跨步超大跳变、回绕反向比对的极端冗余容错分支。 |

---

## 4. 复现命令与日志归档

### 4.1 采集与合并命令
```powershell
# 1. 编译时添加代码覆盖率插桩并逐用例保存 UCDB
powershell -ExecutionPolicy Bypass -File sim/run_regress.ps1 -Coverage

# 2. 合并全量 53 项 UCDB
vcover merge -out out/arena-debug/continue5/coverage_merged_completed53.ucdb out/arena-debug/continue5/ucdb/*.ucdb

# 3. 导出详细逐文件分支/语句报告与摘要
vcover report -byfile -details -output out/arena-debug/continue5/raw/vcover_details_completed53.txt out/arena-debug/continue5/coverage_merged_completed53.ucdb
vcover report -summary -branch out/arena-debug/continue5/coverage_merged_completed53.ucdb > out/arena-debug/continue5/raw/vcover_summary_b_completed53.txt
vcover report -summary -statement out/arena-debug/continue5/coverage_merged_completed53.ucdb > out/arena-debug/continue5/raw/vcover_summary_s_completed53.txt

# 4. 执行结构化解析脚本提取 RTL-only 及 Top-N 未覆盖模块
python out/arena-debug/continue5/raw/parse_coverage.py
```

### 4.2 文件校验和 (SHA256)

| 文件路径 | SHA256 校验和 | 说明 |
|---|---|---|
| `out/arena-debug/continue5/coverage_merged_completed53.ucdb` | `0ab38cb2f108bbcb30d227bd5b4ef0d863cd5f255354477f010d78c90af96e36` | 53 项合并 UCDB 数据库 |
| `out/arena-debug/continue5/coverage_merged.ucdb` | `86a5cb1f1501effddfb121f96970b913ae1852f786035f4898465bf71a69f3db` | 全量 UCDB 合并库 |
| `out/arena-debug/continue5/coverage_metrics.json` | `3abf2ae8eaf5923bbc867208ca233674ae522a597404b7f9d505dcd45519113d` | 结构化解析指标与 Top-N 列表 |
| `out/arena-debug/continue5/raw/vcover_details_completed53.txt` | `8d9bbb4733096b9160f9d250989b2ec12c650a9142b307b19dde6ea43df9473f` | Questa 原始明细报告 (22 MB) |
| `out/arena-debug/continue5/raw/vcover_summary_b_completed53.txt` | `281c66489cab31a047257361664ef2fef8b9e1d3ee6e0d289b1eb804c1232abe` | 分支覆盖率摘要日志 |
| `out/arena-debug/continue5/raw/vcover_summary_s_completed53.txt` | `4f9e8b100db2eeb67bd1fd6cb001fc70ceb57aa1671241e298600319c0d264cb` | 语句覆盖率摘要日志 |
| `out/arena-debug/continue5/raw/vcover_merge_completed53.log` | `0b1eac7b193a9bf6e29ea7bdbaf7c308fdcdc17be0671149d3c39f3dc68ab1cd` | UCDB 合并操作日志 |
| `out/arena-debug/continue5/raw/parse_coverage.py` | `893601441769a26b6be75e74c12f062484f08715ad8ff478c2430c356dff35f8` | 指标解析与分类脚本 |
