# eLinx 3.0.7 拆解报告（2026-09-21，本机实测）

> **2026-10-01 资料位置提示：**下文列出的 `_elinx_probe*.txt`、`_elinx_strings_hits.txt`、`_elinx_tcl_cmds.txt`、`_ug102*.txt` 原件均已保持原字节归档至 `archive/20261001_root_capture/probe_outputs/`。原路径与 SHA-256 对照见 `out/arena-debug/folder_cleanup_20261001/MANIFEST.json`；正文为历史调查时点记录。

对象：`C:\Program Files (x86)\eHiWay\eLinx3.0`（亿海微 eLinx Design Suite，Version 3.0.7 Build 1/22/2025，2.4 GB / 31 793 文件）。
方法：目录/配置/注册表扫描 + PE 字符串扫描 + **实际运行**各后端 exe 的 `-help`/`--version`/Tcl 枚举脚本（均在 %TEMP% 下、超时即杀，没有启动 GUI、没有动任何工程）+ 用本机 PyMuPDF 抽取官方手册 UG102（298 页）文本对照。
原始证据：`_elinx_probe4.txt`（探测输出）、`_elinx_strings_hits.txt`（字符串命中）、`_elinx_tcl_cmds.txt`（4 个后端的全部 Tcl 命令）、`_ug102_toc.txt` / `_ug102_text.txt`（手册目录与全文）。

---

## 0. 一句话结论

eLinx 不是一个"仿真器"，而是一个 **Qt 5.5 前端 + 一组内嵌 Tcl 8.5 的控制台后端 + Yosys 分支综合器** 的 FPGA 全流程 IDE；它的"仿真"功能本身没有内核，**完全依赖外部 ModelSim**（GUI 只负责生成 `.do` 脚本并调用 `modelsim.exe`）。随包的 Verilator / GHDL 只用于语法检查和层次提取，不参与仿真。这台机器目前**没有安装 ModelSim**，所以 eLinx 的 Run Behavioral Simulation 现在按下去只会报 "ModelSim install path not exists"。

---

## 1. 身份与血统

| 项 | 证据 |
|---|---|
| 厂商/版本 | `data\version.ini`：VENDOR "eHiWAY"，"eLinx 64-Bit Version 3.0.7 Build 1/22/2025 Full Version"；注册表卸载项 eLinx 3.0.7 |
| 前端框架 | Qt 5.5.0（Qt5Core.dll 5.5.0.0）+ QScintilla 编辑器；主程序 `eLinx3.0.exe` 103 MB，功能 DLL：PinPlanner、Floor_Planning、TimingAnalyzerGui、SchematicDll、Integrator（Block Design，类 Vivado IP Integrator）、IPCatalog、BitprobeDll（ILA）、VIO、DashBoardDll（在线波形）、PRPlanning（部分重构）、eFPGACompilerDll |
| Altera 血统 | `bin\Passkey\` = Quartus II 11~12 时代的完整命令行层（quartus_map/fit/sta/cdb/eda/pgm、jtagd、lmgrd、mega_*q 向导、cygwin、jre、perl、tcl8.5）；仿真库源码文件头是 "Quartus II 11.0/12.0 ... Altera Corporation"；IP 里的 M4K/M9K/LPM_*/ALTFP_* 都是 Altera 名字 |
| 目标器件 | SettingsDLL/主程序字符串：EQ6HL9 / EQ6HL16 / EQ6HL25 / EQ6HL45 / EQ6HL130 / EQ6HL130P / EQ6GL9，run_all.tcl 里还有 EQ6HL150；系列名 EHICHIP6 / EHICHIP9；另有 "3000H" 位流页、"14nm" 器件分支（FIFO_14nm、run_*_14nm.tcl）、eFPGA 分支（ELINKSEAS_6/9，run_*_efpga*.tcl） |
| 许可 | 主流程没看到许可检查；只有 **TMR 是许可功能**（`tmr\licence.dat`，字符串 "TMR Licence Authorization expired / Version error"） |
| 第三方许可文件 | Licenses\：Qt、boost、eclipse、**openocd**（RISC-V 调试）|

---

## 2. 目录地图

```
eLinx3.0\
├─ eLinx3.0.exe + *.dll            Qt 前端与功能插件（见上表）
├─ Programmer.exe / ProgrammerSDK.exe   下载器 GUI / SDK
├─ scyxx.exe, M4kHex.exe           小工具（M4kHex：mif→hex 之类，无参数直接崩）
├─ UG102_...User_Guide_v2024.9.pdf 官方手册 298 页（中文）
├─ data\                           common.ini（流程开关 + 20 组 SmartExplore 布线参数）、version.ini、
│                                  comboboxsetting.ini（I/O 标准表，含 14nm/EQ6HL9 变体）、programmer\FlashType.json + *.jpsk
├─ bin\shell\bin\                  ★后端：eLinx_synthesis(.exe/_ip.exe)、Infrastructure、Implementation、
│                                  BitGenerator、Programmer_core、QInfrastructure + 49 个 run_*.tcl
├─ bin\shell\{sdc2.0.1, log4cpp, eigen3, tclsystem, psk_intern, psk_extern, mif2hex}   后端依赖
├─ bin\Passkey\                    Quartus II 遗产层（19 125 文件）：bin\、libraries\、lmf\、common\
├─ bin\ip\GUI\*.exe (90 个)        每个 IP 一个独立配置器 exe，ip_repository.xml 是目录，default_settings.xml 是映射
├─ bin\ip\RTL\<IP>_RTL\            ★IP 的 RTL 源码是明文交付的（7 259 文件；TMAC 18 个 .v，RISCV 26 个，FFT 6 464 个）
├─ bin\ip\doc\*.pdf (84 份)        IP 用户手册
├─ bin\drivers\                    CH341PAR 驱动、vcredist
├─ Simulation\                     ★仿真库：elinx_lib（ModelSim 预编译库）、verilog\、vhdl\（库源码）
├─ verilator\verilator.exe (5.006) 仅 2 个文件、没有 include\ → 只能 lint，不能建仿真模型
├─ ghdl\  (GHDL 0.36 mcode)        含 std/ieee/synopsys 库，能独立分析/仿真 VHDL，但 GUI 只拿它做语法检查
└─ tmr\tmr.exe + TMRGUI.exe        三模冗余插入（吃 .vqm 出 _tmr.vqm），需要 licence.dat
```

---

## 3. RTL → 位流：每一步到底调了什么

下面每条都来自字符串里的调用模板或实跑输出。

| 步骤 | 实际执行体 | 输入 → 输出 | 备注 |
|---|---|---|---|
| ① 语法检查 & 层次树 | `verilator.exe --relative-includes --bbox-unsup -Wno-lint -Wno-style --lint-only`；层次用 `--dump-tree --xml-only` 生成 `hierarchy.xml`；VHDL 走 `ghdl.exe`（`--ieee=synopsys`） | .v/.sv/.vhd → hierarchy.xml | 类名 `SyntaxCheck::Verilog_SyntaxCheckUsingVerilator` / `VHDL_SyntaxCheckUsingGhdl`；支持 `--language 1364-1995/2001/1800-2005` |
| ② 综合 | `"%exe_dir%/eLinx_synthesis.exe" -s "%curDir%/<x>.ys" -l "<log>"` | RTL → **.vqm**（Altera VQM 门级网表） | 就是 Yosys：`-h` 输出完整 Yosys 用法；`-V` = "eLinx synthesis tool v1.0 (Windows Visual Studio)"；.ys 由 `generator_yosys_shells.py` 模板生成；私有命令 `read_device <resource_file>`、`amendvqm [-io]`（"amend vqm output, run before verilog_backend"）；`read_vhdl` 支持 "a large subset of vhdl-2008"；`help synth` 会崩（0xC0000005，分支 bug）|
| ②' 可选 TMR | `tmr\tmr.exe <x>.vqm` → `<x>_tmr.vqm` | 网表级三模冗余 | 许可控制 |
| ③ 实现 | `Implementation.exe -f run_pack*.tcl / run_route*.tcl -silence` | .vqm(+.edc/.sdc) → 布局布线结果、.pcp 检查点、psk_fit.log | Tcl 脚本按器件分支：普通 / 14nm / efpga / 130nm / PR / smart_explore_run（多组参数并发试布线）|
| ④ 时序 | 同上，`run_timing_report.tcl` / `run_synthesized_timing.tcl` | 时序报告 | SDC 命令全套已注册（见 §5）|
| ⑤ 位流 | `BitGenerator.exe -f run_bitgen*.tcl -silence` | → **.psk**（不是 .bit）；`bitgen_genpsk/genvpsk/genbgd/genecc/genrpt` | 还能出 .bin / .hex / .mcs，甚至 "xilinxbit"（走 iMPACT+PROM 的兼容路径）|
| ⑥ 下载 | `Programmer.exe` → `Programmer_core.exe`（Tcl：`send_rawpsk_usb2cable2jtag2fpga`、`send_flashpsk_...spi2flash`、`send_readbackpsk_...`、efuse/AES 命令）| .psk → JTAG/Flash | 线缆：CH347/CH341（沁恒 USB-JTAG）、FTDI D2XX、libusb；Flash 型号表 FlashType.json |
| ⑦ 在线调试 | BitprobeDll（Set Up Debug/ILA）、VIO.dll、DashBoardDll（Dashboard 波形/触发）| | 手册第 9 章 |

后端 4 个 exe（Infrastructure / Implementation / BitGenerator / Programmer_core）**实跑 `-help` 输出完全一致**：

```
-f file_name: Run Tcl script. eg: psk_shell -f psk.tcl
-tcl: Launch Tcl interface.
-silence: Run script without Tcl interface.
-verbose: Run in verbose mode.
```

即同一个 "psk_shell" 骨架，只是链进去的 Tcl 命令集不同。

---

## 4. 仿真子系统拆解（重点）

### 4.1 官方定义（UG102 第 11 章 + §4.2 + §4.9）
- §11.1：Settings 里设 **Simulation 库路径**（默认 `Simulation/elinx_lib`）和 **Simulation Resolution**（1 ps ~ 100 us 共 9 级）；原话："不同的 ModelSim 版本之间库文件不能通用，如果 ModelSim 仿真时遇到库文件无法使用的错误，需要用户自己编译库文件"。
- §4.9 3rd Party Simulators：只有一个设置——**modelsim.exe 所在目录**。
- §11.3：Flow → Run Simulation → **Run Behavioral Simulation**（行为仿真）/ **Run Post-Implementation Simulation**（后仿）；前提是装了 ModelSim、设置了路径、且 Simulation Sources 里有一个文件被设为 target。
- §11.4：库版本不匹配时，在 ModelSim 里新建库，把 `Simulation\verilog\*.v`（或 `vhdl\*.vhd`）全选编译，再在 eLinx 里指向它。

### 4.2 GUI 实际做的事（字符串证据）
类 `RunSimulation::write_behavioral_simulation_do_file()` 生成 ModelSim `.do`，内容模板就是 Quartus NativeLink 那一套：

```
vlib rtl_work
vmap work rtl_work
vlog -vlog01compat -work work +incdir+<...> <files>      # 或 vlog -sv -work work +incdir+
vcom -work work {<vhdl files>}
vsim -t 1ps -voptargs=+acc work.<tb_top>                  # 后仿变体：vsim -t 1ps +transport_int_delays +transport_path_delays -L work -voptargs="+acc"
add wave *
```

然后在 `<工程>/simulation/modelsim/` 下调用 `<ModelSimInstallPath>/modelsim.exe`。找不到时报 "Can't find modelsim.exe in '%1', please set modelSim install path again."。设置项名：`ModelSimInstallPath` / `ModelSimPath`（SettingsDLL）。

### 4.3 仿真库到底是什么
`Simulation\elinx_lib\`（882 文件）是 **ModelSim 预编译库**：`_info` 头是 `cModel Technology`、编译器版本 **`10.0c`**、源路径 `D:\elinx_lib\altera_mf.v`，编译时间 2024-09-04 / 2024-11-15，带 `modelsim.ini`。301 个单元目录名全是 Altera 原语（`stratixiv_*`、`stratixii_*`、`stratixiii_*`、`srff`、`soft`、`altera_primitives` …）。

对应源码在 `Simulation\verilog\` / `vhdl\`，各 3 个文件：

| 文件 | 实际是 | 大小 |
|---|---|---|
| `elinx_mf.v/.vhd` | Altera `altera_mf`（ALTSYNCRAM/ALTPLL/DCFIFO/LPM_MULT… 行为模型） | 2.2 MB / 2.4 MB |
| `elinx_atoms.v/.vhd` | Altera Stratix 系列原子级模型（文件头 "Quartus II 11.0 Build 157"） | 322 KB / 460 KB |
| `220model.v/.vhd` | LPM 220 库 | 240 KB / 384 KB |
| `elinx_lib\ELINX_ICAP.v` | 亿海微自己写的 ICAP 模型（2024-03） | 1.3 KB |

含义：eLinx 器件的仿真模型 = Altera Stratix/Cyclone 模型改名。**任何能编译 altera_mf 的 Verilog 仿真器（Icarus、Verilator 除外的事件驱动仿真器）理论上都能仿 eLinx 的 IP 输出**——但 GUI 只会调 ModelSim。

### 4.4 后仿路径
Implementation.exe 里注册了 `generate_eda_netlist`、`DoGenerateVOFile`、`back_annote`、`write_net_delay`，主程序里还有 `quartus_eda.exe --read_settings_files=off --write_settings_files=off` 与 `--netlist_type=atom_map`、`--back_annotate=lc` 的调用串 → 后仿是"实现后导出 .vo 门级网表（原子模型来自 elinx_atoms）+ 延迟，再交给 ModelSim"。（推断自命令名，未实跑。）

### 4.5 Verilator / GHDL 的真实角色
- `verilator\` 只有 `verilator.exe`（5.006, 2023-01-22）和 `msys-2.0.dll`，**没有 `include\`（verilated.h/.cpp），也没有 C++ 编译器** → 物理上不可能用它生成仿真模型；GUI 只用 `--lint-only` 与 `--dump-tree --xml-only`。
- `ghdl\`（0.36 mcode，2019）带完整 std/ieee 库，`-a/-e/-r` 能独立跑 VHDL 仿真并输出 VCD/GHW，但 GUI 只拿它做 VHDL 语法检查。你要自己用它跑 VHDL 回归是可行的，只是与 eLinx 的"仿真"无关。

### 4.6 本机现状与建议
- ModelSim/Questa：PATH、注册表卸载项、`C:\intelFPGA*`、`C:\Modeltech*` 都没有；注册表里只有 eLinx 自己留的 "ModelSim 注册表: eLinx 3.0.7" 痕迹。
- 库是 ModelSim **10.0c** 编的：装 ModelSim-Altera 10.1d Starter / ModelSim SE 10.x 直接可用；装 Questa 2020+ 大概率要 `vlog -refresh` 或按 §11.4 重编（源码都在，10 分钟的事）。
- 绕开 GUI 的批处理路径完全成立：`vsim -c -do run.do`，`.do` 就照 4.2 的模板写。赛方要求"eLinx 编译及仿真"，用 eLinx 综合/实现 + ModelSim 批处理仿真，与 GUI 点按钮的产物是同一套。

---

## 5. 自动化接口（对"AI 驱动"的意义）

### 5.1 Tcl 命令面（本次用 `-f probe.tcl -silence` 实际枚举，全表见 `_elinx_tcl_cmds.txt`）

| 后端 | 命令总数 | 非标准 Tcl 命令 | 代表 |
|---|---|---|---|
| Infrastructure.exe | 150 | 58 | `udm_parse_vqm`、`udm_save/load_checkpoint`、`set_global/instance/location/parameter_assignment`、`arc_build_*`（器件模型）、`create_pblock`、`set_arc_ucm_parameter`、`setlogfile`、`show_all_cmd` |
| Implementation.exe | 306 | **213** | 上面全部 + pack（`DoTVPack`、`pack_timing`）、place（`place_seed/effort/freq/tdc/tsu/tco/tpd`、`try_place`、`place_early_timing_estimate`）、route（`route_channel/internal/write_results`）、时序（`create_clock`、`create_generated_clock`、`set_input/output_delay`、`set_false_path`、`set_multicycle_path`、`set_max/min_delay`、`set_clock_groups/latency/uncertainty`、`get_cells/nets/pins/ports/clocks`、`read_sdc_cmd`、`do_timing_analysis`、`print_timing_report`、`compute_clock_fmax`、`get_fmax_and_slack`）、功耗（`power_*`）、EDA 输出（`generate_eda_netlist`、`DoGenerateVOFile`、`write_netlist_hierarchy`、`write_schematic_data`）、内存监控（`memory_monitor`、`show_*_max_memory`）、调试核（`create_debug_core/port`）、位流（`bitgen_*` 也链在里面）|
| BitGenerator.exe | 202 | 110 | `bitgen_genpsk/genvpsk/genbgd/genecc(4/8)/genfst/genmin/genrpt/cfgbram/cfgcram/showcram/showmem` + SDC 子集 + `udm_*` |
| Programmer_core.exe | 153 | 70 | `program`、`get_id`、`get_chain_*`、`send_rawpsk_usb2cable2jtag2fpga`、`send_flashpsk_...`、`send_readbackpsk_...`、`gen_mcs/bin/hex_from_rawpsk_*`、efuse/AES 读写 |

要点：
- `-help` 只打印 4 个开关，**不会列 Tcl 命令**；列命令用脚本里的 `show_all_cmd` 或 `info commands`（GUI 的 Tcl Console 里输 `-help` 才会列，见 UG102 §3.7）。
- `-f x.tcl -silence` 实跑确认：无窗口、跑完退出、退出码 0；stdout 正常可捕获。
- 时序约束命令就是 SDC 语义（`bin\shell\sdc2.0.1` 是解析器），文件扩展名 `.edc`（eLinx Design Constraints，物理+时序合一）；对话框同时接受 `.sdc`。

### 5.2 综合器（Yosys 分支）
- 标准 Yosys 命令行全部可用（`-s script.ys`、`-p "cmd"`、`-l log`、`-q`、`-D macro`、`-c tcl_script`）。
- 每条命令的用法可用 `eLinx_synthesis.exe -p "help <cmd>"` 现场查（`help synth` 会崩，其它正常）。
- 没有 `read_constr` / `read_library` 命令（早前笔记里的这两条不存在）；存在的私有命令是 `read_device`、`amendvqm`。

### 5.3 文件格式速查

| 扩展名 | 含义 | 来源 |
|---|---|---|
| `.epr` | 工程文件，注册为 `eLinx3.0.Project`，双击用 `eLinx3.0.exe "%1"` 打开 | HKCR |
| `.edc` | eLinx 约束（物理 + 时序） | UG102 §2.1 (5)、对话框过滤器 |
| `.eci` | 源文件类型之一（对话框 `*.v *.sv *.vh *.vhd *.mif *.hex *.eci *.vqm *.bd`） | 字符串 |
| `.bd` | Block Design（Integrator.dll） | 字符串 |
| `.vqm` | 综合网表；`_m.vqm`、`_add_assign.vqm`、`_add_icap/vio_assign.vqm`、`_tmr.vqm` 是各阶段改写版 | 字符串 |
| `.pcp` | Passkey Check Point（udm 检查点） | all_tcl_manual.tcl |
| `.psk` / `.jpsk` | 位流 / JTAG 读 Flash 用位流 | bitgen_*、data\programmer |
| `.ecp` | SettingsDLL 里的 "ECP Files" | 字符串 |
| `.stp` | Debug（ILA）配置 | 字符串 |
| `.ys` | 综合脚本（自动生成） | 字符串 |
| `psk_fit.log` / `log4cpp.property` | 实现日志 | run_all.tcl |

### 5.4 对早前笔记（`doc_eLinx3.0与AI驱动方案.md`）"未验证"清单的回填
1. 后端开关：**已实跑确认**，就是 `-f <tcl> -silence`，不需要额外工程参数（脚本里用 `set_global_assignment` 给全即可）。
2. 工程文件：**`.epr`**；约束 `.edc`；是否能完全脱离 `.epr` 跑后端——run_all.tcl 不读 .epr，只吃 assignment，仍成立。
3. Tcl socket（`tcl_server.tcl`/`QUARTUS_TCL_PORT`）：主程序字符串里**没有** `QUARTUS_TCL_PORT` / `eda_socket`，基本可判定是 Passkey 遗留文件，GUI 没装载。
4. UG102 正文：已抽成 `_ug102_text.txt`（6 809 行），可直接 `search_files`。
5. ModelSim 缺失：**确认缺失**，且明确影响仿真取证；不影响综合/实现演示。

---

## 6. 对本项目（AFDX 端系统 / 选题一）的直接启示

1. **仿真环境是唯一硬缺口**：装 ModelSim 10.x（或 Questa + 重编库），其余链路本机已齐。
2. **TMAC 可以白盒**：`bin\ip\RTL\Tri_Mode_Ethernet_Mac_RTL\`（18 个 .v：mac_tx/rx_ctrl、tx/rx_CRC、mdio、pause、dcfifo_mixed_inst…）是明文，接口时序可直接读源码/仿真确认，比只看 PDF 可靠。
3. **资源预算按 Altera 原语算是对的**：IP 输出实例化的是 ALTSYNCRAM/DCFIFO 等，M4K/M9K 手册与 `elinx_mf.v` 一致。
4. **可脚本化的调参杠杆**：`data\common.ini` 的 20 组 SmartExplore 参数 + `run_route_*_smart_explore_run.tcl`，以及 Implementation.exe 里 `place_seed/effort/freq/tdc` 等命令，都能在无 GUI 下扫。
5. **内存**：本机 15.4 GB，探测时空闲仅 0.9–1.4 GB（Quartus 安装在跑）；eLinx 实现阶段自带 `memory_monitor`/`show_*_max_memory`，跑大设计前先把 Quartus 装完、关掉浏览器。

---

## 7. 本次实跑清单（可复现）

| 命令 | 结果 |
|---|---|
| `Infrastructure/Implementation/BitGenerator/Programmer_core.exe -help` | exit 0，4 行用法 |
| 同上 4 个 `-f probe_cmds.tcl -silence`（`info commands`） | exit 0，命令数 150/306/202/153 |
| `eLinx_synthesis.exe -V` / `-h` / `-p "help read_device|amendvqm|read_vhdl"` | 正常；`-p "help synth"` 崩溃 0xC0000005 |
| `verilator.exe --version` | Verilator 5.006 2023-01-22 |
| `ghdl.exe --version` / `--help` | GHDL 0.36 [Dunoon edition] mcode |
| `tmr.exe -h` | "Cannot open source file: -h.vqm"（第一个参数就是 vqm 路径） |
| `QInfrastructure.exe`、`M4kHex.exe` 无参数 | 立刻访问违例退出（需要参数/GUI 上下文） |
| `ProgrammerSDK.exe` 无参数 | 不退出（8 s 后被杀），别在脚本里裸调 |

## 8. 仍未验证
- `.epr` 的内部格式（XML 还是 QSF 风格）——需要用 GUI 建一个空工程看一眼。
- GUI 生成的 `.ys` 模板全文（在工程目录里才会出现）。
- 后仿导出 `.vo` 的确切命令序列。
- `read_device <resource_file>` 吃的资源文件在哪（推测在 `bin\shell\Infrastructure\` 或 `data\`）。
