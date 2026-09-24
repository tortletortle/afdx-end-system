# AFDX 端系统总体设计书 —— 优化增量 r1

| 项目 | 内容 |
|---|---|
| 基线 | `AFDX端系统_总体设计书.md` v0.5.2（2026-09-21，1387 行）+ `doc_组委会问答.md` + eLinx 3.0.7 拆解结果（`doc_eLinx3.0_拆解报告.md`） |
| 性质 | **增量评审文档，不改动原文**。每条建议给出：现状（引用原文章节）→ 问题 → 建议 → 影响面（章节 / 脚本 / 用例）→ 代价。采纳与否由原作者决定，采纳后按 §10 质量门回写并跑 `tools/run_all.py` |
| 评审范围 | 全文：协议合规、架构、微架构、存储、时序口径、验证环境、工具链适配（eLinx/ModelSim）、进度、文档交付 |
| 日期 | 2026-09-21 |

优先级约定：**P0** = 影响正确性/合规或必须在 RTL 动工前（第 1 周末 09-29）定下来；**P1** = 明显降低复杂度或风险，第 2~3 周内可做；**P2** = 可选增强。

---

## 0 结论速览

设计书整体质量高：需求分解完整、判决式与地址表有脚本闭环、风险登记与用例矩阵齐全，这些不需要动。下面 28 条建议里，真正要"改方案"的只有 P0 的 9 条，其余是简化与加固。

| # | 建议 | 优先级 | 收益 | 代价 |
|---|---|---|---|---|
| O-01 | 统一 Lmax 口径为 A664P7 定义（以太帧长含 FCS），线上开销 +20 B；重算 T05a/b/c 与 CFG_SUM | **P0** | 消除 43 B/帧的系统性低估（T05b 实为 115% 过载） | 改 `bag_model.py`、§8.2、§12.2、附录 C 说明 |
| O-02 | SN 不计入 IP Total Length / UDP Length（核对 XAPP1130 帧格式图） | **P0** | 帧格式合规，`scapy` 可直接解析 | 改 §6.1/§6.3/§6.4、builder/parse 两处长度式 |
| O-03 | SMAC 按 A664P7 布局：`02:00:00:UDI[15:8]:UDI[7:0]:{IF_ID[2:0],5'b0}` | **P0** | 合规；评委易查 | 改 §6.2、`tx_rm`/builder 替换字节位置 |
| O-04 | CRC32 与 UDP/IP 校验和在 `mac_rx_if` 收字节时**流式计算**，删除"迟到撤销"机制 | **P0** | 判决链与帧长无关且无撤销；删 `FCS_LATE_DROP_DIS`、`crc_late_drop`、R8；修复"坏帧已更新 PSN"漏洞 | 删代码为主，新增约 100 行 |
| O-05 | `mac_rx_if` 顺带抓取前 42 B 首部到寄存器，`rx_flt`/`rx_ip_udp_parse` 不再回读 PMEM | **P0** | 判决链 ≈10 拍确定值；PMEM 读口压力降为 0 | 336 FF + 5 B 尾部移位寄存器 |
| O-06 | PMEM 改 32 bit 宽（4 字节通道），与主机字宽一致；pass1 4 B/拍 | **P0** | 饱和最大帧 TX 首字节 118.7 μs → ≈3 μs；解决"32 bit 主机写 8 bit RAM"未定义问题 | 收发各加一个 4 字节打包/拆包 |
| O-07 | 主机接口改为流水式单拍写/固定延迟读，删除 `BURST_*` 三个寄存器 | **P0** | 全表灌入 0.555 ms → 0.278 ms；`host_if` 少 ~100 行 | `regs.yaml` 删 3 项 |
| O-08 | 复位后增加表项清零扫描 `INIT_DONE`（PSN/RM/哈希 valid/描述符） | **P0** | 修复"BRAM 不复位但假设 PSN=0"的 X 传播 bug | 一个计数器 FSM，≈25k 拍 |
| O-09 | 接口适配层支持两种模式：`IF_MODE=0` 帧包络（现方案）/ `IF_MODE=1` GMII 连续字节（`valid` 即 DV，`ready` 忽略/状态） | **P0** | 对冲 R1 与附录 D 第 1/2 项未答复的风险 | `mac_*_if` 各 +50 行；用例 ×2 |
| O-10 | BAG 锚定在帧首（`frame_start`）而非 `done` | P1 | 饱和配置才真能饱和；与 A664P7 BAG 定义一致 | 改一行更新点 |
| O-11 | 采用 A664P7 的抖动上界公式作为合规判据，单帧/30 μs 只作稳态工程目标；增加起始相位错开 | P1 | 同相启动的 T05b 至少排队 801.04 μs，无法按 500 μs 合规 | 文档 + 必要的 `vl_offset` 或等效错相机制；RTL/配置脚本/T05 待验证 |
| O-12 | IC 首帧规则：PSN=0 时按通用式接受 SN∈{1,2}（核对规范） | P1 | 合规 | 一行 |
| O-13 | RX 哈希改 2 表 × 2 路布谷鸟（cuckoo），查找固定 2 拍、无探测、无 `HASH_CONF` | P1 | 删 3 级探测；地址区 16384 字 → 8192 字（顺带关闭 v0.5.2 遗留项） | `hash_seed.py` 改为布谷鸟摆放 |
| O-14 | 调度器改顺序扫描 + BRAM 时间戳（1 μs 内扫完 128 VL） | P1（可选） | −2.0K LUT −5.9K FF，代码 420 → ≈250 行 | 调度延迟 +≤1.02 μs |
| O-15 | 仿真器选型：用 Quartus 包里的 Questa-Altera Starter（64 位、支持 SVA/covergroup）；ModelSim 10.x 仅作 eLinx 联合仿真取证 | **P0** | 断言/覆盖率计划才能落地 | 重编 `elinx_lib`（3 个文件） |
| O-16 | 断言写成过程式检查器、covergroup 用 `ifdef` 隔离，保证在 ModelSim/Questa/Verilator 三者都能编译 | P1 | 环境无关 | 写法约束 |
| O-17 | 回归用"后门装载"替代 `save`/`restore` 快照 | P1 | 稳定、快；T22 仍走前门 | `bram_sdp` 模型加 `load_hex()` 任务 |
| O-18 | 黄金模型 → 文件向量（stim/expect），TB 做确定性回放 | P1 | 与仿真器解耦，产物可归档进报告 | 约定目录与格式 |
| O-19 | 第 2 周末先打通"纵向切片"（1 VL 端到端 + eLinx 综合 + 回归 + 出图） | P1 | 集成风险前移 | 调整 §13 |
| O-20 | eLinx 适配：SDC 只用 eLinx 支持的命令子集；器件默认 EQ6HL130P；RAM 推断冒烟测试；`clog2` 自备函数 | P1 | 第 5 周不被工具卡住 | 见 §5 |
| O-21 | eLinx 工程作为交付物：TB 顶层保持"eLinx 可点 Run Behavioral Simulation"的简单形态 | P1 | 评委可一键复现 | 双 TB 顶层 |
| O-22 | 用 eLinx 自带 Verilator 做 lint（本机已有，不必另装） | P1 | 质量门立即可用 | 改 `tools/lint.sh` 路径 |
| O-23 | PMEM 分配粒度 2 KB → 512 B 链式（或至少 `PMEM_KB=64`） | P2 | 小帧缓存能力 ×4 | 描述符加 `next` 链 |
| O-24 | 长时随机回归可用 Verilator（Linux/WSL）做吞吐，Questa 出取证波形 | P2 | T18 8 h 的有效覆盖 ×10 以上 | 需 C++ 环境 |
| O-25 | 文档双版本：评委版（去掉过程性自查叙述）与内部版同源生成 | P1 | 20% 文档分 | `tools/md_public.py` |
| O-26 | 指标测量定义前置：每个指标给测量点、公式、脚本名 | P1 | 20% 指标分 | §2.2 加列 |
| O-27 | `CFG_SUM` 的每 VL 带宽份额由脚本算好写入表项，硬件只做加法 | P1 | 去掉未说明的除法 | 表项加 1 字段 |
| O-28 | 100 MHz→125 MHz 换算残留与前后不一致清单（15 处） | **P0** | 文档自洽 | 给 `check_doc_numbers.py` 加规则 |

---

## 1 协议合规（P0 为主）

### O-01 Lmax 口径与线上开销（P0）

**现状**：§8.2 判决式写作 `Σ (20 + Lmax_j + 4) × 8 / BAG_j`（把 Lmax 当作不含 FCS 的帧长），而 v0.4 版本记录与 T05 用例块又写明「Lmax=载荷、帧长=Lmax+24」，T05c 取 Lmax=1471（这是载荷上限，不是帧长上限）。§7.8 的 `len ≤ Lmax[vl]` 里 `len` 又是帧长。同一个词三种含义。

**问题**：按「Lmax=载荷、帧长=Lmax+24」算，每帧漏掉 14+20+8+1 = 43 B 的首部与 SN。后果：

| 用例 | 原文 | 实际线上字节（载荷+47+20） | 实际占用 |
|---|---|---|---|
| T05a 32 VL / 载荷 256 / 8 ms | 280 B，8.96% | 323 B | **10.34%** |
| T05b 32 VL / 载荷 256 / 718 μs | 280 B，99.83%「合法」 | 323 B | **115.2%，实际过载** |
| T05c 128 VL / 载荷 1471 / 8 ms | 1495 B，1.9136× | 1538 B | 1.969× |

T05b 是抖动指标的承载用例，按现在的参数跑，调度器会持续落后、`bag_viol` 计数上涨，而 `CFG_SUM` 硬件（同一公式）却判"合法"——测出来的将是"判决式放过了过载配置"。

**建议**：采用 A664P7 的定义：**Lmax = 以太帧长度，DMAC 起算、含 FCS，64 ≤ Lmax ≤ 1518**；线上开销固定 20 B（7 B 前导 + 1 B SFD + 12 B IFG）；载荷 = Lmax − 47。判决式改为 `Σ (Lmax_j + 20) × 8 / BAG_j ≤ 100 Mbps`。T05 重算：

```
T05a  32 VL / Lmax=303 (载荷 256) / BAG=8 ms   ⇒ 10.34 Mbps，占用 10.34%，单帧线上 25.84 μs
T05b  32 VL / Lmax=303 / BAG=828 μs            ⇒ 99.86 Mbps，占用 99.86%（饱和）
T05c  128 VL / Lmax=1518 (载荷 1471) / 8 ms    ⇒ 196.9 Mbps，占用 1.969 倍 → 必须被 CFG_SUM 拒绝
```

**影响面**：§2.2（帧长一栏"不含前导码与 FCS"改为"不含前导码/SFD、含 FCS"，与其 1471 推导式一致）、§6.1、§7.8、§8.2、§12.2 T05 参数、附录 B/C 的 `lmax` 字段说明、`tools/bag_model.py`（唯一实现，改一处）、`check_doc_numbers.py` 的期望值、`STATUS`/`ERR.BAG_OVF` 阈值。

### O-02 SN 的位置与长度字段（P0，需核对）

**现状**：§6.3 `Total Length = 20 + 8 + L + 1`，§6.4 `Length = 8 + L + 1（含 SN）`，§7.12 P2 检查 `length == L+9（含 SN）`，UDP 校验和含 SN。

**问题**：按 A664P7（XAPP1130 v1.0.1 的 Frame Format 图同口径），SN 是以太网帧数据域尾部、FCS 之前的独立 1 字节，**不计入 IP Total Length，也不计入 UDP Length 与 UDP 校验和**；填充（使 AFDX 载荷 ≥17 B）位于载荷之后、SN 之前。现方案自洽（TB 和 RTL 同一约定），但：① 与规范不符，评委按规范核帧格式会扣；② `scapy` 交叉验证时 SN 会被当作 UDP 载荷最后一字节，§12.1 的独立复核失去意义；③ 若决赛要与任何第三方模型互通必然失败。

**建议**：`Total Length = 20 + 8 + L(+pad)`，`UDP Length = 8 + L`，SN 位于 `14 + Total Length` 处（FCS 之前 1 字节）；接收侧 SN 位置由 IP Total Length 定位（或 FCS 前 1 字节，两者应一致，不一致计入 `drop(len)`）。请先在本机 `xapp1130 (1).pdf` 的帧格式图核实一次再改，改动本身只是两条长度式。

**影响面**：§6.1/§6.3/§6.4/§6.5、§7.3（`P1_CSUM` 不累加 SN）、§7.12、`afdx_model.py`、T02/T03 期望帧。

### O-03 SMAC 布局（P0）

**现状**：§6.2 `02-00-00-UDI-IFID<<4|net_id-00`。

**建议**：A664P7 的源地址是 24 bit 常量 `02:00:00` + **16 bit User Defined ID** + **3 bit Interface ID**（A 网 = 001，B 网 = 010）+ 5 bit 0，即最后一字节为 `0x20`（A）/`0x40`（B）。`SMAC_CFG` 寄存器把 `UDI` 扩到 16 bit，`IFID` 字段改为 3 bit Interface ID。`tx_rm` 替换的字节位置从第 4 字节改为第 5 字节。XAPP1130 有同样的图可核对。

### O-04 校验流式化，删除"迟到撤销"（P0）

**现状**：§7.8 S4 与 §7.12 P4 在判决链之后从 PMEM 回读整帧算 CRC32 / UDP 校验和，最坏 1518 拍；为保持"判决链恒定"，CRC 错的帧先放行再撤销（`crc_late_drop`、`FCS_LATE_DROP_DIS`、R8）。

**问题**：
1. **协议漏洞**：被撤销的帧已经通过 IC 更新了 `psn`，且可能通过 RM 更新了 `last_sn/last_ts`。CRC 覆盖 SN 字节，坏帧的 SN 是随机值——撤销之后 PSN 已被污染，后续合法帧会被判 `OUT_OF_ORDER` 直到 SN 复位。A664P7 的 IC 只对通过 MAC 层校验的帧生效。
2. 完全没必要：字节到达节奏是 1 B/10 拍（GMII 连续模式也只是 1 B/拍），8 级 XOR 树一拍一字节绰绰有余。

**建议**：在 `mac_rx_if` 写 PMEM 的同时流式累加三样东西：CRC32（DMAC 起）、IP 首部反码和（字节 14~33）、UDP 反码和（伪首部 + 字节 34 到 `14+TotalLength−1`，TotalLength 在第 17 字节就已知）。帧尾时三个结果随描述符一起交付，判决链拿到的是"已校验过的帧"。CRC 比较可以用全帧（含 FCS）余数恒等的做法（反射 CRC-32、含末尾取反时全帧余数为 `0x2144DF1C`），不需要知道 FCS 从哪开始——常数请用 `tools/selftest_crc.py` 实测确认后再写入代码。

**删除项**：`rx_flt` S4、`rx_ip_udp_parse` P4、`crc_late_drop` 中断位、`CTL.FCS_LATE_DROP_DIS`（bit 6 变保留）、`INT_ENABLE` 的"CRC 撤销"位、R8、T08/T17 的"两种模式各跑一遍"。`FCS_MODE` 仍保留（0 = MAC 处理，≥1 = ES 校验）。

### O-05 首部抓取，判决链不回读 PMEM（P0，与 O-04 配套）

**现状**：§7.8 S1 读 14 B（14 拍）、S2 读 IP 头，§7.12 P1 读 20 B、P2 读 8 B——判决链实际 ≈ 14+4+2(+6 探测)+4+4+20+8+2 ≈ 60~65 拍，不是 §3.3 写的 20 拍（结论"≪ 640 拍"仍成立，但数字要改）。

**建议**：`mac_rx_if` 把前 42 B 存入 42×8 寄存器（336 FF），另用 5 字节尾部移位寄存器取 SN（FCS 前 1 字节）。描述符携带 `{vlid, ethertype_ok, ip_ver_ihl_ok, proto, total_len, dst_port, udp_len, sn, crc_ok, ipcsum_ok, udpcsum_ok, len, ts, blk}`。`rx_flt`/`rx_ip_udp_parse` 退化为对描述符字段的组合比较，各 1~2 拍。判决链 = flt(1) + lookup(2) + ic(4) + rm(4) + parse(2) + port(2) ≈ 15 拍，确定值。PMEM 读口只剩 builder 与主机两个读者。

**影响面**：§3.3、§7.7/§7.8/§7.12 重写（变短）、§3.4 行数（接收组约 −400 行）、§9 逻辑估算、A8 断言阈值。

### O-06 PMEM 32 bit 宽（P0）

**现状**：§8.6 "16 个 16 Kbit×8 RAM 实例"（8 bit 宽）；§7.14 地址空间按 32 bit 字编址、块 = 0x200 字；§7.1 主机写 PMEM 是 32 bit 字。主机 32 bit 写入 8 bit RAM 的拆分方式全文未定义。§7.3 pass1 按 8 拍/字节读，最大帧 pass1 = 117.7 μs，成为 §8.3"饱和最大帧 TX 首字节 118.7 μs"的全部来源。

**建议**：PMEM = 8192 × 32 bit，物理上用 4 个字节通道（4 × 8192 × 8，天然支持字节写），一个写口一个读口。RX 侧 4 字节打包后写（1 次/40 拍，GMII 连续模式 1 次/4 拍），builder 侧读一字拆 4 字节发。pass1 以 4 B/拍扫描：1471 B → 368 拍 = 2.9 μs。

新的 TX 首字节最坏值：commit 2 + 调度 ≤3（或 O-14 的 ≤128）+ pass1 368 + 首部 12 + IFG ≤ 200 ≈ **585 拍 = 4.7 μs**（最大帧、饱和），比 118.7 μs 好 25 倍，§8.3 的叙事从"时延主要来自 pass1"变成"时延主要来自线速"。

顺带解决：主机写宽度问题、"块号即实例号"的 16 路路由（单口仲裁即可：RX 0.025 字/拍 + builder 0.025 字/拍 + 主机，冲突可忽略）、§7.3 的 4 深字节缓冲。

**影响面**：§7.1/§7.3/§7.7/§8.6/§9（PMEM 行不变仍 256 Kbit）、`bram_sdp` 参数化位宽、`fix_addr.py` 不受影响（字编址不变）。

### O-07 主机接口单拍流水（P0）

**现状**：§5.4 固定 2 拍非流水；为提速引入 `BURST_ADDR/LEN/DATA` 三个寄存器与 16 字突发，收益只有 1.8 倍。

**建议**：同步 SRAM 式接口：写在 `cs&we` 当拍完成、每拍可接一笔；读固定 2 拍延迟、可流水；`host_ack` 保留（cs 的下一拍拉高）以兼容模板。全表 34 688 字 → 34 688 拍 = **277.5 μs**（原 555/312 μs）。删除 `BURST_*`，`host_if` 少一个 16 字 FIFO 与状态机。T22 仍测冷启动灌表时间。

**影响面**：§5.4、§7.14、附录 A（`0x00F0~0x00F8` 变保留）、`regs.yaml`、`host_bfm` API。

### O-08 表项复位扫描（P0，真 bug）

**现状**：§4.2 "BRAM 与表项不复位……`psn[*]=0`（用复位后的 0 值语义）"。

**问题**：行为模型里 `reg [7:0] mem[0:8191]` 复位后是 X，不是 0；`rx_ic` 第一帧就会 `psn == 0` 比较出 X，判决链 X 传播，T09 必挂。FPGA 上未初始化 BRAM 内容也不保证为 0。

**建议**：复位释放后由 `init_sweep` FSM 顺序写 0：PSN 8192 + RM 4096 + 哈希 8192（valid 位）+ 端口描述符 256 + `vl_stats` 128 ≈ 21k 拍（0.17 ms）；期间 `STATUS.INIT_DONE=0`，`RX_EN/TX_EN` 写入被忽略并置 `ERR.ACC`。TB 在配置前等待 `INIT_DONE`。附录 A.2 `STATUS` 加 bit `[13] INIT_DONE`。

### O-09 接口双模式（P0，对冲 R1）

**现状**：§5.3 按"`ready` 帧包络 + `valid` 字节选通、字节间固定 `BYTE_SLOT_CYC` 拍空闲"实现；附录 D 第 1、2 项（语义、字节间能否插空闲拍）仍未答复。`mac_rx_if` 以 `rx_ready` 上升沿开帧。

**问题**：组委会只答了"GMII"。GMII 的语义是 `TX_EN/RX_DV` 在整帧期间持续为高、**每拍一个字节、字节间无空闲**。若评测 BFM 按 GMII 驱动（`rx_valid` 连续、`rx_ready` 恒 1 或悬空），现方案永远等不到 `rx_ready` 上升沿，一帧都收不到。

**建议**：参数 `IF_MODE`：
- `0` 帧包络（现方案，`BYTE_SLOT_CYC=10`）；
- `1` GMII：帧边界 = `rx_valid` 连续为高的区间（低电平 ≥ `IFG_MIN` 拍视为帧间隙），`rx_ready` 仅作可选限定（忽略或作为背压）；发送侧 `tx_valid` 连续 1 B/拍，`tx_ready` 作为"可接收新消息"状态输出；`BYTE_SLOT_CYC=1`。

两种模式共用内部 `{byte, sof, eof}` 流，差异全部封在 `mac_tx_if`/`mac_rx_if`。O-04/O-06 已经把每字节处理做成 1 拍可完成，所以 `BYTE_SLOT_CYC=1` 不需要再改别的模块。T01/T02/T08/T17 各加一档 `IF_MODE=1`。

同时把附录 D 第 2 项改成一个更容易答的问法："评测激励里 `rx_valid` 是否每拍连续（GMII RX_DV 语义）？`rx_ready` 是否恒为 1？"

### O-10 BAG 锚定帧首（P1）

**现状**：§7.2 在 `done` 拍更新 `next_tx = max(tb_us, last_tx) + bag`，`done` 是帧尾。

**问题**：A664P7 的 BAG 定义在两帧**首比特**之间。锚在帧尾等于每个 BAG 多加一个帧时间：T05b 里 828 μs 的 BAG 实际变成 854 μs，"饱和"配置永远到不了饱和；抖动测量基准也随之漂移。

**建议**：`frame_start` 拍记 `last_start[i] = tb_us; next_tx[i] = tb_us + bag[i]`；`due = (tb_us − next_tx) < 2^23`。不再需要 `max()`。

### O-11 抖动判据与相位错开（P1）

**现状**：§8.2 推导"任一 VL 单次等待 ≤ 自身最大帧时间 22.4 μs"，并注明只在占用≈1 的稳态成立。

**问题**：这不是一个上界。所有 VL 在 `TX_EN` 同一拍首次到期时，第 32 条要等 31 帧；即使稳态，BAG 互质的 VL 集合也会周期性对齐。答辩时这条推导容易被问倒。

**建议**：
1. 合规判据改用 A664P7 的 ES 抖动上界（XAPP1130 亦有引用）：`MaxJitter ≤ 40 μs + Σ_j (20 + Lmax_j) × 8 / Nbw`，且 `≤ 500 μs`。T05b（32 × 323 B）的公式值 866.9 μs，取 500 μs 为合规线；22.4/30 μs 改称"稳态工程目标"，报告同时给出瞬态最大值与稳态最大值两列。
2. 加**起始相位错开**：配置脚本给每 VL 一个 `vl_offset_us`（w4 有空位，或复用 `user_vl_tag`），`TX_EN` 置位时 `next_tx[i] = now + vl_offset_us[i]`。这是让稳态抖动真正压到"几十 μs"的手段，成本是一个加法。
3. 抖动测量定义写进 §2.2：每帧 `jitter = t_first_bit − t_bag_slot_start`，`t_bag_slot_start = last_start + BAG`（若消息晚到则以 `commit` 时刻为基准另计，报告分列）。

**v0.5.6 后续核算**：现行 T05b 的 Lmax=303 B、线上 323 B，若 32 VL 同相启动，末条仅排队 `31×25.84=801.04 μs`（未计扫描/握手），已超过 500 μs；`tx_vl_scheduler.v` 目前未实现错相。上述 offset/等效机制从「可选优化」升级为达成 T05b 目标的前置任务，含启动瞬态的合规统计待 RTL/T05 取证。本文早期 22.4 μs 和 `Lmax+24` 等数值属于提案时的历史问题口径，现行公式与数字以总体设计书 §8.2 为准。

### O-12 IC 首帧规则（P1，需核对）

§7.10 在 `psn==0` 时只接受 SN=1。A664P7 的通用式是接受 `SN ∈ {PSN+1, PSN+2}`，PSN=0 时即 {1, 2}；SN=0 恒接受（复位）。建议按通用式实现，`IC_FIRST_ANY` 保留为扩展。请以规范原文或 XAPP1130 的 IC 描述为准。

---

## 2 微架构与存储

### O-13 RX 查找改布谷鸟哈希（P1）

**现状**：§7.9 单哈希 + 2 way + 固定 3 级线性探测，随机 VLID 时最长链实测 6，靠脚本压到 3 以内，压不到就把槽数加倍；`ERR.HASH_CONF`；v0.5.2 遗留"哈希区 16384 字 vs 8192 表项"。

**建议**：2 张表 × 2048 桶 × 2 路（每桶 64 bit 一次读出），两个独立哈希函数 `h1 = fold(vlid) ^ SEED1`、`h2 = fold(vlid × 0x9E37 ...) ^ SEED2`（脚本可选），查找 = 两表并行读（不同 BRAM）+ 4 路比较，**固定 2 拍**。摆放由 `hash_seed.py` 改为布谷鸟插入（负载 50%、桶 2 路时失败概率可忽略，失败则换种子重摆）。运行期没有探测、没有 `HASH_CONF`。存储仍是 8192 × 32 bit = 256 Kbit，主机地址区 8192 字（把 §7.14 那行从 16384 字改回 8192 字，`fix_addr.py` 重排一次）。

### O-14 调度器顺序扫描（P1，可选）

**现状**：§7.2 128 路并行 `due` + 三级 min 归约树，2.2K LUT + 6.1K FF，D3 的理由是"优先选指标"。

**建议**：`tb_us` 每 125 拍才变一次，128 条 VL 用 1 个比较器顺序扫一遍只要 128 拍 = 1.02 μs；`next_tx/last_start/valid/port` 放一块 BRAM（128 × 64 bit），扫描时同时得到"最早到期"的 VL，无需归约树，也无需 128 个 256 选 1 的 `port_ready` mux。代价是调度延迟上界 +1.02 μs（对 30 μs 目标可忽略）。`SCHED_MODE` 可保留用作对照实验，或干脆删掉并改写 D3。若采纳，§3.4 调度器 420 行 → 约 250 行，§9 逻辑合计 15.5K → 约 13.5K LUT。

### O-23 PMEM 分配粒度（P2）

16 块 × 2 KB 意味着全芯片同时只能缓存约 10 帧（含在途），256 个端口、队列深度 1~8 的配置在满载下会频繁 `pmem_exhaust`；64 B 小帧的块利用率 3%。可选两档：① 先把 `PMEM_KB` 默认改 64（无器件约束，仿真里只是多 32 KB 数组）；② 512 B 单元 + `next[64]` 链（1518 B 用 3 个单元），小帧缓存能力 ×4，描述符 `blk` 4 bit → 6 bit，builder/RX 写在单元边界切换地址。①零成本，②约 +150 行。

### O-27 `CFG_SUM` 的份额来源（P1）

§8.2 "每条 VL 存 `ceil((Lmax+24)×80 ns/BAG)`"，但附录 B 的 w0~w4 没有这个字段，硬件若自算需要除法（`bag_us` 是任意 μs）。建议：配置脚本算好 Q20 份额写入表项（w4 `[31:16] port_base` 后仍有空间，或占用 `user_vl_tag`），硬件只做 128 项累加 + 一次比较。同时把 §8.2 的 `20_000` 改为 `2^20 = 1_048_576`（T05 用例块里已是 2^20 口径，正文那句是笔误）。

### 其他微架构备注

- **采样端口覆盖与在途读的竞争**：§7.1 "新消息 commit 覆盖 `ptr`"，若 builder 正在 pass2 读该块会发错帧。规则应为：新消息永远分配新块，旧块在 `frame_done` 后释放；RX 侧同理（主机读中的块不复用）。建议加断言 A13"被读中的块不被重新分配"。
- **§8.5 无旁路前提**加一句：同一 VL 的 A/B 两网副本同拍到达时 IC 表项不同（A 低半区、B 高半区），无冲突；RM 表项相同，由 §7.11 的仲裁串行化。
- `STATUS.PMEM_FREE` 6 bit、`desc_ptr` 10 bit、`blk[3:0]` 4 bit、§7.13 "未读满 32 块"——四处口径不一，按最终块数统一。

---

## 3 验证环境

### O-15 仿真器选型（P0）

事实（见拆解报告）：本机无 ModelSim；eLinx 的联合仿真只认 `modelsim.exe` 路径；`Simulation\elinx_lib` 由 ModelSim 10.0c 预编译；正在安装的 Quartus Pro 26.1.1 自带 **Questa-Altera Starter Edition（64 位，`questa_fse\win64`）**，免费 license 在 Altera 自助授权中心领取。

| 需求 | ModelSim 10.x / Intel Starter | Questa Starter |
|---|---|---|
| §8.8 并发断言 `assert property` | 不支持（Questa 特性） | 支持 |
| §12.3 `covergroup` 功能覆盖 | 不支持 | 支持 |
| 代码覆盖（行/分支/FSM） | PE/SE 可选 | 支持（`vsim -coverage` + `vcover`） |
| eLinx 预编译库 | 直接可用 | 需按 UG102 §11.4 用 `Simulation\verilog\*.v` 重编（3 个文件，几分钟） |
| 规模限制 | Starter 版 >10k 行降速 | Starter 版 >10k 行降速 |

建议：主力用 Questa Starter（跑回归、覆盖率、断言）；eLinx GUI 里"Run Behavioral Simulation"的截图与 log 作为"eLinx 编译及仿真"的形式证据，指向同一个 Questa（若 GUI 坚持找 `modelsim.exe`，复制 `vsim.exe` 一份改名即可，或退回 `vsim -c` 批处理）。**10k 行降速**是真实约束：RTL 7.4K + TB 很可能过线，第 1 周用空壳实测每秒仿真拍数，再定 T18 的时长与 T04 的 BAG 档位是否全跑真实时基。

### O-16 断言与覆盖的写法（P1）

- A1~A12 全部写成过程式检查器（`always @(posedge clk) if (...) $error(...)`），放在 `sim/chk/*.sv`，用 `bind` 或顶层例化；这样 ModelSim、Questa、Verilator（O-24）都能跑。
- `covergroup` 包在 `` `ifdef QUESTA_COV `` 里；同时在 TB 维护一份"手工覆盖计数"（帧长桶、IC 原因、RM skew 桶……）在仿真结束打印成表——没有 covergroup 的环境也能出覆盖率表。
- RTL 内 `ifndef SYNTHESIS` 的断言只允许立即断言。

### O-17 回归快照改后门装载（P1）

§12.4 依赖 `save`/`restore`。ModelSim 的 `checkpoint/restore` 对版本、编译库、外部对象都敏感，且"每条用例独立 vsim 会话"下收益有限。建议 `bram_sdp` 行为模型提供 `load_hex(path)` 任务，TB 在 `INIT_DONE` 后用层次引用直接灌表（毫秒级）；只有 T22 走前门 `host_bfm` 灌表并测时间。配置文件由 `sw/golden` 生成为 `.hex`，同一份也给 eLinx 的 `.mif/.hex` 初始化（工具支持这两种源文件）。

### O-18 黄金模型走文件向量（P1）

`afdx_model.py` 与 SV TB 之间没有写明接口。建议：Python 预生成 `stim/<case>.hex`（主机操作序列 + 注入帧 + 故障事件表）与 `expect/<case>.csv`（每帧期望：判决、原因、端口、时间窗），TB 是确定性回放 + 比对引擎；随机用例的种子记录在 CSV 头。好处：与仿真器无关、失败可精确复现、`expect/*.csv` 直接进测试报告附件。

### O-19 纵向切片先行（P1）

§13 按模块横向推进，"双向单链路打通"在第 3 周。建议第 2 周末交付一个**最小闭环**：1 条 VL、采样端口、无 IC/RM/管理面，但走完 主机配置 → 发送 → BFM 回环 → 接收 → 端口读 → `timing_monitor` 出 CSV → `make_report.py` 出图 → eLinx 综合通过。此后每周只是往切片里加模块。40% 的分在"环境"，环境越早成型越安全。

### O-24 Verilator 做吞吐（P2）

单时钟、同步复位、无 `#延迟` 的 RTL 天然适合 Verilator。8 小时随机回归（T18）在 Questa Starter 降速下有效帧数有限；Verilator 快 1~2 个数量级。取证仍用 Questa（赛方要求波形），Verilator 只负责"跑得多"。需要 Linux/WSL + g++，TB 需满足 O-16 的写法。

---

## 4 时序与数字口径（O-28，P0）

`check_doc_numbers.py` 的 100 MHz 残留禁查漏掉了下面这些；建议逐条修并加规则：

| 位置 | 现文 | 应为 |
|---|---|---|
| §5.3 波形图 | "8 cycles per byte" | `BYTE_SLOT_CYC` = 10 |
| §7.3 P1_FETCH | "按 8 拍/字节"、"L×8" | 按 O-06 改 4 B/拍；不采纳也应是 10 |
| §3.3 表 | pass1 L×10、pass2 F×10 | 与 §7.3 统一 |
| §8.3 | "349 拍 = 3.5 μs"、"117.7 μs"、"pass1（1 B/拍）" | 349 拍 = 2.8 μs；口径按 O-06 重算 |
| §7.10 | "最小帧间隔 512 拍" | 64 B 帧 + 20 B 开销 = 840 拍（或与 §3.3 的 640 统一说明是否含前导/IFG） |
| §3.3/§8.3/A8 | "判决链 20 拍" | O-05 后 ≈15 拍；不采纳则 ≈60 拍 |
| §7.8 | "每帧固定 8 拍" | 与 S1 的 14 拍矛盾 |
| §4.3 `PMEM_KB` 说明 | "发送 8 KB 顺序区 + 8 KB 块区，接收 16 KB 块区" | 三池 16 × 2 KB（v0.3.1 已改，此处漏改） |
| §7.13 | "写 PMEM 顺序区"、"未读满 32 块" | 块池；16 块 |
| §7.7 | `desc_ptr` 10 bit | 与 `blk[3:0]` 统一 |
| §8.2 | `CFG_SUM` 与 `20_000` 比较 | `2^20` |
| §8.2 | 判决式 `(20 + Lmax + 4)` 与 T05 的 `Lmax=载荷` | O-01 |
| §2.2 | 帧长 "不含前导码与 FCS" | "不含前导码/SFD、含 FCS"（否则与 1471 推导矛盾） |
| §7.14 | 哈希区 16384 字 | O-13 后 8192 字 |
| §11.3 | 关键路径预估值 | 标注"未实测"已做到；O-05/O-06 后 PMEM 仲裁与 CRC 两行可删 |

---

## 5 eLinx / 工具链适配（O-20 ~ O-22）

依据拆解实测（`doc_eLinx3.0_拆解报告.md`）：

1. **SDC 子集**：eLinx 实现器（`Implementation.exe`）注册的约束命令只有 `create_clock`、`create_generated_clock`、`set_clock_latency/uncertainty/groups`、`set_input/output_delay`、`set_false_path`、`set_multicycle_path`、`set_max/min_delay`、`get_ports/pins/cells/nets/clocks`（清单见 `_elinx_tcl_cmds.txt`）。§11.2 里的 `set_clock_transition`、`set_max_fanout`、`group_path`、`all_inputs`、`all_outputs`、`remove_from_collection`、`current_design`、`report_timing ... >` 都不在清单里，会直接报错。约束文件扩展名 `.edc`（对话框也收 `.sdc`）。建议 §11.2 只保留：

   ```tcl
   create_clock -name clk -period 8.000 [get_ports clk]
   set_clock_uncertainty 0.45 [get_clocks clk]
   set_false_path -from [get_ports pps_in]
   ```
   时序报告用 GUI 的 Report Timing Summary（后台命令是 `do_timing_analysis` / `print_timing_report` / `get_fmax_and_slack`），不写重定向；§11.4 "`report_timing` 的 20 条最差路径"改为"`print_timing_report` 输出的 rpt 文件"。

2. **器件**：题目不指定，但赛方材料（选题二）出现过 `EQ6HL130P-CSG484`，eLinx 的器件列表里也有它。综合自证选它最无争议；§11.1 "器件用安装自带默认工程"改为"EQ6HL130P（与赛方材料一致）"。§9 的 18 Kbit 块口径保留，另加一列"按该器件 RAM 块实测"（做了 §11 才填）。

3. **综合器是 Yosys 分支**：RAM 推断依赖 Yosys 的 `memory_bram` 规则，4096 × 64 这类大表若推断失败会展开成寄存器、综合跑不完。第 1 周的冒烟测试必须包含一个 `bram_sdp` 实例（同步读、地址/数据寄存、无复位、不做同拍读写假设）看是否映射到 M9K/M4K；不行就走 `ifdef ELINX_SYNTH` 例化 eLinx IP（IP 目录有 M4K/M9K 配置器）。

4. **联合仿真的编译开关**：eLinx 生成的 `.do` 对 `.v` 用 `vlog -vlog01compat`，对 `.sv` 用 `vlog -sv`。RTL 严格 Verilog-2001；`$clog2` 是 2005 项，自备 `function integer clog2` 更稳；第 1 周用 GUI 的 Run Behavioral Simulation 实跑一次空壳确认。

5. **TB 形态（O-21）**：eLinx 用自带 Verilator 5.006 建立源文件层次（`--relative-includes --dump-tree --xml-only`）并做语法检查（`--bbox-unsup -Wno-lint -Wno-style --lint-only`）；`covergroup`、类、`bind` 这类 Verilator 不支持或半支持的构造，很可能让它对 TB 文件报错或认不出仿真 top。建议两个 TB 顶层：`tb_afdx_top.v`（纯 Verilog-2001 + 过程式检查器，加进 eLinx 的 Simulation Sources，评委点按钮就能跑）与 `tb_afdx_cov.sv`（覆盖率、随机约束，只由 `regress.tcl` 在 Questa 下用）。

6. **lint（O-22）**：`tools/lint.sh` 直接调用 `"C:\Program Files (x86)\eHiWay\eLinx3.0\verilator\verilator.exe" --lint-only -Wall`，与 eLinx GUI 用的是同一个二进制，不必另装；README 里那句"Verilator 若没装"可以删。

7. **eLinx 工程即交付物**：`elinx/prj/afdx.epr` 引用 `rtl/` 原位文件（Settings 里关掉 Copy sources into project），Top 设为 `AFDX_top`，Simulation Sources 指向 `tb_afdx_top.v`，3rd Party Simulators 指向 Questa。打包前在干净目录重开一次工程验证路径全部相对。

8. **后仿加分项**：eLinx 有 Run Post-Implementation Simulation（`generate_eda_netlist` 出 `.vo`）。缩配下跑一次 T02，就有"综合后网表波形"，正好回应组委会"对 RTL 或综合后网表跑波形"的口径。

---

## 6 文档与交付（O-25、O-26）

- **双版本**：现文大量"上一版这里写错了""答辩必问""评审最容易挑的刺"属于团队内部语境，评委版应删。建议源文件里用 `<!-- internal -->…<!-- /internal -->` 标注，`tools/md_public.py` 生成评委版；`verify_all.py` 对两个版本都跑。附录 F 的版本记录在评委版只保留版本号与一句话。
- **指标测量定义**：§2.2 加两列"测量点/公式"与"脚本"。例如：抖动（O-11 的定义，`timing_monitor` → `metrics/jitter.csv`）、ES 时延（TX：`MSG_WR` 写拍 → `tx_valid` 首字节拍；RX：`rx_valid` 末字节拍 → `INT_STATUS` 置位拍）、吞吐（`net_model` 统计的线上占用）。20% 的指标分靠的是"可复现的测法"，不是数字本身。
- **帧格式图**：O-02/O-03 落地后在 §6.1 放一张字节级完整帧图（含 pad/SN/FCS 位置与三个长度字段覆盖范围），这是评委最先看的图。
- **A664P7 引用**：R4 说拿不到原文。XAPP1130 已在本机，帧格式、SN/IC/RM 语义、抖动公式都能从它引用；文档里凡写"A664P7 规定"的地方补 "（XAPP1130 v1.0.1 §… 同口径）"。

---

## 7 进度影响与决策期限

| 时间 | 需要定下来的事 |
|---|---|
| 09-23（第 1 周一） | O-01/O-02/O-03（帧格式与口径）、O-06（PMEM 位宽）、O-07（主机接口）、O-09（接口双模式）、O-15（仿真器） |
| 09-26 | O-04/O-05（接收链结构）、O-08（INIT_DONE）、O-13/O-14（查找与调度器方案） |
| 09-29（第 1 周末） | eLinx 空壳综合 + Questa 空壳仿真 + lint 三个门跑通；O-20 第 3 条冒烟结论 |
| 10-06（第 2 周末） | O-19 纵向切片闭环 |

### 09-23 提前定稿（原 09-26 节点；现行口径以总体设计书 v0.5.6 为准）

| 项 | 决策 / 相对本提案的修正 | 落地状态 |
|---|---|---|
| O-04 / O-05 | 采纳：`mac_rx_if` 收字节时完成 CRC/IP/UDP 流式校验，抓前 42 B、末 5 B；好帧描述符才可进入 flt→lookup→IC→RM→parse，坏帧不更新 PSN/RM/端口。删迟到撤销；FCS 完帧余数用 zlib 独立核得 `crc_final=0x2144DF1C` / 原始状态 `0xDEBB20E3`（RTL 仍须 T08 复核）。`INT_STATUS` 原 bit3 改报 CRC 错帧，`CTL[6]` 预留；原风险 R8 不删除编号，改为「校验/复位未闭环」风险，以维持 R1~R9 追溯。 | 文档/`regs.yaml` 定案；RX RTL、T08/T17 尚待实现；不得把 15 拍预算写成实测。 |
| O-08 | 采纳并补齐提案漏算的 BRAM 配置 valid：PSN 8192 + RM 4096 + HASH 8192 + RX 配置 4096 + TX 配置 128 + 端口配置 256 + RX 描述符 256 + VL 统计 128 = **25 344** 写拍（125 MHz 约 203 μs，另计 FSM/可见性延迟），不是原文约 21k。`STATUS[13].INIT_DONE` 为开流门，过早使能置 `ERR.ACC`。 | 文档/`regs.yaml` 定案；`init_sweep`/T01/T22 尚待落地。 |
| O-13 | 采纳「两表×2048 桶×2 way、配置期布谷鸟摆放、运行期固定 2 拍」；**不采纳缩小 host 地址区**：v0.5.3 已将 `0x3D80~0x7D7F` 的 16384 字定为低 8192 表项 + 高半 P2 保留。本版只将低半区映射为 `base+table×4096+bucket×2+way`，地址、逻辑 256 Kbit/15 块不变，不运行 `fix_addr.py`。种子必须参与混合而非只 XOR 桶号，离线重试全失败则拒绝配置。 | 文档定案；`hash_seed.py`、lookup RTL、T12 以及存储映射仍待验证。 |
| O-14 | 采纳并按当前 `tx_vl_scheduler.v` 回写：128 拍顺序扫描、年龄最大者优先、`sch_take`/`sch_ack`、`frame_start` 更新 `next_tx=tb_us+BAG+1`；`bag_viol` 是迟到哨兵，不是小于 BAG 的发送。旧 `SCHED_MODE` bit4 仅保留配置口径，无轮询切换；T13 TX 预算相应改为轻载 ≤1.5 μs、饱和无排队 ≤2.5 μs。 | RTL 有 T04/T04g 单元回归记录；`AFDX_top` 接线、T05/T13、缩配参数与 RAM 推断未取证，资源只列估计。 |

以上是**方案决定与文档回写**，不代表 RX、初始化和满载系统级功能已经通过仿真。`python tools/run_all.py` 只查文档结构/算术；功能仍需 T01/T05/T08/T12/T17/T22 与 eLinx/Questa 实证。

以下为 09-21 原提案的历史估算，不代表 v0.5.6 的实际行数与工期；现行模块清单/小计以总体设计书 §3.4 为准。

---

## 8 无需改动的部分（评审确认）

- IC 的 `exp1/exp2` 回绕式、SN 1~255 与 0 复位语义、RM 的先到有效 + SkewMax 判决与同拍仲裁。
- 单时钟域、同步复位、`pps_in` 两级同步。
- 地址表由 `fix_addr.py` 生成、`check_addr.py` 复核的机制；`regs.yaml` 单一来源。
- 满配/缩配双档（D9）、`TICK_US` 缩放、T21/T22 的加入。
- 风险登记 R1~R9 与需求追溯矩阵的形式。

---

## 9 新增需向赛方确认的问题（建议并入附录 D）

1. 评测激励中 `rx_valid` 是否为 GMII `RX_DV` 语义（整帧连续、每拍一字节）？`rx_ready` 是否恒为 1？（替代原第 2 项的问法）
2. 评测方是否会打开 eLinx 工程点击 Run Behavioral Simulation？若是，使用的 ModelSim/Questa 版本号是多少（决定我们交付的预编译库与脚本形态）。
3. 帧格式中 SN 是否按 A664P7 放在 UDP 数据之外（不计入长度字段）——我们按规范实现，此问只为留痕。

---

## 附：本文引用的原文位置索引

§2.2 指标表 · §2.5 假设 3 · §3.3 数据通路 · §4.2 复位 · §4.3 参数表 · §5.3 接口时序 · §5.4 主机接口 · §6.1~§6.6 帧格式 · §7.1 `tx_port_buf` · §7.2 调度器 · §7.3 builder · §7.7~§7.13 接收链 · §7.14 地址表 · §8.2 判决式 · §8.3 时延预算 · §8.5 无旁路前提 · §8.6 PMEM · §9 存储预算 · §11.2 SDC · §12.1~§12.4 验证 · §13 进度 · 附录 A/B/C/D/F。
