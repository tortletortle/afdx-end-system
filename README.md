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

## 当前阶段（2026-09-24 最新 32 项快照）

- **TX**：顶层主机前门、初始化扫描、发送链和 Q20 配置判决已有实现及阶段性仿真证据。
- **RX**：双网入口、块池、PMEM 写仲裁、顶层哈希查表、FLT 语义过滤、**IC 完整性检查（v0.5.14）与 RM 双网去重（v0.5.15）** 已接线，IC/RM 各独占唯一状态 RAM；`T08d/T08dg` 取证四类过滤拒绝，`T08e/T08eg` 取证 IC 判决/PSN/块守恒（故障注入 7/7），`T10/T10g` 取证 A/B 副本只转发一次、SkewMax 窗口内外、RM 开关、IC 拒绝不污染 RM（故障注入 7/7）。**v0.5.16 起 RM 转发帧经 `rx_ip_udp_parse` → `rx_port_buf` 投递到 RX 采样/队列端口**，主机经前门读 `PORT_DESC`/`MSG_CNT`、运行期读 PMEM 载荷、写 `MSG_RD` 释放；`T11/T11g` 取证逐字节载荷读回、覆盖/pin、队列序与溢出、五类解析丢弃（故障注入 13/13）。SAP/管理面与中断未接。
- **验证**：一次重新编译/32 次独立 Questa 会话 **32/32 PASS**；[归档 CSV](sim/out/regress_full_32_20260924.csv) SHA-256 `398860249BD66845634FFFAF0769D254487916D56F596F8FD1E1A6C9DF34FD8F`，对应[源码/日志哈希索引](sim/out/test_evidence_32_20260924.json)。局部通过不等于 T00–T22 目标矩阵全部实现。
- **当前检查**：严格文档门 5/5 + 自查，Verilator lint 0 `%Error`；顶层故障注入 T11 13/13、T10 7/7、T08e 5/5、T08c 3/3、T12 顶层 5/5 检出。详见[当前进度](doc/当前进度_20260923.md)。
- **未验收**：完整 T08/T21/T22、SAP/管理面、RX 中断与 PMEM 耗尽反压；T05b 合法满载抖动、T13/T17/T18、长期主机等待/混合读写、IC/RM 调试窗口、管理面和整机 STA。若必须报进度，按[当前进度所定义的 8 个等权 P0 里程碑](doc/当前进度_20260923.md)粗估约 69%，不是整机验收率。

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
python sim/test_t08c_mutants.py  # 故障注入与回归串行运行
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
