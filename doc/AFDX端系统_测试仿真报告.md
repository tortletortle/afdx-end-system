# AFDX 端系统 — 测试（仿真）报告

> **现行（2026-10-19）：** Questa **140/140 PASS**；可复现 commit **`08a0ad0`**（tag `baseline-full140-repro`）。历史 80/80、70/70、56/56 见文末附录，**不代表当前候选**。

评委先读 [00_先读](00_先读_提交范围与汇报口径.md)。宣称等级按 [验收尺子](验收尺子.md)（S/N/T · P/I/F）。

---

## 0. 现行锚点（第一屏）

| 项 | 结论 | 证据 |
|---|---|---|
| 现行回归 | Questa **140/140 PASS** | `sim/out/post_fix4_full140_20261018_011708/regress.csv` |
| 可复现 | 干净 checkout commit **`08a0ad0`**（tag `baseline-full140-repro`）跑出 **140/140**；与基准 CSV `test_id+result` **0 mismatch** | 验证树 `out/repro_check_20261019` → `sim/out/full140_repro3/regress.csv` |
| 综合（可映射） | eLinx `memory_bram`+`stat` **PASS**；**106241 cells / 507 `altsyncram`** | `out/baseline_full140_synth_20261018_171617/`。**不是** Fit/STA，**不是**网表业务，**不是**「LUT 已变小」 |

禁止句：满足 2 ms；综合后业务已过；当前工作树 140/140（只说 commit `08a0ad0` 可复现）；已推云端。

---

## 1. 需求 → T → 实测 → 不能推出

日志前缀除非另注：`sim/out/post_fix4_full140_20261018_011708/`（与可复现 tip 结果列一致）。主表格均为 **P**（有 T + 日志）；边界列按尺子写死。

| 赛题要求 | T | 实测（P） | 不能推出 |
|---|---|---|---|
| RTL 全量 | manifest 140 | **140/140 PASS**；commit `08a0ad0` 干净 checkout 可复现 | 非综合后业务；非板卡 |
| 100 Mbps 吞吐 | T42 | 每网 TX/RX **131.072 / 131.080** Mbps（IF_MODE=2） | 16 活动 VL，非 128 满载 |
| 单帧时延 ≤2 ms | T42 | commit→GMII 末字节 max **16.080 μs** | 多片 8192B 单列；**2 ms 官方口径 OPEN** |
| 抖动几十 μs | T42 / T05b | T42 极差 **5.016 μs**；T05b 启动 **2** / 稳态 **0** μs | 规范第一式封顶 500 μs，非全合法档 |
| 128 TX VL | T34p | 128VL×100 轮漂移 ~9 μs | 16B 载荷非满吞吐 |
| 4096 RX VL | T35p | 4096 唯一+4096 重复 drops=0 | 非 4096 路同时收 |
| 高完整性 IC/RM | T08e / T09 / T10 | IC accept=463 reject=5；RM fwd=56 dup=46；N=4096 IC 6007 | 该剧本范围 |
| 双网去重 | T10 / T22 | skew/dup 与模型一致；回环 2 帧去重 1 | 非 babbling/全表 |
| SNMP | T15 / T24 / T43 | GET/GETNEXT/SET+上线 A/B 匹配 | v1 子集；无 v3/Trap |
| 615A/TFTP | T16 / T25 / T43 | WRQ/DATA/ACK/卸载，load/unload 520B | 子集；完整 615A/665 **OPEN** |
| RTC | T16 | 锁定/失步/恢复、FLL 稳态 PASS | 非板级 1Hz；时间戳口接 0 |

---

## 2. 时延界 vs 仿真对照

离线工具：[`tools/afdx_delay_bound.py`](../tools/afdx_delay_bound.py)。完整推导与 Nbw 口径见 [时延界与仿真对照_20261018](时延界与仿真对照_20261018.md)。下表 **P/I 分级原样保留**，不升不降。

### 2.1 结论（对照文档 §0）

| 项 | 等级 | 一句话 |
|---|---|---|
| 计算器自检（T13w 复现 J=499.36 μs） | **P** | `--self-check` PASS；与 `tb_t13w_worst.v` 头注释代数一致 |
| T13w 排队实测 ≤ J(100 Mbps) | **P** | 425.200 μs ≤ 499.360 μs（`worst_queue` / `arinc_bound`） |
| T05b 抖动实测 ≤ 封顶 500 μs | **P** | 启动 2 μs、稳态 0 μs ≤ 500 μs（第一式未封顶 866.88 μs） |
| T42 同 VL 时延极差 ≤ 项目 50 μs | **P**（项目界） | 5.016 μs ≤ 50 μs；规范封顶仍是 500 μs，非 A664 抖动全集 |
| T13 端到端 Total vs 抖动式 J | **I** | Total=243.416 μs **不是** MaxJitter；不可与 J 直接比 |
| T82 8192 B 多片 ≤ 计算器界 | **P** | 最差 6161.736 μs ≤ 6233.360 μs。**禁止**写「满足 2 ms」（官方 2 ms 口径 OPEN） |

### 2.2 三列表（对照文档 §5）

| 场景（量） | 计算器界 | 实测 | 实测≤界？ | 等级 |
|---|---|---|---|---|
| T13w 排队 QUEUE（IF_MODE=0） | J@100M = **499.360 μs** | worst_queue=**425.200 μs** | 是 | **P** |
| T13w 端到端 TOTAL（IF_MODE=0） | 忙期串行化 449.76 μs（工程参考，非 MaxJitter） | worst_total=**453.752 μs** | 口径不同 | **I** |
| T13 最大帧 TOTAL（IF_MODE=0） | J=163.04 μs（抖动界） | worst_total=**243.416 μs** | 不可与 J 直接比 | **I** |
| T05b 启动 / 稳态抖动 | **500 μs** | 2 μs / 0 μs | 是 | **P** |
| T42 每网 TX 载荷吞吐 | （非抖动式） | 131.072 Mbps | — | **P**（吞吐） |
| T42 同 VL 时延极差 | 项目 50 μs；规范封顶 500 μs | 5.016 μs | ≤50 是 | **P**（项目界） |

多片 8192 B 见对照文档 §4 单列；**不得**写成满足 2 ms。

---

## 附录：历史证据（按各自冻结版本，不代表当前候选）

以下内容自报告原顶部与正文整体下移，**只挪位降级、不删改数字**。阅读时勿把 10-08 的 80/80 或更早 70/70、56/56 当成现行结论。

> **2026-10-08 捕获版本历史状态（不是当前工作区结果）：** Questa 2025.3 捕获版 `goal_completion_20261008_warning_fix_r1` 完成 80/80（1629.3 s，编译 `Errors: 0`；CSV SHA-256 `9dbbe7051eb65b47ad39bf97eccafab69f9e7bef298ddd9da024663b3b63ee67`），且 29 个 RTL 输入哈希与该捕获版本当时的 RTL 一致。其后 TB、runner 和 manifest 有更新（当时更新后的 manifest 为 83 项）；该 manifest 当时尚未全量重跑。T33/T33g 16 轮与 T34 100 轮记分板已静态审查，未编译或仿真。T30 严格时延与超界负控、T31/T31g SNMP 语义、T32/T32g TFTP 正常流有独立结果。Quartus functional VO 的 A/B TX→RX port-only 业务回环 PASS，79 B/网、32 B 载荷、A/B 去重和 IRQ 均通过。eLinx r6 历史综合 PASS，而后续一次隔离重跑在 ABC 失败且未产出 VQM。Final r3 ZIP 的 4/4 回放是旧包证据，不代表当前工作区的新测试及文档已打包。

评委先读 [00_先读](00_先读_提交范围与汇报口径.md)。本报告后续章节保留对应日期的历史证据；历史 70/80、门级帧和 Fit/STA 不自动代表当前候选。

## 2026-10-08 捕获版本证据（历史）

| 项 | 结果 | 证据 / 边界 |
|---|---|---|
| RTL 全量 | 捕获版 **80/80 PASS**，1629.3 s；不等于当前 83 项完整 manifest 已全过 | `sim/out/goal_completion_20261008_warning_fix_r1/regress.csv`；SHA-256 `9dbbe7051eb65b47ad39bf97eccafab69f9e7bef298ddd9da024663b3b63ee67`；run metadata 绑定 80 项输入。当前 manifest 与该运行相比有后续测试台/runner 变更 |
| T15/T15g | **PASS** | 同一全量结果；SAP ingress 共享描述符在 ready 拉低时被重复接收的根因已在 `AFDX_top` 修复 |
| TFTP 地址宽度 | **PASS** | `AFDX_top.v` 先执行 16 位偏移计算再显式连接 13 位 RAM 地址；完整输入域穷举记录在 warning triage |
| eLinx 综合 | r6 冻结结果 **PASS**；当前隔离复现 ABC 失败、没有新 VQM | 历史报告 `out/arena-debug/goal_completion_20261008/final_synth_candidate_20261008_r6/run_status.json`：39,580 cells、475 个 `altsyncram`；隔离重跑失败目录 `out/plan_execution_20261008_r1/native_elinx_r2/` |
| 结构检查 | **有告警，未清零** | post-map 996 行：728 无驱动、268 多驱动、0 位宽调整；pre-map TFTP 双读 RAM 抽象冲突有独立记录。不能写“结构检查干净” |
| Quartus post-map functional VO | **已导出**，69,013,015 B，SHA-256 `e0c40c4138f736fc057262189b12aa018aede7e5ef9992ae560ff3927d4f5f21` | `out/arena-debug/goal_completion_20261008/quartus_postsynth_r6/map_project/simulation/modelsim_functional/AFDX_top.vo`；绑定当前 28 个活动工程 RTL（空壳 `host_if.v` 未列入/未例化），map 与 EDA Writer rc=0 |
| Quartus post-map 接口/RTC smoke | **PASS** | r6 `gate_smoke/simulation_status.json`；3680 ns、`Errors: 0`、1 条厂商原语 warning |
| Quartus post-map port-only 业务回环 | **PASS** | `out/plan_execution_20261008_r1/quartus_gate/run_v2/`；到 234384 ns、79 B/网、32 B RX payload、去重和 IRQ PASS，`Errors: 0`、1 条 RAM 模型 warning。VO SHA-256 `e0c40c4138f736fc057262189b12aa018aede7e5ef9992ae560ff3927d4f5f21`；不等于 eLinx VQM/SDF |
| T30 严格时延 | **PASS**；10 μs 网络延迟模型下 4 帧 26–1003 μs，判据 `<2 ms` | `sim/out/plan_execution_20261008_t30_strict_r1/`；超界负控在 2100 μs 延迟下 4 帧按预期设计级 FAIL，仿真器本身 0 errors/0 warnings；不是 128 TX 连续压力结果 |
| T31/T31g SNMP 语义 | **PASS** | `sim/out/plan_execution_20261008_snmp_semantic_r3/`；12 个完整 A/B 响应帧独立 BER/链路层解码 PASS |
| T32/T32g TFTP 正常网络流 | **PASS** | 捕获版 80 项含 10 μs 网络模型下 WRQ→ACK(0)、DATA(1)→ACK(1)；多块网络、丢包/超时恢复仍未覆盖 |
| Final r3 release 验收记录 | 旧包 **4/4 PASS** | `out/submission_20261008_final_r3/` 中 ZIP 及旁置 `FINAL_ZIP_REPLAY.json` 绑定旧 ZIP 的 SHA/CRC、成员清单和干净解压 T13/T13g/T25/T25g 结果；当前 83 项 manifest 和本轮文档尚未进入此 ZIP |

这些是 RTL 与 post-map 仿真证据，不含实际上板、SDF、post-fit 或真实网络设备闭环；比赛交卷不要求实际上板。

## 历史包指标（2026-10-03；不代表当前候选）

| 项 | 本包路径 | 数字 | 不是 |
|---|---|---|---|
| RTL 回归（冻结） | `evidence/rtl_regress_70/regress.csv` | **70/70 PASS**，SHA-256 `7C197B9CC2C5D5E83007704AC4F75330C155841220374BBE20C6EFB6B8931A6C` | 不是门级；不是 9/29 的 65/65 |
| 历史完整回归 | `sim/out/closeout_20261006/regress.csv` | **80/80 PASS**，SHA-256 `F12C99D7B6F92B731BA8CC355C523A09E78B371757999663B9F50B7098C7907C`，wall_s=3144.7 | 含 T26–T32 附加项；不是 8h T18；不覆盖 10-07 后最终工作树 |
| 默认综合（70/70 冻结日） | `elinx/prj/AFDX_top_synth.log` | rc=0，顶层 **517×altsyncram** | 不是 Fit/STA |
| 已有 Yosys 报告 | `elinx/prj/AFDX_top_synth_txmerge.log` | **474×altsyncram**、cell **39718** | 对应报告输入；最终候选综合待重绑；不是 GUI LUT；122542 未重测；不是 Fit/STA |
| 时延 T13 | `evidence/rtl_regress_70/T13_console.txt` | 最大帧 Total=**244.856 µs**（IF_MODE=0，1518 B） | 无交换机；非 128 VL 满载 |
| 争用 T13w | 同上 `T13w_console.txt` + [图](../evidence/waves/t13w_latency.png) | 最差 Total=**455.272 µs**（6 VL / 12 帧） | 不是网络端到端最坏 |
| 抖动 T05b | `T05b_console.txt` + [图](../evidence/waves/t05b_saturated_jitter.png) | 32 VL，稳态约 **3.20 µs** | 不是 128 VL 同时满载 |
| RTC T16a | `T16a_console.txt` + [图](../evidence/waves/t16a_rtc_drift.png) | **FLL STRICT PASS**，稳态 PPS 0/0/0/0/1 µs | 80/77/115 µs 是同日志 **旧 P-only 对照** |
| 波形 | `evidence/waves/` | T15c/T05b/T13w/T16a/T16u PNG | 原始 VCD、覆盖率 UCDB **未打包** |
| 综合后单网一帧 | `out/arena-debug/postsyn_closeout_20261007/gate_frame_v1/` | **PASS**（单网 TX 64 B） | ≠ 双网回环；≠ 80 门级；vsim 2799.9 s |
| 综合后双网一帧 | `…/gate_frame_dual_v1/` | **PASS**（txA=txB=64） | ≠ 回环/SDF/80 门级；vsim 2120.1 s；VO SHA `851fd9df…6dff68` |
| 覆盖率 | — | 未随本包 | 旧 UCDB 含 TB、非本版 |

历史完整回归和 2026-10-03 冻结包仍按各自来源保留；当前完整回归请查阅上面的 `goal_completion_20261008_warning_fix_r1`，不要复用或覆盖历史目录。冻结 70 包仍在 `evidence/rtl_regress_70/`。

## A. 溯源：9/29 冻结包与本包增量

### A.1 被测版本、判决与工具

### A.1 被测版本、判决与工具

| 项目 | 本次独立实测 | 证据／边界 |
|---|---|---|
| 生产 RTL 对应性 | 隔离副本中 128 个输入冻结哈希；结束时 `root_changed_since_freeze=[]` | `out/arena-debug/merge_snmp_20260929/full_current_001/status.json`，SHA-256 `321b90438493bdeef34b8eaa217ebc6c3d7a164ce40220026fad8ae986cebc5d`；只保证列明的冻结输入，非整个工作区 |
| Questa RTL 仿真 | 2026-09-29 23:10:38–23:26:23（UTC+8），全量独立重新编译，编译 rc=0；**65/65 PASS**，manifest 与 CSV 同序 | `full_current_001/regress.csv`，SHA-256 `122cf7fbf6071629b93d0fd055310898fabe1811bbcd07248fa942bb47d97b5d`；逐项原始日志在相同运行目录 |
| Questa RTL 仿真（本包） | 2026-10-03，全量独立重新编译（rc=0，0 error），**70/70 PASS**（含 T24/T24g/T25/T25g） | 本包 `evidence/rtl_regress_70/`（与 `sim/out/full/` 同源）。SHA-256 见上表。**不是** 9/29 的 128 项冻结包，也不是门级/STA |
| 判决规则 | 每例进程 rc=0、仅一个对应测试族 PASS、无 FAIL/Error/Fatal、Questa 摘要 Errors=0；没有把子集拼接为全量 | `out/arena-debug/merge_snmp_20260929/verify_merged.py` 与 `status.json` 的 67 个步骤（vlib/vlog + 65 项） |
| 静态门禁 | lint 以 `%Error`=0 为门；文档门以本包 `python tools/run_all.py --strict` 为准 | 9/29 的 `gates_status.json` 只证明当时那一版，不代替本包重跑 |
| eLinx 综合 | 同一脚本：改前 `AFDX_top_synth.log` 517 M4K；RX 去镜像档 479；现行 `AFDX_top_synth_txmerge.log` **474** M4K / 39718 cell | 大网表未打包。没有 SDF、没有整帧门级、没有 GUI LUT 重测 |
| 本包波形图 | T15c / T05b / T13w / T16a / T16u 五张 PNG，由 RTL VCD 绘制 | `evidence/waves/` 与 [清单](../evidence/waves/README.md)。原始 VCD **不在本包** |

本包复现用 `sim/run_regress.ps1`（见文首表）。9/29 冻结副本复跑命令仍在 `out/arena-debug/`，**不在本包**。

### A.2 技术指标场景：取原始日志，不外推到未测负载

| 指标／测试 | 本次观测 | 已知边界 |
|---|---|---|
| 100 Mbps 档时延 T13 | IF_MODE=0、125 MHz RTL 时钟：17 B/64 B 帧 `Total=12.496 µs`；1471 B/1518 B 帧历史运行 `Total=244.856 µs`，本轮当前 run 为 `244.776 µs`；三档 PASS。`Total` 含测试平台回灌 | 单 VL 每档一帧；**无交换机**，不能等价于网络端到端或所有负载条件的最坏值；125 MHz 是仿真周期，不证明当前源码的物理时序或板级表现 |
| 争用时延 T13w | IF_MODE=0，6 VL、2 轮、12 帧，测试内最差 `Total=455.272 µs`、排队 `426.720 µs`、RX pipe `0.152 µs`；测试用排队上界 `499.360 µs` | 构造的双轮混合帧场景，不是 128 VL／长时最坏情况；连续字节的 IF_MODE=1 仅为额外档（T13wg：最差 `36.976 µs`） |
| 抖动 T05b | IF_MODE=0，32 VL、96 帧、配置线速占比 99.86%；启动最大 4 µs；**独立原始 VCD 中稳态最大为 400 个 8 ns 时钟周期 = 3.20 µs，64 组均值 `21540/(64×125)=2.6925 µs`** | 原 TB 日志以整数除法输出稳态“3 µs/2 µs”，是向下截断显示，不得作为精确上界；本场景不是 128 VL 同时满载，也不含交换机 |
| 帧长、容量 | T13 最大帧 1518 B／有效载荷 1471 B；T08f 验 4096 RX 键写读；T12c 验 10 万次查找及 4096 索引；T17 验 512 对最小帧 | 表深度／查找测试 ≠ 4096 路同时运行；最小帧压力 ≠ 128 VL 最大帧满载 |
| SNMP/BAG T15/T15b/T15c | T15 顶层接收 18 帧，16 个应答经**主机观测窗**、1 community 丢弃、1 busy 拒绝；T15b 74 组／674 项 BER 边界检查；T15c 5 次 BAG commit、42 个主机等待周期，线侧数据帧间隔有 1 ms→2 ms 切换 | `T15c` 的线上是**业务数据帧**，不是 SNMP 响应上线；管理响应上线另由 T24/T24g 取证（`CTL[9]` 默认关，T15 路径不变） |
| 615A-TFTP T16u | 1300 B + 1024 B 加载及 RRQ `UPLOAD` 读回，40 项断言 PASS | 已测 TFTP 子集，不是完整 ARINC 615A 协议或签名校验；上线仅覆盖 WRQ→ACK(0)（T25/T25g），**未做对端收包闭环**，也未验证 4 B ACK 补零后的尾随字节兼容性 |
| RTC T16r/T16a | T16r 锁定/失步/恢复 PASS。T16a **FLL STRICT PASS**（364 checks）：FLL 稳态 PPS 误差 **0/0/0/0/1 µs**；同日志旧 P-only 对照为 0/80/77/115/4 µs | 短秒加速不是物理 1 Hz 板测。现行结论以 FLL 列为准，不要把 P-only 80 µs 写成现行环路失败 |

本包 console 在 `evidence/rtl_regress_70/`。9/29 的 65 项日志仍在 `out/arena-debug/merge_snmp_20260929/`（不在本包），不可与 70 项拼接。

### A.3 仍需区分的边界与补充项

1. **综合后仿真范围**：旧版 Quartus 功能 VO 的接口 smoke、单网帧和双网 TX 帧均为其所绑定历史源码的 PASS（详见日期段落），不能替代当前版。历史捕获版本曾有 80/80 RTL 全量；另有绑定各自冻结输入的 post-map 接口/RTC smoke。它们都不是当前工作区结果。无 SDF、全量门级 80；这些都不是板测，比赛不要求上板。
2. **波形**：五张 PNG 已在本包 `evidence/waves/`。原始 VCD 仍在包外。覆盖率 UCDB 未打包。
3. **时序与覆盖率**：旧 Fit 中断不作现行结论。`timing_cut_v5`（2026-10-07）：Setup **+0.214** / Fmax **128.44 MHz** / 0 violated（Slow85；EP4SGX530 代理）→ **post-fit 125 P**；**不得**写成板卡签核。对照：初测 −2.813/92.48；v1 −0.290/116.55。GUI LUT 122542 未重测（synth_stratix ABC 失败）。
4. **协议完整性**：当前 RTL 测试覆盖 SNMP GET/GETNEXT/SET、TFTP WRQ/DATA、ACK/DATA/卸载帧及 A/B 口帧比对（T24/T25/T31/T32 族）。它们是 testbench/BFM 场景，**不是与真实对端互操作**；SNMP v3/Trap、完整 ARINC 615A、Find/Information 及 4 B ACK 的外部兼容性仍未承诺，不能从子集用例推出全协议一致性。


Continue12（56/56）正文已迁入 [历史基线](历史/AFDX端系统_测试仿真报告_历史基线.md)，**不是本包打分底本**。


## 后综合网表顶层功能仿真（2026-09-30 01:33，新证据）

本条**补充**前述 RTL 证据，而不替换原 65/65 输入与旧网表失败记录。eLinx 捆绑 Quartus II 13.0.1 在**隔离复制**的当前生产版 map 工程中执行 `quartus_eda AFDX_top -c AFDX_top --simulation=on --format=verilog --tool=modelsim --functional=on --output_directory=simulation/modelsim_functional`，writer **rc=0、0 errors**；生成的**后综合／post-map 功能网表** `out/arena-debug/postsyn_quartus_eda_20260930/export_project_functional/simulation/modelsim_functional/AFDX_top.vo` 为 189,911,225 B、SHA-256 `95c254fd4f5e4eeba7a4ec59374c6a7d43192730246ab77a27413f85d57d0c5e`，绑定完整回归状态 SHA-256 `321b90438493bdeef34b8eaa217ebc6c3d7a164ce40220026fad8ae986cebc5d`。未加 `--functional=on` 的先前 writer 探测 **rc=3／Error 199063**（需要 Fit 和 TimeQuest），原日志保留；这里明确不是该失败输出的“PASS”。

Questa FSE 2025.3 对**原 VO** `vlog` **rc=0、0 errors／0 warnings**，并链接安装目录内 eLinx Stratix IV 原语模型 `elinx_lib` 执行**真正的全顶层后综合零延时功能 smoke**：`vsim` **rc=0、Errors: 0、Warnings: 1**，原语模型 `mem_invalidate` 有 1 条 `vopt-13162` 警告，未删改或隐藏。原 testbench SHA-256 `f0560fd10bba3bb0b42a750f80c252d6d811d6428893e3bf796970af983b2ce9`，模拟至 **3680 ns**，检查 REG_ID `AF071000`、REV `00040000`、控制默认 `0000051c`、SMAC 默认／写 `DEADBEEF`／读回／复位恢复与 RTC 有效递增，打印 `PSTSYN TOP SMOKE PASS`。独立状态 `out/arena-debug/postsyn_quartus_eda_20260930/gate_full_compile/simulation_status.json` SHA-256 `13b40e47cc5a4789f57915c4fa4e4e89ae221c3b41a0759a914d94cde65ab967`；原始 `vsim_gate.log` SHA-256 `72cab826fda4731cd5258d1e1d08a251941e6a6688d51cce388648cdafc616a9`。原 eLinx `write_verilog` 导出网表的 Questa 编译失败记录仍存在，这里使用的是**不同的、由 Quartus EDA Writer 合法生成的功能 VO**。

**严格边界**：短时接口 smoke ≠ 整帧。现行：`gate_smoke_v3`；`gate_frame_v1` 单网 PASS；`gate_frame_dual_v1` 双网 TX PASS（txA=txB=64，VO SHA `851fd9df…6dff68`）；`timing_cut_v5` Fmax 128.44 / Setup +0.214 → post-fit 125 P。**双网 TX ≠ 双网回环/SDF**；**post-fit ≠ 板卡签核**。

## 2026-09-30 后综合网表接口原始波形（补充 A 节，不替代 65 项 RTL）

在与页末功能 VO、TB、厂商原语相同的真实后综合顶层接口仿真上，使用 **仅对 `tb_elinx_postsynth_smoke` 的寄存器/线网开放可见性**的 Questa 优化选项取证，完成原 testbench 到 3680 ns，rc=0、`PSTSYN TOP SMOKE PASS`，并修复默认 vopt 隐藏 TB 对象致 `vcd add` 查找失败的问题。完整 VCD（17,568 B）位于 `out/arena-debug/finish_20260930/gate_trace_tb_only/postmap_top_io.vcd`，SHA-256 `99c2e5dff79a97f5eb928b5ebc73c75494891b1bd0f211ac485880e1417cc18a`；判决状态 `trace_status.json` SHA-256 `06b410a0215f77b3f76a938073a317e9bc2ebb94ca1a92f3319ba70089c6ac28`。独立原始波形解析 `gate_trace_events.json` 复原全部七笔读写（REG_ID、REV、CTL、SMAC 默认／写／读／复位恢复），脚本与同源 [SVG 波形图](../out/arena-debug/finish_20260930/gate_trace_tb_only/postmap_top_io.svg) 一并保存；图**不是 GUI 截屏**。该 VCD 不包含测试用例 T13w 的整帧双网门级交付；先前网表双网单帧 900 s 超时仍保持失败结论。RTC 非零漂移误差、post-fit STA 与 125 MHz 不能从此接口波形推出。

## 当前工作区静态状态（2026-10-10）

本报告原有仿真/综合段落均按各自冻结输入和日期理解。当前工作区的静态检查证据是 `out/luna_non_sim_20261010_r1/static_r2/static_status.json`；它不含功能仿真或综合结论。T41/T42/T43 3/3 与 13 个不同用例早于本轮 TFTP/顶层修改；旧 95/95、native_r4、旧 eLinx 综合也不能代表当前输入。当前 615A 上层控制、主动客户端、IP 分片/重组、8 kB 队列与 SAP 路径未实现或未接入，均保持 OPEN。

