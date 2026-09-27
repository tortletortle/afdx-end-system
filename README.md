# AFDX 端系统设计与仿真验证

2026 FPGA 创新设计赛道 · 中科亿海微命题 · 选题一。项目以 Verilog RTL、eLinx 工程和 Questa/ModelSim 仿真为交付主线；Python 黄金模型用于生成向量和独立对账，不能替代 RTL 仿真证据。

## 从这里开始

| 你要了解什么 | 入口 |
|---|---|
| 所有文档、阅读顺序与维护规则 | [文档索引](doc/README.md) |
| **正式测试（仿真）报告：56 项逐项判据与证据哈希** | **[测试仿真报告](doc/AFDX端系统_测试仿真报告.md)** |
| 协议、架构、地址、寄存器与目标用例 | [总体设计书](AFDX端系统_总体设计书.md)（规格基线 v0.5.12） |
| 怎么运行工具和验证 | [工具与验证说明](README_tools.md) |
| 时序重设计的基线与决策 | `out/arena-debug/continue8/` |
| 历史快照（**均已过期，仅供溯源**） | [当前进度](doc/当前进度_20260923.md) · [项目现状](doc/项目现状.md) · [状态核查](doc/项目状态核查_20260924.md) |

## 当前阶段（2026-09-27）

### 功能验证：已完成

- **全量回归 56/56 PASS**，累计仿真墙钟 613.5 s，编译 0 errors。数据源 `sim/out/regress.csv`
  （SHA-256 `F4EEE57D0A4F266DCAC482F44A16EB332566802FAA8DA90505345E073A8A9B0C`），
  清单 `sim/tests.manifest` 56 项（SHA-256 `659F8D30920BF7F979C97BE6A74B6DC6E7684F0B62BEB59B179B094EF5F92F1B`）。
- **设计书测试矩阵 T00–T23 全部覆盖并通过**。每个顶层用例在 `IF_MODE=0`（100 Mbps，选题指南指标）
  与 `IF_MODE=1`（GMII，约 1 Gbps）两档各跑一遍。
- **管理面已实现并取证**（此前文档所称"空壳"结论已作废）：
  `snmp_lite.v`(622 行) / `a615a_tftp.v`(336) / `rtc_sync.v`(132) / `stats_regs.v`(288) / `mgmt_sap_rx.v`(165)
  均为真实实现并在顶层例化，对应 **T14 统计 / T15 SNMP / T16 TFTP+RTC** 各含单元级与顶层在线 SAP 帧证据。
- **此前列为缺口的 T05b 满载抖动、T13 端到端时延、T17 线速最小帧冲击、T18 长时随机回归均已补齐并 PASS。**
- **故障注入 9 套全数检出**（T11 13/13、T11i 9/9、T10 7/7、T08e 7/7、T22 6/6 等），证明测试具备发现缺陷的能力。
- 逐项判据、实测摘要与证据索引见[测试仿真报告](doc/AFDX端系统_测试仿真报告.md)。

### 综合与时序：唯一未收敛项

- **顶层综合通过**：eLinx/Yosys `AFDX_top_synth.ys` rc=0；BRAM 映射流程 rc=0（47,041 cells 含 439 `altsyncram`）。
  Quartus II 13.0.1 `quartus_map` rc=0，器件 **EP4SGX230HF35C2（Stratix IV）**，139,607 logic cells（**map 估计值，未经 Fit 验证**）。
- **post-map STA 实测**：**Fmax 45.84 MHz / Setup WNS −13.815 ns / Endpoint TNS −700,108.256 ns**，
  最差路径 `tx_port_buf:u_txbuf|s1_vld → s1_desc[*]`（数据延迟 21.292 ns）。
- **未达成 125 MHz 内部时钟目标。** 注意：选题指南要求的技术指标是**线速 100 Mbps**，
  125 MHz 是本项目自设的内部时钟；时钟频率与 `BYTE_SLOT_CYC` 的取值组合仍有重新权衡空间，
  该权衡尚未完成，**不得据此宣称指标已满足**。
- **未跑 `quartus_fit`**，因此无布线延迟、无 post-fit setup/hold，**不是时序签核**。
  71 个输入、121 个输出端口未约束，整机 I/O 时序未闭合。
- Continue7 的 `tx_port_buf` 四银行实验为负收益（45.85 → 45.84 MHz）并已按纪律回滚，
  回滚后文件 SHA-256 与备份一致。重设计方案见 `out/arena-debug/continue8/REDESIGN-ARCHITECTURE.md`。

### 覆盖率：部分

Questa `+cover=sb` 合并 50 份 UCDB，1440 instances：分支 36788/58849 = **62.51%**，
语句 65555/89642 = **73.12%**，合计 **67.82%**。
**含 TB 实例、仅分支+语句；不是 RTL-only，不是功能（covergroup）覆盖率，不是认证指标。**

### 门禁

`tools_lint.ps1` rc=0（`LINT GATE: PASS, all gates 0 %Error`）；
`python tools/run_all.py --strict` rc=0（5/5 + selfcheck）。

### 剩余工作

1. 时序：先确定 100 Mbps 所需的真实内部时钟与 `.sdc` 约束，再决定是否投入 `tx_port_buf` 关键路径重构。
2. `quartus_fit` + post-fit STA，取得真实资源占用与签核口径。
3. 目标板引脚与 IO 预算，补 `set_input_delay/set_output_delay`。
4. 覆盖率加 RTL-only 过滤与 covergroup 功能覆盖率。

## 常用命令

在项目根目录运行，Windows PowerShell：

```powershell
# 文档、地址、寄存器与模型算术检查，不等于 RTL 验收
python tools/run_all.py --strict

# RTL 静态检查
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools_lint.ps1

# 全量：一次重新编译，按当前 manifest 运行 56 项
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_regress.ps1

# 子集：会覆盖 sim/out/regress.csv，不能称为全量结果
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_regress.ps1 -Tests T08c,T08cg

# 故障注入（与回归串行运行，会抢占同一套 Questa 许可）
python sim/test_t11_mutants.py
python sim/test_t10_mutants.py
python sim/test_t22_mutants.py
```

更多脚本见 [README_tools.md](README_tools.md)。**回归脚本会停止同名仿真器进程；运行前确认没有其他仿真任务，且不要并行跑两份回归。**

## 仓库布局

```text
rtl/          公共模块、顶层、TX、RX、管理面（均已实现）
sim/          测试清单、TB、向量、回归脚本及 out/ 证据
sw/golden/    黄金模型与向量生成器
elinx/        eLinx 工程与综合材料
tools/        文档与配置校验脚本
doc/          文档导航、测试报告、寄存器 YAML/生成头、历史快照
out/arena-debug/  分轮次工作记录、综合/STA/覆盖率原始证据与备份
```

根目录 `doc_*.md` 是保留原路径的设计评审、答复和工作记录。`competition_case/` 属选题二材料，不纳入本 AFDX 主线验收。

## 变更约定

1. 改协议/地址/寄存器先核对设计书、`doc/regs.yaml` 与相关生成器；不要手改生成结果掩盖不一致。
2. 修改后跑相应检查；记录**源版本、测试清单、命令、配置、结果和覆盖边界**。
3. 任何 RTL 变更后串行重跑 56 项回归 + lint + 严格文档门，保留失败原件、真实 rc、命令与哈希。
4. **不得以功能仿真 PASS 宣称综合/时序/认证完成。** 功能、综合、时序、覆盖率四类结果分开列示。
