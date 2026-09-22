# elinx/ — eLinx 3.0.7 工作目录

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
