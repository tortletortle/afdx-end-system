# elinx/ — eLinx 3.0.7 工作目录

## 2026-10-03 评阅包默认综合（优先看这里）

默认脚本 `prj/AFDX_top_synth.ys`：现行工作区 RTL（含 SNMP/TFTP/RTC）+ `memory_bram`/`techmap` 后再 `memory_map`。  
本机 2026-10-03 重跑 **rc=0**，`Yosys execute success`，顶层 `stat` **517 × altsyncram**。日志：`prj/AFDX_top_synth.log`（冻结对照，**不要覆盖**）。  
现行源另存：`prj/AFDX_top_synth_demirror.log` **479**；`prj/AFDX_top_synth_txmerge.log` **474** / cell 39718。GUI LUT 122542 未重测。不是 Fit/STA。  
展平失败原件：`prj/AFDX_top_synth.memory_map_fail.log`（`ERROR: invalid vector<T> subscript`），不当 PASS。  
本脚本不导出大网表。综合后整帧仍开放。

```bat
"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe" ^
  -s elinx/prj/AFDX_top_synth.ys -l elinx/prj/AFDX_top_synth.log
```

## 2026-09-29 隔离顶层综合（不在本评阅包）

早期 `prj/AFDX_top_synth_bram.ys` 的 RTL 列表**缺少现有三个管理模块**（`snmp_lite` / `a615a_tftp` / `rtc_sync`）；不得拿其旧 `hierarchy -top` 结果证明当前顶层已综合。新隔离运行从当时 QSF 对应的 **28 个**冻结 RTL 重新生成脚本，在本机获得 **rc=0、197.33 s**。证据在 `../out/arena-debug/elinx_current_20260929/`（评阅 ZIP 不含该目录）。该输出仍不是 post-fit／门级带 SDF。

在**相同本机环境及未变更的 RTL**复跑，请到项目根目录的 PowerShell 建立全新同级证据目录（不要覆盖既有结果；运行前不要有别的 eLinx 综合进程）：

```powershell
New-Item -ItemType Directory .\out\arena-debug\elinx_current_recheck_002 | Out-Null
Copy-Item .\out\arena-debug\elinx_current_20260929\run_synth.py .\out\arena-debug\elinx_current_recheck_002\run_synth.py
python .\out\arena-debug\elinx_current_recheck_002\run_synth.py prepare
python .\out\arena-debug\elinx_current_recheck_002\run_synth.py synth
```

环境依赖：本机 `C:\Program Files (x86)\eHiWay\eLinx3.0` 及 vendor BRAM 映射规则、`out/arena-debug/timing_current_20260929/source/` 的冻结输入、原 QSF 与对应生产 RTL。脚本逐哈希比对全部 28 文件，独占新证据目录。尚未复核 eLinx GUI 打开／点击仿真；Questa RTL 全量 65/65 PASS 详见 `../doc/AFDX端系统_测试仿真报告.md` A 节。**另有独立的真实后综合功能仿真**：Quartus EDA Writer 在冻结版 map 工程导出 `AFDX_top.vo`（不是上文 eLinx Yosys 的 `write_verilog` 网表），Questa 加载 eLinx Stratix IV 功能原语完成全顶层寄存器接口短时 smoke，原始状态在 `../out/arena-debug/postsyn_quartus_eda_20260930/gate_full_compile/simulation_status.json`。这不是网表全量帧仿真、SDF、Fit/STA 或 GUI 已复现。

## 以下为历史冒烟与工具研究（不能替代当前版证据）

## 空壳综合（第 1 周出口条件后半，已通过 2026-09-21）

```bat
:: 在 C:\Workspace\diansai 下执行
"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe" ^
  -s elinx/prj/AFDX_top_synth.ys -l elinx/prj/AFDX_top_synth.log
```
结果：`synth` 通过，**3281 cells**（1417 MUX / 550 OR / 572 AND / 103 NOT /
11 XOR / 509 DFF / 119 LCELL），500 wires，0 错误。证据：`prj/AFDX_top_synth.log`。

## BRAM 推断冒烟（O-20 第 3 条，2026-09-22 已定论：可行）

```bat
"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe" ^
  -s elinx/prj/bram_sdp_smoke.ys -l elinx/prj/bram_sdp_smoke.log
```
结果：`rtl/common/bram_sdp.v`（1W2R 8192×32）映射 **128 × altsyncram(M4K)**，
rc=0（双读口各镜像 64 块）。**裸 `synth` 宏不能用**——其 memory_switch 生成的
$mem 有 RD_DATA/RD_DATA_B 双驱动 bug（CHECK 必炸，与 RTL 写法无关）；必须用
`bram_sdp_smoke.ys` 里的显式 `memory_bram -rules ...brams.txt` + `techmap -map
...brams_map.v` 序列（规则在 eLinx 安装目录 `bin\shell\share\stratix\common\`，
路径含空格要加引号）。ELINX_SYNTH IP 分支（设计书 §7.19）不需要了。
注意：128 M4K = 512 Kbit，EQ6HL45（437 Kbit）装不下——指标按赛方 EQ6HL130P 算。

## RX IC 的 PSN RAM 冒烟（2026-09-23，独立单元）

```bat
"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe" ^
  -s elinx/prj/rx_ic_smoke.ys -l elinx/prj/rx_ic_smoke.log
```

结果：`rx_ic` 的 8192×8 bit PSN 表映成 **16 × altsyncram(M4K)**，脚本以
`select -assert-count 16 t:altsyncram` 为硬判据，rc=0；`rx_ic_probe.ys` 可查
`memory_collect` 是否仍有 1 个 `$mem`。旧 3 写口形式虽也 rc=0，但会展开
24576 个 `$dffe`（失败证据 `rx_ic_smoke_ff_first.log`），不可当通过。
本试验没有把 IC 接到顶层，也不证明顶层资源或 125 MHz 时序。

## 已有认识（详见 doc_eLinx3.0_拆解报告.md）
- eLinx 仿真是 GUI 生成 ModelSim `.do` 再调 `modelsim.exe`；本 build（Questa
  2025.3 Starter）的 win64 目录**没有 modelsim.exe**（只有 vsim.exe）→ GUI
  “Run Behavioral Simulation” 无法指向它。等价批处理路径（拆解报告
  §4.6）：`vsim -c -do xxx.do`，即本项目 sim/run_t01.tcl 已验证的流程。
- 无 GUI 的 `.vqm` 网表导出：本 build 的 eLinx_synthesis(_ip) 均无 `write_vqm`
  命令（.vqm 由 Infrastructure 后端在 GUI 流程中写出）。综合自证按
  设计书 §11 口径（可选项，非交付物），目前到 synth+stat 即可。
- 后端命令：`Infrastructure/Implementation/BitGenerator/Programmer_core.exe -f x.tcl -silence`（无 GUI）；
  约束文件 `.edc`（SDC 语义），第 4 周后加 `prj/AFDX_top.edc`（create_clock 8ns）。

## 目录约定（设计书 §10）
- prj/  工程脚点（.ys / 将来 .epr / .edc）
- sdc/  时序约束（后筛入 prj 或单置）
- ip/   自建 IP 目录（本项目无额外 IP，占位）

## 2026-10-10 当前源码状态提示

当前生产清单为 `AFDX_top_sources.f` 中 30 个 RTL 文件。最新静态结果见 `../out/luna_non_sim_20261010_r1/static_r2/static_status.json`；这是 Verilog 前端/结构检查，不是完整综合、技术映射或网表业务结果。本文上方 2026-10-03 综合记录以及下方 2026-09-29/更早结果均绑定各自源码清单，不能代表当前工作区的 TFTP/顶层修改。`a615a_init_tx`、`a615a_lur_rx`、`a615a_file_rx`、`a615a_tftp_client_1350` 只在 `AFDX_615A_prepare_sources.f`，尚未接入顶层；`ipv4_fragment_plan`、`ipv4_fragment_header` 和 `tx_pmem_byte_reader` 只在 `AFDX_fragment_prepare_sources.f`，也尚未接入生产路径。
