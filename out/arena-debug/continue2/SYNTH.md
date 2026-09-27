# 顶层 eLinx 综合 —— continue2（2026-09-25）从 BLOCKED 到 rc=0

## 1. 结论

| 流程 | 脚本 | exit_code | 耗时 | `^ERROR` | `^Warning` | 成功横幅 | 结果 |
|---|---|---:|---:|---:|---:|---|---|
| 通用（memory_map 全展开） | `elinx/prj/AFDX_top_synth.ys` | **0** | 177 s | 0 | 0 | `Yosys execute success!` | 473,423 cells / 83,219 `$dff` |
| 器件 BRAM 映射 | `elinx/prj/AFDX_top_synth_bram.ys` | **0** | 130 s | 0 | 0 | `Yosys execute success!` | 47,041 cells，含 **439 `altsyncram`** |

两次都是 `hierarchy -top AFDX_top` 的**完整层次**（24 个模块全部实例化，日志无 blackbox/未解析模块），
不是子模块探针、不是 pre-opt 中间态。原始日志、rc、SHA-256 见本目录 `synth/`。

## 2. 根因（二分定位，可复现）

顶层 `OPT_MUXTREE / OPT_MERGE: ERROR: bad allocation` 的决定性变量是 **`NUM_RX_VL`**，
不是 `NUM_PORTS`。三个隔离实验（全部子模块 `blackbox`，只留 `AFDX_top` 自身逻辑与存储）：

| 实验 | 参数 | 结果 | 停在 |
|---|---|---|---|
| `synth/iso_top_only` | 默认 `NUM_RX_VL=4096` | **失败** `ERROR: bad allocation`（55 s） | `OPT_MERGE` |
| `synth/iso_top_rxvl64` | `NUM_RX_VL=64` | **exit_code=0**（29 s） | 正常结束 |
| `synth/iso_top_ports16` | `NUM_PORTS=16`，RX_VL 不变 | 超时被杀（300 s） | `OPT_MUXTREE` |

被压垮的结构是顶层 `reg [31:0] rx_cfg_mem [0:2*NUM_RX_VL-1]`（8192×32 bit）
带 **6 个组合读口**（FLT w0/w1、RM w0、解析 w0、主机 w0/w1）。旧 Yosys 分支在
32 位进程里把它展开成多路选择器树，内存耗尽。

## 3. 已采用的修复（功能等价，未削功能/未缩地址/未屏蔽错误）

1. `rtl/common/bram_sdp.v` 新增 `bram_1w1r`（1 写口 + 1 同步读口，`RD_NEG` 选择读口时钟沿）。
2. `rtl/top/AFDX_top.v` 把 `rx_cfg_mem` 换成 **6 个 `bram_1w1r` 副本**，每个消费者独占一个读口：
   `u_rxcfg_flt0/flt1/rm0/prs0`（`RD_NEG=1`，读地址是上升沿寄存的级输出，下降沿采样，
   与原组合读**逐拍等价、无额外气泡**，代价是读出到消费寄存器为半周期路径）；
   `u_rxcfg_h0/h1`（`RD_NEG=0`，主机读在 ACK 拍直出）。写口全部同源，扫描优先级不变。
3. `rtl/common/bram_sdp.v` 的 `BYTE_EN=1`（PMEM）按 lane 拆成 4 个 8 bit 整字写存储体，
   因为"同一 `$mem` 上按 lane 部分写"不被 `memory_bram` 接受，会退化成 8192×32 触发器。

**本轮修复的真实缺陷**：上一轮把 `rdata_r` 在 `rx_hit` 时改成常 0 并新增 `rxc_rd_d/rxc_host_rdata`，
但 **`assign host_rdata` 选择器漏接了 `rxc_host_rdata`**，导致所有 RX_VL_CFG 主机回读恒为 0。
这不是工具问题而是接线遗漏，现场证据是 `T01 [err] RX CFG readback 00000000`、
`T08f/T08fg errors=8191`、`T22/T22g [err] RX_VL_CFG readback`。修复见 `fixes.patch`。

## 4. 存储是否真的进了 BRAM

`memory_bram -rules .../stratix/common/brams.txt` + `techmap .../brams_map.v` 装入
`$__M4K_ALTSYNCRAM_{DUALPORT,SINGLEPORT,ROM,BIDIRDUALPORT}_FULL`，最终 `stat`：

- `bram_1w1r W=32 D=4096 RD_NEG=0`：35 cells = **32 `altsyncram`** + 3 `$mux`（×2 实例）
- `bram_1w1r W=32 D=4096 RD_NEG=1`：同上（×4 实例）
- `bram_sdp_core W=8 AW=13 D=8192`：`altsyncram`（×4 lane）
- 顶层合计 **439 `altsyncram`**，`Number of memories: 0`（已全部映射，无残留 `$mem`）

对照：不做 BRAM 映射时同一 `bram_1w1r` 是 20,659 cells（4,097 `$dff` + 8,194 `$mux`），
顶层 473,423 cells。**10 倍差距就是"存储落 BRAM"与"存储展开成寄存器"的区别。**

## 5. 边界（不得越界宣称）

- 这是**前端综合**：通用 cell + `altsyncram` 原语。eLinx 这条路径**没有** LUT/ALM 技术映射、
  没有布局布线、没有器件利用率百分比，因此**不能**说"FPGA 资源占用 X%"。
- 该 eLinx 分支**没有** `memory_libmap`（`synth/probe_writers.log:351 No such command`），
  只能用 legacy `memory_bram -rules`。
- 网表 `synth/AFDX_top_bram_netlist.v`（49,126,317 B）由 `write_verilog -noattr` 导出，
  是 RTLIL 级网表，**未**做等价性检查（LEC），不能当作签核网表。
- 器件级资源/时序请看 `STA.md`（Quartus 真实工程），不要用本文件的 cell 数替代。
