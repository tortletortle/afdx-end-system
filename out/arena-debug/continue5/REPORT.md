# continue5-finalize 报告 —— GMII 变体补强、覆盖率深度报告与全量 56 项回归验收

日期：2026-09-26 · 工作区：`C:\Workspace\diansai` · 产出目录：`out/arena-debug/continue5/`  
任务书：`out/arena-debug/MISSION-CONTINUE5-FINALIZE.md`（sha256 `0e7219dbcaa2165d92a3dd4cc4f31a8a7d134ac8403039fc9bff892f61aaef2a`）

---

## 0. 一句话结论

**全部目标圆满收尾并闭环**：
1. **GMII 变体用例补齐**：T14/T15/T16 补全 `IF_MODE=1` 变体（`T14g`、`T15g`、`T16g`），测试列表由 53 项扩展为 **56 项**，改前均已备份至 `continue5/backup/`，定向回归 6/6 全部通过。
2. **覆盖率报告与深度剖析**：基于上一轮完成的 53 项基线 UCDB，严格区分「全量含 TB」与「RTL-only 纯硬件」口径完成 `COVERAGE.md`，深入剖析了 Top-15 未覆盖 RTL 模块的协议与代码特征。
3. **三大门禁全绿验收**：
   - **全量回归 56/56 PASS**（零失败，耗时 557.9 s）；
   - **Verilator 代码 Lint PASS**（零致命错误）；
   - **文档与模型自查 `run_all.py --strict` 5/5 全绿通过**。
4. **完整打包交付**：生成 `COVERAGE.md`、`REPORT.md`、`fixes.patch`、`COMMANDS.md`、`RESULTS.json` 以及 `SHA256SUMS.txt`。

---

## 1. 目标 1：GMII 变体补强（T14g / T15g / T16g）

在 continue4 中，管理面模块（`stats_regs`、`snmp_lite`、`a615a_tftp`、`rtc_sync`）仅在 MII 模式（`IF_MODE=0`）下进行了顶层验证。本轮将 GMII 8-bit 模式补强并接入统一回归体系：

| 用例 ID | 顶层 TB 模块名 | 对应文件 | 接口模式 | 验证焦点 | 定向结果 |
|---|---|---|:---:|---|:---:|
| `T14` | `tb_t14_stats_regs` | `sim/tb/tb_t14_stats_regs.v` | MII (`IF_MODE=0`) | 统计页 RW、丢弃计数、直方图、W1C、读清 | **PASS** (6.5 s) |
| `T14g` | `tb_t14_stats_regs_gmii` | `sim/tb/tb_t14_stats_regs.v` | GMII (`IF_MODE=1`) | GMII 下千兆字节流驱动统计页对齐与计数 | **PASS** (5.5 s) |
| `T15` | `tb_t15_snmp` | `sim/tb/tb_t15_snmp.v` | MII (`IF_MODE=0`) | 12 条真实 BER 报文解码、GET/SET、STATS_BLOCK | **PASS** (4.7 s) |
| `T15g` | `tb_t15_snmp_gmii` | `sim/tb/tb_t15_snmp.v` | GMII (`IF_MODE=1`) | GMII 8-bit 下真实 SAP 帧解码与 SNMP 响应 | **PASS** (4.0 s) |
| `T16` | `tb_t16_tftp_rtc` | `sim/tb/tb_t16_tftp_rtc.v` | MII (`IF_MODE=0`) | TFTP WRQ/DATA/ACK/RRQ 状态机与 PPS 秒脉冲 | **PASS** (3.9 s) |
| `T16g` | `tb_t16_tftp_rtc_gmii` | `sim/tb/tb_t16_tftp_rtc.v` | GMII (`IF_MODE=1`) | GMII 8-bit 线下 32KB 加载区校验与对时 | **PASS** (4.1 s) |

- **改动备份**：相关文件修改前已全量备份至 `out/arena-debug/continue5/backup/gmii-variants/`。
- **Manifest 扩展**：`sim/tests.manifest` 注册用例数由 53 项更新为 56 项。
- **调度器映射**：`sim/run_regress.ps1` 增加多顶层模块映射表项，支持单个源文件包含多个顶层 module 时的动态分发。

---

## 2. 目标 2：覆盖率深度分析与口径核实

基于已完成的 53 项基线回归 UCDB 合并库（`coverage_merged_completed53.ucdb`），使用 `parse_coverage.py` 严格区分并提取数据：

### 2.1 覆盖率核心数据对照

| 指标维度 | 语句覆盖率 (Statement) | 分支覆盖率 (Branch) | 说明 |
|---|:---:|:---:|---|
| **全量（含 TB 实例）** | **60.81%** (83,960 / 138,059) | **52.52%** (35,542 / 67,673) | 包含 Testbench 内部的所有驱动、比较器与辅助验证代码 |
| **RTL-only（纯硬件模块）** | **58.93%** (74,233 / 125,961) | **51.62%** (34,117 / 66,092) | 严格排除 `sim/tb/`，仅统计 `rtl/` 目录下的硬件实现模块 |

> **强制口径约束**：
> 1. 本工程代码覆盖率仅包含语句（Statement）与分支（Branch）覆盖（`+cover=sb`）；
> 2. **未定义 covergroup 功能覆盖率**，亦无表达式/FSM/toggle 覆盖；
> 3. 任何数字均不得混称为"功能覆盖率"或整机符合性认证指标。

### 2.2 Top-15 未覆盖 RTL 模块主要特征与原因分析

1. **`rtl/mgmt/snmp_lite.v` (未命: 分支 9,500 / 语句 14,282)**：
   - 包含完整的 SNMP 协议 MIB 树、大量异常 OID 捕获、ASN.1/BER 类型错误、只读违例及越界保护分支。当前测试以主要对象 GET/GETNEXT/SET 和 STATS_BLOCK 基础链路为主，大量防御性异常分支未全遍历。
2. **`rtl/mgmt/a615a_tftp.v` (未命: 分支 4,566 / 语句 7,834)**：
   - TFTP 包含超时重传上限退出、非法操作码报错、异常块重发等容错状态机，主要测试覆盖集中于正常文件写入与状态查询。
3. **`rtl/tx/tx_sn_gen.v` (未命: 分支 5,668 / 语句 5,792)**：
   - 4096 条 VL 独立序列号管理中，部分非常规配置分支及极端溢出回绕边界未全部激发。
4. **`rtl/tx/tx_frame_builder.v` (未命: 分支 1,397 / 语句 4,425)**：
   - 帧长（64~1518 B）填充垫片状态分支及各层报头拼装中的罕见异常中止路径。
5. **`rtl/top/AFDX_top.v` (未命: 分支 4,215 / 语句 1,255)**：
   - Host 总线未映射地址空间的访问 Trap 与缺省错误分支占比高。
6. **`rtl/rx/rx_vl_lookup.v` (未命: 分支 446 / 语句 4,048)**：
   - Cuckoo 哈希多级置换搬移及放弃置换的死分支。
7. **`rtl/tx/mac_tx_if.v` (未命: 分支 1,298 / 语句 1,676)**：
   - MII/GMII 模式差异对齐、前导码插入时序与跨时钟域握手分支。
8. **`rtl/tx/tx_port_buf.v` (未命: 分支 497 / 语句 2,153)**：
   - 端口多通道写满反压、读空及异常复位清空逻辑。
9. **`rtl/rx/mac_rx_if.v` (未命: 分支 532 / 语句 1,998)**：
   - 物理层非对齐半字节、RX_ER 错误注入等异常物理帧容错。
10. **`rtl/mgmt/mgmt_sap_rx.v` (未命: 分支 1,008 / 语句 1,216)**：
    - PMEM 读仲裁争用、超长载荷截断及未分配端口过滤分支。
11. **`rtl/rx/rx_port_buf.v` (未命: 分支 594 / 语句 1,624)**：
    - 接收端口 FIFO 溢出、丢包计数器自增逻辑。
12. **`rtl/top/stats_regs.v` (未命: 分支 538 / 语句 1,560)**：
    - 部分目前无独立硬件判决源的常零丢弃通道（dmac/ip_csum/udp_csum）分支。
13. **`rtl/mgmt/rtc_sync.v` (未命: 分支 510 / 语句 804)**：
    - 顶层 `sync_vld` 硬接 0（仅在 T16 单元测试中验证报文对时）。
14. **`rtl/common/bram_sdp.v` (未命: 分支 0 / 语句 1,309)**：
    - 分支覆盖 100%，未覆盖语句来自未启用的 RAM 字节写使能组合。
15. **`rtl/rx/rx_ic.v` (未命: 分支 152 / 语句 484)**：
    - 序列号跨步超大跳变与回绕极端容错分支。

---

## 3. 目标 3：三大门禁全绿执行记录

### 门禁 1：全量回归（56 项）
- **执行命令**：`powershell -ExecutionPolicy Bypass -File sim/run_regress.ps1`
- **执行结果**：**56/56 PASS（0 失败，0 超时）**
- **总耗时**：`wall_s = 557.9 s`
- **慢用例 Top 3**：`T01` (226.3 s), `T18` (58.3 s), `T18g` (15.0 s)
- **原始记录**：`raw/full_regress_56_final.log`、`raw/regress_56.csv`

### 门禁 2：Verilator 静态 Lint
- **执行命令**：`powershell -ExecutionPolicy Bypass -File tools_lint.ps1`
- **执行结果**：**PASS（Exit Code 0，无阻塞性错误）**
- **原始记录**：`raw/lint.log`

### 门禁 3：严格同源自查门禁（5 项文档/数值 + Claims）
- **执行命令**：`python tools/run_all.py --strict`
- **执行结果**：**5/5 全绿 + Claims 自查通过（Exit Code 0）**
- **明细项**：
  - `PASS verify_all`（全文一致性，0 处问题）
  - `PASS check_addr`（地址表 15 行无重叠，53536 字）
  - `PASS check_s9`（存储预算 1.33 Mbit / 84 块 BRAM）
  - `PASS gen_regs`（位域表对账一致）
  - `PASS check_doc_numbers`（§8.2 判决式复算全部一致）
  - `PASS selfcheck_claims`（模型与文档严格一致）
- **原始记录**：`raw/run_all_strict.log`

---

## 4. 交付文件清单

所有产物均位于 `out/arena-debug/continue5/`：

1. `REPORT.md`：本轮总结报告；
2. `COVERAGE.md`：全量 53 项 UCDB 深度覆盖率报告；
3. `fixes.patch`：本轮代码改动补丁（546 KB）；
4. `COMMANDS.md`：复现与验证命令手册；
5. `RESULTS.json`：机器可读的结构化结果；
6. `SHA256SUMS.txt`：全量交付件哈希校验清单；
7. `coverage_metrics.json`：结构化解析指标；
8. `coverage_merged_completed53.ucdb` / `coverage_merged.ucdb`：合并 UCDB 数据库；
9. `raw/` 目录：包含 56 项全量回归日志、定向回归日志、Lint 日志、Questa 报告等原始记录。

---

## 5. 纪律与边界说明

1. **未读取或回显任何敏感配置/凭据**，未触碰 `competition_case/`、`data/`、`logs/`；
2. **严格保持工作区整洁**，未执行 `git commit/push/reset`；
3. **单进程独占 Questa**，未并行运行多份仿真；
4. **覆盖率指标严谨规范**，严格区分「含 TB」与「RTL-only」，无任何虚假指标或篡改。
