# AFDX 端系统测试报告（提交版）

> 数字一律双花括号 metric 锚点（对照 `out/p8_freeze_225cd91/metrics.json`）。历史全量计数等只允许出现在历史附录并注明版本。  
> 每个 **P** 结论后附适用边界。冻结 commit：`{{metric:freeze_commit}}`。

---

## 1. 验证环境

### 1.0 架构概要

```
激励 / BFM (sim/env) ──► DUT AFDX_top / chipsim ──► chk bind / scoreboard
         │                        │
         └─ sw/golden + Python ───┴─ 独立复算（部分 T）
```

- **仿真器**：Questa FSE（功能全量）；ModelSim SE 2020.4（功能全量对照 + 门级 T88b、eLinx GUI 行为）。
- **TB**：`sim/tb/`；清单 `sim/tests.manifest`；runner `sim/run_regress.ps1` / `sim/run_smoke.ps1`。
- **时钟**：与 GMII 线速拍一致（仿真 125 MHz）。
- **双仿真器墙钟**：同树 `098efc9` 全量 Questa FSE **wall_s=6306.3**、ModelSim SE **wall_s=840.9**（约 **7.5×**）。原因：Questa **FSE 受限版** 仿真吞吐低于 SE；**判据与 PASS/FAIL 逐项一致**（`dual_sim_compare.csv` 145/145 match），墙钟差不表示结果不一致。

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
| 负控变异 | T08c/e、T09–T12、T22 + **C3** `test_c3_mutants.py` | 注入故障期望 FAIL | — | 仅「编译成功且功能 FAIL」计杀死；C3：**新增 28 / 杀死 23 / 存活 5 / 已证等价 0**（基线 21/28 + 加严再杀 2；与历史 **57/57** 分列） |
| 公开端口回环 | T88b（RTL/门级/GUI） | 载荷 hex / 步骤打印 | 是 | 只用顶层端口，便于 VO |

### 1.4 白盒与看门狗口径（C3 加严）

- **T41 IFG**：精确 12 拍判据为**白盒**——TB 读 `u_tx.st`（`mac_tx_if` 状态机 `ST_IFG`），非仅观 GMII 线上空闲。用于杀 `ifg_minus_one`；该判据为白盒状态观测，不是仅观线上空闲的黑盒证明。
- **T16a 看门狗**：仿真墙钟由 **200 ms → 220 ms**（`#220_000_000`）。原因：C3 加严新增约 **2 ms** 量级的停 PPS→`sync_loss` 场景；**FLL 精度判据未放宽**。FLL 精度判据未放宽。

### 1.5 Runner 说明（harvest）

`sim/run_regress.ps1` 的 `Run-Vsim`：若日志已出现 `$finish` 与 `Errors: N` 而进程未退出，grace 后**收割**并返回 0，**不改 TB 判据**。用于消除个别用例（如历史冒烟 T42）「日志已 PASS、墙钟 TIMEOUT」的假失败。  
本冻结全量 N=`{{metric:full_n}}` 在带 harvest 的 runner 上得到；与历史全量（旧 runner、不同 N）**不可直接等同**。详见 §9。

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
> **主口径（新答疑 / `afdx_app_top`）**：应用口时延·抖动·吞吐·128 VL → **T93/T94/T95**（§5.4）。T92–T95 为 RTL 仿真（测试台用 `dut.*` 层次引用），门级证据是 §6 的 T88b。BAG 整形证据仍是核心测试 T04 / T05c / T27 / T90。  
> **补充**：T42/T89/T90（GMII/ES 贡献）；单 ES 回环「GMII SFD→SFD」不作主宣称。

### 3.1 五功能

| 赛题条目 | T（代表） | 配置 | 实测（metric） | 等级 | 适用边界 |
|---|---|---|---|---|---|
| 通信 / 调度与流量整形（BAG、端口缓冲、组帧） | T04/T05c/T27；回环切片 T22 | IF_MODE 分档见各 TB；T27 合法 BAG 扫档 | 全量计入 `{{metric:full_pass}}`/`{{metric:full_n}}`；无单独 BAG 时延 key | P（各 TB 标题范围） | 限于各 TB 标题场景；不含任意 BAG×Lmax 笛卡尔积或板级线速调度 |
| 高可靠：完整性检查 IC（SN/PSN） | T08e/T09 | 见 TB；向量+模型 | accept `{{metric:t09_accept}}` / reject `{{metric:t09_reject}}` | P | 限于该剧本向量；不含顶层全错误笛卡尔积或 babbling 全空间 |
| 高可靠：冗余管理 RM（双网去重 / SkewMax） | T10 | 见 TB | fwd `{{metric:t10_fwd}}` dup `{{metric:t10_dup}}` skew `{{metric:t10_skew}}` | P | 限于该剧本；不含任意迟到历史或网表级 RM |
| SNMP 网络管理（v1 子集） | T15 族；演示 T88 步 5 | v1 only | T88 步 5：**分段演示** TB 内 PASS（`p_c2_t88_r3`）；线上 BER 见 T31/T36 | P（子集+演示步 5） | 限于已实现 SNMP v1 子集与演示步 5；完整 SNMP 与独立 wire 钩子不在本场 |
| 615A / TFTP 加卸载（披露子集） | T34p/T35p 等规模与管理相关；615A 专用 TB 见 manifest | 固定块长等边界见各 TB | `{{metric:t34p_pass}}` / `{{metric:t35p_pass}}` | P（已跑子集） | 限于已跑加卸载子集；不含完整 615A/665 认证或被动标准 LUI 全生命周期 |
| RTC 时钟同步（PPS/FLL） | T16a 等 | 见 TB | `{{metric:t16a_pass}}` | P（该剧本） | 限于该 PPS/FLL 剧本；不含网络授时口或与 SNMP/TFTP 全共存矩阵 |

### 3.2 四指标

| 指标 | T | 配置 | 实测 | 等级 | 适用边界 |
|---|---|---|---|---|---|
| **主·时延** 首字节 tx→rx ≤2 ms | **T93** | `afdx_app_top`；PLEN=256；A 单 VL / B 4 VL | A max **{{metric:t93_a_max_ns}} ns** / B max **{{metric:t93_b_max_ns}} ns** | **P** | 封装口定义；不含网络/交换机端到端 |
| **主·抖动** 同 VL 同长 max−min | **T93** | 同上 | A_jit **{{metric:t93_a_jit_ns}} ns**；B_jit **{{metric:t93_b_jit_ns}} ns** | **P** | 本场；A 抖动来源与按 VL 的 BAG 判据见 `doc/T93_抖动来源与BAG判据_20261029.md` |
| **主·吞吐** 应用口 ≥100 Mbps | **T94** | NVL=16 ROUNDS=3 PLEN=1471 | 稳态 **{{metric:t94_steady_rx_mbps}} Mbps** | **P** | 本场 |
| **主·128 VL** | **T95** | TX128 / RX126 + unconf×4 | submit={{metric:t95_submit}} deliver={{metric:t95_deliver}} unconf={{metric:t95_unconf}} | **P** | 交付以 126 为准；VL126/127 unconf |
| 补充·吞吐（GMII 去重载荷） | T42；T90 | 见 §5.1/§5.3 | T90 rx_dedup **673.304** Mbps 等 | P（补充） | 不替代 T94 主口径 |
| 补充·ES 贡献 ≤2 ms | T89 | IF_MODE=2 | 3384 / 2592 / 5976 ns | P（补充） | 与封装口起止分列 |
| 补充·工程时延 | T13 / T13w / T42 | 见各节 | metric 锚点见原列 | P（补充） | 不冒充封装主口径 |
| 补充·抖动（BAG 压力等） | T05b；T42；T89 | 见各节 | 见 metric 锚点 | P（补充） | 新场景须重算 40+Σ |
| 规模：4096 RX 等 | T34p / T35p | 见 TB | `{{metric:t34p_pass}}` / `{{metric:t35p_pass}}` | P | 不含 4096 路同时收 |

**分列：** 封装口（T92–T95）与 GMII/host 工程起止（T42/T89/T90）不可拼成同一「现行」数字。

全量矩阵：`{{metric:full_pass}}` / `{{metric:full_n}}`（`{{metric:full_all_pass}}`）。  
**适用边界：**认证实验室套件；评委自建 TB 以外的协议全集。

---

## 4. 全量清单

由冻结同源 `regress.csv` **自动生成**（脚本 `tools/gen_regress_table.py`，只读 CSV）。  
打包时附完整表或生成物；正文不手抄 144 行。

- 汇总：PASS `{{metric:full_pass}}` / N `{{metric:full_n}}`
- 建议 CSV：`out/p8_clean_20261022_191733/sim/out/p8_full_20261022_191856/regress.csv`（与 metrics `full_*` 同源）
- 生成：`python tools/gen_regress_table.py --csv <上路径> [--out doc/submit/_generated_regress_table.md]`

列：id、功能/摘要、配置、结果、墙钟(s)。

---

## 5. 指标章

### 5.4 评测封装 `afdx_app_top`（主口径；T92–T95）

| 项 | 实测 | 证据 |
|---|---|---|
| T92 基本收发 | {{metric:t92_pass}} checks={{metric:t92_checks}} | `T92_console.txt`；VL0/32/64/96 四档最小与最大载荷 |
| T93 时延 max | A **{{metric:t93_a_max_ns}}** / B **{{metric:t93_b_max_ns}} ns** ≪ 2e6 | `T93_console.txt` + `t93_metrics_check` |
| T93 抖动 A/B | **{{metric:t93_a_jit_ns}} / {{metric:t93_b_jit_ns}} ns** | 同上；来源与 BAG 判据见 `doc/T93_抖动来源与BAG判据_20261029.md` |
| T93 按 VL 的 TX SFD 间隔 | min **{{metric:t93_vl_gap_min_cyc}}** 周期 ≥ BAG **{{metric:t93_bag_cyc}}** 周期（违例 {{metric:t93_vl_bag_viol}}） | `t93_gmii_sfd.csv` / `t93_vl_gap.csv` + `t93_metrics_check`；TB 注入间隔 > BAG，BAG 整形证据仍为 T04 / T05c / T27 / T90 |
| T94 稳态吞吐 | **{{metric:t94_steady_rx_mbps}} Mbps**（≥100） | `T94_console.txt` |
| T95 128 VL | submit={{metric:t95_submit}} deliver={{metric:t95_deliver}} unconf={{metric:t95_unconf}} | `T95_console.txt`；VL125 port=**255**（`vl_valid` 修复） |
| 封装综合（平铺）能正常综合 | **{{metric:app_synth_pass}}**（P） | `run_status.json`：eLinx `memory_bram`+`stat` 通过；非 Fit/STA/GUI LUT |
| 封装综合数字 | cells **{{metric:app_synth_cells}}** / altsyncram **{{metric:app_synth_altsyncram}}**（I）；核心 **{{metric:cells}}/{{metric:altsyncram}}**，增量 +{{metric:app_synth_delta_cells}} / +{{metric:app_synth_delta_altsyncram}}（I） | 同流程；「器件装得下」是由此推出的判断（I）。eLinx 综合器为 32 位进程（约 2 GB），封装 RTL 为此去掉大数组复位 for 循环与变量地址组合读 |

汇总：最终冻结 metrics 副本中的 `t92_*` … `t95_*`、`app_synth_*` 键。  
**适用边界：** 限于封装字节流与本仓 GMII 回环；不含评委自建 TB 以外协议全集；不得写封装已 Fit。T93 的 BAG 间隔判据由 TB 注入节奏（约 132144 周期）决定，只说明未早于 BAG 发帧；没有「同 VL 连续快速提交」场景。T93 Phase A 抖动来源（封装接收轮询相位，仅首帧）见 `doc/T93_抖动来源与BAG判据_20261029.md`（诊断，I）。

### 5.1 T42（IF_MODE=2，公开 GMII；工程起止；**补充**）

| 项 | metric | 备注 |
|---|---|---|
| TX commit→eof max | `{{metric:t42_tx_commit_to_eof_max_us}}` μs | 工程界 |
| RX sof→host max | `{{metric:t42_rx_sof_to_host_max_us}}` μs | 工程界 |
| 抖动 max−min | `{{metric:t42_jitter_max_us}}` μs | 勿写「官方 50 μs」 |

**适用边界：**本结论限于 T42 工程起止与该场景 VL 配置；不含官方字面 SFD→SFD、板级测量或 128 VL 满配吞吐（见 T90）。

### 5.2 T89（IF_MODE=2；ns 主打印）

| 项 | metric | 备注 |
|---|---|---|
| max_tx | `{{metric:t89_max_tx_ns}}` ns | commit→eof（工程） |
| max_rx | `{{metric:t89_max_rx_ns}}` ns | 工程 RX 界 |
| max_jit | `{{metric:t89_max_jit_ns}}` ns | 同 VL max−min |
| 本场景 40+Σ | `{{metric:t89_bound_40sig_us}}` μs | **本场景重算**；非一律 500 μs |
| frames/VL | `{{metric:t89_frames_per_vl}}` | 抖动样本数 |
| 官方字面 SFD→SFD | （信息列） | **I**：wire loopback 0 by construction |
| ES commit→TX SFD max | 3384 ns | **P**：`sim/out/p_c0_t89_questa_20261024_170643/T89_console.txt` **L33** |
| ES RX SFD→host max | 2592 ns | **P**：同上 **L33** |
| ES 总占用 | 5976 ns | **P**：同上 **L33**（≪2e6）；Python `T89_METRICS_CHECK PASS` |
| 满配 128 VL 吞吐 | （T90） | **P**：见 §5.3 |

抖动说明：T89 对照本场景第一式 **40 μs + Σ** = `{{metric:t89_bound_40sig_us}}` μs；实测 max_jit = `{{metric:t89_max_jit_ns}}` ns。新场景须重算 40+Σ。

**适用边界：**本结论限于 T89 场景参数；与 T13w 配置不同，不可混读；不含官方字面 SFD→SFD 已 P，也不外推到任意 BAG 的 T90。

### 5.3 T90（IF_MODE=2，128 TX VL；现行 **P**）

**宣称口径**：128 TX VL 全测；RX **126** VL 交付 + **2** VL（126/127）精确丢弃对账；**SAP 开**（CTL 0x051F）；端口预算 `256 = 128 TX + 126 RX + 2 SAP`。

证据：Questa `sim/out/p_c1_t90_r6_20261024_214647/` + Python `T90_METRICS_CHECK PASS`（wall 82s）。  
TB sha256：`5938A22595C02051D2D8BF0F0E75D7EC170760DB80E410EBF4328941636DB29D`（=现行磁盘）。

| 项 | 实测 |
|---|---|
| UNCONF @0x0040 | delta **12** == 2×3×2 |
| RX deliver | **378** == 126×3 |
| TX payload Mbps A/B | **679.188** |
| RX 去重 Mbps | **673.304** |
| e2e 抖动 max−min | **36936** ns ≤ 500 μs |
| ES 总占用 | **85360** ns |
| CFG_SUM | **815008** |
| host_ack_wait_max | **368** ≤ 1000（契约 L93） |

| 阶段 | 结果 | 说明 |
|---|---|---|
| r1–r5 | FAIL / 绕开 | 见冲刺卡；不以关 SAP 的历史跑次冒充现行 |
| **r6** | **PASS** | ACK=1000；定稿 **P** |

**适用边界：**本结论限于 T90 本场 BAG/Lmax 与端口预算；不含任意 BAG 外推、官方字面 SFD→SFD，或 4096 路同时收。

图：占位（VCD 绘，非 GUI 截屏）。缺图见文末。

#### 5.3.1 T88 演示场（并列；非 T90）

Questa `p_c2_t88_r3_20261024_202813`：**1–8 PASS**（**分段演示**：步 5 前复位；步 5–6 `mgmt_mode` 断开 TX→RX 回环，与 T43 同口径；本场为分段演示，不是一次上电连续 8 步）。步 7=PPS 解除失步+RTC 前进；**FLL 精度归 T16a**。SNMP 为 TB 内判据；独立线上 BER 见 T31/T36。SE 复跑 → D 阶段。

---

## 6. 综合后仿真

- 门级 T88b：S1=`{{metric:gate_t88b_s1}}` S2=`{{metric:gate_t88b_s2}}` S3=`{{metric:gate_t88b_s3}}`
- VO sha256：`{{metric:gate_vo_sha256}}`
- 阐述：`VoptFlow=0`（见 `out/p8_freeze_225cd91/STATUS.md` / `out/p8g_t88b`）；**判据与 RTL 场相同**，仅加载路径不同。
- **eLinx GUI 行为仿真（人工，2026-10-23）**：工程 `elinx/gui_afdx/AFDX_top.epr`，顶层 `tb_gate_public_loopback`，ModelSim SE。  
  证据（**仅此**）：`out/p3_elinx_gui_20261023/transcript` **L1102**（`T88b GATE PUBLIC LOOPBACK PASS…`）、**L1106**（`Errors: 0, Warnings: 2`）；`shots/elinx_sources.png`；`shots/elinx_modelsim_path.png`。  
  等级：**P（GUI 行为）**；≠ 门级 VO。  
  证据不含 `elinx_pass.png` / `elinx_run_behav.png` / 记事本摘录 / `shots/_discard/`。
- **T91 门级吞吐：F**（2026-10-26）。公开端口吞吐场在 RTL（Questa，NVL=16 ROUNDS=3，稳态第 2–3 轮）已 PASS；门级探速 ROUNDS=1 至 18:10 决策点仍未 `$finish`（墙钟约 20994 s），按外推不再启动 R=2/R=3 门级。综合后仿真证据以 **T88b 切片**为准，不以 T91 门级吞吐宣称。

**适用边界：**本结论限于公开端口门级切片 T88b；不含门级全量矩阵、SDF、T91 门级吞吐，也不将 eLinx 原生网表等同 Quartus VO。

综合规模（旁证）：cells=`{{metric:cells}}`，altsyncram=`{{metric:altsyncram}}`（eLinx；≠ GUI LUT）。本作品不做时序签核与板级验证（赛题未要求）。

---

## 7. 质量证据

| 项 | 值 | 等级 |
|---|---|---|
| 变异杀死 | **分列**：历史 `{{metric:mutants_historical_detected}}`/`{{metric:mutants_historical_total}}`；C3 新增 `{{metric:c3_mutants_total}}`、杀死 `{{metric:c3_mutants_killed}}`、存活 `{{metric:c3_mutants_survived}}`、已证等价 `{{metric:c3_mutants_equiv}}`（`p_c3_merged_20261025`） | **P**（分列；勿与历史 57/57 拼接成现行） |
| lint %Error | `lint_error` = `{{metric:lint_error}}`（`out/p4_lint_20261022_182034`；rtl 相对 `225cd91` 空差，见 `out/p9_freeze_dfac58a/rtl_empty_vs_225cd91.txt`） | **P** |
| 覆盖率（DU 加权，全设计） | stmt `{{metric:coverage_stmt_pct}}`% / branch `{{metric:coverage_branch_pct}}`% / total `{{metric:coverage_total_pct}}`% | **I** |
| 覆盖率（实例口径，含 TB/bind） | stmt **58.73%** / branch **44.63%** / total **51.68%**（145 UCDB `vcover summary` BY INSTANCES，8379 实例） | **I** |
| 覆盖率（单行 AFDX_top DU 参考） | stmt `{{metric:coverage_top_du_stmt_pct}}`% / branch `{{metric:coverage_top_du_branch_pct}}`% / total `{{metric:coverage_top_du_total_pct}}`% — 仅作顶层 DU 参考，非全设计覆盖率 | **I** |
| 形式 BMC（BAG） | cover 可达；bmc20 **vacuous**；bmc40 FAIL（主因 wrapper (a)）；**(c) 未排除（VCD 未能解码 start_vld/next_tx）**；**不宣称 BAG** — `formal/ENV_STATUS.md` / `bag_bmc40_CE_ANALYSIS.md` | **F** |
| 形式 BMC（pool/RM 历史） | 有界 PASS 见 ENV_STATUS；不替代仿真 T | I |

### 7.1 覆盖率统一表（并列，均 **I**）

| 指标 | 统计对象 | 是否含 TB/bind | 来源报告文件 | 数值 |
|---|---|---|---|---|
| 语句% | 全设计生产 DU 加权（Σhits/Σbins） | **否** | `out/p9_freeze_dfac58a/coverage_by_du.md` | `{{metric:coverage_stmt_pct}}`% |
| 分支% | 同上 | **否** | 同上 | `{{metric:coverage_branch_pct}}`% |
| 合计% | 同上（语句/分支再合成） | **否** | 同上 | `{{metric:coverage_total_pct}}`% |
| 语句% | UCDB **BY INSTANCES**（8379 实例） | **是** | `out/p9_freeze_dfac58a/coverage_summary_all145.txt` | **58.73%** |
| 分支% | 同上 | **是** | 同上 | **44.63%** |
| 合计% | 同上 | **是** | 同上 | **51.68%** |
| 语句% | 仅 `AFDX_top` 单 DU 参考 | **否**（该 DU） | `coverage_report_du_AFDX_top.txt` | `{{metric:coverage_top_du_stmt_pct}}`% |
| 分支% | 仅 `AFDX_top` 单 DU 参考 | **否** | 同上 | `{{metric:coverage_top_du_branch_pct}}`% |
| 合计% | 仅 `AFDX_top` 单 DU 参考 | **否** | 同上 | `{{metric:coverage_top_du_total_pct}}`% |

**读表规则：** DU 加权 = 各生产模块 `vcover -du` 后 Σhits/Σbins（**任一实例命中即算该 DU bin**），数字可高于实例口径——**不是**「设计已测到 93% 行级」。实例口径含 TB/bind/多实例，未命中实例拉低总比。顶层单 DU 行**不得**当作全设计覆盖率。三者并列，**不可混称「另一口径」糊弄**。

旁证：`coverage_hotspots_top20.md`。

**语句覆盖最低的 5 个生产 DU（及原因，I）：**

| DU | 语句% | 主要原因（不宣称已穷尽） |
|---|---:|---|
| `bram_sdp` | 42.85 | 包装层/少用端口与字节使能边角；多数访问走 `bram_sdp_core` |
| `bram_1w1r` | 60.00 | 单口变体路径在现行 TB 矩阵中较少激励 |
| `tx_sn_gen` | 79.66 | SN 回绕/复位/旁路等边沿未在全矩阵打满 |
| `rx_reassembly_chain` | 80.08 | 分片超时、乱序、异常终止等负路径只覆盖子集 |
| `rx_pmem_scatter_copy` | 83.09 | 散写/背压组合未笛卡尔扫满 |

另：`a615a_tftp` 语句约 86%——TFTP 错误码/超时/TID 错等分支仅部分 TB 触及；本场覆盖为子集路径，非 615A/TFTP 全状态机。

**适用边界：**覆盖率为两种并列 I 口径，不以 95% 为目标；DU 加权与实例口径不可混称；变异与 BMC 仅覆盖已报告范围，bmc20 空真不作 BAG 证明。

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
| 适用边界 | 满配 `AFDX_top` 也曾漏接；chipsim ≡ 满配门级 |

### D2. T42 runner 卡死与 harvest

| 项 | 内容 |
|---|---|
| 现象 | T42 日志已 `$finish`/PASS，进程 hung → 冒烟记 TIMEOUT / 假失败 |
| 根因 | vsim 收尾未退出；runner 仅靠进程退出判成败 |
| 修复 | `run_regress.ps1` Run-Vsim：见 `$finish`+Errors 后 grace **harvest**；`run_smoke.ps1` 同步 |
| 回归 | 冒烟一次 15/15（含 T42） |
| 证据 | `sim/out/p3_smoke_20261022_182316/SMOKE_SUMMARY.md`；提分计划 §12 步骤 9；commit `225cd91` |
| 适用边界 | harvest 只改进程退出判定，不改 TB 判据；冒烟集不等于全量矩阵 |

### D3. lint 误改 RTL 后回退

| 项 | 内容 |
|---|---|
| 现象 | 为消 BLKLOOPINIT 曾改 `rx_reassembly` / `tx_message_store` |
| 根因 | lint 清 warning 动机越权改生产 RTL |
| 修复 | `git restore` 回 `683e959`；改用 `-Wno-BLKLOOPINIT` 豁免 |
| 回归 | `tools_lint.ps1` LINT GATE PASS（sources.f=48）；RTL 与锚点 ignore-cr 一致 |
| 证据 | `out/p4_lint_20261022_182034/`；提分计划 §12 步骤 8；commit `225cd91` |
| 适用边界 | lint 无 warning；本 FREEZE `lint_error` 已有数（实为 null） |

### D4. 门级 TB 参数覆盖 → vopt-2732

| 项 | 内容 |
|---|---|
| 现象 | 门级加载失败（vopt-2732）；早期 sim_r1/r2 失败 |
| 根因 | VO 无 parameter 口，TB `#()` 参数覆盖非法；另缺 `-L elinx_lib` |
| 修复 | `tb_gate_public_loopback` 去掉参数覆盖（依赖 RTL 默认 IF_MODE=2/FCS_MODE=2）；脚本补 `-L` |
| 回归 | 门级 T88b S1+S2（后 S3）PASS |
| 证据 | `out/p2_gate_vo_20261021_193847/sim_r3/`；提分计划 §12 步骤 4；现行 VO 键 `{{metric:gate_vo_sha256}}` |
| 适用边界 | 本条仅覆盖门级加载路径修复；不含门级 full 矩阵或 SDF |

### D5. T89 re-init 清 PSN

| 项 | 内容 |
|---|---|
| 现象 | 多阶段指标场后接官方 e2e 时，IC PSN 被前段污染 / 共享 VL_RX 索引串扰 |
| 根因 | 同场连续激励未 hard re-init；配置曾共享 RX 索引导致跨 VL 污染 PSN |
| 修复 | TB：独立 VL_RX 索引；jit32 后 **hard re-init**（`wait_init`）再跑 e2e；注释见 `sim/tb/tb_t89_gmii_metrics_full.v` |
| 回归 | T89 PASS（checks 与 Python 复算）；冻结键 `t89_*` |
| 证据 | 提分计划 §12 步骤 10；`tb_t89_gmii_metrics_full.v`（「hard re-init after jit32 so IC PSN is clean」）；全量目录 T89_console |
| 适用边界 | 本条修复 IC PSN 污染；官方字面 SFD→SFD 仍按 I 列，未写入本冻结主键 |

### D6. T15/T15g SAP 背压重复接收

| 项 | 内容 |
|---|---|
| 现象 | SAP 忙时仍对同一描述符重复接收 |
| 根因 | 入站 valid 未与 `sap_engine_ready` 联合门控 |
| 修复 | `AFDX_top`：`prs_to_sap && sap_engine_ready` |
| 回归 | T15/T15g 及当时完整回归 |
| 证据 | `doc/整改执行记录_20261008.md` §1 / §2.1 |
| 适用边界 | 当时另一冻结全量 = 现行 `{{metric:full_n}}` |

### D7. TFTP 主机地址位宽

| 项 | 内容 |
|---|---|
| 现象 | 地址映射 warning / 宽度不一致风险 |
| 根因 | 16 位基址减法后未显式取窗内 13 位 |
| 修复 | 先 `host_addr - 16'hCC20`，再取 `[12:0]`；穷举有效窗 |
| 回归 | 地址空间穷举 + 完整回归相关项 |
| 证据 | `doc/整改执行记录_20261008.md` §2.1；`warning_triage_r2/check_tftp_addr_width.py` |
| 适用边界 | 本条仅覆盖地址位宽修复；不含完整 615A 认证 |

### D8. 管理面提交暴露的真实缺陷（T24 过程）

| 项 | 内容 |
|---|---|
| 现象 | 管理面响应上线过程中暴露两处真实 RTL 缺陷 |
| 根因 | 见该次合入说明（CTL 开关与响应路径） |
| 修复 | commit `d979f5a`（修缺陷）；`0aa8648`（管理面响应上线，CTL[9] 保护既有用例） |
| 回归 | 相关 SNMP/管理 T |
| 证据 | `git log`：`d979f5a`、`0aa8648` |
| 适用边界 | 本条仅覆盖已合入缺陷修复；管理面仍为已披露子集 |

### D9.（补充）门级缺 `-L` / 加载路径（与 D4 同轮）

| 项 | 内容 |
|---|---|
| 现象 | sim_r1 缺库导致加载失败 |
| 根因 | 门级脚本未链 `elinx_lib` |
| 修复 | `run_gate_t88b.ps1` 等补 `-L elinx_lib` |
| 回归 | 同 D4 sim_r3 PASS |
| 证据 | 提分计划 §12 步骤 4 卡内「r1 缺 -L」 |
| 适用边界 | 以最终 PASS 证据为准；中间失败次数不拼成通过 |

---

## 9. 流程差异说明

| 差异 | 含义 | 判据是否变 |
|---|---|---|
| Runner **harvest** | 日志已结束则收割 hung 进程 | **不变**（只改退出判定） |
| 门级 **VoptFlow=0** | 阐述/优化流关闭，加载 functional VO | **不变**（与 RTL 同 TB 判据） |
| 全量 N=`{{metric:full_n}}` vs 历史 `post_fix4` 全量 | manifest / runner 代际不同；另一 commit（计数见文末历史附录） | **不可等同、不可拼接** |
| eLinx GUI vs 门级 VO | GUI 行为 P ≠ VO 门级 P | 分列 |

**适用边界：**把历史附录中的旧全量计数与本冻结 `{{metric:full_pass}}`/`{{metric:full_n}}` 写成「同一轮」。

---

## 10. 边界与未覆盖

| 项 | 状态 | 等级 |
|---|---|---|
| 官方单帧 SFD→SFD ≤2 ms 对口列 | 待 C0 T89 补测；metrics 无 `t89_max_sfd2sfd_ns` | I |
| 128 TX VL 同时活动吞吐（T90） | r6 PASS（`p_c1_t90_r6_20261024_214647`） | **P** |
| T88 演示步骤 1–8 | `p_c2_t88_r3` + D 全量 Questa/SE PASS；分段演示 | **P** |
| BAG 有界 BMC（C4） | bmc20 空真；bmc40 未收绿 | **F**（不宣称） |
| ModelSim SE 全量逐项 vs Questa | D：145/145 一致（`dual_sim_compare.csv`）；墙钟 SE 快约 7.5×（FSE） | **P**（结果）；墙钟差 I |
| 覆盖率 / FREEZE 内变异·lint 数值 | 全设计加权覆盖率 I（非单行 AFDX_top）；lint_error=0 **P**；变异分列见 §7 | I（覆盖）/ P（lint·C3） |
| 时序签核 / 板级验证 | 不做（赛题未要求） | — |
| 门级 full 矩阵、SDF、eLinx 原生网表业务 | 未做 | F |
| T91 门级吞吐（公开端口 ROUNDS=2/3） | 探速未在 18:10 前完成；不启门级 | **F**（RTL R=3 旁证另列） |
| 完整 ARINC / 615A/665 认证、对端真 ES | 不做 | F |
| T18 8h 长时 | 禁止宣称 | F |

---

## 缺图清单（人工补）

- [x] eLinx GUI：`transcript` L1102/L1106 + `shots/elinx_sources.png` + `shots/elinx_modelsim_path.png`（`_discard/` 不入包）
- [x] T10 / T16u / T88 / T89 / T90 波形 PNG（`out/p9_freeze_dfac58a/wave_png/*_signals.png`；VCD→`plot_vcd_signals.py`；注明 VCD sha256）。图注：**取自 -Acc 调试运行（严格判官因 vopt-10908 警告记 FAIL，TB 自判 PASS），功能结论以全量回归为准**（等级 **I**）。探针：T10=RM fwd/dup/skew；T16u=TFTP unload ack/file_valid；T88/T89/T90=TX/RX valid + host_ack/MT_COMMIT（帧时序/去重/吞吐相关，非活动度直方）。
- [ ] T42/T89 吞吐时间序列、时延直方图、抖动箱线（可选补；现行探针图已覆盖时延/去重窗口）

---

## 历史附录（勿与现行冻结拼接）

- 2026-10-18：140/140 — `sim/out/post_fix4_full140_20261018_011708/`（commit 内容哈希另册）
- 2026-10-06：80/80 — `closeout_20261006`
- 更早：70/70（2026-10-03）等  

以上 N 与 runner **≠** 本报告 `{{metric:full_n}}`。
