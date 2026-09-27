# STA —— continue2（2026-09-25）：从 BLOCKED 变成有实测数据，且**明确不收敛**

## 1. 前置条件如何被解除

旧状态 `BLOCKED_NO_REVISION_OR_TIMING_NETLIST` 的直接原因是
`create_timing_netlist` 报 `Can't find active revision` —— 本机**从来没有 Quartus 工程**。
本轮查明：eLinx3.0 捆绑了**完整 Quartus II 13.0.1 后端**
（`bin/Passkey/bin/` 下有 `quartus_sh/map/fit/sta/asm/cdb/...`），
已安装器件族 **Stratix IV 与 Stratix**（`common/devinfo/`、`sta/part_list.txt` 共 256 个型号）。
于是本轮**真的建了工程**，而不是继续写 BLOCKED。

- 工程：`elinx/prj/quartus/AFDX_top.qpf` / `AFDX_top.qsf`，revision **AFDX_top**
- 器件：**EP4SGX230HF35C2**（取自本机实际型号清单）
- 约束：`elinx/sdc/AFDX_top.sdc`（本轮新增）。**注意它与 `AFDX_top.edc` 并非逐字一致**：
  Quartus TimeQuest 不接受 Synopsys 写法 `set_clock_uncertainty <值> <对象>`，
  必须写成 `-setup/-hold -from ... -to ... <值>`；`set_clock_transition` 在 TimeQuest
  中没有对应命令，只保留在 `.edc` 里供 eLinx 流程使用。两处差异已写进 `.sdc` 头部注释。
- 建工程脚本：`elinx/prj/quartus/mk_project.tcl`（rc=0）

## 2. Analysis & Synthesis（quartus_map）

`quartus_map AFDX_top -c AFDX_top` → **rc=0**，12 分 10 秒，**0 errors / 66 warnings**：

| 指标 | 值 |
|---|---:|
| Implemented device resources | 140,534 |
| Implemented logic cells | 139,607 |
| Implemented RAM segments | 731 |
| Implemented input pins | 73 |
| Implemented output pins | 123 |

（`Warning (21074)`：`pps_in` 不驱动任何逻辑——与 `.sdc` 里 `set_false_path -from [get_ports pps_in]` 一致。）

## 3. 一次必须记录的事故：约束文件缺失 → 默认 1 ns 时钟 → 数字全错

本轮 STA **跑了两遍**，第一遍的数字是**错的**，此处完整披露：

- 第一遍运行时，`.qsf` 里已写 `SDC_FILE "C:/Workspace/diansai/elinx/sdc/AFDX_top.sdc"`，
  但该文件**实际并不存在于磁盘上**（创建步骤此前失败且未被发现）。
- Quartus **不会因此报错**：`read_sdc` 找不到文件就静默回退到**默认 1 ns（1 GHz）时钟**。
  `post_map_sdc.rpt` 里写着 `create_clock ; clk ; 1.000`，是唯一能发现问题的地方。
- 后果：第一遍得到的 `WNS -22.048` / `TNS -1,103,482.274` / `Fmax 43.39 MHz`
  全部是**对着 1 GHz 时钟**算出来的，不能用。
- 处置：补齐 `.sdc` → 第二遍 `read_sdc` 又因 Quartus/Synopsys 语法差异 **rc=3** 报错
  （见 §1 说明）→ 改正语法后第三次运行 rc=0，才得到下表数字。
- 第一遍的错误报告**没有删除**，原样归档在 `sta/default_1ns_no_sdc/`（9 个文件）作为反例。

**经验**：Quartus 的 SDC 缺失是静默失败。任何 TimeQuest 结论都必须先核对
`report_sdc` 输出里的 `create_clock` 周期是不是你要的值，再看 slack。

## 4. TimeQuest 实测结果（post-map，8.000 ns 约束真实生效）

`quartus_sta -t sta_post_map.tcl` / `sta_summary.tcl`，rc=0，Slow 900mV 85C 模型：

| 项目 | 实测值 | 要求 | 判定 |
|---|---:|---:|---|
| **Fmax（clk）** | **42.56 MHz**（Restricted 42.56） | 125 MHz | **不满足（差 2.94 倍）** |
| Setup WNS | **-15.498 ns** | ≥ 0 | **违规** |
| Setup End-Point TNS | **-567,451.740 ns** | — | 大面积违规 |
| Hold WNS | -0.128 ns | ≥ 0 | 违规（post-map 无布线，仅供参考） |
| Hold End-Point TNS | -35.706 ns | — | — |
| 约束时钟 | clk **8.000 ns**（波形 0.000/4.000），uncertainty 0.45（setup+hold 各一条） | — | 未约束时钟 0、非法时钟 0 |

`report_sdc` 已确认约束来自 `AFDX_top.sdc:27/30/34`，周期 8.000 —— 与事故那轮的 1.000 形成对照。

**关键路径（20 条最差路径同值 -15.498）**：

```
From : rst_sync:u_rstsync|r[2]
To   : rx_port_buf:u_rxpb|p_cnt~508 （以及 ~28/~60/.../~500 等 256 端口计数器组）
Data Arrival 28.644 ns / Data Required 13.146 ns / Data Delay 22.975 ns
Clock Skew -0.013 ns / Clock Uncertainty -0.450 ns / Relationship 8.000 ns
```

即**同步复位 `rst_sync` 扇出到 `rx_port_buf` 256 端口计数器组**的组合路径，单条 22.975 ns。
注意 `Data Delay` 与时钟周期无关，所以事故那轮和本轮的 22.975 ns 是同一条物理路径——
变的只是它被拿去和 1 ns 还是 8 ns 比较。完整明细：`sta/post_map_setup.rpt`（153,236 B，20 条 full_path）。

## 5. 边界（这些话不能说）

- 这是 **post-map（综合后、布局布线前）** 分析：**没有布线延时**。
  因此 setup 结果是**乐观上界**——真实布线后只会更差；hold 结论在此阶段**无参考价值**。
  **不是时序签核（sign-off）**，没跑 `quartus_fit`。
- **没有板级引脚分配与实测 IO 预算**，因此 `.sdc` 里**故意不写** `set_input_delay/set_output_delay`。
  未约束路径：输入端口 71 个、输出端口 120 个（`sta/post_map_unconstrained.rpt`）。
  **结论只对寄存器到寄存器的内部路径有效。**
- 器件 EP4SGX230HF35C2 是**本机可用型号中的选择**，不是项目指定的目标器件；
  139,607 logic cells 是综合估计，**未经 Fit 验证能否装下**。

## 6. 由此产生的、必须承认的新结论

> **整机在 125 MHz 下时序不收敛，且差距很大：实测 Fmax 42.56 MHz，需要约 2.94 倍改善。**
> 这不是"未验证"，是"已验证为不满足"。之前所有"周期级功能仿真 50/50 PASS"
> **不能**推出时序收敛；本轮首次拿到可审计的反证。

下一步的真实工程动作（按收益排序）见 `../../doc/后续计划.md`：
复位扇出流水化/分级、`rx_port_buf` 256 端口计数器组分银行、
大位宽比较链（`$eq` 19,019 个）打拍，然后再做 Fit + post-fit STA。
