# DIANSAI 修复与复验报告（2026-09-25）

## MISSION-CONTINUE2 — 2026-09-25 最新收口结论（优先于本文件下方所有历史快照）

> **本轮是状态变化最大的一轮：顶层 eLinx 综合从 BLOCKED 变成 rc=0；STA 从"无数据"变成
> 有实测数据且结论是"125 MHz 不收敛"；并修复了一个会让整机主机接口 RX_VL_CFG 回读恒为 0 的真实缺陷。
> 整机仍未完成：时序不收敛，T14–T16 管理协议仍是 `OPEN_SPEC_GAP`。**

### 0. 本轮开始时的真实状态（必须先承认）

接手时工作树**是坏的**，不是上一节所写的"50/50 PASS"：上一轮（13:16–13:19）把 `rx_cfg_mem`
改成 BRAM 后**没有跑完验证就中断**（`continue2/dbg_t08f.do` 停在调试态）。实测 13:22 的
`sim/out/regress.csv`：**T01 / T08f / T08fg / T22 / T22g 五项 FAIL**
（`T01 [err] RX CFG readback 00000000`、`T08f errors=8191`、`T22 [err] RX_VL_CFG readback`）。
原件备份在 `backup/continue2_20250925/out/arena-debug/regress_pre_continue2fix.csv`。

**根因**：`rtl/top/AFDX_top.v` 把 `rdata_r` 在 `rx_hit` 时改成常 0 并新增 `rxc_rd_d/rxc_host_rdata`，
但 `assign host_rdata` 的选择器**漏接了 `rxc_host_rdata`**。属接线遗漏，不是工具限制。
**修复**：在 `host_rdata` 选择器最前插入 `rxc_rd_d ? rxc_host_rdata :`（地址域互斥，不改其他读路径优先级）。

### 1. 本轮结果总表

| 项目 | 本轮实际结果 | 判定 |
|---|---|---|
| **顶层 eLinx 综合** | `AFDX_top_synth.ys` **rc=0**／177 s／`^ERROR`=0／`^Warning`=0／`Yosys execute success!`／473,423 cells；`AFDX_top_synth_bram.ys`（新增 BRAM 映射流程）**rc=0**／130 s／0 ERROR／**47,041 cells 含 439 `altsyncram`**／导出网表 `AFDX_top_bram_netlist.v` 49,126,317 B。两次均为 24 模块完整层次，无 blackbox。 | **DONE** |
| **STA** | 本机 eLinx 捆绑完整 Quartus II 13.0.1（Passkey），已装 **Stratix IV**。新建真实工程 `elinx/prj/quartus/AFDX_top.q{pf,sf}`、revision `AFDX_top`、器件 **EP4SGX230HF35C2**。`quartus_map` **rc=0**（12:10，0 errors/66 warnings，139,607 logic cells、731 RAM segments、73 in/123 out pins）；`quartus_sta` post-map **rc=0**：**Fmax 42.56 MHz**、**Setup WNS −15.498 ns / TNS −567,451.740 ns**、Hold WNS −0.128 ns / TNS −35.706 ns、关键路径 `rst_sync:u_rstsync\|r[2] → rx_port_buf:u_rxpb\|p_cnt~508`（数据延时 22.975 ns、时钟不确定度 0.450 ns）。**这组数字是第三次运行才拿到的**：头两次分别因 `.sdc` 文件缺失（Quartus 静默退回默认 1 ns 时钟）与 Quartus/Synopsys 约束语法差异而作废，错误报告归档在 `continue2/sta/default_1ns_no_sdc/`，经过见 `continue2/STA.md` §3。 | **MEASURED_NOT_MET**（125 MHz **不收敛**，非 BLOCKED） |
| **功能回归（变更后复验）** | RTL 本轮真改过，旧 50/50 结论不适用，故**必须**重跑：`sim/run_regress.ps1` 全量 **rc=0**、**50/50 PASS**、335 s、manifest 50 项、编译 0 errors。先行定向 8 项（T01,T08b,T08c,T08f,T08fg,T22,T22g,T22a）也 **8/8 PASS**。 | **DONE** |
| **覆盖率** | 在**改造后**的 RTL 上重采：50 个 UCDB、`vcover merge` **rc=0**、`vcover report` **rc=0**（Errors 0/Warnings 0）。1440 instances：分支 36788/58849=**62.51%**、语句 65555/89642=**73.12%**、total **67.82%**。**含 TB 实例，仅分支+语句，非 RTL-only、非功能覆盖率、非认证指标。** | **DONE_PARTIAL** |
| **门禁** | `tools_lint.ps1` **rc=0**、`LINT GATE: PASS (all gates 0 %Error)`；`python tools/run_all.py --strict` **rc=0**、5/5 + selfcheck。 | **DONE** |
| **管理面 T14–T16** | `snmp_lite.v`(7 行)/`a615a_tftp.v`(6)/`rtc_sync.v`(6)/`stats_regs.v`(7) 均为**无端口空壳**，在 `AFDX_top.v` 中引用数 **0**，manifest 中 T14/T15/T16 **各 0 条**，无书面豁免。 | **OPEN_SPEC_GAP**（不是 DONE，也不是 OUT_OF_SCOPE） |

### 2. 综合为什么能通过（根因与修复，不是碰运气）

二分实验证明决定变量是 **`NUM_RX_VL`** 而非 `NUM_PORTS`（全部子模块 blackbox，只留顶层自身）：
`iso_top_only`（4096）→ `ERROR: bad allocation`；`iso_top_rxvl64`（64）→ **rc=0**；
`iso_top_ports16`（NUM_PORTS=16、RX_VL 不变）→ 300 s 超时仍卡在 `OPT_MUXTREE`。
被压垮的是顶层 `rx_cfg_mem [0:2*NUM_RX_VL-1]`（8192×32 bit）**6 个组合读口**。
修复为 6 个 `bram_1w1r` 同步读副本（流水读口用 `RD_NEG=1` 负沿读，**逐拍等价、无额外气泡**；
主机读口正沿读、ACK 拍直出），PMEM 的 byte-enable 按 lane 拆成 4 个整字写体。
**没有删功能、没有缩地址空间、没有屏蔽错误换通过**——证据是同一份 RTL 跑出 50/50 PASS。
详见 `continue2/SYNTH.md`。

### 3. 本轮**不能**宣称的事

- **不能说时序收敛**。post-map 已测 Fmax 42.56 MHz，距 125 MHz 差约 2.94 倍；且 post-map
  **不含布线延时**，真实结果只会更差。未跑 `quartus_fit`，**不是 sign-off**。
- **不能说器件资源占用 X%**。eLinx 侧只到通用 cell + `altsyncram`，无 LUT/ALM 映射与布局布线；
  Quartus 侧只到 Analysis & Synthesis，139,607 logic cells 是估计值，未经 Fit 验证能否装下。
- **不能说 IO 时序合格**。`.sdc` 故意不写 `set_input_delay/set_output_delay`（无板级预算），
  未约束端口：输入 71、输出 120。结论只覆盖寄存器到寄存器内部路径。
- **不能把覆盖率 67.82% 说成功能覆盖率**（含 TB、仅分支+语句、无 covergroup）。
- **不能说管理协议已交付**。

### 4. 本轮证据、备份与补丁

- 证据目录：`out/arena-debug/continue2/`
  —— `SYNTH.md`、`STA.md`、`COVERAGE.md`、`MANAGEMENT-SCOPE.md`、`COMMANDS.md`、
  `synth/`（.ys/.log/_rc.txt/网表）、`sta/`（.rpt/console/part_list）、
  `coverage/`（50 UCDB + full50.ucdb + merge/report 日志）、`sim/`、`gates/`、
  逐文件 SHA-256 清单 `SHA256SUMS.txt`（由 `make_sha256.ps1` 生成）。
- 关键原始件 SHA-256：
  `continue2/synth/top_after_rxcfg_bram.log` = `08AE03026CAAACBEBE039B53429D74D2FA33F5F6C20368D24B227B88D85819C9`；
  `continue2/synth/top_bram.log` = `EDC7AF03BE0B7D5C694BB32C46E613DF693A360C2568AE0F465922B86803B3C9`；
  `sim/out/regress.csv` = `367DF048C236D38AA710E5A736FF72D46FA84596AFA28B7D7CC90B3A96AEE07A`。
- 备份：`out/arena-debug/backup/continue2_20250925/`（改动前的 `AFDX_top.v`、`bram_sdp.v`、
  `.ys`、两份 doc、旧 `DIANSAI-REPORT.md`、旧 `fixes.patch`、失败态 `regress_pre_continue2fix.csv`）。
  **没有 commit/push/reset；未触碰 `competition_case/` 与凭据。**
- 补丁：本轮产出**两份**，均由 `continue2/make_fixes_patch.ps1` 用 `git diff --no-index`
  对「备份镜像树 / 当前文件」生成，头部写明各自基线，**只含源码/脚本/约束/文档**
  （不含日志、UCDB、49 MB 网表、`.rpt`、Quartus `db/` 等生成物）：
  1. `out/arena-debug/fixes.patch` —— **本轮改动**，基线 `backup/continue2_20250925/`（接手时状态，
     即 rx_cfg 已被上一轮改成 `bram_1w1r` 但主机回读仍坏、5 个 TB FAIL）。21 个文件。
  2. `out/arena-debug/continue2/continue2_full_rtl.patch` —— **完整 RTL 改造差异**，基线
     `backup/continue_20250925/session_20260925_0432/`（改造前，9 处 `rx_cfg_mem`、0 个 `bram_1w1r`）。
     3 个文件，这份才是"顶层综合由 FAIL 变 rc=0"的完整代码依据。
  - **两份补丁都做过回放校验**：把补丁 `git apply` 到各自基线的副本上，再与当前树逐字节比对，
    `git_apply_rc=0` 且 `byte_identical=0`，记录见 `continue2/patch_verify.log`。
    回滚用 `git apply -R <patch>`，回到的是**对应基线**，不是仓库 HEAD。
  - 校验过程中发现并规避了两个会导致"假通过"的陷阱：`git apply` 在仓库子目录内运行会
    **静默跳过**该子目录外的路径（校验目录已移到仓库外）；`doc/*.md` 混合 UTF-8 与历史 GBK
    字节，按文本 UTF-8 往返会损坏补丁（改为字节级处理）。
- 未并行运行 Questa 与 eLinx/Quartus；每次运行前检查无 `vsim/vopt/vlog` 残留。

### 5. 下一步（按工程收益排序，均为可执行动作）

1. **时序**：`rst_sync` 复位扇出分级/流水化；`rx_port_buf` 256 端口计数器组分银行；
   顶层 19,019 个 `$eq` 比较链打拍。改完重跑 post-map STA 看 Fmax 是否越过 125 MHz。
2. **Fit**：时序接近目标后再跑 `quartus_fit` + post-fit setup/hold STA，才谈 sign-off。
3. **管理面**：按 `continue2/MANAGEMENT-SCOPE.md` §5 的最小可验收定义实现 T14–T16 并入 manifest。

---

## MISSION-CONTINUE — 2026-09-25 收口结论（已被上节取代，保留存档）

> **本节优先于下方所有历史 FINALIZE / MISSION-FIX 快照。整机仍未完成：综合 BLOCKED_TOOL，STA 无有效数据，完整管理协议未交付。** 本轮没有把已有 tx_rm 修复冒充新修改，没有改变 RTL/TB 功能。

| 项目 | 本轮实际结果 |
|---|---|
| 全量代码覆盖率 | **DONE：50/50 PASS、50 个 UCDB**；`+cover=sb`、`vsim -coverage`，merge/report rc=0；1083 instances、含 TB：分支 35798/57608=62.14%，语句 64040/86985=73.62%，工具 total=67.88%。不是 RTL-only/功能覆盖率/认证，不与旧四例分母混比。 |
| 最终普通功能回归 | **DONE：50/50 PASS**，rc=0，耗时 329.98s；manifest/CSV 同序、50 份 console、编译 0 errors；与覆盖率回归分别留档。 |
| 最终 lint / 严格文档门 | **DONE**：lint rc=0、0 `%Error`；`tools/run_all.py --strict` rc=0。最终文档修改后再次执行文档门，见 `post_docs_docgate.log` / `post_docs_docgate_rc.txt`。 |
| 原综合故障定位 | 旧 tx_rm 的 exp_q/vl_q 循环复位数组独立复现 invalid vector，rc=1；当前 packed 版本独立 rc=0/554 generic cells，属于上轮已修复项，本轮复验。 |
| 当前顶层综合 | **BLOCKED_TOOL**：原流程 rc=1/bad allocation；opt -fast 和现有显式 BRAM 映射尝试同样 rc=1。只映射 AFDX_top 存储的隔离探针在 OPT_EXPR 访问异常 0xC0000005；工具确认为 32 位。没有完整成功网表/器件资源摘要。 |
| STA | **BLOCKED_NO_REVISION_OR_TIMING_NETLIST**：TimeQuest 实跑 rc=3、Can't find active revision。现有 8ns 最小内部约束已核对，未伪造 IO delay。WNS/TNS/Fmax/关键路径 N/A；没有证据证明许可证缺失。 |
| 管理面 | **OUT_OF_SCOPE_FINALIZE / OPEN_SPEC_GAP**：三个 mgmt 模块和 `rtl/top/stats_regs.v` 都是未例化空壳；**纠正旧报告 stats_regs 缺失的错误**。T14–T16 不在 manifest，没有正式需求豁免，整机要求仍开放。 |

### 本轮证据、备份与补丁

- 新证据：`out/arena-debug/continue/session_20260925_0432/`。`commands.jsonl` 保存命令、cwd、实际子进程 rc、耗时及原始日志 SHA-256；`acceptance_audit.json` 独立核对 CSV/manifest/原始失败行；`source_binding.json` 证明本轮 RTL/TB 与修改前备份字节一致。
- 综合详情 `SYNTH-STA.md`；覆盖率详情 `COVERAGE.md`；管理范围 `MANAGEMENT-SCOPE.md`；操作/辅助失败记录 `OPERATIONS.md`。无效 rx_cfg_isolate 探针明确作废，未作为 PASS 证据。原始所有失败日志完整保留。
- 备份：`out/arena-debug/backup/continue_20250925/session_20260925_0432/`（父目录拼写遵从 MISSION；实际日期 2026-09-25）。没有 commit/push/reset；未触碰 competition_case 或凭据。
- `out/arena-debug/fixes.patch` **仅本轮文档与新增可复现脚本**，相对上述备份生成，不混入先前 RTL 修改；旧补丁保存在备份。`patch_verify.log` 记录反向只检查、隔离备份正向应用与逐字节相等检查；不对当前工作树实际回滚。
- finalize 入口 `out/arena-debug/finalize/CONTINUE-20260925.md`；本轮哈希表 `continue/session_20260925_0432/SHA256SUMS.txt` 与 `finalize/CONTINUE-20260925-SHA256SUMS.txt`。旧 finalize 哈希表与旧证据不覆盖。

下一步：对顶层多组合读口配置存储做有行为验证的分银行/寄存握手或适配受支持综合器，完成同参数网表和器件项目再 STA；完整管理协议须实现+TB 或正式豁免。不能用本轮 50/50 或覆盖率替代这些未完成项。

---


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
