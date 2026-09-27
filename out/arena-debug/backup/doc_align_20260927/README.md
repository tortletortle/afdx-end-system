# AFDX 端系统设计与仿真验证

2026 FPGA 创新设计赛道 · 中科亿海微命题 · 选题一。项目以 Verilog RTL、eLinx 工程和 Questa/ModelSim 仿真为交付主线；Python 黄金模型用于生成向量和独立对账，不能替代 RTL 仿真证据。

## 从这里开始

| 你要了解什么 | 入口 |
|---|---|
| 所有文档、阅读顺序与维护规则 | [文档索引](doc/README.md) |
| 现在做到了哪里、证据是什么 | [当前进度](doc/当前进度_20260923.md)（旧 [项目现状](doc/项目现状.md) 是 14/16 项历史快照） |
| 下一步做什么、怎样算完成 | [后续计划](doc/后续计划.md) |
| 协议、架构、地址、寄存器与目标用例 | [总体设计书](AFDX端系统_总体设计书.md)（规格基线 v0.5.12） |
| 怎么运行工具和验证 | [工具与验证说明](README_tools.md) |
| 本轮整理及检查结果 | [2026-09-23 检查记录](doc/检查记录_20260923.md) |

## 当前阶段（2026-09-25 FINALIZE；仅限已取证的 RTL 子集）

- **功能仿真**：末次完整 `sim/run_regress.ps1` 独立串行执行，编译 rc=0/0 errors，清单顺序 **50/50 PASS**（285.4 s）。T23/T23g 有 SN=0→1 连续两帧 SAP、PB1 槽竞争 2 次/模式且块数守恒；T18/T18g 在 100 笔串行随机事务之外各增加 **2 笔不同端口同时在飞**，双网重放、反压/去重/逐字节/精确计数均通过。只有两笔并发取证，**没有证明 4 端口持续多事务并发**。
- **真实但局部的代码覆盖率**：Questa `+cover=sb` 生成 T23/T23g/T18/T18g 四份 UCDB 和合并报告；这四个用例（**含 TB 实例**）分支 4035/6098 = 66.16%，语句 7110/9200 = 77.28%。不是 50 项全量或功能覆盖率；不能用 50/50 PASS 替代覆盖率。
- **硬件交付阻塞**：`AFDX_top` 顶层 eLinx 综合仍在 `OPT_MUXTREE` 报 `bad allocation`（rc=1），虽有 8 ns 内部时钟的初步 `.edc`，仍没有完整网表/目标板约束/P&R。TimeQuest 可执行但无 active revision；**STA WNS/TNS/Fmax 未取得**，125 MHz 时序收敛不得声称完成。
- **明确不在本次可验收交付范围的管理协议**：`mgmt_sap_rx` 仅为最小 SAP 描述符/块归还窗口；`snmp_lite.v`、`a615a_tftp.v`、`rtc_sync.v` 是未例化的模块壳，`stats_regs.v` 不存在，T14–T16 未执行。这些仍是[总体设计书](AFDX端系统_总体设计书.md)中的**未满足目标/规格缺口**，本次绝不称完整 SNMP/TFTP/RTC/统计面已交付。
- 最新命令、失败原件、全量 CSV/50 个 console、UCDB、STA 负例与 SHA-256 见 [FINALIZE 报告](out/arena-debug/DIANSAI-REPORT.md)和 `out/arena-debug/finalize/`；下面为按日期保留的旧快照，**不可用来替代最新状态**。

### 2026-09-24 历史快照（以下旧断言已过期，仅供溯源）

- **TX**：顶层主机前门、初始化扫描、发送链和 Q20 配置判决已有实现及阶段性仿真证据。
- **RX**：双网入口、块池、PMEM 写仲裁、顶层哈希查表、FLT 语义过滤、**IC 完整性检查（v0.5.14）与 RM 双网去重（v0.5.15）** 已接线，IC/RM 各独占唯一状态 RAM；`T08d/T08dg` 取证四类过滤拒绝，`T08e/T08eg` 取证 IC 判决/PSN/块守恒（故障注入 7/7），`T10/T10g` 取证 A/B 副本只转发一次、SkewMax 窗口内外、RM 开关、IC 拒绝不污染 RM（故障注入 7/7）。**v0.5.16 起 RM 转发帧经 `rx_ip_udp_parse` → `rx_port_buf` 投递到 RX 采样/队列端口**，主机经前门读 `PORT_DESC`/`MSG_CNT`、运行期读 PMEM 载荷、写 `MSG_RD` 释放；`T11/T11g` 取证逐字节载荷读回、覆盖/pin、队列序与溢出、五类解析丢弃（故障注入 13/13）。**v0.5.17 补两件**：① RX 事件中断——`INT_STATUS`（0x0018，W1C）低 4 位 = 新采样消息 / 队列入队 / 采样覆盖或队列满 / CRC 错帧（双网 `mac_rx_if.crc_err`），同拍新事件优先于 W1C，`INT_ENABLE`（0x0014）只存低 8 位，`host_irq` = `CTL[14]` 或（`INT_ENABLE & INT_STATUS`）为电平式；`T11i/T11ig` 覆盖屏蔽期间仍登记、使能即拉高、软件中断、采样/入队/覆盖/满、A/B 网坏 FCS 只置 bit3 且不投递、同拍竞争（故障注入 9/9）。② `T22/T22g` TX→RX 冷启动真回环——一次 `CFG_MODE` 配好 TX VL0 与 RX（种子/哈希项/RX_VL_CFG/端口表 + 映像提交）后，主机 PMEM 写 → `MSG_WR` → 抓取 DUT 在线的 A/B 字节流回灌 RX 入口（两帧、保留真实 BAG 1000 μs），描述符/`MSG_CNT`/PMEM 载荷与发出帧逐字节一致、SN 连续、IC 去重、块守恒、`INT_STATUS[0]` 置位（故障注入 6/6）。**本轮新增 `T21/T21g`**：队列端口占满 RX 块 6..15 → 第 11 帧触发 `NO_BLK`/`rx_exh_cnt` 且无 PMEM 写/无入队 → `MSG_RD` 逐条归还 → 后续帧恢复交付，两种 IF_MODE 2/2 PASS。SAP/管理面未接。
- **验证**：基线一次重新编译/36 次独立 Questa 会话 **36/36 PASS**；[归档 CSV](sim/out/regress_full_36_20260924.csv) SHA-256 `7D5D1FB487FA6ABEDBC9D3A0228D9ECA28820772B1EA91773F6141D4EDA2F77C`，对应[源码/日志哈希索引](sim/out/test_evidence_36_20260924.json)。本轮 T21/T21g 定向回归 **2/2 PASS**（`sim/out/regress_t21_2_20260924.csv`）；一次 38 项全量尝试在 T10g 处遇到 Questa/vish RPC/license 断连并留下残进程，清理后 T10g、T11/T11g/T21/T21g 以及 T09/T12/T22/T11i/T22a 后续子集均复跑 PASS，因此暂不登记新的完整 38/38。局部通过不等于 T00–T22 目标矩阵全部实现。
- **当前检查**：严格文档门 5/5 + 自查，Verilator lint 0 `%Error`；顶层故障注入 T11 13/13、T10 7/7、T11i 9/9、T22 6/6、T08e 5/5、T08c 3/3、T12 顶层 5/5 检出。详见[当前进度](doc/当前进度_20260923.md)。
- **未验收**：完整 T08（全表灌装 + 逐笔 scoreboard）、SAP/管理面投递；T05b 合法满载抖动、T13/T17/T18、长期主机等待/混合读写、IC/RM 调试窗口、管理面和整机 STA。T21 已有定向仿真证据，但尚未并入完整 T08 全表逐笔 scoreboard。若必须报进度，仍按[当前进度所定义的 8 个等权 P0 里程碑](doc/当前进度_20260923.md)粗估约 75%～80%，不是整机验收率。

## 常用命令

在项目根目录运行，Windows PowerShell：

```powershell
# 文档、地址、寄存器与模型算术检查，不等于 RTL 验收
python tools/run_all.py --strict

# RTL 静态检查；本轮最新复核通过
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools_lint.ps1

# 全量：一次重新编译，按当前 manifest 运行
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_regress.ps1

# 子集：会覆盖 sim/out/regress.csv，不能称为全量结果
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_regress.ps1 -Tests T08c,T08cg
python sim/test_t08c_mutants.py   # 故障注入与回归串行运行（会抢占同一套 Questa 许可）
python sim/test_t11i_mutants.py   # RX 事件中断故障注入
python sim/test_t22_mutants.py    # TX→RX 回环故障注入
```

更多脚本见 [README_tools.md](README_tools.md)（09-24 已按真实根目录布局修订）；**当前设计书与本 README 均在仓库根，不要执行旧的批量 Move-Item 命令**。文档定位和剩余归并项见[文档索引](doc/README.md)。**回归脚本会停止同名仿真器进程；运行前确认没有其他仿真任务，且不要并行跑两份回归。**

## 仓库布局

```text
rtl/          公共模块、顶层、TX、RX、管理面；部分模块仍是占位
sim/          测试清单、TB、向量、回归脚本及 out/ 证据
sw/golden/    黄金模型与向量生成器
elinx/        工程/综合冒烟材料，不能视作当前整机综合验收
tools/        文档与配置校验脚本
doc/          文档导航、现状、计划、检查记录、寄存器 YAML/生成头
```

根目录 `doc_*.md` 是保留原路径的设计评审、答复和工作记录；早期结论按日期查看，最新状态见 `doc/当前进度_20260923.md`。旧文档和赛方材料不迁移，以免破坏脚本路径与交叉引用。`competition_case/` 属选题二材料，不纳入本 AFDX 主线验收。

## 变更约定

1. 改协议/地址/寄存器先核对设计书、`doc/regs.yaml` 与相关生成器；不要手改生成结果掩盖不一致。
2. 修改后跑相应检查；记录**源版本、测试清单、命令、配置、结果和覆盖边界**。
3. 当前状态写入 `doc/当前进度_20260923.md`，下一步写入 `doc/后续计划.md`，过程追加到工作记录。`doc/项目现状.md` 和 HTML 演示是旧快照，不作最新验收清单。
