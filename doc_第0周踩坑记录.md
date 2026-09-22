# 第 0 周踩坑记录（2026-09-21，Questasim 安装 + T01 首跑）

> 配套文件：`doc_第0周问题清单.md`（发群）。本文是内部工作记录，第 1 周 lint.sh 与后续周次
> 的环境/工具问题先查这里。结果：T01 SMOKE PASS（证据 `sim/out/run_t01_console.txt`）。

## 一、环境事实（实测，勿再猜）

| 项 | 值 |
|---|---|
| 安装目录 | `C:\altera_pro\26.1.1\questa_fse\`（**不是** modelsim_ase/modelsim_ae） |
| vsim | `C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe`（**win64**，不是 win32aloem） |
| 版本 | Questa Altera **Starter FPGA Edition**-64 vsim 2025.3（Simulator 2025.09） |
| 授权机制 | SALT RSA keyring（`questa_fse\keyring\*.active`），文件式授权，无 lmgrd 守护 |
| 授权变量 | `SALT_LICENSE_SERVER = C:/Users/tortl/questa_lic.dat`（安装器写 **User** 级） |
| 授权进程组 | `vsim` + `vish`（license）+ `vlm`（license manager）；杀 vsim 可能残留 vish/vlm |
| Verilator | eLinx 内置 5.006：`C:\Program Files (x86)\eHiWay\eLinx3.0\verilator\verilator.exe` |

Verilator 5.006 要点：
- 宽度警告名改了：`-Wno-WIDTH`（旧名 WIDTHEXPAND/WIDTHTRUNC 已废）。
- 推荐 flags：**DUT** `--lint-only -Wall -Wno-fatal -Wno-WIDTH --top-module AFDX_top`；
  **TB** 再加 `--timing -Wno-PINCONNECTEMPTY`（TB 里空接 DUT 输出引脚属故意）。
- **Verilator 比 vlog 宽松**：前向引用（声明前使用 reg/wire）Verilator 过、vlog 报 vlog-2730。
  双轨保留，以 vlog 为准。

## 二、工具链坑

1. **vsim 批处理入口**：必须 `vsim -c -do "source xxx.tcl"`，tcl 结尾 `quit -f`。
   `vsim -c -v` 会进 `Questa>` 交互提示符，无 stdin 就永久挂起（本次就留下过孤儿进程）。
2. **授权变量不继承**：安装器只写 User 级注册表；安装前启动的常驻终端（如 MCP 桥）
   拿不到 → `Unable to checkout a license`。`run_t01.ps1` 已内置从 User 注册表自动恢复；
   新开的 shell 无此问题。
3. **.ps1 编码**：UTF-8 **无 BOM** 的 ps1 被 PS 5.1 按 GBK 解析——中文注释乱码，且乱码
   可能悄悄破坏脚本行为（本次 license-恢复分支静默失效）。规范：ps1 纯 ASCII 或带 BOM
   （`run_t01.ps1` 已是 ASCII+BOM）。
4. **控制台日志编码**：vsim 输出走 PS 管道（`2>&1 | ForEach`）会被控制台代码页重编码，
   中文永久变 `?`。现方案：cmd 层重定向（字节透明）写 `sim/out/run_t01_console.txt`，
   再 `Get-Content -Encoding UTF8` 回显。
5. **桥接命令 ~120 s 超时**：超时杀的是顶层进程，孙进程（vsim/vish/vlm）**变孤儿**，
   占住日志/源码文件 → `The process cannot access the file because it is being used by
   another process`。对策：长跑仿真用 `Start-Process` 分离（见 run 流程）；每次跑前先清
   残留：`Get-Process vsim,vish,vlm,vcom,vopt,vlog | Stop-Process -Force` +
   `powershell.exe` 且 CommandLine 含 run_t01 的；日志文件加时间戳防碰撞。
   （以下 6~9 为 2026-09-22 第 1 周新增，lint/回归/BRAM 冒烟当天踩的）
6. **eHiWay Verilator 5.006 路径参数 bug（msys-2.0.dll）**：命令行里任何带路径前缀的
   文件参数（`rtl\x.v`、`.\x.v`、`C:\...\x.v`，正反斜杠都一样）都被误当 **module 名**，
   报 `Cannot find file containing module: <路径>` + `Looked in: ...`；只有**裸文件名**
   （当前目录下）可用。对策：全部参数走 **`-f` 响应文件**（内容不做参数转换，内部路径
   正斜杠 OK）——`tools_lint.ps1` 已内置（写 `_lint_gate.f` 再 `verilator -f`）。
   第 0 周四节记录的裸命令行**不可直接复用**，注意。
7. **VCD 近乎空（坑 #11）根因 = vopt 默认优化**：vsim 默认优化把信号可见性剥光，
   `$dumpvars` 只写得出 scope 头（299~318 B、一个 `$var` 都没有，与层级深度无关，
   实测 `$dumpvars(0, tb)` 同样空）。对策：**`vsim -voptargs=+acc`** → 实测 6.9 MB
   正常波形（`sim/out/t00_acc_console.txt`）。`run_t01.tcl` 已加（T01 的 VCD 是正式
   产出）；回归 `run_regress.ps1 -Acc` 按需开（代价 ~2x 仿真时间）。
8. **eLinx 裸 `synth` 宏不能推断 BRAM**：其 `memory_switch` 生成的 `$mem` 里
   `RD_DATA` 与 `RD_DATA_B` **双驱动**同一读口 → CHECK `multiple conflicting
   drivers` 必炸。已排除 RTL 写法因素（单/双 always、1W1R/1W2R、有无 rd_en、
   `(* no_rw_check *)` 全试过）。对策：**显式 `memory_bram -rules <brams.txt>` +
   `techmap -map <brams_map.v>` 序列**（规则文件在
   `eLinx3.0\bin\shell\share\stratix\common\`，路径含空格须加引号）。
   1W2R 8192×32 → **128 × altsyncram(M4K)**，rc=0（`elinx/prj/bram_sdp_smoke.ys`，
   证据 `_bram_mbram.log` / `bram_sdp_smoke.log`）。**O-20 第 3 条结论：BRAM 推断
   可行，`ELINX_SYNTH` IP 分支不需要**；注意 128 块是 1W2R 双读口镜像的代价，
   换器件/降读口数时重算（EQ6HL45 只有 437 Kbit ≈ 107 M4K，装不下——赛方
   EQ6HL130P 才是目标器件）。
9. **PS 5.1 两个进程坑**：a) `cmd /c` 参数串里有 ≥3 个引号时首尾引号被剥、exe 路径
   断裂（`'C:\...\vsim.exe" -c -do "source' is not recognized`）→ 整串**外层再包一对
   引号**；b) `Start-Process -PassThru` 的 `ExitCode` 在 WaitForExit 后仍可能为
   `$null` → 改用 `[System.Diagnostics.Process]::Start()` 直调。两者都已固化进
   `sim/run_regress.ps1` 的 `Run-Vsim`。

## 三、RTL / 仿真坑（均为已修真 bug）

| # | 坑 | 处置 / 教训 |
|---|---|---|
| 1 | **vlog-2730 前向引用**：timebase 实例 `.rtc_hold(ctl_r[11])` 早于 `ctl_r` 声明；读 mux 用 `we` 早于其声明 | 信号声明一律前置；Verilator 放过 ≠ vlog 放过 |
| 2 | **读未命中漏置 ERR.ACC**：初版只有写路径置位；§7.14「未列出地址」读写都要置 | ACC 事件统一为 `wr_bad \|\| rd_miss`，与 W1C 同拍逻辑合并进单一 always 块（避免双驱动） |
| 3 | **CTL_WMASK 算错**：初值 0xFFFF_EBFF 没清 bit5；正确 `~(bit5\|bit12) = 32'hFFFF_EFDF` | 保留位 mask 写完后用测试向量 0x1021→0x01 反向验证 |
| 4 | **Verilog-2001 语法**：initial 块中间声明 reg → `Declarations not allowed in unnamed block` | 声明前置或用 wire 常量 |
| 5 | **localparam 非常量**：`localparam [21:0] SINK = {rx_data, ...}` 被 Verilator 拒（localparam 必须常量） | 骨架期未消费端口用 `/* verilator lint_off UNUSED */` 开关并注明恢复时机 |
| 6 | **计算位选退化**：`rtc64[TICK_LSB-1:0]` 在 TICK_LSB=0 时变 `[-1:0]`（vlog SELRANGE） | 时基 tick 改计数器取模，不保留恒 0 位（17 bit 而非 18 bit） |
| 7 | **算术翻车**：PMEM_FREE=16 落在 [7:2] 域 = **0x40**（16=0b010000），我期望写成 0x80（那是 32） | 位域期望值用 `(value << 低位)` 心算两遍 |
| 8 | **ALIVE 周期**：beat_cnt[23] 在 2²³ 拍**上升**、2²⁴ 拍回零（周期 2²⁴、占空 50%） | TB 在 (2²³, 2²⁴) 区间采样（现取 2²³+2²²） |
| 9 | **TB 时序**：`#80_000` 是 80 μs 不是 100 μs（注释骗了自己）；CRC 泵必须放在复位释放**后**，否则状态被复位冻结、自检恒 0 | delay 注释与数值互检；自检序列排在复位序列之后 |
| 10 | **vlog-2600 RDGN**：字面量前导零冗余（`4'h00`、`32'h0004_0000`） | 写 `4'h0`、`32'h4_0000` |
| 11 | **VCD 近乎空**：`$dumpvars(1, dut)` 只出 299 B（值变化没落盘） | ✅ 已定位（09-22）：vopt 默认优化剥可见性，见工具链坑 7；`-voptargs=+acc` 修复，实测 6.9 MB |
| 12 | **`expect` 是 SV 2005 保留字**：task 参数名叫 expect → Verilator 报 `Unsupported: reserved word 'expect'` 连环语法错（vlog 宽松不报，双轨都被 Verilator 拦下） | TB 标识符避开 SV 保留字（用 `expect_crc`） |
| 13 | **rst_sync 不能单独 `--top-module` lint**：模块内输出端口与模块同名（合法 Verilog、存量代码），Verilator 报 `same name as instance` | 该模块由 AFDX_top gate 覆盖（tools_lint.ps1 gate 2 已剔除并注明） |
| 14 | **tb 里 NBA 于 initial/task**：`<=` 在 task 里被 Verilator 按 `=` 执行告警（INITIALDLY） | TB 延时驱动本就依赖调度顺序，-Wno-fatal 下无害，认知即可 |

## 四、已验证的可用命令

```bat
:: 版本/授权自检（新 shell 直接可用；旧 shell 先恢复变量）
set SALT_LICENSE_SERVER=C:\Users\tortl\questa_lic.dat
C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe -version

:: T01 一键（自动定位 vsim + 恢复授权 + 日志到 sim/out/run_t01_console.txt）
cd C:\Workspace\diansai\sim
powershell -ExecutionPolicy Bypass -File run_t01.ps1

:: DUT lint（Verilator）
"C:\Program Files (x86)\eHiWay\eLinx3.0\verilator\verilator.exe" ^
  --lint-only -Wall -Wno-fatal -Wno-WIDTH --top-module AFDX_top ^
  rtl\common\rst_sync.v rtl\common\timebase.v rtl\common\sync_fifo.v ^
  rtl\common\crc32.v rtl\top\AFDX_top.v
:: TB lint：再加 --timing -Wno-PINCONNECTEMPTY 和 sim\tb\*.v
```

墙钟参考：T01 全跑 ≈ 90 s（vsim 启动 ~25 s + vlog ~15 s + 84 ms 仿真），远在 §12.4 的 600 s 预算内。

## 五、eLinx 侧补充（同日，空壳综合通过后）

1. **eLinx_synthesis 无 headless `write_vqm`**（主 exe 与 _ip.exe 均无此命令，`help` 249 行里
   私有命令只有 `amendvqm`/`read_device`；`verilog_backend` 也不存在）→ `.vqm` 网表只能由
   GUI 流程的 Infrastructure 后端写出。无 GUI 综合自证到 `synth`+`stat` 为止
   （按设计书 §11：综合是可选项、非交付物）。可复现命令与日志在 `elinx/prj/`。
2. **Questa 2025.3 Starter 的 win64 目录没有 `modelsim.exe`**（有 vsim.exe/visbatch.exe/
   questasim.exe/qrun.exe 等 57 个 exe，唯独没有 modelsim.exe）→ eLinx GUI 的
   "Run Behavioral Simulation"（硬编码找 modelsim.exe）无法指向本模拟器。等价批处理路径
   `vsim -c -do xxx.do` 已验证可用（拆解报告 §4.6），交付证据走批处理日志。
3. eLinx 综合实跑结果（2026-09-21）：`eLinx_synthesis.exe -s elinx/prj/AFDX_top_synth.ys`
   → **Yosys execute success**，3281 cells（1417 MUX / 550 OR / 572 AND / 103 NOT /
   11 XOR / 509 DFF / 119 LCELL），500 wires，0 错误。
4. **设计书是 CRLF 文件**（1387/1387 行全 CRLF）：跨行锚点补丁必须用 `\r\n` 匹配，
   只用 `\n` 的单行锚点能过、跨行锚点必挂（09-22 v0.5.3 补丁第一版 E6 即此）。
   远端补丁流程（已验证）：SHA256 锚点定位文件（命令里不出现中文路径）+
   `[IO.File]::ReadAllText/WriteAllText`（UTF8 无 BOM）+ old/new 全 base64 载荷 +
   「每处锚点必须恰好 1 次出现，否则整单不写」的原子校验；先备份到 `.bak_20260921\`。
5. timebase.v 头注释仍引用旧节号「§7.18」（FREQ_ADJ 那条），文档该节现为 §7.15——
   第 2 周动 RTL 时顺手把注释节号对齐（本轮只动文档，未碰 RTL）。
