# AFDX 端系统 — 测试（仿真）报告

评委先读 [00_先读](00_先读_提交范围与汇报口径.md)。下面「本包」表是打分底本；56/65 只作溯源。

## 本包指标（2026-10-03 提交哈希）

| 项 | 本包路径 | 数字 | 不是 |
|---|---|---|---|
| RTL 回归 | `evidence/rtl_regress_70/regress.csv` | **70/70 PASS**，SHA-256 `7C197B9CC2C5D5E83007704AC4F75330C155841220374BBE20C6EFB6B8931A6C` | 不是门级；不是 9/29 的 65/65 冻结包 |
| 默认综合 | `elinx/prj/AFDX_top_synth.log` | rc=0，`Yosys execute success`，顶层 **517×altsyncram** | 不是 Fit/STA；旧展平失败见同目录 `AFDX_top_synth.memory_map_fail.log` |
| 时延 T13 | `evidence/rtl_regress_70/T13_console.txt` | 最大帧 Total=**244.856 µs**（IF_MODE=0，1518 B） | 无交换机；非 128 VL 满载 |
| 争用 T13w | 同上 `T13w_console.txt` + [图](../evidence/waves/t13w_latency.png) | 最差 Total=**455.272 µs**（6 VL / 12 帧） | 不是网络端到端最坏 |
| 抖动 T05b | `T05b_console.txt` + [图](../evidence/waves/t05b_saturated_jitter.png) | 32 VL，稳态约 **3.20 µs** | 不是 128 VL 同时满载 |
| RTC T16a | `T16a_console.txt` + [图](../evidence/waves/t16a_rtc_drift.png) | **FLL STRICT PASS**，稳态 PPS 0/0/0/0/1 µs | 80/77/115 µs 是同日志 **旧 P-only 对照** |
| 波形 | `evidence/waves/` | T15c/T05b/T13w/T16a/T16u PNG | 原始 VCD、覆盖率 UCDB **未打包** |
| 综合后整帧 | — | **未通过** | 页末 post-map 接口 smoke ≠ 整帧；大网表不在本包 |
| 覆盖率 | — | 未随本包 | 旧 UCDB 含 TB、非本版 |

复现 RTL：`sim/run_regress.ps1`，要求 70 行全 PASS 且与 `tests.manifest` 同序。复现综合：`eLinx_synthesis.exe -s elinx/prj/AFDX_top_synth.ys`。

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
| eLinx 综合（本包默认） | 现行源 `elinx/prj/AFDX_top_synth.ys`（BRAM 后 `memory_map`）；本机 rc=0，顶层 517×altsyncram | 日志在本包 `elinx/prj/AFDX_top_synth.log`。大网表未打包。9/29 隔离综合仍在 `out/arena-debug/`（不在本包）。没有 SDF、没有整帧门级 |
| 本包波形图 | T15c / T05b / T13w / T16a / T16u 五张 PNG，由 RTL VCD 绘制 | `evidence/waves/` 与 [清单](../evidence/waves/README.md)。原始 VCD **不在本包** |

本包复现用 `sim/run_regress.ps1`（见文首表）。9/29 冻结副本复跑命令仍在 `out/arena-debug/`，**不在本包**。

### A.2 当前版技术指标：取原始日志，不沿用旧基线

| 指标／测试 | 本次观测 | 已知边界 |
|---|---|---|
| 100 Mbps 档时延 T13 | IF_MODE=0、125 MHz RTL 时钟：17 B/64 B 帧 `Total=12.496 µs`；1471 B/1518 B 帧 `Total=244.856 µs`；三档 PASS。`Total` 包括出站传输、测试平台回灌及入站传输 | 单 VL 每档一帧；**无交换机**，不能等价于网络端到端或所有负载条件的最坏值；125 MHz 仅仿真周期，物理实现仍待 STA |
| 争用时延 T13w | IF_MODE=0，6 VL、2 轮、12 帧，测试内最差 `Total=455.272 µs`、排队 `426.720 µs`、RX pipe `0.152 µs`；测试用排队上界 `499.360 µs` | 构造的双轮混合帧场景，不是 128 VL／长时最坏情况；连续字节的 IF_MODE=1 仅为额外档（T13wg：最差 `36.976 µs`） |
| 抖动 T05b | IF_MODE=0，32 VL、96 帧、配置线速占比 99.86%；启动最大 4 µs；**独立原始 VCD 中稳态最大为 400 个 8 ns 时钟周期 = 3.20 µs，64 组均值 `21540/(64×125)=2.6925 µs`** | 原 TB 日志以整数除法输出稳态“3 µs/2 µs”，是向下截断显示，不得作为精确上界；本场景不是 128 VL 同时满载，也不含交换机 |
| 帧长、容量 | T13 最大帧 1518 B／有效载荷 1471 B；T08f 验 4096 RX 键写读；T12c 验 10 万次查找及 4096 索引；T17 验 512 对最小帧 | 表深度／查找测试 ≠ 4096 路同时运行；最小帧压力 ≠ 128 VL 最大帧满载 |
| SNMP/BAG T15/T15b/T15c | T15 顶层接收 18 帧，16 个应答经**主机观测窗**、1 community 丢弃、1 busy 拒绝；T15b 74 组／674 项 BER 边界检查；T15c 5 次 BAG commit、42 个主机等待周期，线侧数据帧间隔有 1 ms→2 ms 切换 | `T15c` 的线上是**业务数据帧**，不是 SNMP 响应上线；管理响应上线另由 T24/T24g 取证（`CTL[9]` 默认关，T15 路径不变） |
| 615A-TFTP T16u | 1300 B + 1024 B 加载及 RRQ `UPLOAD` 读回，40 项断言 PASS | 已测 TFTP 子集，不是完整 ARINC 615A 协议或签名校验；上线仅覆盖 WRQ→ACK(0)（T25/T25g），**未做对端收包闭环**，也未验证 4 B ACK 补零后的尾随字节兼容性 |
| RTC T16r/T16a | T16r 锁定/失步/恢复 PASS。T16a **FLL STRICT PASS**（364 checks）：FLL 稳态 PPS 误差 **0/0/0/0/1 µs**；同日志旧 P-only 对照为 0/80/77/115/4 µs | 短秒加速不是物理 1 Hz 板测。现行结论以 FLL 列为准，不要把 P-only 80 µs 写成现行环路失败 |

本包 console 在 `evidence/rtl_regress_70/`。9/29 的 65 项日志仍在 `out/arena-debug/merge_snmp_20260929/`（不在本包），不可与 70 项拼接。

### A.3 交付前仍待补齐

1. **综合后仿真覆盖范围**：原 eLinx `write_verilog` 的 58 MB 网表因非法转义模块头 `vlog-13069` 编译失败（旧失败原件保留），不能冒充通过；现已另用 Quartus EDA Writer 生成的真实 post-map 功能 VO 与 eLinx 原语库完成顶层接口 smoke，详见页末独立证据。但该 TB 只检寄存器/RTC 短时行为，**同一 TB 的双网单帧网表仿真 900 秒超时，不能称 PASS**；不含 SDF、完整管理面或全量门级测试。请赛方确认“综合后仿真即可”的覆盖与 SDF 要求。
2. **波形**：五张 PNG 已在本包 `evidence/waves/`。原始 VCD 仍在包外。覆盖率 UCDB 未打包。
3. **时序与覆盖率**：首个隔离时序运行 `timing_current_20260929/` 的 Fit 被桥接 30 分钟上限停止；随后 `timing_current_resume_20260930/` 的计划任务在 Fit 时异常终止（`TASK_TERMINATED_NOT_STA_20260930.json`），旧 `running` 状态为陈旧字段，**均无当前版 post-fit STA 结论**。要在全新独立目录重跑并审阅多角报告；旧 Continue12 WNS −1.735 ns、Fmax 99.96 MHz 不是本版。本版 RTL-only/功能覆盖率、128 VL 联合压力与网络端到端测试仍待完成。
4. **协议完整性**：SNMP/TFTP 响应已能经 `CTL[9]` 上线（T24/T24g/T25/T25g），但**只做到本端 A/B 口抓帧判定，未与真实对端收发闭环**；上线只覆盖 SNMP GET 与 TFTP WRQ→ACK 两种响应，加载/卸载方向的 DATA 响应未上线取证，4 B ACK 补零的兼容性未验证；RM 的长时歧义需先定运行契约；不能从局部回归推出全协议一致性。


Continue12（56/56）正文已迁入 [历史基线](历史/AFDX端系统_测试仿真报告_历史基线.md)，**不是本包打分底本**。


## 后综合网表顶层功能仿真（2026-09-30 01:33，新证据）

本条**补充**前述 RTL 证据，而不替换原 65/65 输入与旧网表失败记录。eLinx 捆绑 Quartus II 13.0.1 在**隔离复制**的当前生产版 map 工程中执行 `quartus_eda AFDX_top -c AFDX_top --simulation=on --format=verilog --tool=modelsim --functional=on --output_directory=simulation/modelsim_functional`，writer **rc=0、0 errors**；生成的**后综合／post-map 功能网表** `out/arena-debug/postsyn_quartus_eda_20260930/export_project_functional/simulation/modelsim_functional/AFDX_top.vo` 为 189,911,225 B、SHA-256 `95c254fd4f5e4eeba7a4ec59374c6a7d43192730246ab77a27413f85d57d0c5e`，绑定完整回归状态 SHA-256 `321b90438493bdeef34b8eaa217ebc6c3d7a164ce40220026fad8ae986cebc5d`。未加 `--functional=on` 的先前 writer 探测 **rc=3／Error 199063**（需要 Fit 和 TimeQuest），原日志保留；这里明确不是该失败输出的“PASS”。

Questa FSE 2025.3 对**原 VO** `vlog` **rc=0、0 errors／0 warnings**，并链接安装目录内 eLinx Stratix IV 原语模型 `elinx_lib` 执行**真正的全顶层后综合零延时功能 smoke**：`vsim` **rc=0、Errors: 0、Warnings: 1**，原语模型 `mem_invalidate` 有 1 条 `vopt-13162` 警告，未删改或隐藏。原 testbench SHA-256 `f0560fd10bba3bb0b42a750f80c252d6d811d6428893e3bf796970af983b2ce9`，模拟至 **3680 ns**，检查 REG_ID `AF071000`、REV `00040000`、控制默认 `0000051c`、SMAC 默认／写 `DEADBEEF`／读回／复位恢复与 RTC 有效递增，打印 `PSTSYN TOP SMOKE PASS`。独立状态 `out/arena-debug/postsyn_quartus_eda_20260930/gate_full_compile/simulation_status.json` SHA-256 `13b40e47cc5a4789f57915c4fa4e4e89ae221c3b41a0759a914d94cde65ab967`；原始 `vsim_gate.log` SHA-256 `72cab826fda4731cd5258d1e1d08a251941e6a6688d51cce388648cdafc616a9`。原 eLinx `write_verilog` 导出网表的 Questa 编译失败记录仍存在，这里使用的是**不同的、由 Quartus EDA Writer 合法生成的功能 VO**。

**严格边界**：这是短时接口 smoke，**不是 65 项后综合网表回归、帧路径全覆盖、时序仿真、post-fit SDF／STA、125 MHz 收敛、完整 SNMP／615A 网络互通或板卡签核**。本项目当前 Fit 未完成、当前版 post-fit STA 仍不存在，赛方“综合后仿真即可”的具体评分口径也需以正式答复为准。后续门级波形／更完整功能可继续补，但不能改变此轮实测范围。

## 2026-09-30 后综合网表接口原始波形（补充 A 节，不替代 65 项 RTL）

在与页末功能 VO、TB、厂商原语相同的真实后综合顶层接口仿真上，使用 **仅对 `tb_elinx_postsynth_smoke` 的寄存器/线网开放可见性**的 Questa 优化选项取证，完成原 testbench 到 3680 ns，rc=0、`PSTSYN TOP SMOKE PASS`，并修复默认 vopt 隐藏 TB 对象致 `vcd add` 查找失败的问题。完整 VCD（17,568 B）位于 `out/arena-debug/finish_20260930/gate_trace_tb_only/postmap_top_io.vcd`，SHA-256 `99c2e5dff79a97f5eb928b5ebc73c75494891b1bd0f211ac485880e1417cc18a`；判决状态 `trace_status.json` SHA-256 `06b410a0215f77b3f76a938073a317e9bc2ebb94ca1a92f3319ba70089c6ac28`。独立原始波形解析 `gate_trace_events.json` 复原全部七笔读写（REG_ID、REV、CTL、SMAC 默认／写／读／复位恢复），脚本与同源 [SVG 波形图](../out/arena-debug/finish_20260930/gate_trace_tb_only/postmap_top_io.svg) 一并保存；图**不是 GUI 截屏**。该 VCD 不包含测试用例 T13w 的整帧双网门级交付；先前网表双网单帧 900 s 超时仍保持失败结论。RTC 非零漂移误差、post-fit STA 与 125 MHz 不能从此接口波形推出。
