<!-- rendered from AFDX端系统_测试报告.md using C:/Workspace/diansai/out/p8_freeze_225cd91/metrics.json commit=225cd91be4f6a4b332db1674b44761bca367bd67 -->

# AFDX 端系统测试报告（提交版）

> 数字一律双花括号 metric 锚点（对照 `out/p8_freeze_225cd91/metrics.json`）。历史全量计数等只允许出现在历史附录并注明版本。  
> 每个 **P** 结论后附「不能推出」。冻结 commit：`225cd91be4f6a4b332db1674b44761bca367bd67`。

---

## 1. 验证环境

### 1.0 架构概要

```
激励 / BFM (sim/env) ──► DUT AFDX_top / chipsim ──► chk bind / scoreboard
         │                        │
         └─ sw/golden + Python ───┴─ 独立复算（部分 T）
```

- **仿真器**：Questa（功能全量）；ModelSim SE 2020.4（门级 T88b、eLinx GUI 行为）。
- **TB**：`sim/tb/`；清单 `sim/tests.manifest`；runner `sim/run_regress.ps1` / `sim/run_smoke.ps1`。
- **时钟**：与 GMII 线速拍一致（仿真 125 MHz）；≠ 代理 post-fit Fmax。

### 1.1 BFM 列表（`sim/env/`）

| 模块 | 职责 |
|---|---|
| `afdx_host_bfm.v` | 主机总线读写、寄存器/表项激励 |
| `afdx_mac_bfm.v` | MAC/GMII 侧帧注入与采样 |
| `afdx_net_port.v` / `afdx_net_model.v` | 网络口 / 简化网模型（部分场景） |
| `afdx_timing_mon.v` | 时延/间隔监视辅助 |
| `afdx_scoreboard.v` | TB 内记分板（与独立 Python 并存时以各 T 说明为准） |

### 1.2 独立模型 / 外置脚本（节选）

| 路径 | 用途 |
|---|---|
| `sw/golden/afdx_model.py` | 帧格式 + BAG + IC/RM 语义，不读 RTL 常数 |
| `sw/golden/gen_t09_*.py` 等 | IC/查表/CRC 等向量生成 |
| `tools/t89_metrics_check.py` | T89 CSV 独立复算 |
| `sim/check_snmp_wire_capture.py` 等 | SNMP 线上捕获核对 |
| `sim/test_t*_mutants.py` | 负控变异（杀伤期望 FAIL） |

### 1.3 判据独立性表

| 类别 | 代表 T | 外置模型/脚本 | TB 内自比 | 说明 |
|---|---|---|---|---|
| 有外置 Python/golden | T09 族、T12 族、T35、T42/T43 向量、T89 `t89_metrics_check`、SNMP wire | 是 | 兼有 | Verilog 与 Python 一致才记 PASS（各 T 钩子） |
| 主要 TB 记分板 | T00–T08、T10/T11、T13/T13w、T22、T88 演示 1–4 | 部分 | 是 | 期望值多在 TB/chk；部分引用 golden 常量 |
| 负控变异 | T08c/e、T09–T12、T22 + **C3** `test_c3_mutants.py` | 注入故障期望 FAIL | — | 仅「编译成功且功能 FAIL」计杀死；C3：**新增 28 / 杀死 23 / 存活 5 / 已证等价 0**（基线 `p_c3_mutants_20261024_215956` 21/28 + 加严 `p_c3_retighten_20261025_010733` 再杀 2；与历史 **57/57** 分列） |
| 公开端口回环 | T88b（RTL/门级/GUI） | 载荷 hex / 步骤打印 | 是 | 只用顶层端口，便于 VO |

### 1.4 白盒与看门狗口径（C3 加严）

- **T41 IFG**：精确 12 拍判据为**白盒**——TB 读 `u_tx.st`（`mac_tx_if` 状态机 `ST_IFG`），非仅观 GMII 线上空闲。用于杀 `ifg_minus_one`；不得写成「线上 IFG 已黑盒证明」。
- **T16a 看门狗**：仿真墙钟由 **200 ms → 220 ms**（`#220_000_000`）。原因：C3 加严新增约 **2 ms** 量级的停 PPS→`sync_loss` 场景；**FLL 精度判据未放宽**。不得写成「超时放宽换 PASS」。

### 1.5 Runner 说明（harvest）

`sim/run_regress.ps1` 的 `Run-Vsim`：若日志已出现 `$finish` 与 `Errors: N` 而进程未退出，grace 后**收割**并返回 0，**不改 TB 判据**。用于消除个别用例（如历史冒烟 T42）「日志已 PASS、墙钟 TIMEOUT」的假失败。  
本冻结全量 N=`144` 在带 harvest 的 runner 上得到；与历史全量（旧 runner、不同 N）**不可直接等同**。详见 §9。

---

## 2. 如何复现

1. **冒烟**：`powershell -File sim/run_smoke.ps1`（含 T88；一次全绿）
2. **全量**：`sim/run_regress.ps1` → `python sim/freeze_regress.py --require-full`
3. **门级**：导出 functional VO 后 `sim/run_gate_t88b.ps1`（VoptFlow=0，见 §6 / §9）
4. **eLinx 综合**：`python tools/run_baseline_full140_synth.py`（输入绑定本冻结）
5. **eLinx GUI 行为（人工）**：`elinx/gui_afdx/AFDX_top.epr` → ModelSim SE 路径 → Top=`tb_gate_public_loopback` → Run Behavioral Simulation（步骤见 `doc/eLinx_一键仿真步骤.md`）
6. **全量清单表（可选）**：`python tools/gen_regress_table.py --csv <regress.csv>`

**需按本机修改**：`SALT_LICENSE_SERVER`、Questa/ModelSim/`eLinx_synthesis` 安装路径（勿写死进包）。

---

## 3. 需求追踪大表（五功能 + 四指标）

> 等级：P / I / F（尺子 §1）。实测列只写 metric 锚点或「无独立 key / 未测」。  
> **官方字面 SFD→SFD**：单 ES 回环无网络段 → **I**（0 by construction）。**ES 贡献**三列（`tx_commit2sfd`/`rx_sfd2host`/`es_total`）→ **P**（Questa `p_c0_t89_questa_20261024_170643` **L33**）；尚未写入 C 的 `metrics.json` 键时渲染仍可缺键。

### 3.1 五功能

| 赛题条目 | T（代表） | 配置 | 实测（metric） | 等级 | 不能推出 |
|---|---|---|---|---|---|
| 通信 / 调度与流量整形（BAG、端口缓冲、组帧） | T04/T05c/T27；回环切片 T22 | IF_MODE 分档见各 TB；T27 合法 BAG 扫档 | 全量计入 `144`/`144`；无单独 BAG 时延 key | P（各 TB 标题范围） | 任意 BAG×Lmax 笛卡尔积；板级线速调度 |
| 高可靠：完整性检查 IC（SN/PSN） | T08e/T09 | 见 TB；向量+模型 | accept `1759` / reject `4248` | P | 顶层全错误笛卡尔积；babbling 全空间 |
| 高可靠：冗余管理 RM（双网去重 / SkewMax） | T10 | 见 TB | fwd `56` dup `46` skew `3` | P | 任意迟到历史；网表级 RM |
| SNMP 网络管理（v1 子集） | T15 族 / T31/T36；演示 T88 步 5 | v1 only | T88 步 5：**TB 内**金标 PASS（`p_c2_t88_r3`）；线上独立 BER 解码见 **T31/T36** | P（子集+演示步 5） | 完整 SNMP；T88 本场未挂 `check_snmp_wire_capture` 钩子 |
| 615A / TFTP 加卸载（披露子集） | T34p/T35p；演示 T88 步 6 | 固定块长等；T88：520 B | T88 步 6 PASS（同上） | P（已跑子集+演示） | 完整 615A/665 认证 |
| RTC 时钟同步（PPS/FLL） | **FLL 精度：T16a**；演示 T88 步 7 | T88：PPS 解除失步 + RTC 前进 | T88 步 7 PASS；精度不归 T88 | P（T16a 精度；T88 演示解除失步） | 把 FLL 精度说成 T88 测得；网络授时 |

### 3.2 四指标

| 指标 | T | 配置 | 实测（metric） | 等级 | 不能推出 |
|---|---|---|---|---|---|
| 吞吐 ≥100 Mbps（S：RX 去重后有效载荷） | T42；T89；T90 | T42：16 VL；T89：见 §5；T90：128 TX / RX126+2unconf，CTL 0x051F | T42/T89 见各节；T90 rx_dedup **673.304** Mbps（§5.3 r6） | **P** | 任意 BAG；官方 SFD→SFD |
| 官方字面：单帧 GMII **SFD→SFD** ≤2 ms | T89（列保留） | IF_MODE=2 单 ES 回环 | `sfd2sfd=0 by construction` → **I** | **I** | 「官方 2 ms 实测 0 ns」「SFD→SFD 已 P」；网络/交换机端到端 |
| ES 发送/接收贡献与总占用 ≤2 ms | T89（C0） | IF_MODE=2 | L33：3384 / 2592 / 5976 ns（`p_c0_t89_questa_20261024_170643`） | **P** | 与工程 commit/eof 界混并；官方字面 SFD→SFD |
| 工程时延（分列） | T13 / T13w / T42 / T89 | **IF_MODE=0**：T13/T13w；**IF_MODE=2**：T42/T89 | T13 worst `243416` ns；T13w `453752` ns；T42 tx `16.08` μs / rx `12.936` μs；T89 tx `15536` ns / rx `160` ns | P（各起止） | 冒充官方字面 SFD→SFD；XAPP RX&lt;150μs |
| 抖动（同 VL 时延 max−min；本场景对照 40+Σ） | T05b；T42；T89 | T05b 压力档；T89：32VL×`3` 帧 | T05b startup `2` / steady `0` μs；T42 `5.016` μs；T89 max_jit `72` ns，本场景 40+Σ=`141` μs | P（各场景） | 「官方上限 50 μs」；合法 BAG 全档；未重算 40+Σ 套 500 μs |
| 规模：128 TX / 4096 RX 能力 | T34p / T35p；满配吞吐 T90 | 见各 TB；T90 端口预算 128+126+2 SAP | `True` / `True`；T90 r6 **P** | **P** | 4096 路同时收；任意配置均 ≥100 Mbps |

**IF_MODE 分列（禁止混用）**：T13/T13w/T05b 等为 IF_MODE=0（或 TB 标明）；T42/T89/T88b 公开口指标为 IF_MODE=2。同一物理量在不同 IF_MODE 下**不得**拼成一条「现行」数字。

全量矩阵：`144` / `144`（`True`）。  
**不能推出**：认证实验室套件；评委自建 TB 以外的协议全集。

---

## 4. 全量清单

由冻结同源 `regress.csv` **自动生成**（脚本 `tools/gen_regress_table.py`，只读 CSV）。  
打包时附完整表或生成物；正文不手抄 144 行。

- 汇总：PASS `144` / N `144`
- 建议 CSV：`out/p8_clean_20261022_191733/sim/out/p8_full_20261022_191856/regress.csv`（与 metrics `full_*` 同源）
- 生成：`python tools/gen_regress_table.py --csv <上路径> [--out doc/submit/_generated_regress_table.md]`

列：id、功能/摘要、配置、结果、墙钟(s)。

---

## 5. 指标章

### 5.1 T42（IF_MODE=2，公开 GMII；工程起止）

| 项 | metric | 备注 |
|---|---|---|
| TX commit→eof max | `16.08` μs | 工程界 |
| RX sof→host max | `12.936` μs | 工程界 |
| 抖动 max−min | `5.016` μs | 勿写「官方 50 μs」 |

**不能推出**：官方 SFD→SFD；板级；128 VL 满配。

### 5.2 T89（IF_MODE=2；ns 主打印）

| 项 | metric | 备注 |
|---|---|---|
| max_tx | `15536` ns | commit→eof（工程） |
| max_rx | `160` ns | 工程 RX 界 |
| max_jit | `72` ns | 同 VL max−min |
| 本场景 40+Σ | `141` μs | **本场景重算**；非一律 500 μs |
| frames/VL | `3` | 抖动样本数 |
| 官方字面 SFD→SFD | （信息列） | **I**：wire loopback 0 by construction |
| ES commit→TX SFD max | 3384 ns | **P**：`sim/out/p_c0_t89_questa_20261024_170643/T89_console.txt` **L33** |
| ES RX SFD→host max | 2592 ns | **P**：同上 **L33** |
| ES 总占用 | 5976 ns | **P**：同上 **L33**（≪2e6）；Python `T89_METRICS_CHECK PASS` |
| 满配 128 VL 吞吐 | T90 r6 | **P**：rx_dedup 673.304 Mbps；见 §5.3 |

抖动说明：T89 对照本场景第一式 **40 μs + Σ** = `141` μs；实测 max_jit = `72` ns。新场景必须重算 40+Σ，不得套用他场数字。

**不能推出**：T89 配置 ≡ T13w（BAG/Lmax 不同）；官方 SFD→SFD 已 P；官方 2 ms 实测 0 ns；T90 任意 BAG。

### 5.3 T90（IF_MODE=2，128 TX VL；现行 **P**）

**宣称口径**：128 TX VL 全测；RX **126** VL 交付 + **2** VL（126/127）精确丢弃对账；**SAP 开**（CTL 0x051F）；端口预算 `256 = 128 TX + 126 RX + 2 SAP`。

证据：Questa `sim/out/p_c1_t90_r6_20261024_214647/` + Python `T90_METRICS_CHECK PASS`（wall 82s）。  
TB sha256：`5938A22595C02051D2D8BF0F0E75D7EC170760DB80E410EBF4328941636DB29D`（=现行磁盘；见 `CARD_C1_r6.md`）。  
manifest：`T90 tb_t90_vl128_throughput …`（已入 `sim/tests.manifest`）。

| 项 | 实测 |
|---|---|
| UNCONF @0x0040 | delta **12** == 2×3×2 |
| RX deliver | **378** == 126×3 |
| TX payload Mbps A/B | **679.188** |
| RX 去重 Mbps | **673.304** |
| e2e 抖动 max−min | **36936** ns ≤ 500 μs（本场景 40+Σ→500；节拍一致） |
| ES 总占用 | **85360** ns |
| CFG_SUM | **815008** |
| host_ack_wait_max | **368** ≤ 1000（契约 L93） |

| 阶段 | 结果 | 说明 |
|---|---|---|
| r1–r5 | FAIL / 绕开 | 见冲刺卡；**不得**用 r3 关 SAP 冒充 |
| **r6** | **PASS** | ACK=1000；定稿 P |

抖动算式：`J=min(40+Σ_j(20+Lmax_j)·8/1000,500)`；Σ_bytescale=97152 → **500 μs**。

**不能推出**：任意 BAG；官方 SFD→SFD；4096 路同时收。

图：占位（VCD 绘，非 GUI 截屏）。缺图见文末。

#### 5.3.1 T88 演示场（并列；非 T90）

Questa `p_c2_t88_r3_20261024_202813`：**1–8 PASS**（**分段演示**：步 5 前复位；步 5–6 `mgmt_mode` 断开 TX→RX 回环，与 T43 同口径；**不得**写「连续 8 步一次上电」）。步 7=PPS 解除失步+RTC 前进；**FLL 精度归 T16a**。SNMP 为 TB 内判据；独立线上 BER 见 T31/T36。SE 复跑 → D 阶段。

---

## 6. 综合后仿真

- 门级 T88b：S1=`PASS` S2=`PASS` S3=`PASS`
- VO sha256：`2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46`
- 阐述：`VoptFlow=0`（见 `out/p8_freeze_225cd91/STATUS.md` / `out/p8g_t88b`）；**判据与 RTL 场相同**，仅加载路径不同。
- **eLinx GUI 行为仿真（人工，2026-10-23）**：工程 `elinx/gui_afdx/AFDX_top.epr`，顶层 `tb_gate_public_loopback`，ModelSim SE。  
  证据（**仅此**）：`out/p3_elinx_gui_20261023/transcript` **L1102**（`T88b GATE PUBLIC LOOPBACK PASS…`）、**L1106**（`Errors: 0, Warnings: 2`）；`shots/elinx_sources.png`；`shots/elinx_modelsim_path.png`。  
  等级：**P（GUI 行为）**；≠ 门级 VO；≠ Fit/STA。  
  **不得引用** `elinx_pass.png` / `elinx_run_behav.png` / 记事本摘录 / `shots/_discard/`。

**不能推出**：门级 full 矩阵；SDF；eLinx 原生网表 ≡ Quartus VO；Fit 已签。

综合规模（旁证）：cells=`106241`，altsyncram=`507`；Fmax=`41.66` MHz / Setup=`-16.005` ns（**I**，代理器件未闭合）。

---

## 7. 质量证据

| 项 | 值 | 等级 |
|---|---|---|
| 变异杀死 | FREEZE 键仍 **null**。**分列**：历史 **57/57**；C3 **新增 28、杀死 23、存活 5、已证等价 0**（见上表证据树）。超时/PASS 不计杀 | P（分列） / FREEZE 键 I |
| lint %Error | `lint_error` = **null** → **未跑/未入冻结**（工程门曾 PASS 见执行记录，不得冒充本 FREEZE 数） | I / 未跑 |
| 覆盖率 | 未跑（本轮 FREEZE 标明；D 阶段后再填） | I / 未跑 |
| 形式 BMC（BAG） | cover 可达；bmc20 **vacuous**；bmc40 FAIL（主因 wrapper (a)）；**(c) 未排除（VCD 未能解码 start_vld/next_tx）**；**不宣称 BAG** — `ENV_STATUS.md` / `bag_bmc40_CE_ANALYSIS.md` | **F** |
| 形式 BMC（pool/RM 历史） | 有界 PASS 见 ENV_STATUS；不替代仿真 T | I |

**不能推出**：95% 覆盖；变异已覆盖全部新模块；BMC 无界证明；bmc20 空真当 BAG 证据。

---

## 8. 缺陷与修复记录

每条：现象 → 根因 → 修复 → 回归 → 证据。均为仓库执行记录 / git 可追溯项；**≥8**。

### D1. chipsim 漏接 `rx_error`（T88a 前后对照）

| 项 | 内容 |
|---|---|
| 现象 | chipsim 缩配顶层漏端口，`rx_error*` 悬空 → GMII RX 遇 X 进 DROP，回环 MSG_CNT=0 |
| 根因 | `AFDX_top_chipsim.v` 未引出/接到 `u_es` 的 `rx_error`/`rx_error_b` |
| 修复 | 补端口并接 0（或驱动）；新增 `tb_chipsim_smoke.v`（T88a） |
| 回归 | T88a：修复前 FAIL（MSG_CNT=0），修复后 PASS（MSG_CNT=1） |
| 证据 | `sim/out/p1_chipsim_before_20261021_185558/`；`sim/out/p1_chipsim_after_20261021_185558/`；`doc/提分执行计划_20261020.md` §12 步骤 1b；commit `34383d4` |
| 不能推出 | 满配 `AFDX_top` 也曾漏接；chipsim ≡ 满配门级 |

### D2. T42 runner 卡死与 harvest

| 项 | 内容 |
|---|---|
| 现象 | T42 日志已 `$finish`/PASS，进程 hung → 冒烟记 TIMEOUT / 假失败 |
| 根因 | vsim 收尾未退出；runner 仅靠进程退出判成败 |
| 修复 | `run_regress.ps1` Run-Vsim：见 `$finish`+Errors 后 grace **harvest**；`run_smoke.ps1` 同步 |
| 回归 | 冒烟一次 15/15（含 T42） |
| 证据 | `sim/out/p3_smoke_20261022_182316/SMOKE_SUMMARY.md`；提分计划 §12 步骤 9；commit `225cd91` |
| 不能推出 | harvest 改变了 TB 判据；冒烟 = 全量 |

### D3. lint 误改 RTL 后回退

| 项 | 内容 |
|---|---|
| 现象 | 为消 BLKLOOPINIT 曾改 `rx_reassembly` / `tx_message_store` |
| 根因 | lint 清 warning 动机越权改生产 RTL |
| 修复 | `git restore` 回 `683e959`；改用 `-Wno-BLKLOOPINIT` 豁免 |
| 回归 | `tools_lint.ps1` LINT GATE PASS（sources.f=48）；RTL 与锚点 ignore-cr 一致 |
| 证据 | `out/p4_lint_20261022_182034/`；提分计划 §12 步骤 8；commit `225cd91` |
| 不能推出 | lint 无 warning；本 FREEZE `lint_error` 已有数（实为 null） |

### D4. 门级 TB 参数覆盖 → vopt-2732

| 项 | 内容 |
|---|---|
| 现象 | 门级加载失败（vopt-2732）；早期 sim_r1/r2 失败 |
| 根因 | VO 无 parameter 口，TB `#()` 参数覆盖非法；另缺 `-L elinx_lib` |
| 修复 | `tb_gate_public_loopback` 去掉参数覆盖（依赖 RTL 默认 IF_MODE=2/FCS_MODE=2）；脚本补 `-L` |
| 回归 | 门级 T88b S1+S2（后 S3）PASS |
| 证据 | `out/p2_gate_vo_20261021_193847/sim_r3/`；提分计划 §12 步骤 4；现行 VO 键 `2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46` |
| 不能推出 | 门级 full 矩阵；SDF |

### D5. T89 re-init 清 PSN

| 项 | 内容 |
|---|---|
| 现象 | 多阶段指标场后接官方 e2e 时，IC PSN 被前段污染 / 共享 VL_RX 索引串扰 |
| 根因 | 同场连续激励未 hard re-init；配置曾共享 RX 索引导致跨 VL 污染 PSN |
| 修复 | TB：独立 VL_RX 索引；jit32 后 **hard re-init**（`wait_init`）再跑 e2e；注释见 `sim/tb/tb_t89_gmii_metrics_full.v` |
| 回归 | T89 PASS（checks 与 Python 复算）；冻结键 `t89_*` |
| 证据 | 提分计划 §12 步骤 10；`tb_t89_gmii_metrics_full.v`（「hard re-init after jit32 so IC PSN is clean」）；全量目录 T89_console |
| 不能推出 | 官方 SFD→SFD 键已入本冻结 metrics |

### D6. T15/T15g SAP 背压重复接收

| 项 | 内容 |
|---|---|
| 现象 | SAP 忙时仍对同一描述符重复接收 |
| 根因 | 入站 valid 未与 `sap_engine_ready` 联合门控 |
| 修复 | `AFDX_top`：`prs_to_sap && sap_engine_ready` |
| 回归 | T15/T15g 及当时完整回归 |
| 证据 | `doc/整改执行记录_20261008.md` §1 / §2.1 |
| 不能推出 | 当时另一冻结全量 = 现行 `144` |

### D7. TFTP 主机地址位宽

| 项 | 内容 |
|---|---|
| 现象 | 地址映射 warning / 宽度不一致风险 |
| 根因 | 16 位基址减法后未显式取窗内 13 位 |
| 修复 | 先 `host_addr - 16'hCC20`，再取 `[12:0]`；穷举有效窗 |
| 回归 | 地址空间穷举 + 完整回归相关项 |
| 证据 | `doc/整改执行记录_20261008.md` §2.1；`warning_triage_r2/check_tftp_addr_width.py` |
| 不能推出 | 完整 615A 认证 |

### D8. 管理面提交暴露的真实缺陷（T24 过程）

| 项 | 内容 |
|---|---|
| 现象 | 管理面响应上线过程中暴露两处真实 RTL 缺陷 |
| 根因 | 见该次合入说明（CTL 开关与响应路径） |
| 修复 | commit `d979f5a`（修缺陷）；`0aa8648`（管理面响应上线，CTL[9] 保护既有用例） |
| 回归 | 相关 SNMP/管理 T |
| 证据 | `git log`：`d979f5a`、`0aa8648` |
| 不能推出 | 管理面 = 完整 SNMP/615A |

### D9.（补充）门级缺 `-L` / 加载路径（与 D4 同轮）

| 项 | 内容 |
|---|---|
| 现象 | sim_r1 缺库导致加载失败 |
| 根因 | 门级脚本未链 `elinx_lib` |
| 修复 | `run_gate_t88b.ps1` 等补 `-L elinx_lib` |
| 回归 | 同 D4 sim_r3 PASS |
| 证据 | 提分计划 §12 步骤 4 卡内「r1 缺 -L」 |
| 不能推出 | 一次失败次数可拼成 PASS |

---

## 9. 流程差异说明

| 差异 | 含义 | 判据是否变 |
|---|---|---|
| Runner **harvest** | 日志已结束则收割 hung 进程 | **不变**（只改退出判定） |
| 门级 **VoptFlow=0** | 阐述/优化流关闭，加载 functional VO | **不变**（与 RTL 同 TB 判据） |
| 全量 N=`144` vs 历史 `post_fix4` 全量 | manifest / runner 代际不同；另一 commit（计数见文末历史附录） | **不可等同、不可拼接** |
| eLinx GUI vs 门级 VO | GUI 行为 P ≠ VO 门级 P | 分列 |

**不能推出**：把历史附录中的旧全量计数与本冻结 `144`/`144` 写成「同一轮」。

---

## 10. 边界与未覆盖

| 项 | 状态 | 等级 |
|---|---|---|
| 官方单帧 SFD→SFD ≤2 ms 对口列 | 待 C0 T89 补测；metrics 无 `t89_max_sfd2sfd_ns` | I |
| 128 TX VL 同时活动吞吐（T90） | r6 PASS（`p_c1_t90_r6_20261024_214647`） | **P** |
| T88 演示步骤 1–8 | `p_c2_t88_r3_20261024_202813` PASS；分段演示 | **P**（Questa）；SE→D |
| BAG 有界 BMC（C4） | bmc20 空真；bmc40 未收绿 | **F**（不宣称） |
| ModelSim SE 全量逐项 vs Questa | 本轮 FREEZE 未跑 | I / 未测 |
| 覆盖率 / FREEZE 内变异·lint 数值 | null → 未跑 | I |
| 代理 Fmax≥125 / 板卡签核 | Setup 负裕量 | I / F |
| 门级 full 矩阵、SDF、eLinx 原生网表业务 | 未做 | F |
| 完整 ARINC / 615A/665 认证、对端真 ES | 不做 | F |
| T18 8h 长时 | 禁止宣称 | F |

---

## 缺图清单（人工补）

- [x] eLinx GUI：`transcript` L1102/L1106 + `shots/elinx_sources.png` + `shots/elinx_modelsim_path.png`（`_discard/` 不入包）
- [ ] T88 / T89 / T10 / T16u 波形 PNG（VCD→脚本；注明 VCD sha256）
- [ ] T42/T89 吞吐时间序列、时延直方图、抖动箱线（D 阶段）

---

## 历史附录（勿与现行冻结拼接）

- 2026-10-18：140/140 — `sim/out/post_fix4_full140_20261018_011708/`（commit 内容哈希另册）
- 2026-10-06：80/80 — `closeout_20261006`
- 更早：70/70（2026-10-03）等  

以上 N 与 runner **≠** 本报告 `144`。
