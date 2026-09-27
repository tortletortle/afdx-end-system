# continue4 —— 命令记录（2026-09-26）

所有 PowerShell 调用都在脚本首行显式 `Set-Location C:\Workspace\diansai`（bridge 的
`run_command` 不接受 `cwd` 参数，见下方「踩过的坑」）。全程**没有**执行
`git commit` / `git push` / `git reset`；`git show HEAD:<file>` 与 `git status` 只读。
`competition_case/`、`data/`、`logs/` 三个目录全程未访问。

## 0. 连接与勘察

| # | 动作 | 结果 |
|---|---|---|
| 1 | MCP `initialize` + `notifications/initialized` + `tools/list` | session `abee3ef8-…`，bridge v0.7.2-local，10 个工具 |
| 2 | `read_files` `out/arena-debug/MISSION-CONTINUE4.md` | 37 行，sha256 `3470f6b0…147d` |
| 3 | `read_files` continue2/MANAGEMENT-SCOPE.md §5、continue3/{REPORT,STATUS}.md | 取得 T14/T15/T16 的最小可验收定义与 P0 时序基线 |
| 4 | `read_files` 设计书 §7.14~§7.18 + 附录 A（754-875、1278-1360 行） | 取得寄存器/端口定义 |
| 5 | `read_files` `rtl/top/AFDX_top.v` 全文（1033 行，分 5 段） | 取得集成锚点 |
| 6 | `run_command` 探测工具链 | vsim / quartus(eLinx Passkey) / verilator(eLinx) / python 均可用 |

## 1. 备份（改源码前，纪律要求）

```powershell
Set-Location C:\Workspace\diansai
# 7 个待改文件 → out/arena-debug/continue4/backup/{rtl,sim}/，逐个打印 SHA256
# sim/out/* 181 个文件 → backup/sim_out_before/
```
后续发现还要改 `rtl/common/timebase.v` 与 `elinx/prj/AFDX_top_synth.ys`，
同样**先备份**到 `backup/rtl/common/`、`backup/elinx/prj/` 再改。

`rtl/mgmt/mgmt_sap_rx.v` 与 `tools_lint.ps1` 这两个文件**漏做了本轮现场备份**
（如实登记）；`fixes.patch` 对它们以 `git HEAD` 版本为基线，脚本
`tools/mkpatch.py` 会把这一点打印到补丁头部。

## 2. 基线回归（改动前）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim\run_regress.ps1 `
  *> out\arena-debug\continue4\raw\regress_baseline.log
```
→ **50/50 PASS，wall 285.6 s**（最慢 T01 57.1 s）。

## 3. 源码改动（全部经 MCP `apply_patch`）

| 文件 | 性质 | 摘要 |
|---|---|---|
| `rtl/top/stats_regs.v` | 空壳 9 行 → 309 行 | 全局统计页实现 |
| `rtl/mgmt/snmp_lite.v` | 空壳 9 行 → 566 行 | SNMP v1/v2c GET/GETNEXT/SET |
| `rtl/mgmt/a615a_tftp.v` | 空壳 9 行 → 360 行 | A615-A TFTP 引擎 |
| `rtl/mgmt/rtc_sync.v` | 空壳 9 行 → 133 行 | PPS / 报文对时 |
| `rtl/mgmt/mgmt_sap_rx.v` | 50 → 182 行 | 增加 PMEM 载荷取回 + 字节流分发 |
| `rtl/top/AFDX_top.v` | 1033 → 1300 行 | 例化四个模块、统计页读、MGMT 观测窗、TFTP 加载区、PPS/RTC 输出 |
| `rtl/common/timebase.v` | +5 行 | **修既有缺陷**：`tick_ctr` 无复位项 |
| `sim/tests.manifest` | 50 → 53 条 | 加 T14/T15/T16 |
| `sim/run_regress.ps1` | +12 行 | 登记 4 个新 RTL、加 T15/T16 向量生成 |
| `tools_lint.ps1` | +12 行 | 4 个新 RTL 进 `$rxmods`、3 条新 TB 进 gate 3 |
| `sim/tb/tb_t14_stats_regs.v` | 新增 336 行 | T14 |
| `sim/tb/tb_t15_snmp.v` | 新增 447 行 | T15 |
| `sim/tb/tb_t16_tftp_rtc.v` | 新增 492 行 | T16 |
| `sw/golden/gen_t15_vectors.py` | 新增 142 行 | T15/T16 真实管理帧生成器 |
| `elinx/prj/AFDX_top_synth.ys` | +4 行 | 综合脚本登记新模块 |

每次改完先做语法门：
```powershell
# out/arena-debug/continue4/syncheck.tcl + syn/ 隔离目录
"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe" -batch -do <syncheck.tcl>
# vlog -sv +notimingcheck <全部 27 个 RTL>  →  Errors: 0, Warnings: 0
```

## 4. 三道门（全部实跑）

```powershell
# (1) 全量回归（独占运行，未与任何别的 Questa 进程并行）
powershell -NoProfile -ExecutionPolicy Bypass -File sim\run_regress.ps1 `
  *> out\arena-debug\continue4\raw\regress_clean53.log
#    → 53/53 pass, wall_s=542；CSV 副本 raw/regress_clean53.csv

# (2) Verilator lint gate
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools_lint.ps1 `
  *> out\arena-debug\continue4\raw\lint.log
#    → rc=0, "LINT GATE: PASS (all gates 0 %Error)"

# (3) 文档/数字一致性
python tools\run_all.py --strict *> out\arena-debug\continue4\raw\run_all_strict.log
#    → rc=0, "5/5 全绿"
```

## 5. 目标 B：post-map STA 测量

```powershell
# 隔离工程：out/arena-debug/continue4/project/（qsf 从 continue3 复制后补登 4 个新 RTL）
Set-Location C:\Workspace\diansai\out\arena-debug\continue4\project
& "C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_map.exe" AFDX_top -c AFDX_top
& "C:\Program Files (x86)\eHiWay\eLinx3.0\bin\Passkey\bin\quartus_sta.exe" -t sta_continue4.tcl
# sta_continue4.tcl = continue3 的 sta_continue3.tcl，仅把输出目录改到 continue4/raw/sta；
# 其中的 8 ns SDC 守卫原样保留：post_map_sdc.rpt 不是 8.000 ns 就 fail-closed。
```

## 6. 交付物生成

```powershell
python out\arena-debug\continue4\tools\mkpatch.py      # → fixes.patch
python out\arena-debug\continue4\tools\make_results.py # → RESULTS.json
python out\arena-debug\continue4\tools\make_sha256.py  # → SHA256SUMS.txt（最后一步）
```

## 踩过的坑（供下一轮省时间）

1. bridge 的 `run_command` **`cwd` 参数无效**（传 `'.'` 仍落在 bridge 安装目录）→ 脚本首行必须 `Set-Location`。
2. bridge 的 `list_directory` 永远返回 bridge 安装目录；`find_files` 的 `exclude`/`no_ignore` 不生效且漏目录 → 目录勘察一律 `Get-ChildItem`。
3. `run_command` 前台有 **~120 s 上限**，长任务必须 `background=True` + `get_command_output` 轮询。
4. PowerShell `Get-Content` 读 UTF-8 中文源码会乱码（按 GBK 解）→ 看内容一律用 `read_files`，`Select-String` 必须带 `-Encoding UTF8`。
5. **Windows PowerShell 5.1 把无 BOM 脚本按 ANSI/GBK 解析**：往 `.ps1` 里加中文注释会让解析器在几十行之后报 `UnexpectedToken`。给 `.ps1` 加注释请用纯 ASCII。
6. PowerShell **数组字面量内部不能插注释行**，否则紧跟其后那一行的元素会被整行吃掉（`tools_lint.ps1` 的 `$rxmods` 上踩过，症状是 verilator 报 "Cannot find file containing module"）。
7. `-EncodedCommand` 的命令行长度有上限，用它写大文件会失败 → 大文件一律走 MCP `apply_patch`（`*** Add File:` / `*** Delete File:`）。
8. `apply_patch` 的 `*** Add File:` 要求**父目录已存在**，否则 `PATH_OUTSIDE_WORKSPACE`。


## Finalize amendment (2026-09-26)

- Read-only independent audit: retained RTL, manifest, raw gate logs, BASE/unprefixed STA and patch replay.
- Existing RTC pipeline candidate discovered; its existing background map/STA outputs completed during finalize. Rechecked both rc=0; post-map WNS=-15.723 ns, Fmax=42.15 MHz, TNS=-665200.142 ns. No RTL edits or gate reruns launched in finalize.
- Fixed mixed UTF-16 + ASCII log trailer parsing and regenerated RESULTS.json.
- Regenerated fixes.patch: 15 implementation/test/build inputs, including RTC candidate and synthesis script.
- Baseline correction: tools_lint.ps1 uses HEAD; mgmt_sap_rx.v is NOT in HEAD, so its patch is a full image only.
- tools/make_sha256.py now uses the same sorted per-file SHA-256 format but includes ALL retained files (including Quartus db/output_files and caches); only SHA256SUMS.txt itself is omitted.
- Final verification: python -B out/arena-debug/continue4/tools/finalize_verify.py
- Last writing step: python -B out/arena-debug/continue4/tools/make_sha256.py
- Read-only seal verification: python -B out/arena-debug/continue4/tools/finalize_verify.py --verify-seal
- This finalization does not run git commit/push/reset or access competition_case/, data/, logs/ or credentials.

- Pre-seal audit initially failed on changing STA outputs. After candidate completion, reread raw/map_cand.log, raw/sta_cand.log and post_map reports; results generator now keeps BASE and candidate measurements separate and checks report/log WNS agreement.
