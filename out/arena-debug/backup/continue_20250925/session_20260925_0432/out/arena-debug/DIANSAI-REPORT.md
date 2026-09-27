# DIANSAI 修复与复验报告（2026-09-25）

> **FINALIZE 最新结论（优先于本文件下方的历史 MISSION-FIX 快照）**：核心 RTL 全量功能回归 50/50 PASS；T23 两个不同 SN 的连续 SAP/PB1 槽争用与 T18 两事务同时在飞均取证；Questa 四个定向用例产出真实 UCDB。**顶层 eLinx 综合未成功，STA 无有效数据，完整 T14–T16 管理协议未交付；不能声称整机符合总体设计书或 125 MHz 时序收敛。**

## MISSION-FINALIZE — 最终交付边界与状态

工作目录 `C:/Workspace/diansai`；命令日志、未遮盖的首次失败、原始 CSV/50 份 console、UCDB、约束与工具探针统一在 `out/arena-debug/finalize/`，逐文件 SHA-256 清单 `finalize/SHA256SUMS.txt`。本节只覆盖自 `backup/finalize_20250925/` 备份之后的修改；没有 commit/push/reset，也未碰 `competition_case/` 或凭据。

| 验收项 | 最新状态 | 可核证结果和边界 |
|---|---|---|
| 连续 SAP/PB1（T23/T23g） | **DONE：2/2** | 同线合法 IFG 的 SN=0→1；两档各 accept/return=2、PB1 争用=2、等待=0 拍、块守恒；MII 不虚称线路重叠，PB1 是槽级注入不是第二普通帧流。原始 console：`finalize/tests/directed_T23_console.txt`、`directed_T23g_console.txt`。 |
| 两事务并发（T18/T18g） | **DONE：2/2，限双在飞** | 种子 `51c0ffee`，各档 100 笔串行随机事务 + 端口 0/1 同时 TX 在飞的 2 笔，计 102 帧；A/B 双网回灌、接收 16/17 同时持有两消息、去重 +2、`MSG_CNT` 读/释 1→0、PMEM 逐字节和 RX 块最终 `FFC0`；pair 背压 MII=756/GMII=71 拍。**不是** 4 端口持续并发。 |
| 末次完整功能回归 | **DONE：50/50** | `powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_regress.ps1`，先查无残留 Questa，单流程无 `-Tests`，编译 rc=0/0 errors，50 条 manifest 顺序、CSV 50 PASS 与 50 个 console 全核对；wall_s=285.4，退出码 0。 |
| Questa 覆盖率 | **DONE_PARTIAL：真实四用例 UCDB** | `+cover=sb` 编译、`vsim -coverage`、4 次 `coverage save -onexit`、`vcover merge/report` rc=0；四用例合并 **含 TB 实例**分支 4035/6098=66.16%、语句 7110/9200=77.28%、总 71.72%，116 instances。不是完整 50 项、RTL-only、功能覆盖率或认证指标。 |
| 顶层 eLinx 综合 | **BLOCKED_SYNTH_OOM** | 原脚本 `memory_map: invalid vector<T> subscript`，修复 `tx_rm` 的旧工具敏感小队列后推进到 `OPT_MUXTREE: ERROR: bad allocation`，原路径与显式 BRAM 路径 rc 均为 1；尚无完整 `AFDX_top` 可审阅综合网表/器件利用率。 |
| STA/时序收敛 | **BLOCKED_NO_PROJECT_OR_NETLIST** | TimeQuest 已安装（**非** `BLOCKED_NO_TOOL`），但 `create_timing_netlist` 因无 active revision 报错、探针 rc=3。只有设计书 8 ns 时钟初步 `.edc`，无合法板级 IO delay/已布线设计；**WNS/TNS/关键路径/Fmax 均未取得**。 |
| 完整 SNMP/TFTP/RTC/统计面 | **OUT_OF_SCOPE_FINALIZE／OPEN_SPEC_GAP** | `mgmt_sap_rx` 仅为 SAP descriptor/管理窗口/块归还；`snmp_lite.v`、`a615a_tftp.v`、`rtc_sync.v` 为未例化的 9 行壳，`stats_regs.v` 缺失，T14–T16 不在 manifest。本次可验收交付**明确不包含**完整协议，但设计书仍要求，故整机目标**未完成**；需另做实现+TB 或正式需求豁免。 |
| 门禁 | **DONE** | `tools_lint.ps1` rc=0、0 `%Error`（保留 warnings）；`python tools/run_all.py --strict` rc=0、5/5 + selfcheck（不等于 RTL/STA）。 |

### 原始证据与 SHA-256（均按完整文件取值）

| 证据路径（相对工作目录） | SHA-256 / 阅读要点 |
|---|---|
| `out/arena-debug/finalize/tests/final_full50.log` | `FDE46DB23DE57BE30F2E8E499EEAD05A24458A3BE03BE08ED0A21EE0CC8CD10F`，编译与 50 条原始摘要/rc |
| `out/arena-debug/finalize/tests/final_full50.csv` | `0469EE8878E77B000F63ED7DFE57BF44A6921AF675018F5B0F0060589801A9EB`；`final_audit.log` 核对同序；`full_consoles/` 有 50 份原始文件 |
| `out/arena-debug/finalize/coverage/T18_T23_4cases.ucdb` | `1939643A009AA69B184EAF2379E06B1FE42ACC970816994D0015F8D246EBB2DD`；各档 UCDB、compile/run/vcover 日志及 `merged_summary.txt` 一并保留 |
| `out/arena-debug/finalize/coverage/merged_summary.txt` | `1E2988FFF51FE3E1A3869D7C484F322651B15F56621A26ABD57E81045DB39E80`；只对该四例含 TB 范围 |
| `out/arena-debug/finalize/synth/top_after_tx_rm_console.log` | `8AB90B745319870AC8589F9D207D6F6E31294C495594597BC76DD6E4C94BAE20`；rc=1 同目录 `_rc.txt` |
| `out/arena-debug/finalize/synth/bram_after_tx_rm_console.log` | `9730034DC7550D6E288F8C3E94EAE00CCDE265E7A6773007AD3DB76B588B540D`；rc=1；`bram_pre_opt` 虽 rc=0 只停在优化前，不是综合网表 |
| `out/arena-debug/finalize/sta/sta_probe_console.log` | `197BBDAD642F8D0C76349C0E06691FEB74AE4738BA737195C2E97AF74D4E2B57`；`create_timing_netlist` 无 active revision，rc=3 |
| `out/arena-debug/finalize/gates/final_lint.log` / `final_docgate.log` | 前者 `1A9E9CFCA87FBB3059FF1A3E80868D533FBE00C159EA802FA5A1EFCB3B61F88A`；后者 `EC1EFAB9FA0D691B982721BAE376DF8B23AB8BE3F4339E65185324EE2DE6B782` |

定向原始文件：`out/arena-debug/finalize/tests/directed_T23_console.txt`、`directed_T23g_console.txt`、`directed_T18_console.txt`、`directed_T18g_console.txt`。首次 T23 MII 把合法 IFG 误判为必须接收重叠、首次 T18g TB 在 GMII 第二帧前过早撤 `DV` 导致 MAC 长度丢弃，均有原始失败 console（`t23_mii_overlap_failed_console.txt`、`t18g_first_failed_console.txt`、`t18g_diag_failed_console.txt`），修正的是 TB 驱动/不成立断言，最终四档及完整 50 项复跑 PASS，**失败原件未删**。详情及命令在 `finalize/tests/README.md`、`finalize/coverage/README.md`、`finalize/synth/README.md`、`finalize/sta/README.md`。

补丁 `out/arena-debug/fixes.patch` 只对 `backup/finalize_20250925/` 的本轮源/文档备份生成，包含新增约束与可复现辅助脚本，**不混入先前工作树的修改**；旧补丁另存于备份目录。`finalize/patch_verify.log` 记录 `git apply -R --check` 及对隔离备份的正向应用、字节校验；不对工作树实际反向应用。若需完成整机目标，先拆分/推断顶层大 RAM 或适配器件 BRAM IP，再经全量功能回归、器件 P&R/setup+hold STA；另按 T14–T16 实现管理协议或获得书面范围豁免。

---
## 历史 MISSION-FIX 记录（下方旧结论按当时状态归档，均以以上 FINALIZE 为准）

- 工作区：`C:/Workspace/diansai`；依据：`out/arena-debug/MISSION-FIX.md`、`REVIEW-REPORT.md`。
- **总体结论**：Questa 完整清单 **50/50 PASS**（编译 rc=0、0 errors，耗时 276.3 s）；Lint 与严格文档门通过。`AFDX_top` **综合仍失败**，未进行 STA；不得将功能仿真、AST 解析或 12 个独立子模块综合等同于整机综合/时序收敛。
- 原工作树含大量既存未提交、未跟踪修改；本轮没有 reset/commit/push，也没有碰 `competition_case/`。每处源文件修改前均备份到 `out/arena-debug/backup/fix_20260925/`，保留复现失败证据。原报告文件含乱码及工具回包包装文本，原样备份后重写为本报告。

## 复验索引

| 项目 | 本轮客观结果 | 主要证据 |
|---|---|---|
| B2 FIFO | 模块综合 `rc=0`、全日志 `^ERROR=0`；FIFO/链路定向 4/4 PASS | `elinx/prj/sub_sync_fifo.log`；`out/arena-debug/checks/B2_questa.log` |
| B3/B4 满载抖动 | T05b/T05bg 2/2 PASS；每 VL 首发相位至实际出帧最大发送延迟 4/4 µs（硬界 500 µs）；稳态最大 3/3 µs | `sim/out/T05b_console.txt`、`T05bg_console.txt`；`checks/B3_questa.log` |
| B5 SAP 归还 | T21/T21g/T23/T23g 定向 4/4 PASS；持续 PB1 归还下 SAP 冲突观测各 1 次、等待 ≤1 拍 | `checks/B5_questa.log`；`elinx/prj/sub_rx_block_pool.log` |
| B6/B7 T18 | T18/T18g 2/2 PASS；种子 `51c0ffee`、长度覆盖 17..1471B、97 帧施加解析反压；去重精确 +1 | `checks/B67_questa.log`；`sim/out/T18_console.txt` |
| B10 SAP 禁用负例 | T23/T23g 2/2 PASS，`R_SAP` 各恰好 1 次，管理受理 0，RX 块归还 | `checks/B10_questa.log` |
| B1 顶层综合 | **FAIL**：原脚本 `memory_map` 报 `invalid vector<T> subscript`；BRAM 探针的 `memory_collect` 报 `dict::at()` | `elinx/prj/AFDX_top_synth.log`；`checks/B1_bram_probe.log` |
| 门禁 | Lint 0 Error；`tools/run_all.py --strict` 5/5 + selfcheck 通过；子模块日志核验 12/12（**不是**顶层） | `checks/final_lint.log`、`final_docgate.log`、`B9_table.md` |
| 全量回归 | **50/50 PASS**；与 50 条 manifest 同序，无跳项 | `out/arena-debug/checks/final_full50.log`、`sim/out/regress.csv` |

> 上述均为 RTL 周期级验证及部分前端综合证据，不是器件 STA、覆盖率或 ARINC 664P7 正式认证。

## B2 — `sync_fifo` 多驱动（已修）

**Before**：`rtl/common/sync_fifo.v` 的二维 `mem` 经 eLinx `synth` 生成同一 `rd_data[7:0]` 被 `$mem.RD_DATA` 与 `$mem.RD_DATA_B` 双驱动；原 `sub_sync_fifo.log:571` 的 `ERROR` 出现在 `stat` 80 cells **之后**，该数不能用作综合成功证据。**After**：小深度（≤32）FIFO 改用一维 `mem_bits[W*D-1:0]` 的单次注册读取/写入，消除冲突，原 FIFO 满/空、同步读行为不变。新日志 1433 个逻辑 cell、0 个 `$mem`；较大数量是寄存器实现代价，不是 LUT/布局面积结论。

复现/验证：`Select-String elinx/prj/sub_sync_fifo.log -Pattern '^ERROR'`（旧日志备份在 `backup/fix_20260925/B2/sub_sync_fifo_before.log`）；`& "C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe" -s elinx/prj/sub_sync_fifo.ys -l elinx/prj/sub_sync_fifo.log` → `rc=0` 且无 `^ERROR`。`powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_regress.ps1 -Tests T00,T04,T08a,T08ag` → 4/4 PASS；`B2_lint.log`、`B2_docgate.log` 均通过。

## B3 — T05b 500 µs 真判据（已修）

**Before**：同相批量提交的 MII 首帧总跨度 781 µs 已超文字所称 500 µs，断言却用 867 µs 判 PASS。**After**：每一轮的 `MSG_WR` 按 `i*BAG/32` **实际错相提交**（BAG=828 µs）；按各 VL 的**预设相位到首帧发送**计算最大发送延迟，用**周期精度** `>500*125` 判失败，不再用理论上界或微秒截断放水；稳态界限同样以周期精度判 50 µs。增加逐 VL 帧数及稳态间隔数检查。

定向命令：`powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_regress.ps1 -Tests T05b,T05bg` → 2/2 PASS，96 帧/档；MII/GMII 首发延迟 4/4 µs、稳态最大间隔偏差 3/3 µs。**原始首帧总跨度为 800/799 µs，含人为相位差，单独打印而不称“抖动”**；该 TB 的首发定义并非标准认证全套判据。`B3_lint.log`、`B3_docgate.log` 通过。

## B4 — “同相/错相”文档口径（已修）

**Before**：`doc/当前进度_20260923.md` 把旧同相测试写成“错相”，且误称 32 条 VL 的 BAG 为 1..128 ms。**After**：标注旧 781/96 µs 为**同相**及旧 867 µs 误判；本轮才是按 `i*828µs/32` 错相，记录相位相对延迟与总跨度的不同定义。`tools/run_all.py --strict` 通过。

## B5 — SAP 归还公平且不丢普通 RX 块（已修）

**Before**：`AFDX_top.v` 固定 `pb_free1` 优先，持续 PB1 脉冲可令 `mgmt_free_take=0` 无上界。**After**：主槽按竞争事件轮转；增加 `rx_block_pool.free_spill` 释放口接纳本拍落选者。普通 PB1 是**无 ready 的脉冲**，若只轮转覆盖它会永久丢块；新电路冲突时两路**同拍**释放，`mgmt_free_take=mgmt_free_req`，请求服务上界 1 拍。T23/T23g 在真实 SAP 帧处理期间于 PB1 槽持续注入普通归还脉冲，检查碰撞、两 ID 的归属与 SAP 有界返回；各观测一次冲突。T21/T21g 块池耗尽恢复也通过。`sub_rx_block_pool.ys` 重跑 `rc=0`、`^ERROR=0`；`B5_lint.log`、`B5_docgate.log` 通过。

局限：PB1 冲突为 TB 定向槽级注入，不等于含真实普通帧流的长期混合负载验证。

## B6 — T18 真随机激励（已修、范围已限）

**Before**：长度仅由 `%8` 固定查表，且无 RNG/种子、所谓“四端口并发”实际逐帧串行。**After**：一次 `$urandom(seed)` 初始化，之后连续 `$urandom()` 生成可重放的长度、发送间隙、A/B 错峰、MII 字节间隔、解析→端口握手反压及每帧 payload 盐；PASS 摘要含种子与覆盖统计。首次试跑发现 Questa 每次带同一 seed 重置 RNG、导致 100 帧长度都 465B，被覆盖断言**正确判 FAIL**；改为只初始化一次后通过，失败日志保留 `checks/B67_debug_questa.log`。

`-Tests T18,T18g` → 2/2 PASS；两档各 100 **串行消息事务**，A/B 副本同时回灌，长度覆盖 17..1471B，97 帧施加反压、100 帧具非零额外间隔，固定种子 `51c0ffee`。**未**证明四端口多个不同消息同时在飞，也无 UCDB/功能覆盖率统计。`B67_lint.log`、`B67_docgate.log` 通过。

## B7 — 去重及计数断言（已修）

**Before**：T18 仅判 `deliver_cnt` 有增加，双网重复交付两次也能漏过；`MSG_CNT` 仅判非零，极大长度时末尾 payload 字节未全部遍历。**After**：两网流水线排空后强判 `deliver_cnt === prev_deliv + 1` 且等于累计事务数；`MSG_CNT` 接收后 `===1`、`MSG_RD` 后 `===0`；payload 循环覆盖末字节。`T18/T18g` 2/2 PASS（如双交付会触发明确 FAIL，不以 `>0` 判定）。

## B1 — 顶层综合（**仍未闭环，已纠正状态**）

`& "C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe" -s elinx/prj/AFDX_top_synth.ys -l elinx/prj/AFDX_top_synth.log`：**rc=1**，`MEMORY_MAP → ERROR: invalid vector<T> subscript`。以现有 `bram_sdp_smoke.ys` 的 `memory_collect → memory_bram → techmap` 顺序生成 `checks/B1_bram_probe.ys` 复试：**rc=1**，顶层在 `MEMORY_COLLECT → ERROR: dict::at()`，尚未进入 BRAM 映射。单独的 BRAM/PSN 冒烟日志与所选小模块成功，均不能替代顶层验证；未把失败改写成成功。

`doc/当前进度_20260923.md` 已将“芯片逻辑综合”改为 **[ ] 部分完成**。若继续推进，需要定位 eLinx 旧 Yosys 在顶层混合存储的故障模块，尝试受支持 BRAM/IP 或较新综合器复现，并完成全顶层网表与器件后端。此轮没有强行大范围替换 RAM 实现。

## B8 — 时序表述（已订正）

**Before**：原报告将 Questa 的零延时周期级仿真描述为“时序分析完成”。**After**：明确 **时序收敛未验证；当前仅有周期级功能仿真**。本轮没有时钟/IO 约束下的 P&R、建立/保持/关键路径报告，不能声称 125 MHz 收敛或 STA PASS。

## B9 — 综合表格路径及判据（已订正）

**Before**：原表误写 `init_sweep → rtl/mgmt/`、`mac_tx_if → rtl/mac/`，还在 `CHECK` 报错的日志上将 `sync_fifo` 记 PASS。**After**：`python tools/gen_synth_table.py --out out/arena-debug/checks/B9_table.md` 从 `sub_*.ys` 解析真实源码（含依赖文件），逐个检查源码存在、**整份日志**无 `^ERROR` 且有 `Yosys execute success!`；不读取 `stat` 之前的中间状态充当成功。此脚本核验已有日志；本轮实际重跑了 `sync_fifo` 和 `rx_block_pool`，其余为既有单模块日志。

| 子模块 | 实际 RTL 路径 | 全日志核验 | Cells（仅统计） |
|---|---|---|---:|
| `crc32` | `rtl/common/crc32.v` | **PASS** | 352 |
| `init_sweep` | `rtl/top/init_sweep.v` | **PASS** | 152 |
| `mac_tx_if` | `rtl/tx/mac_tx_if.v (依赖: rtl/common/crc32.v)` | **PASS** | 983 |
| `mgmt_sap_rx` | `rtl/mgmt/mgmt_sap_rx.v` | **PASS** | 373 |
| `rst_sync` | `rtl/common/rst_sync.v` | **PASS** | 3 |
| `rx_block_pool` | `rtl/rx/rx_block_pool.v` | **PASS** | 959 |
| `rx_flt` | `rtl/rx/rx_flt.v` | **PASS** | 852 |
| `sync_fifo` | `rtl/common/sync_fifo.v` | **PASS** | 1433 |
| `timebase` | `rtl/common/timebase.v` | **PASS** | 506 |
| `tx_frame_builder` | `rtl/tx/tx_frame_builder.v` | **PASS** | 5430 |
| `tx_pace` | `rtl/tx/tx_pace.v` | **PASS** | 42 |
| `tx_sn_gen` | `rtl/tx/tx_sn_gen.v` | **PASS** | 7626 |

**口径：12/12 仅对上述已有独立子模块日志有效，未包括大容量存储子模块或顶层，不代表 FPGA 综合/STA。**

## B10 — T23 负例及弱断言（已修一部分）

**Before**：仅一帧使能 SAP 正例，块号弱判 `>=6`。**After**：正例精确断言块号 `6` 且验证 PB1 冲突；复位重新配置后在 `SNMP_EN=0` 发送**有效 SAP 帧**，精确断言 `R_SAP` 1 次、MGMT accept/free 均 0、端口/总 drop 各 1、块池恢复 `FFC0`。`-Tests T23,T23g` → 2/2 PASS，`disabled_rsap=1`。背靠背两个**不同序号** SAP 的反压覆盖仍未补，列为剩余工作，不称完全覆盖。

## B11 — 文档门自述（已订正）

**Before**：`selfcheck_claims.py` 把已经存在的 T05b/T22 用例写成“仍未取证”，并称错相“待做”。**After**：C3 明确是**旧同相启动风险的理论模型**，说明现有 TB 用例可查但脚本不读取其结果；通过与否以回归 CSV/Questa 日志为准，理论模型不等于 STA。`python tools/run_all.py --strict` → 5/5 + selfcheck 通过。

## 最终回归、门禁与剩余项

- 回归命令（执行前确认无 `vsim/vopt/vlog` 残留，**仅运行一份**）：`powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_regress.ps1`。
- 本轮结果：50/50 PASS；`sim/tests.manifest` = 50 项；`sim/out/regress.csv` = 50 行，PASS=50、FAIL=0；编译 rc=0、0 errors；总耗时 276.3 s。逐项原始输出：`checks/final_full50.log`、`sim/out/*_console.txt`。
- 证据 SHA-256：`sim/out/regress.csv` = `023E9CF471DE0E4C2662DEC6C4CB02A40476FFC24534DB591148AD13220EDD57`；`sim/out/compile_console.txt` = `0822DAC6FCE9B7EC7CD4008BE8602BFCA622596BB832BAF30C69AA3A2CD01BA4`。本轮重新生成的日志不能借旧报告所列哈希充数。
- 最终门禁：`powershell -NoProfile -ExecutionPolicy Bypass -File ./tools_lint.ps1` → 0 Error；`python tools/run_all.py --strict` → 5/5 + selfcheck；`python tools/gen_synth_table.py --out out/arena-debug/checks/B9_table.md` → 12/12 **所选子模块日志核验**。
- **未修/未验证**：B1 全顶层 eLinx 综合仍失败，STA/125 MHz 收敛、实际 BRAM 资源/布局、形式化与 UCDB 覆盖率未做；T23 背靠背新 SN 的 pending 反压、T18 四端口真正多事务并发未覆盖；完整 SNMP/ARINC 615A 应用协议不是本次 RTL 范围。以上不随 50/50 功能仿真变为 PASS。

## 备份、补丁与回滚

- 备份：`out/arena-debug/backup/fix_20260925/{B2,B3,B5,B67,B1,B8_B11,pre_full50}/`。原报告也已备份于 `B8_B11/DIANSAI-REPORT_before.md`。
- 补丁：`out/arena-debug/fixes.patch`，使用 **`git diff --no-index` 对本轮改前备份与改后文件生成**；仅包含本轮实际修改的 10 条源码/文档路径，避免把项目原已存在的大量未提交、未跟踪修改混进补丁。它是 Git 统一格式补丁，可用 `git apply -R --check out/arena-debug/fixes.patch` 检查、`git apply -R out/arena-debug/fixes.patch` 回滚到**本轮开始时**（不是回退到仓库 HEAD）；生成时对隔离目录做正向和反向字节比较。仿真生成的 `sim/out/` 文件不属于源代码补丁，原件另在 `pre_full50/` 中。
