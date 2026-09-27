# Continue3：8 ns post-map STA 证据守卫与复位优化的负结果

**结论（2026-09-25）**：125 MHz **仍未达标**。实测的 RX 复位复制候选使时序退化，已从实际 RTL **逐字节回滚**；最终保留的是正式 TimeQuest 脚本的最小证据改进：只有在 `report_sdc` 确认实际 `clk` 周期为 **8.000 ns** 后才允许生成 setup/Fmax 报告，否则 `error` 中止。正例实际执行 Quartus STA，反例用历史真实 1 ns 报告执行同一生产守卫逻辑；**不宣称整机 PASS 或新的时序优化**。

## 1. 范围与选择依据

已阅读 `../DIANSAI-REPORT.md`、`../REVIEW-REPORT.md`、`../continue2/SYNTH.md`、`../continue2/STA.md`。125 MHz 对应 8.000 ns SDC；先前 `continue2` 同器件 **EP4SGX230HF35C2** 的 post-map 实测 Fmax 42.56 MHz、setup WNS −15.498 ns，最差路径起点 `rst_sync:u_rstsync|r[2]`。本轮先尝试局部复制该复位以减扇出；在重跑 lint、仿真、综合、Quartus map 和 TimeQuest 后，发现**更慢**（第 3 节），遂否决并回滚。转而修复可独立核验的 STA **证据缺口**：原正式 `elinx/prj/quartus/sta_post_map.tcl` 把 `report_sdc` 放在 `report_timing` 和 Fmax **之后**；历史真实的 `../continue2/sta/default_1ns_no_sdc/post_map_sdc.rpt` 表明缺失约束时工具可能按默认 **1.000 ns** 出报告，若不验证约束即可能误引时序数据。

## 2. 最终保留的改动及验证

| 项目 | 事实与证据 |
|---|---|
| 正式脚本 | `elinx/prj/quartus/sta_post_map.tcl`：在任何 setup/Fmax 报告前先生成 `post_map_sdc.rpt` 并调用 `check_sdc_8ns`；不匹配即 Tcl `error`。可通过 `DIANSAI_STA_OUT` 把本轮输出定向到 `continue3/raw/guarded/`，默认输出路径保持原值。 |
| 守卫函数 | 新增 `elinx/prj/quartus/check_sdc_8ns.tcl`，读取**工具实际报告**中的 `create_clock; clk; 8.000;` 行；没有此行（包括默认 1 ns）即报 `SDC_GUARD_FAILED`。只核查时钟周期，**不**声称检查了完整 IO、uncertainty 或所有 SDC 项。 |
| 正例：正式 STA 脚本 | 在已存在的**被否决候选 post-map 网表**上，`quartus_sta -t C:/Workspace/diansai/elinx/prj/quartus/sta_post_map.tcl`，子进程 rc=0、58.2 s；`raw/sta_guard.stdout.log` 有 `SDC_GUARD_OK: clk=8.000 ns` 和 `POST_MAP_STA_DONE`；`raw/guarded/post_map_sdc.rpt` 确实显示 8.000 ns，setup/Fmax 报告生成。**不是回滚后 RTL 的重新测量。** |
| 反例：共用生产函数 | `quartus_sh -t guard_selftest.tcl`，子进程 rc=0、0.6 s；在同一 `check_sdc_8ns` 函数中，正例 8 ns 被接受，历史**真实报告** 1 ns 的异常被 `catch` 捕获并按预期拒绝，见 `raw/guard_selftest.stdout.log`。这是报告夹具测试，**不是**本轮重跑无 SDC 的完整 STA。 |
| 补丁及回退 | 最终 `fixes.patch` **只涉及这两个 STA Tcl 文件**（SHA-256 `1a69fe66a9d30fb5764850004c92c52928127669902c5afdfe8f586dde804e75`）。`raw/final_patch_verify.log` 有隔离目录正向/反向 `git apply --check` 及实际回放 rc=0；正向两文件逐字节一致，反向旧脚本逐字节恢复、新 helper 被删除。**没有** git commit/push/reset。 |

正式脚本修改前的备份：`backup/elinx/prj/quartus/sta_post_map.tcl`，SHA-256 `a630b96074817e607b14fda0c678eea397d58c82b9567a83ec8f627903124a00`。新 helper 在修改前不存在；验证时所用正式脚本/helper 与最终版本哈希一致，见 `RESULTS.json`。检测只避免错误周期冒充 8 ns；未消除现有负 slack、缺失 IO 延迟或约束来源配置问题。

## 3. 被否决的复位复制实验（**非最终源码**）

改动前备份 `backup/rtl/common/rst_sync.v` SHA-256 `c0829708816348af8e0a510277231feee45389aae788de711e96a46c00cfc53e`；`backup/rtl/top/AFDX_top.v` SHA-256 `f975bdc6bf9b672de250cf119346bfb2c30a7b3927aa5df3cf130f47ca95bb6d`。候选令 RX 主机操作路径使用与原同步器末级同拍采样的 `(* preserve *) r_rxpb` 副本；这种 RTL 逐拍关系也不等于 CDC、极端亚稳态或物理复位释放签核。

| **相同 8.000 ns SDC、相同器件、post-map（非 post-fit）** | continue2 基线 | 本轮被否决候选 | 变化 |
|---|---:|---:|---:|
| Fmax | 42.56 MHz | **41.49 MHz** | **−1.07 MHz** |
| Setup WNS | −15.498 ns | **−16.103 ns** | **−0.605 ns** |
| Setup endpoint TNS | −567451.740 ns | −639993.268 ns | 更差 |
| 最差路径数据延迟 | 22.975 ns | 23.580 ns | 更差 |

最差起点两者均为 `rst_sync:u_rstsync|r[2]`；基线终点 `rx_port_buf:u_rxpb|p_cnt~508`，候选终点 `rx_port_buf:u_rxpb|p_pin[127]`。候选未消除关键复位路径，**两个测量都不满足 125 MHz**。基线来源 `../continue2/sta/`；本轮原始数据 `raw/post_map_setup.rpt`、`raw/post_map_setup_summary.rpt`、`raw/post_map_fmax.rpt`、`raw/post_map_sdc.rpt`；机读对照 `RESULTS-timing-attempt.json`（13 项证据检查均 true，但不代表设计 PASS）。测试前 `raw/input_binding.log` 核对隔离工程 24/24 RTL 与**当时的候选源文件**、SDC 一致；**不可**将它当作回滚后 RTL 的输入绑定证明。

候选相关实际工具结果（均有 `COMMANDS.jsonl` 和 `raw/<stage>.stdout.log`、`.stderr.log`、`.rc`）：Verilator 两次 lint rc=0（顶层 26 条 warning、定向 TB 3 条 warning）；Questa 编译 0 errors/0 warnings，复位同拍 TB、T01 冷启动、T11 两档端口主机操作共 **4 个定向仿真**分别 rc=0 且有预期 PASS 行；eLinx 全层次通用综合 rc=0、473429 generic cells；Quartus map rc=0、964.2 s；原隔离 TimeQuest post-map rc=0、71 s，8 ns SDC 守卫通过。**这些是被否决候选的局部验证，不是当前回滚后 RTL 的重跑，更不是原 50 项整机回归。**

该实验补丁单独保存在 `timing_attempt.patch`（不应当成最终 `fixes.patch`）；实测否决后在真实工作树执行 `git apply --reverse --check`、`git apply --reverse` 均 rc=0，`raw/live_rollback.log` 证明两份 RTL 与改前备份 **2/2 逐字节相同**。未对回滚后的 RTL 再做 map/STA，因此不能说本轮重新测得最终源码的 Fmax；现可引用的 42.56 MHz 是既有 `continue2` 基线。

## 4. 边界、证据与操作记录

- 后综合、未布局布线的 TimeQuest 数字**不是最终 setup/hold 签核**；外部 IO 延迟约束不完整，也没有板级收敛证据。管理面 T14–T16 等既有 `OPEN_SPEC_GAP` 未由本轮关闭；125 MHz 瓶颈仍需结构性改动和 post-fit 实测。
- `RESULTS.json` 只表示**最终补丁及证据完整性**的 13 项审计，不表示时序闭合。`RESULTS-timing-attempt.json` 记录失败实验的测量和局部工具检查。`SOURCE_SHA256.txt`、`raw/input_binding.log` 指向候选网表快照；避免与已回滚的当前 RTL 混用。
- 原始 stdout/stderr/返回码及完整综合/STA 报告在 `raw/`；Quartus map `.map.rpt/.map.summary` 已复制到 `raw/` 再删隔离 DB、Questa work 库，见 `raw/cleanup.log`。补丁重放证据见 `raw/patch_verify.log`（候选）、`raw/final_patch_verify.log`（最终）。工具/许可证**没有**导致本轮测试失败；首次辅助文件创建时父目录不存在的 MCP 预检失败保留在 `raw/setup_patch_failure.log`，补建目录后成功。一次备份路径引号错误曾产生临时目录，已移到正确备份目录并核验、删除临时目录，见 `COMMANDS.md`。
- 完整实际命令、环境输出目录、阶段退出码见 `COMMANDS.md`、`COMMANDS.jsonl`；`SHA256SUMS.txt` 是清理后所有保留产物（不含清单自身）的逐文件摘要。未读取受禁文件或触碰受禁目录；未执行 git commit/push/reset。
