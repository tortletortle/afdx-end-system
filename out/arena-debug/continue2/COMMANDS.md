# continue2 — 完整命令清单、退出码与耗时

本文件列出本轮**实际执行过**的每一条命令。所有 shell 均为 Windows PowerShell 5.1，
工作目录统一为 `C:\Workspace\diansai`（PowerShell 不支持 `&&`，命令前需 `Set-Location`）。
耗时来源：运行器脚本写入的 `*_rc.txt`，或 Quartus 日志里的 `Info: Elapsed time`。
未在此列出的命令都是只读查询（`Get-ChildItem` / `Select-String` / `Get-FileHash`），不改变状态。

## 0. 总表

| # | 步骤 | rc | 耗时 | 证据 |
|---|---|---|---|---|
| 1 | 改前备份 | 0 | <1 s | `backup/continue2_20250925/` |
| 2 | RTL 修复 `host_rdata` mux | — | — | `AFDX_top.v` +10/-4 |
| 3 | 定向回归（8 TB） | **0** | 86 s | `continue2/sim/fix1_targeted_rc.txt` |
| 4 | eLinx 顶层综合（generic） | **0** | 177 s | `continue2/synth/top_after_rxcfg_bram_rc.txt` |
| 5 | eLinx 顶层综合（器件 BRAM） | **0** | 130 s | `continue2/synth/top_bram_rc.txt` |
| 6 | Quartus 器件列表查询 | 0 | 2 s | `continue2/sta/part_list.txt` |
| 7 | 建 Quartus revision | **0** | 1 s | `continue2/sta/mk_project.log` |
| 8 | `quartus_map`（Analysis & Synthesis） | **0** | **730 s** | `continue2/sta/qmap_console.log` |
| 9a | post-map TimeQuest（**作废**：`.sdc` 缺失，默认 1 ns 时钟） | 0 | 55+115 s | `continue2/sta/default_1ns_no_sdc/` |
| 9b | post-map TimeQuest（**作废**：Quartus 约束语法错误） | **3** | 11+11 s | 见 §6 说明 |
| 9 | post-map TimeQuest 主报告（有效） | **0** | 57 s | `continue2/sta/sta_post_map_console.log` |
| 10 | post-map TimeQuest 摘要/关键路径（有效） | **0** | 118 s | `continue2/sta/sta_summary_console.log` |
| 11 | 全量功能回归 50/50（改造后 RTL） | **0** | 335 s | `continue2/sim/full50_after_fix_rc.txt` |
| 12 | 覆盖率重采（50 用例带 coverage） | **0** | 378 s | `continue2/coverage/run_full_cov_rc.txt` |
| 13 | `vcover merge` + `report` | **0 / 0** | ~2 s | `continue2/coverage/vcover_rc.txt` |
| 14 | lint 门禁 | **0** | 40 s | `continue2/gates/lint.log` |
| 15 | docgate `run_all.py --strict` | **0** | 6 s | `continue2/gates/docgate.log` |
| 16 | 生成并自校验补丁 | 0 | 3 s | `continue2/patch_verify.log` |
| 17 | 生成 SHA-256 清单 | 0 | 20 s | `continue2/SHA256SUMS.txt` |

## 1. 备份（改动前，强制）

备份根目录：`out/arena-debug/backup/continue2_20250925/`。**实际清单**（44 个文件）：

- `rtl/**` — 完整 24 个 RTL 源文件（含 `rtl/top/AFDX_top.v`、`rtl/common/bram_sdp.v`）
- `elinx/prj/AFDX_top_synth.ys`
- `doc/当前进度_20260923.md`、`doc/后续计划.md`
- `out/arena-debug/DIANSAI-REPORT.md`、`out/arena-debug/fixes.patch`
- `out/arena-debug/regress_pre_continue2fix.csv` — **修复前的失败态回归结果**（5 项 FAIL 的证据）
- 根目录下另有上一轮中断会话留下的副本（`AFDX_top_synth.ys`、`DIANSAI-REPORT.md`、
  `fixes.patch`、`当前进度_20260923.md`、4 个 `tb_*.v`），本轮未删除，原样保留。

> 注意：`backup/continue2_20250925/rtl/top/AFDX_top.v` 是**上一轮 BRAM 改造之后、本轮修复之前**
> 的状态（含 6 个 `bram_1w1r`）。BRAM 改造**之前**的 RTL 在
> `backup/continue_20250925/session_20260925_0432/rtl/`（含 9 处 `rx_cfg_mem`、0 个 `bram_1w1r`）。
> 两个基线分别对应下文第 16 步生成的两份补丁。

## 2. RTL 修复

通过 MCP `apply_patch` 编辑 `rtl/top/AFDX_top.v`（+10/-4，`host_rdata` mux 补回 `rxc_rd_d` 分支）。

- 改前 sha256：见 `backup/continue2_20250925/` 同目录清单
- 改后 sha256：`F975BDC6BF9B672DE250CF119346BFB2C30A7B3927AA5DF3CF130F47CA95BB6D`
- 等价补丁：`out/arena-debug/fixes.patch`（本轮）与 `continue2/continue2_full_rtl.patch`（含上一轮 BRAM 改造的完整 RTL 差异）

## 3. 定向回归（先于全量，快速证伪）

```powershell
Set-Location C:\Workspace\diansai\sim
powershell -NoProfile -ExecutionPolicy Bypass -File .\run_regress.ps1 -Tests T01,T08b,T08c,T08f,T08fg,T22,T22g,T22a
# rc=0, elapsed_s=86, "REGRESS SUMMARY: 8/8 pass, wall_s=85.6"
# 这 8 项覆盖修复前失败的 T01/T08f/T08fg 及其相邻的主机接口/顶层通路用例
# 日志 out/arena-debug/continue2/sim/fix1_targeted.log
```

## 4–5. eLinx 顶层综合（**目标 1**）

运行器 `continue2/synth/run_syn.ps1` 固定记录 rc / 耗时 / ERROR 行数 / 成功横幅 / 日志 SHA256。
被调用的可执行文件：`C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe -s <ys> -l <log>`

```powershell
Set-Location C:\Workspace\diansai
# 5-1 generic 流程（沿用原 .ys，未改）
powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue2/synth/run_syn.ps1 `
  -Ys elinx/prj/AFDX_top_synth.ys -Name top_after_rxcfg_bram -TimeoutS 900
# -> exit_code=0 elapsed_s=177 error_lines=0 success_banner=1
#    log_sha256=08AE03026CAAACBEBE039B53429D74D2FA33F5F6C20368D24B227B88D85819C9

# 5-2 器件级 BRAM 流程（本轮新建 .ys，映射到 altsyncram 并导出网表）
powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue2/synth/run_syn.ps1 `
  -Ys elinx/prj/AFDX_top_synth_bram.ys -Name top_bram -TimeoutS 900
# -> exit_code=0 elapsed_s=130 error_lines=0 success_banner=1
#    log_sha256=EDC7AF03BE0B7D5C694BB32C46E613DF693A360C2568AE0F465922B86803B3C9
#    网表 out/arena-debug/continue2/synth/AFDX_top_bram_netlist.v = 49,126,317 B
```

## 6–10. Quartus / TimeQuest（**目标 2**）

后端可执行文件目录：`C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/`（Quartus II 13.0.1 64-Bit）。
**所有多语句 Tcl 必须写成 `.tcl` 文件用 `-t` 调用**：`quartus_sh --tcl_eval` 只接受单条简单命令。

```powershell
Set-Location C:\Workspace\diansai
$Q = "C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin"

# 6 列出该安装实际支持的器件（确认 Stratix IV 可用，避免拍脑袋选型）
& "$Q/quartus_sh.exe" -t out/arena-debug/continue2/sta/list_parts.tcl > out/arena-debug/continue2/sta/part_list.txt

# 7 建 revision：EP4SGX230HF35C2 / TOP=AFDX_top / 24 个 VERILOG_FILE / SDC_FILE
Set-Location C:\Workspace\diansai\elinx\prj\quartus
& "$Q/quartus_sh.exe" -t mk_project.tcl            # rc=0

# 8 Analysis & Synthesis
& "$Q/quartus_map.exe" AFDX_top -c AFDX_top        # rc=0, Elapsed 00:12:10, CPU 00:21:56

# 9 post-map 时序分析（setup/hold/fmax/clocks/sdc/unconstrained 报告）
& "$Q/quartus_sta.exe" -t sta_post_map.tcl         # rc=0, 57 s

# 10 摘要 + 关键路径明细
& "$Q/quartus_sta.exe" -t sta_summary.tcl          # rc=0, 118 s
```

### 9/10 一共跑了三轮，前两轮作废——必须照抄的教训

```powershell
# 第 1 轮：.qsf 里写了 SDC_FILE，但 elinx/sdc/AFDX_top.sdc 文件根本不在磁盘上。
#          Quartus 不报错，静默使用默认 1 ns 时钟；rc=0，数字全错。
#          发现方式：post_map_sdc.rpt 里 create_clock 周期是 1.000 而不是 8.000。
#          作废报告已归档：out/arena-debug/continue2/sta/default_1ns_no_sdc/（9 个文件）

# 第 2 轮：补出 .sdc，但沿用 .edc 的 Synopsys 写法 ->
#          "set_clock_uncertainty 0.45 [get_clocks clk]" 被 TimeQuest 拒绝，
#          Critical Warning (332008) + Error (23031)，rc=3。

# 第 3 轮（有效）：改成 Quartus 语法后 rc=0
#   create_clock -name clk -period 8.000 [get_ports clk]
#   set_clock_uncertainty -setup -from [get_clocks clk] -to [get_clocks clk] 0.45
#   set_clock_uncertainty -hold  -from [get_clocks clk] -to [get_clocks clk] 0.45
#   set_false_path -from [get_ports pps_in]
# 注：set_clock_transition 是 Synopsys DC 命令，TimeQuest 无对应，只保留在 .edc。

# 验收任何 TimeQuest 结果前，先执行这一条自检：
Select-String out/arena-debug/continue2/sta/post_map_sdc.rpt -Pattern "create_clock"
# 必须看到 period = 8.000，否则所有 slack 数字无效。
```

> `quartus_fit`（布局布线）**本轮未执行**，因此所有时序数字都是 **post-map 乐观上界**，不是 sign-off。

## 11. 全量功能回归（改造后 RTL）

```powershell
Set-Location C:\Workspace\diansai
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_regress.ps1
# rc=0, 335 s, compile 0 error, 50/50 PASS
# sim/out/regress.csv sha256=367DF048C236D38AA710E5A736FF72D46FA84596AFA28B7D7CC90B3A96AEE07A
```

## 12–13. 覆盖率（**目标 3**）

```powershell
Set-Location C:\Workspace\diansai
# 12 在新 RTL 上重采 50 个用例（每例一个 UCDB）；不含 merge
powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue2/coverage/run_full_cov.ps1
# rc=0, 378 s, 生成 50 个 *.ucdb

# 13 合并 + 摘要（上一轮缺失的一步）
Set-Location C:\Workspace\diansai\out\arena-debug\continue2\coverage
$u = (Get-ChildItem *.ucdb | Where-Object { $_.Name -ne "full50.ucdb" }).Name
& C:/altera_pro/26.1.1/questa_fse/win64/vcover.exe merge -out full50.ucdb @u   # rc=0
& C:/altera_pro/26.1.1/questa_fse/win64/vcover.exe report -summary full50.ucdb > merged_summary.txt  # rc=0
# -> 1440 instances / branches 36788-58849 62.51% / statements 65555-89642 73.12% / total 67.82%
```

## 14–15. 门禁（串行，Questa 与 eLinx 不并行）

```powershell
Set-Location C:\Workspace\diansai
powershell -NoProfile -ExecutionPolicy Bypass -File ./tools_lint.ps1   # rc=0 -> "LINT GATE: PASS (all gates 0 %Error)"
python tools/run_all.py --strict                                       # rc=0 -> 5/5
```

## 16–17. 补丁与校验清单

```powershell
Set-Location C:\Workspace\diansai
powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue2/make_fixes_patch.ps1
# -> out/arena-debug/fixes.patch                      （本轮改动，基线 backup/continue2_20250925）
# -> out/arena-debug/continue2/continue2_full_rtl.patch（完整 RTL 改造，基线 backup/continue_20250925/session_20260925_0432）
# 两份补丁均经过 git apply 回放 + 与目标树逐字节比对（rc 记录在 continue2/patch_verify.log）

powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue2/make_sha256.ps1
# -> out/arena-debug/continue2/SHA256SUMS.txt
```

## 附：本轮踩过的工具坑（供复现者避让）

1. `quartus_sh --tcl_eval` 不支持 `foreach`/多语句 → 一律 `.tcl` 文件 + `-t`。
2. TimeQuest `get_timing_paths -less_than_slack 1e9` 是非法参数，会让整个脚本 rc=3；
   改用 `get_timing_paths -setup -npaths N` + `foreach_in_collection` + `get_path_info -slack`。
3. 上一轮 `create_timing_netlist` 报 `Can't find active revision`，根因是**没有 Quartus 工程**，
   不是工具缺陷；建出 revision 后即可。
4. PowerShell 的 `>` 会把输出重编码成 UTF-16；生成二进制/混合编码文本（如补丁）必须
   用 `cmd /c "... > file"` 或 `[IO.File]::WriteAllBytes`。
5. `git apply` 在仓库子目录里运行时会**静默跳过**该子目录之外的补丁路径，
   校验目录必须放到仓库之外（本脚本用 `$env:TEMP`），否则校验会假通过。
6. 本仓库 `doc/*.md` 混合 UTF-8（新增段）与历史 GBK 字节，任何按 UTF-8 的文本
   往返都会损坏它们；补丁生成走字节级（ISO-8859-1 无损映射）处理。
7. `.ps1` 脚本保持纯 ASCII：PS 5.1 会把无 BOM 的 UTF-8 脚本按 GBK 解析。
