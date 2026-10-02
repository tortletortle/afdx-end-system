# AFDX 端系统 — 测试（仿真）报告


> **当前版分层结论（截至 2026-09-30）：65/65 项 RTL 回归 PASS、eLinx 28 文件综合 PASS、真实 Quartus post-map 功能 VO 顶层寄存器接口 smoke PASS。** 后者只测至 3680 ns，不是 65 项门级回归或双网帧路径证据；当前版 post-fit STA、RTC 非零漂移 ≤1 µs 亦未达成证明。下方“2026-09-27 Continue12 历史档案”保留旧数字，不能当作本日生产版；**56/62/65 与两份网表对照见 [版本与证据口径对照](版本与证据口径对照_20261002.md)**。详见页末“后综合网表顶层功能仿真”原始哈希。

## A. 2026-09-29 当前合并版：生产哈希对应的隔离回归

### A.1 被测版本、判决与工具

| 项目 | 本次独立实测 | 证据／边界 |
|---|---|---|
| 生产 RTL 对应性 | 隔离副本中 128 个输入冻结哈希；结束时 `root_changed_since_freeze=[]` | `out/arena-debug/merge_snmp_20260929/full_current_001/status.json`，SHA-256 `321b90438493bdeef34b8eaa217ebc6c3d7a164ce40220026fad8ae986cebc5d`；只保证列明的冻结输入，非整个工作区 |
| Questa RTL 仿真 | 2026-09-29 23:10:38–23:26:23（UTC+8），全量独立重新编译，编译 rc=0；**65/65 PASS**，manifest 与 CSV 同序 | `full_current_001/regress.csv`，SHA-256 `122cf7fbf6071629b93d0fd055310898fabe1811bbcd07248fa942bb47d97b5d`；逐项原始日志在相同运行目录 |
| 判决规则 | 每例进程 rc=0、仅一个对应测试族 PASS、无 FAIL/Error/Fatal、Questa 摘要 Errors=0；没有把子集拼接为全量 | `out/arena-debug/merge_snmp_20260929/verify_merged.py` 与 `status.json` 的 67 个步骤（vlib/vlog + 65 项） |
| 静态门禁 | 当前源码 lint rc=0（有 warning）；严格文档门 rc=0，5/5 + selfcheck | `out/arena-debug/timing_current_20260929/gates_status.json`，SHA-256 `e226c3c924b016498393286dd71d1cab98b80fd2bf478b37050f4520c15571f0` |
| eLinx 综合 | 冻结 QSF 指定 28 个 RTL；rc=0，耗时 197.33 s，成功标志存在、零 `ERROR` 行；网表 58,076,177 B，SHA-256 `926eb1af6e2ab92e618b2d9bf293afd592adfc3015945abfe17021f3562448a3` | `out/arena-debug/elinx_current_20260929/` 的 `SOURCE_BINDING.json`、`AFDX_top_current.ys`、`synth.log`、`AFDX_top_current_netlist.elinx.rpt`、`synth_status.json`（SHA-256 `a6797b1e31bde05aa0fde7c18202445d82550dda874eb80302fef6c06e03d569`）。**该 eLinx Yosys 网表未通过直接 Questa 编译；另有使用同哈希源的 Quartus EDA 功能 VO 完成顶层接口 smoke，见页末。没有 SDF 或全量门级回归。** |
| 当前版关键波形 | 从独立重编译的 T15c 功能仿真导出 15 个信号的 VCD，T15c PASS、Questa Errors=0；五对数据帧起始间隔分别为 **1002.560／2002.960／2004.000／1002.560／2004.000 µs**，与 BAG SET 提交时序同图 | `out/arena-debug/wave_current_20260929_r2/` 的 `wave_status.json`（SHA-256 `7f47f420e3b713d17f68a8c578b38b52b44492afd7c15e54a2f3cc7a3a890383`）、原始 `t15c_control_current.vcd`（SHA-256 `de618c94731413162e33e57a000dc9d85540d9a82556edb99d3be4dfb937a3ae`）、[波形图 PNG](../out/arena-debug/wave_current_20260929_r2/t15c_bag_wave_current.png)（SHA-256 `63f54c55e22229b1b14e03244dfa498c56f68daaed48958d7d4a95f080753972`），另有 SVG。**图片由 VCD 绘制而非仿真器 GUI 截屏，帧是业务数据帧，不是 SNMP 响应上线证据。** |
| 其他当前版独立 RTL 波形 | T05b 完整顶层 96 帧／满载抖动；T13w 完整顶层 12 帧／最差 455.272 µs；T16u **模块级** 40 项加/卸载检查。每组均另行比对冻结 TB／生产源哈希、重编译运行 PASS，并保存原始 VCD 与由 VCD 绘制的 PNG/SVG | `wave_t05b_current_20260930/`（VCD `513283286cf1346953f4d5099b16b8c0d46ed8a947ada3c327e61739683efa84`，PNG `f6a588989f8a40d29c2c4052c0350e1d25adf4c7f3a295baf39a9fa59edf4749`）；`wave_t13w_current_20260930/`（VCD `766e654af6924727c989cf2a05beb2e4374db522104cb12cd10caf311166a3c8`，PNG `d620ff3d3009a0ea495ff0feff42076754471f33002e3ed37ffafc3b41e15bca`）；`wave_t16u_current_20260930/`（VCD `6c17b08012976cfd966f22da969d9259e8986653ab35f9ed8cf3919eda5f0744`，PNG `0a10d2373f74cf3aef5383c0f586f670d2ef09798040bc74d16b250692a1a2f6`）。均为行为级，不是 GUI 截屏或门级证据 |
| RTC T16a 新增 RTL 波形 | 模块级 5×20 PPS、117 个判决 PASS；从原始 230,254,363 B VCD 仅删去高频 `sec_phase[31:0]` 后生成 20,703 B 同源显示 VCD 与 PNG/SVG；五种稳态最大误差 0／80／77／115／4 µs 可由 VCD 独立复算 | `out/arena-debug/wave_t16a_current_20260930/`：原始 VCD SHA-256 `3cbf190778c0525ef4b75fac405f0e869c2427afa56df544749607833773fae6`；仅用于绘图的稀疏派生 VCD `0d8eab4606c3dfe8c56e23e0e5088d6f59943be22544b32f9f20ebb426a676a7`；PNG `c2b358eeb55d770363d24ae971821a1691c6035665f82c90ddec9903eb95a784`，过滤细节见 `sparse_vcd_status.json`；**非物理时序或 ≤1 µs 全工况证明** |

安全重跑本版本功能回归（项目根目录，**新 tag**，工作站不能有其他 Questa 作业；脚本不强停别人的进程；不要调用旧 `sim/run_regress.ps1` 的全局停进程步骤）：

```powershell
python .\out\arena-debug\merge_snmp_20260929\verify_merged.py full --tag full_recheck_002
```

此命令使用已经冻结并验证为生产哈希的副本，在新的独立目录编译运行；运行后仍应核对 `status.json` / CSV / 原始日志和输入哈希。eLinx 入口 `out/arena-debug/elinx_current_20260929/run_synth.py` 固定使用隔离源，已有证据目录**拒绝重复写入**；重新综合须复制脚本到同级全新证据目录，先执行 `prepare` 后执行 `synth`。eLinx 产物并非可直接代替 Quartus 的 post-fit 报告。

### A.2 当前版技术指标：取原始日志，不沿用旧基线

| 指标／测试 | 本次观测 | 已知边界 |
|---|---|---|
| 100 Mbps 档时延 T13 | IF_MODE=0、125 MHz RTL 时钟：17 B/64 B 帧 `Total=12.496 µs`；1471 B/1518 B 帧 `Total=244.856 µs`；三档 PASS。`Total` 包括出站传输、测试平台回灌及入站传输 | 单 VL 每档一帧；**无交换机**，不能等价于网络端到端或所有负载条件的最坏值；125 MHz 仅仿真周期，物理实现仍待 STA |
| 争用时延 T13w | IF_MODE=0，6 VL、2 轮、12 帧，测试内最差 `Total=455.272 µs`、排队 `426.720 µs`、RX pipe `0.152 µs`；测试用排队上界 `499.360 µs` | 构造的双轮混合帧场景，不是 128 VL／长时最坏情况；连续字节的 IF_MODE=1 仅为额外档（T13wg：最差 `36.976 µs`） |
| 抖动 T05b | IF_MODE=0，32 VL、96 帧、配置线速占比 99.86%；启动最大 4 µs；**独立原始 VCD 中稳态最大为 400 个 8 ns 时钟周期 = 3.20 µs，64 组均值 `21540/(64×125)=2.6925 µs`** | 原 TB 日志以整数除法输出稳态“3 µs/2 µs”，是向下截断显示，不得作为精确上界；本场景不是 128 VL 同时满载，也不含交换机 |
| 帧长、容量 | T13 最大帧 1518 B／有效载荷 1471 B；T08f 验 4096 RX 键写读；T12c 验 10 万次查找及 4096 索引；T17 验 512 对最小帧 | 表深度／查找测试 ≠ 4096 路同时运行；最小帧压力 ≠ 128 VL 最大帧满载 |
| SNMP/BAG T15/T15b/T15c | T15 顶层接收 18 帧，16 个应答经**主机观测窗**、1 community 丢弃、1 busy 拒绝；T15b 74 组／674 项 BER 边界检查；T15c 5 次 BAG commit、42 个主机等待周期，线侧数据帧间隔有 1 ms→2 ms 切换 | `T15c` 的线上是**业务数据帧**，不是 SNMP 响应上线；管理响应尚未接 TX |
| 615A-TFTP T16u | 1300 B + 1024 B 加载及 RRQ `UPLOAD` 读回，40 项断言 PASS | 已测 TFTP 子集，不是完整 ARINC 615A 协议或签名校验；管理回应未上线 |
| RTC T16r/T16a | T16r 默认真实 1 Hz PPS 的锁定、失步及恢复 PASS；T16a 的 5×20 PPS **加速每轮**使用 `US_PER_SEC=100000`，每个 PPS 分别偏移 d=0／+20／−20／+50／交替0/1 个 µs 计数（对应真实 1 Hz 下每脉冲相同的 0／±20／+50／+0.5 ppm **等效输入**）；稳态最大绝对误差 0／**80**／**77**／**115**／**4** µs | T16a 的短秒周期不是物理 1 Hz 下真实施加 20 ppm 漂移；仅验证每 PPS 相位偏差控制模型和各自界限，**不能声称非零漂移 ≤1 µs**，更不能替代板级测量 |

T13/T13w 分别见 `full_current_001/T13.log`、`T13w.log`；抖动见 `T05b.log`；协议与 RTC 见 `T15.log`、`T15b.log`、`T15c.log`、`T16u.log`、`T16r.log`、`T16a.log`。所有路径基准均为 `out/arena-debug/merge_snmp_20260929/`。完整 65 项顺序与用时以本轮 `regress.csv` 为准；原第 4 节 56 项矩阵是旧哈希，**不可与新增 9 项直接拼接成“本版 65 项”**。

### A.3 交付前仍待补齐

1. **综合后仿真覆盖范围**：原 eLinx `write_verilog` 的 58 MB 网表因非法转义模块头 `vlog-13069` 编译失败（旧失败原件保留），不能冒充通过；现已另用 Quartus EDA Writer 生成的真实 post-map 功能 VO 与 eLinx 原语库完成顶层接口 smoke，详见页末独立证据。但该 TB 只检寄存器/RTC 短时行为，**同一 TB 的双网单帧网表仿真 900 秒超时，不能称 PASS**；不含 SDF、完整管理面或全量门级测试。请赛方确认“综合后仿真即可”的覆盖与 SDF 要求。
2. **波形与环境**：T15c、T05b、T13w、T16u、T16a 共五组均有可追溯 RTL VCD 与同源图（非 GUI 截屏），其中 T13w 含 RX 交付，T16u/T16a 是模块级；T16a 保留原始约 230 MB VCD，只过滤 `sec_phase` 得轻量显示副本。仍缺部分异常路径／误码波形、eLinx GUI 点击仿真的工程与评委一键运行的项目封装。
3. **时序与覆盖率**：首个隔离时序运行 `timing_current_20260929/` 的 Fit 被桥接 30 分钟上限停止；随后 `timing_current_resume_20260930/` 的计划任务在 Fit 时异常终止（`TASK_TERMINATED_NOT_STA_20260930.json`），旧 `running` 状态为陈旧字段，**均无当前版 post-fit STA 结论**。要在全新独立目录重跑并审阅多角报告；旧 Continue12 WNS −1.735 ns、Fmax 99.96 MHz 不是本版。本版 RTL-only/功能覆盖率、128 VL 联合压力与网络端到端测试仍待完成。
4. **协议完整性**：SNMP 与 615A-TFTP 的响应尚未通过 TX 上网；RM 的长时歧义需先定运行契约；不能从局部回归推出全协议一致性。

---

## 2026-09-27 Continue12 历史档案（原第 0～7 节；下方“本版”均指旧版）

> **当前版结论只看第 0～6 节（Continue12，证据时间 2026-09-27 23:40）。** 历史基线在同目录《测试仿真报告_历史基线》，墙钟 613.5 s，哈希不同，不得当作当前源码的指标。

**项目**：2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 赛道 · 中科亿海微命题选题一  
**被测设计**：`AFDX_top`  
**仿真器**：Questa / ModelSim，`sim/run_regress.ps1` 串行独立会话  
**静态检查**：Verilator，`tools_lint.ps1`  
**原始证据**：`out/arena-debug/continue12/tests/full56/`

## 0. 当前版结论

| 项 | 结果 | 不能据此推出的结论 |
|---|---|---|
| 回归 | 清单 56 项，无过滤重新编译，**56/56 PASS**，编译 0 errors | 不是首轮 54 项与补跑 2 项拼接 |
| 脚本墙钟 | 回归脚本报告 **672.1 s**，runner 673.72 s，23:40:04 结束 | CSV 各行 `wall_s` 合计 668.7 s，少 3.4 s 的脚本开销；两数都保留，不以合计替换脚本值 |
| CSV | SHA-256 `e7f57060a43c773eacdd7b4820c8a84fcfcb971180659f6bd09fcef1638efda2` | 脱离该哈希的逐项数字不可复用 |
| 全量日志 | `full56.log` SHA-256 `8df18fe698e022b3342731a558afa13308fc611fc9687fd742a4cbc6cf631ae1` | — |
| lint | rc=0，各门禁 0 `%Error` | 不是零 warning。T13 console 有 `host_addr` 位宽 warning（vopt-2241），Errors=0 |
| 本版故障注入 | 只重跑 T12 四类，**4/4 检出**，18.16 s，rc=0 | 后文其他 mutation 集属于历史源版本 |
| 文档门 | 本次回写后再跑 `run_all.py --strict`，rc=0，5/5 + selfcheck | 全绿只说明文档自洽，不代替 RTL |
| 综合 / 时序 | 顶层 map rc=0 | Fit/多角 STA 未完成，**不宣称 125 MHz** |
| 覆盖率 | 本版未重跑 | 旧 UCDB 含测试平台，不是本版 RTL-only，也不是功能覆盖率 |
| 波形截图 | 本版未附 | 证据是逐项 console 与 CSV，不把未附截图写成已有波形 |

复现（项目根目录，不要与其他 Questa 任务并行；回归脚本会停止同名仿真器）：

```powershell
python tools/run_all.py --strict
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools_lint.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\sim\run_regress.ps1
```

## 1. 技术指标达成表

指南指标由仿真测量。下表只采用本版 CSV 与对应 console，不用第 7 节的旧数字。

| 指南指标 | 要求 | 本版证据 | 边界 |
|---|---|---|---|
| 链路速率 | 100 Mbps | `IF_MODE=0` 为 10 拍/字节。T04、T05b、T17 及同档其他用例 PASS | `IF_MODE=1` 是连续字节额外档，约 1 Gbps 接口能力，不代替 100 Mbps |
| 帧格式 | IEEE 802.3 + A664，含 VLID、SN | T03：16 个黄金帧 × 3 种 ready，载荷 8～1471 B，pad/SN/校验和/B 网 SMAC | 单元构造证据；顶层回环另见 T13、T22 |
| 长度 | 载荷 ≤1471 B，帧 ≤1518 B | T13 记录帧长 64 / 303 / 1518 B；T18 载荷 17～1471 B | 1518 = 14+20+8+1471+1+4，含 FCS |
| 序列号 | 1～255，复位后 0，255 后回到 1 | T02 PASS：wrap/override/init | 不把单元通过写成全配置同时发 SN |
| BAG | 1/2/4/8/16/32/64/128 ms | T04/T04g：138/140 帧，同 VL 间隔、FCS、SN、载荷、双网、IFG 检查 PASS | console 给出单 VL 间隔 4220～4360 拍（模式 0）与 4229～4674 拍（模式 1），这是该用例间隔，不是 128 ms 档的普遍上界 |
| 抖动 | 几十微秒量级 | T05b：32 VL、96 帧、链路占用 99.86%、启动最大 4 μs、稳态最大 3 μs、稳态平均 2 μs。T05bg 稳态平均 3 μs。硬判据 500 μs | **不是 128 路同时满载**。25.84 μs 只是单帧线上时间，不是抖动 |
| 端到端时延 | 最坏 1～2 ms，含交换网络 | 见 §2。模式 0 最大帧 Total=244.856 μs | 不含交换机，不是 1000 帧排队，不能写成网络端到端达标 |
| 发送 VL | 典型最多 128 | 表容量 128。T05c：Q20 对 32/128 条 VL 做边界、突发、缺项、超配、复位和前门检查，PASS | **不是 128 路同时发流** |
| 接收 VL | 典型最多 4096 | T12c/T12r：4096 索引、四 way、各 10 万次查询。T08f/T08fg：4096 键全表写读 | **不是 4096 路同时收流** |
| 高完整性 | IC / RM / 双网 / SN | T08e、T09、T10、T02、T22 PASS | 见各行 summary，不外推成标准认证 |
| SNMP | 组委会：参考协议，自定子集 | T15/T15g PASS，见 §3 | 不是 SNMPv3，回包不上线 |
| 615A | 同上 | T16/T16g 的 TFTP 子集 PASS，见 §3 | 不是 Find/Information/Upload 全流程 |
| RTC | 指南功能项 | T16/T16g：period/jump/smooth/lock/loss/hold，顶层 pps fired | console 没有给出偏差微秒数，不宣称 ≤1 μs 已测得 |

## 2. T13 时延

测量定义来自 `sim/tb/tb_t13_latency.v`，时钟 125 MHz，每拍 8 ns：

- `TX_pipe`：主机 `MSG_WR` 提交到发送首字节。
- `Wire`：发送首字节到发送末字节，含接口节拍。
- `RX_pipe`：发送末字节到接收端口交付。其中包含测试平台把已抓取帧再灌回接收口的时间，不是纯接收流水。
- `HW_E2E`：`TX_pipe + RX_pipe`，按脚本定义不含 `Wire`。
- `Total`：提交到接收端口交付，等于 `TX_pipe + Wire + RX_pipe`。

这是单 VL、每档 1 帧、测试平台抓发再回灌。没有交换机，也不是设计书里“满载/轻载各 1000 帧”的计划用例。

### 2.1 100 Mbps 档（IF_MODE=0，评分口径）

| 用例 | 载荷 / 帧长 | TX_pipe | Wire | RX_pipe | HW_E2E | Total |
|---|---:|---:|---:|---:|---:|---:|
| CASE 1 | 17 B / 64 B | 2.168 μs | 5.040 μs | 5.288 μs | 7.456 μs | 12.496 μs |
| CASE 2 | 256 B / 303 B | 1.856 μs | 24.160 μs | 24.408 μs | 26.264 μs | 50.424 μs |
| CASE 3 | 1471 B / 1518 B | 1.888 μs | 121.360 μs | 121.608 μs | 123.496 μs | 244.856 μs |

来源：`out/arena-debug/continue12/tests/full56/T13_console.txt`。三档载荷回读一致，结果 PASS。

### 2.2 连续字节额外档（IF_MODE=1，不代替 100 Mbps）

| 用例 | 载荷 / 帧长 | TX_pipe | Wire | RX_pipe | HW_E2E | Total |
|---|---:|---:|---:|---:|---:|---:|
| CASE 1 | 17 B / 64 B | 2.528 μs | 0.504 μs | 0.680 μs | 3.208 μs | 3.712 μs |
| CASE 2 | 256 B / 303 B | 1.880 μs | 2.416 μs | 2.592 μs | 4.472 μs | 6.888 μs |
| CASE 3 | 1471 B / 1518 B | 4.816 μs | 12.136 μs | 12.312 μs | 17.128 μs | 29.264 μs |

来源：`T13g_console.txt`。PASS。

## 3. 协议子集

组委会没有给出 SNMP / 615A 对象清单，要求参考协议并自行界定。当前承诺以 RTL 和本版测试为准，不以设计书里尚未落到 RTL 的状态图为准。

### 3.1 SNMP

承诺：SNMPv1/v2c 的 GET、GETNEXT、SET 与 response；community 不符则静默丢弃；企业 MIB 前缀 `1.3.6.1.4.1.4444.1.1`。不承诺 SNMPv3、trap、inform、GETBULK 和完整 MIB-II。

T15/T15g：单元侧 12 个真实 BER PDU，覆盖 GET/GETNEXT/SET、STATS_BLOCK、noSuchName、readOnly、badValue、community 丢弃、OCTET STRING 和多 VarBind。顶层 12 个 SAP 帧进入接收路径，11 个产生响应，1 个因 community 丢弃。

边界：响应只编码，经主机观测窗读出，**未接入发送构建器，管理面回包不上线**。不宣称表内每一个 OID 都逐项测过。

### 3.2 ARINC 615A

承诺的是数据加载所用的 **RFC 1350 TFTP 子集**，不是完整 615A 会话：

- WRQ 只接受白名单 `UPLOAD`，mode 必须为 octet。
- DATA 写入 32 KB 加载区；重复块只补 ACK；末块结束会话。
- RRQ 只返回固定 32 B 的 `STATUS`，不能从加载区回读任意文件。
- 覆盖 ERROR、非法操作码、超时重传和重试上限。
- 不做 Find / Information / Upload opcode，不做 OACK、blksize 选项和签名校验。

T16/T16g 的 TFTP 单元项与上述范围一致。顶层 8 个 SAP 帧进入接收路径，加载区回读核对。响应同样经观测窗读出，不上线。

### 3.3 RTC

T16/T16g 单元项覆盖自由运行周期、大偏差跳变、小偏差平滑、锁定、失步和保持；顶层 PPS 有脉冲。没有把偏差微秒数写入 console，因此不把设计目标“≤1 μs”写成测量结果。

## 4. 本版用例矩阵

`wall_s` 取自本版 `regress.csv`，摘要只截关键事实，完整句子在 CSV 与 console。

| ID | 配置 | 结果 | wall_s | 本版摘要 |
|---|---|:--:|---:|---|
| T00 | default | PASS | 4.8 | crc32 ×9；fifo 4000；bram 8192 |
| T01 | default | PASS | 298 | 25344 次写、再复位、表项读写、流水、timebase |
| T02 | default | PASS | 5.5 | SN 回绕/覆盖/初值；采样/队列/耗尽 |
| T03 | default | PASS | 5.3 | 16 黄金帧 ×3 ready；载荷 8～1471 |
| T04 | default | PASS | 12.6 | 模式 0；138 帧；BAG/FCS/SN/双网/IFG；间隔 4220～4360 拍 |
| T04g | gmii | PASS | 11.8 | 模式 1；140 帧；间隔 4229～4674 拍 |
| T05c | default | PASS | 6.2 | Q20 32/128 VL；边界/突发/缺项/超配/复位；前门 |
| T05b | saturated-jitter | PASS | 14 | 32 VL；96 帧；启动 4 μs；稳态最大 3 μs；平均 2 μs；占用 99.86% |
| T05bg | saturated-jitter-gmii | PASS | 11.1 | 同上；稳态平均 3 μs |
| T08a | default | PASS | 4.3 | 模式 0；22 帧；坏帧隔离 |
| T08ag | gmii | PASS | 4.1 | 模式 1；22 帧 |
| T08b | default | PASS | 5.7 | 双网；BE；坏 FCS；drain=17/24；未配置拒绝=2 |
| T08bg | gmii | PASS | 5.1 | 同上 |
| T08c | host-arb | PASS | 5.5 | 主机写 40，全部延后，max_wait=2 |
| T08cg | host-arb-gmii | PASS | 5 | 同上 |
| T08d | flt | PASS | 5 | 7 判决，放行 3，丢弃 4 |
| T08dg | flt-gmii | PASS | 4.9 | 同上 |
| T08e | ic-top | PASS | 13.9 | IC 468，接受 463，拒绝 5 |
| T08eg | ic-top-gmii | PASS | 6.6 | IC 468，接受 463，拒绝 5 |
| T08f | full-table | PASS | 7.2 | 4096 键，8192 字写读，四 way |
| T08fg | full-table-gmii | PASS | 7.2 | 同上 |
| T09 | full | PASS | 3.6 | N=4096；接受 1759，拒绝 4248 |
| T09s | small | PASS | 3.3 | N=16 |
| T09p | full | PASS | 3.8 | 10240 帧；8192/8192 槽覆盖 |
| T09ps | small | PASS | 3.5 | N=16；32/32 槽覆盖 |
| T10 | rm-top | PASS | 6.4 | 转发 48，重复消除 36 |
| T10g | rm-top-gmii | PASS | 5.6 | 转发 48，重复消除 36 |
| T11 | rx-port-top | PASS | 4.7 | 交付 14；采样/队列/溢出/复位 |
| T11g | rx-port-top-gmii | PASS | 5.2 | 同上 |
| T11i | int-top | PASS | 4.2 | 中断屏蔽、电平、W1C |
| T11ig | int-top-gmii | PASS | 4.2 | 同上 |
| T12c | full-contiguous | PASS | 10.9 | 10 万次；命中 61638；4096 索引；四 way |
| T12r | full-random | PASS | 10.8 | 同上统计 |
| T12s | small-collision | PASS | 4.5 | 2 万次；16 索引 |
| T12h | small-rehash | PASS | 4.9 | 换种子；2 万次 |
| T12f | frontdoor | PASS | 5.9 | 8192 字前门；命中 3，未命中 1，坏 CRC 1 |
| T12fg | frontdoor-gmii | PASS | 5.5 | 同上 |
| T13 | latency | PASS | 3.9 | 模式 0；3 档；数字见 §2.1 |
| T13g | latency-gmii | PASS | 3 | 模式 1；3 档；数字见 §2.2 |
| T14 | stats-page | PASS | 3.8 | 帧/字节/丢弃/直方图；1 个真实帧 64 B |
| T14g | stats-page-gmii | PASS | 4 | 同上 |
| T15 | snmp-lite | PASS | 3.3 | 12 PDU；顶层 12 帧，应答 11，community 丢弃 1 |
| T15g | snmp-lite-gmii | PASS | 3.3 | 同上 |
| T16 | tftp-rtc | PASS | 4 | TFTP 子集 + RTC；顶层 8 帧；加载区核对；PPS |
| T16g | tftp-rtc-gmii | PASS | 3.2 | 同上 |
| T17 | min-frame-512 | PASS | 13.2 | 模式 0；512 对；主机写 4096；crc_reject=1 |
| T17g | min-frame-512-gmii | PASS | 7 | 同上 |
| T18 | random-stress | PASS | 38.9 | 25 轮；102 帧；载荷 17～1471；seed=51c0ffee |
| T18g | random-stress-gmii | PASS | 12.4 | 同上；rx_stall=68 |
| T21 | block-pool | PASS | 4.5 | 装满 10，耗尽后归还恢复 |
| T21g | block-pool-gmii | PASS | 3.8 | 同上 |
| T22 | loopback | PASS | 7.4 | 冷启动 2 帧回环；载荷逐字节；IC 去重 |
| T22g | loopback-gmii | PASS | 6.8 | 同上 |
| T22a | default | PASS | 4.4 | 发送前门；A/B 的 FCS/SN/载荷 |
| T23 | sap-minimal | PASS | 5.6 | SAP 接受 2，归还 2 |
| T23g | sap-minimal-gmii | PASS | 5.4 | 同上 |

合计 56 项 PASS。T05c 在 CSV 中位于 T04g 之后、T05b 之前，上表按指标阅读把 T05b 挪到 T05c 旁边，没有改任何数字。

## 5. 失败记录

首轮完整回归 **54/56，rc=1**，墙钟 660.12 s。只有 T08b/T08bg 失败：旧测试把完成等待固定为 12 拍，新接收查表流水下提前采样。失败 CSV、56 份 console、当次源清单和日志保留在 `out/arena-debug/continue12/failed_full56_old_t08b/`。该次 `full56.log` SHA-256 为 `a6fc9891680f668a956eab08c54c2ead71eb9f82f058f0a559209b82ea0039dd`。

修正只改 T08b 测试平台：最多等 24 拍，要求恰好 2 次未配置拒绝，并要求块池全部归还。专项 2/2 的完成拍是 17/24。随后独立重新编译并重跑全部 56 项，得到本节的 56/56。**不用 54+2 拼接通过率。**

## 6. 仍未写入本报告的交付物

1. 关键波形截图尚未附上。
2. 评委可在 eLinx 里一键打开并仿真的操作步骤，尚未按本版源码重新取证。现有回归是 Questa 命令行。
3. 125 MHz 的 post-fit slack / Fmax 尚未产生，不进入指标结论。
4. 本版未重跑覆盖率，不引用旧 62.51% / 73.12% 作为当前结果。

---

## 7. 历史基线（613.5 s，禁止与上文混用）

旧矩阵、旧耗时和旧覆盖率已移到 [历史基线](历史/AFDX端系统_测试仿真报告_历史基线.md)。该文件墙钟 613.5 s，不得与本文件混用。

## 后综合网表顶层功能仿真（2026-09-30 01:33，新证据）

本条**补充**前述 RTL 证据，而不替换原 65/65 输入与旧网表失败记录。eLinx 捆绑 Quartus II 13.0.1 在**隔离复制**的当前生产版 map 工程中执行 `quartus_eda AFDX_top -c AFDX_top --simulation=on --format=verilog --tool=modelsim --functional=on --output_directory=simulation/modelsim_functional`，writer **rc=0、0 errors**；生成的**后综合／post-map 功能网表** `out/arena-debug/postsyn_quartus_eda_20260930/export_project_functional/simulation/modelsim_functional/AFDX_top.vo` 为 189,911,225 B、SHA-256 `95c254fd4f5e4eeba7a4ec59374c6a7d43192730246ab77a27413f85d57d0c5e`，绑定完整回归状态 SHA-256 `321b90438493bdeef34b8eaa217ebc6c3d7a164ce40220026fad8ae986cebc5d`。未加 `--functional=on` 的先前 writer 探测 **rc=3／Error 199063**（需要 Fit 和 TimeQuest），原日志保留；这里明确不是该失败输出的“PASS”。

Questa FSE 2025.3 对**原 VO** `vlog` **rc=0、0 errors／0 warnings**，并链接安装目录内 eLinx Stratix IV 原语模型 `elinx_lib` 执行**真正的全顶层后综合零延时功能 smoke**：`vsim` **rc=0、Errors: 0、Warnings: 1**，原语模型 `mem_invalidate` 有 1 条 `vopt-13162` 警告，未删改或隐藏。原 testbench SHA-256 `f0560fd10bba3bb0b42a750f80c252d6d811d6428893e3bf796970af983b2ce9`，模拟至 **3680 ns**，检查 REG_ID `AF071000`、REV `00040000`、控制默认 `0000051c`、SMAC 默认／写 `DEADBEEF`／读回／复位恢复与 RTC 有效递增，打印 `PSTSYN TOP SMOKE PASS`。独立状态 `out/arena-debug/postsyn_quartus_eda_20260930/gate_full_compile/simulation_status.json` SHA-256 `13b40e47cc5a4789f57915c4fa4e4e89ae221c3b41a0759a914d94cde65ab967`；原始 `vsim_gate.log` SHA-256 `72cab826fda4731cd5258d1e1d08a251941e6a6688d51cce388648cdafc616a9`。原 eLinx `write_verilog` 导出网表的 Questa 编译失败记录仍存在，这里使用的是**不同的、由 Quartus EDA Writer 合法生成的功能 VO**。

**严格边界**：这是短时接口 smoke，**不是 65 项后综合网表回归、帧路径全覆盖、时序仿真、post-fit SDF／STA、125 MHz 收敛、完整 SNMP／615A 网络互通或板卡签核**。本项目当前 Fit 未完成、当前版 post-fit STA 仍不存在，赛方“综合后仿真即可”的具体评分口径也需以正式答复为准。后续门级波形／更完整功能可继续补，但不能改变此轮实测范围。

## 2026-09-30 后综合网表接口原始波形（补充 A 节，不替代 65 项 RTL）

在与页末功能 VO、TB、厂商原语相同的真实后综合顶层接口仿真上，使用 **仅对 `tb_elinx_postsynth_smoke` 的寄存器/线网开放可见性**的 Questa 优化选项取证，完成原 testbench 到 3680 ns，rc=0、`PSTSYN TOP SMOKE PASS`，并修复默认 vopt 隐藏 TB 对象致 `vcd add` 查找失败的问题。完整 VCD（17,568 B）位于 `out/arena-debug/finish_20260930/gate_trace_tb_only/postmap_top_io.vcd`，SHA-256 `99c2e5dff79a97f5eb928b5ebc73c75494891b1bd0f211ac485880e1417cc18a`；判决状态 `trace_status.json` SHA-256 `06b410a0215f77b3f76a938073a317e9bc2ebb94ca1a92f3319ba70089c6ac28`。独立原始波形解析 `gate_trace_events.json` 复原全部七笔读写（REG_ID、REV、CTL、SMAC 默认／写／读／复位恢复），脚本与同源 [SVG 波形图](../out/arena-debug/finish_20260930/gate_trace_tb_only/postmap_top_io.svg) 一并保存；图**不是 GUI 截屏**。该 VCD 不包含测试用例 T13w 的整帧双网门级交付；先前网表双网单帧 900 s 超时仍保持失败结论。RTC 非零漂移误差、post-fit STA 与 125 MHz 不能从此接口波形推出。
