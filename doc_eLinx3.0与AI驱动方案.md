# eLinx 3.0 应用构成与 AI 驱动路径（研究记录）

调查对象：`C:\Program Files (x86)\eHiWay\eLinx3.0`，在本机实测枚举得到，不是抄手册。
调查方式：只读扫描目录与文本文件、扫 PE 里的 ASCII 串。**没有启动 eLinx 或任何阶段程序**，
所以「`-h` 到底认哪些开关」这类只能靠实跑确认的事，下面一律标成未验证。
日期：2026-09-21，工具版本 `Version 3.0.7 Build 1/22/2025 Full Version`（`data\version.ini`）。

## 1 它不是一个 GUI 程序，是「Qt 前端 + 一组控制台后端 + Tcl 内核」

安装根目录 2.4 GB、31 793 个文件。三层东西分得很清楚：

| 层 | 位置 | 内容 |
|---|---|---|
| 前端 | `eLinx3.0.exe`（103 MB）+ `Qt5*.dll`、`PinPlanner.dll`、`Floor_Planning.dll`、`TimingAnalyzerGui.dll`、`SchematicDll.dll`、`VIO.dll`、`BitprobeDll.dll` | 工程导航、引脚规划、楼层规划、时序分析、原理图、在线调试的界面 |
| 后端阶段程序 | `bin\shell\bin\` | `eLinx_synthesis.exe`、`eLinx_synthesis_ip.exe`、`Infrastructure.exe`、`QInfrastructure.exe`、`Implementation.exe`、`BitGenerator.exe`、`Programmer_core.exe` |
| 流程编排 | `bin\shell\bin\*.tcl` | `run_all.tcl`、`run_pack*.tcl`、`run_route*.tcl`、`run_bitgen*.tcl`、`run_timing_report.tcl`、`run_power*.tcl`、`gen_drc_model.tcl`、`load_udm.tcl` 等 49 个脚本 |

Tcl 内核有两套：`bin\shell\bin\tcl85.dll`（后端脚本用）和 `bin\Passkey\bin\{tclsh.exe,tclsh85.exe,wish.exe}` 外加 `bin\Passkey\...\tclsystem`（ActiveTcl 8.5，连 `ActiveTclHelp8.5.chm` 帮助都打包进来了）。**这意味着工具的自动化面本来就是 Tcl**，不是需要我逆向出来的隐藏功能。

`bin\Passkey\` 那一层是 Altera Quartus II 的血统证据：`qcmd.bat` 是 `perl -x` 写的「Quartus II Command-Line Control Layer for stand-alone executables」（Copyright Altera 2004），`tcl_server.tcl`/`tcl_client.tcl`/`remote_cmp.tcl` 是 Quartus 的 Tcl socket 服务端/客户端样例（`q_attach`、`QUARTUS_TCL_PORT`、`q_project_open`、`q_cmp_add_assignment` 等几十个 `q_*` 命令），`modelsim_q.tcl` 与 `common\tcl\apps\qsim\qsim_script_modified.tcl` 则负责把仿真器挂进来。亿海微是在 Quartus 的 Passkey 外壳上换了自己的综合/布线内核，所以命令风格、日志结构、EDA 接口约定都能按 Quartus 的常识去猜——这点对「让 AI 写脚本」很关键，能猜对大半。

## 2 它的 Tcl 命令集长什么样

`bin\shell\bin\all_tcl_manual.tcl`（3 KB，带中文注释）就是命令小抄，逐条列了 UDM（器件模型）阶段的命令：

```tcl
set_global_assignment -name TOP_LEVEL_ENTITY a2b           ;# 顶层实体
set_global_assignment -name DESIGN_PATH      E:\Testbench\a2b
set_global_assignment -name PROJECT_NAME     a2b           ;# 与待解析的 VQM 文件同名
set_global_assignment -name VERILOG_FILE     a2b.v
set_global_assignment -name DEVICE_SERIES    series_06ip_new
set_global_assignment -name DEVICE_NAME      06eip_t1
set_global_assignment -name UDM_LPM_INFO_PATH ...\series_06ip_new.lpm
udm_parse_vqm            ;# 解析门级网表
udm_write_signal[-timestamp] / udm_write_cluster / udm_read_signal / udm_read_cluster
udm_save_checkpoint / udm_load_checkpoint        ;# .pcp（Passkey Check Point）二进制快照
udm_parse_meminitial / udm_write_meminitial      ;# 初始化 memory（.mif/.hex）
udm_parse_ipspecific / udm_parse_icapspecific     ;# IP 与 ICAP 描述文件
readback_jtag / down_prom / psk_to_bin           ;# 下载与回读，本赛题用不到
```

`run_all.tcl` 的入口签名把整条后端流程的参数一次性收齐：

```tcl
proc run_all {projectDir projectName topEntity seriesName deviceName} { ... }
setlogfile $projectDir/log4cpp.property $projectDir/psk_fit.log
if {[catch {udm_parse_vqm} err_msg]} { ...; exit }
set_arc_ucm_parameter BLK glj_blk_hc      ;# 之后 30 多行全是器件 ARC 单元库映射
```

两处值得注意。一是它开头就读 `.vqm`，即 **`run_all.tcl` 是「综合之后的后端」脚本**，前端还要 `eLinx_synthesis.exe` 先把 RTL 编成 VQM 网表。二是 `set_arc_ucm_parameter` 那一大串是按器件（`EQ6HL150` 走 `wb_m4kblk_hc`，其它走 `hzh_*`）写死的单元库名——所以器件系列名不能瞎填，必须跟 `data`/`series_library` 对得上。日志走 `log4cpp.property`，固定落在 `psk_fit.log`，这对「AI 读结果」很友好：解析点只有一个。

## 3 三条可行的驱动路径，按可靠性排序

**路径 A：文件 + 批处理回路（推荐，先做这条）。** 不碰 GUI，全链路是：AI 写/改 RTL → 调 `eLinx_synthesis.exe` 出 `.vqm` → 用 `tclsh` 或 GUI 的 Tcl 控制台 `source run_all.tcl` 跑 pack/route/bitgen 与 `run_timing_report.tcl` → AI 解析 `psk_fit.log` 与报告文本 → 决定下一版改什么。可复现、可回归、可以把每条命令与日志摘要写进 §11 当证据。代价是工程/约束的创建入口可能仍在 GUI 里（安装目录里我只看到 JRE 的 `.template`，没看到 eLinx 自己的 `.qpf/.prj` 样例，说明工程文件可能是别的形式），需要拿一个真工程验证一次；验证方法很轻——用 GUI 建一个空工程，然后看目录里多出什么文件、哪些文件被 Tcl 读取。

**路径 B：Tcl socket 注入（真正的"操控 GUI"）。** `tcl_server.tcl` 用 `socket -server` 在 `QUARTUS_TCL_PORT` 上开一个命令服务，`tcl_client.tcl` 侧有全套 `q_project_*`/`q_cmp_*`/`q_device_*`，`remote_cmp.tcl` 演示了「外部进程 attach 上去、发命令、把 GUI 的消息流管道回来、编译完打印 SUCCESSFUL/FAILED」。如果这版的 GUI 真启用了这个服务（未验证），那 AI 就有了一个交互式控制台：不用重启进程就能改 assignment、跑编译、拿回消息。风险是它可能只是随 Passkey 一起带上的遗留文件、并没有被 eLinx 主程序装载。判定成本低：GUI 开着时用 `netstat` 看它是否 LISTENING 一个本地端口，或扫 `eLinx3.0.exe` 的串里有没有 `msg_tcl_enable_eda_socket` 之类的注册名（我只扫了命令行开关，没扫这个，下次补）。

**路径 C：GUI 自动化（兜底，不作为主路径）。** Qt5 程序，`pywinauto`/UIA 理论上能点菜单、按 Flow Navigator 逐步跑，也能截图存证。但它没有语义反馈（成功与否还得靠读窗口文字），一旦版本换了控件名就全断。只在 A/B 都被堵住时才用，而且只用来出「界面确实跑通了」的截图，不用来做迭代回路。

**仿真侧另说。** eLinx 自带的 `Simulation\` 是厂商原语库（`verilog`/`vhdl`/`elinx_lib`，目录名是 `@m@f_cycloneiii_pll` 这种 ModelSim 自动库映射风格），`qsim_script_modified.tcl` 里对 ModelSim 的调用是 `quartus_eda --simulation --tool=modelsim_oem --format=verilog` 生成网列表 + `vsim -c` 批处理启动，并在 `<安装目录>\..\modelsim_ae|modelsim_ase\win32aloem\` 找 `vsim.exe`。我在你机器上把这几种常见位置都查了：**没装 ModelSim，PATH 上也没有 vsim/vlog/vlib/vmap**，这跟赛题要求「eLinx 编译及仿真」直接冲突，是当前最要紧的环境缺口。它自带的 `verilator\verilator.exe` 与 `ghdl\bin\ghdl.exe` 能立刻拿来当快速 lint/回归用，但 Verilator 是二值仿真为主、不认 `#delay` 与 X 传播，我们要测的抖动/时序判决不能用它出结论，交付口径还得回到 ModelSim（赛方原话是「要求基于 FPGA 做仿真」，`vsim -c` 批处理完全符合）。

## 4 顺带挖到的、对本选题有用的材料

`bin\ip\doc\` 下有 90 份 IP 用户手册 PDF，其中两份直接压在选题一的点上：`Tri_Mode_Ethernet_Mac_User_Guide.pdf`（1.1 MB，三速以太网 MAC，含 MII/GMII 口径）和 `TripleSpeedEthernet_User_Guide.pdf`；还有 `M4K_User_Guide.pdf`/`M9K_User_Guide.pdf`（我们 §9 的 PMEM 预算就是按 M4K 算的）、`FIFO_User_Guide.pdf`、`PLL_User_Guide.pdf`、`VIO_User_Guide.pdf`。根目录另有 `UG102_eLinx_Design_Suite_User_Guide_ehiway_v2024.9.pdf`（8.9 MB，官方用户指南）。这些是比 XAPP1130 更贴题的依据来源——XAPP1130 讲的是 Virtex 上的 AFDX IP 划分，而 TMAC 手册讲的正是我们要对接的那个 MAC。

`data\common.ini` 里有两类可调项对「AI 自动调参」有用：`[Settings] Used_Incremental_Compile = 1`、`Used_Synthesis_Tools = 0`；`[SmartParams]` 列出 12 个打包/布线旋钮（`PackAlgName`、`CLB_MaxNumIns`、`TIMING_TRADEOFF_LAMBDA`、`HEAP_WEIGHT_ADD` …），`[SmartExploreRun] Run_Count = 20 / Default_Job_Count = 4` 配 `run_route_*_smart_explore_run.tcl`——工具自己就带了「多组参数并发试布线、挑时序最好的一版」的机制，格式是逗号分隔的一行参数串。这个机制将来若需要压时序余量，是比改 RTL 更省力的杠杆，而且完全可脚本化。

## 4.5 第二轮补测：命令行口与综合内核都确认了（同一日）

扫 `Implementation.exe` / `Infrastructure.exe` 的内嵌帮助文本，原样抄出来是这一组：

```
-help
-f file_name: Run Tcl script. eg: psk_shell -f psk.tcl
-tcl: Launch Tcl interface.
-silence: Run script without Tcl interface.
-verbose: Run in verbose mode.
Parameter undefined, type "-help" for more information.
```

`Infrastructure.exe` 里紧跟着还有一串日志类别 `[ARC] [UDM] [UCM] [Packer] [Placer] [Router] [BitGen] [Timer] [GUI] [Common] [PGM] [Power]`，以及 `Initialize Tcl system error!`、`No TCL script file needs to be run.`。合起来的含义很明确：**这两个 exe 本身就是内嵌 Tcl 8.5 的 shell**（帮助里那个 `psk_shell` 是它的旧名，安装目录里没有独立的 `psk_shell.exe`），`-f xxx.tcl -silence` 就是无人值守跑脚本，`-tcl` 是给人的交互口。`run_all.tcl` 那套 `udm_*/set_global_assignment/set_arc_ucm_parameter` 命令正是在这个解释器里注册的。

综合器 `eLinx_synthesis.exe` 是 **Yosys 的分支**：里面能扫到 `read_verilog`/`read_vhdl`/`read_liberty`/`read_device`/`read_constr`/`read_library`/`synth`/`memory -bram <rules>`/`memory_dff -nordff -memx`/`opt`/`stat`/`tee`/`write_verilog`/`write_json`/`write_blif`/`write_edif`/`write_aiger`/`write_btor`/`write_smt2`/`miter -equiv`/`verilog_defaults -add`，外加亿海微自己的 `amendvqm [operation]`（Yosys 里没有这条）。所以「RTL → 门级 `.vqm`」这步的标准用法就是写一个 `.ys` 脚本喂给它，资源与时序前的网表统计可以直接 `stat` + `tee -o` 出文本——这对 AI 是好消息，Yosys 脚本是所有模型都会写的东西。注意两点：`stat` 给的是单元/位数统计，不等于器件 LUT 占用，别把它当 §9 的占比用（我们本来也不写占比）；BRAM 推断结果取决于 `-bram <rules>` 有没有喂进 eLinx 的 M4K 规则，这条要在实跑里核对一次。

## 5 还没验证、别当成结论的几件事


1. 上面那组开关是从二进制里读出来的**帮助文本**，不是实跑结果：`-f` 与 `-silence` 的确切位置参数顺序、是否还需要指定工程目录，要跑一次 `Infrastructure.exe -help` 确认（我故意没启动，怕留下挂死进程）。
2. 工程与约束的文件格式、能否脱离 GUI 创建：`.template` 搜到的都是 JRE 自带的，eLinx 的工程载体还没定位到；但既然 `run_all.tcl` 只吃 `set_global_assignment` 那五个变量，很可能**根本不需要 GUI 工程**——脚本给全参数即可，这条待实测。
3. `bin\Passkey\bin\tcl_server.tcl` 那套 socket 服务（`QUARTUS_TCL_PORT` + `q_attach`）在本版是否被装载：路径 A 已够用，这条不用急着验。
4. UG102 与 TMAC 手册的正文内容：桥不传二进制，我目前只掌握文件大小与路径；要读得先把它转成文本（我可以在你机器上跑转换，或按页取回）。
5. ModelSim 缺失是否影响报名阶段的演示（不影响选题报名，影响 10 月起的仿真取证）。

