# 第 1 周工作记录（2026-09-22，提前开工日）

> 第 0 周出口条件（空壳双通过）已于 09-21 提前达成，本日把 §13 第 1 周的
> RTL/验证两条腿与 O-20 第 3 条决策点全部收口。新坑见
> `doc_第0周踩坑记录.md` 工具链坑 6~9、RTL/仿真坑 12~14。

## 一、完成清单

| # | 项 | 产出 | 判据与证据 |
|---|---|---|---|
| 1 | `bram_sdp` 存储封装 | `rtl/common/bram_sdp.v`（**1W2R**：1 写 + 读口 A/B，读延迟 1 拍，W=32/D=8192） | 端口形状按 §7.14（读口 A 给 flt/parse、B 给 CRC/校验和）；vlog 0E0W、Verilator lint 过、T00 过 |
| 2 | T00 公共模块单测 | `sim/tb/tb_t00_common.v` | crc32 **9 向量**（8 模式 + 1 真实 AFDX 帧，对黄金模型）；sync_fifo 全行为 + **4000 拍随机**（参考模型逐拍对账）+ 32×4 参数化抽查；bram A 口 8192 全扫 + B 口步长 97 抽样 + 三口同拍并发。`T00 COMMON PASS` |
| 3 | CRC 向量生成器 | `sw/golden/gen_crc_vectors.py` | 黄金模型单一来源（zlib.crc32）；真实帧 FCS=0xC45B5174 与 RTL 一致 |
| 4 | 回归基建（§12.4 骨架） | `sim/tests.manifest` + `compile.tcl` + `run_one.tcl` + `run_regress.ps1` | 每用例独立 vsim 会话、600 s 超时保护、`out/regress.csv`；`REGRESS SUMMARY: 2/2 pass` |
| 5 | lint 门 | `tools_lint.ps1`（7 gate） | `LINT GATE: PASS`（AFDX_top + bram_sdp/sync_fifo/crc32/timebase + 2 TB） |
| 6 | 踩坑 #11 VCD 定位 | `run_t01.tcl` 加 `-voptargs=+acc`、回归 `-Acc` 开关 | 根因 vopt 剥可见性；+acc 实测 299 B → **6.9 MB**（`sim/out/t00_acc_console.txt`） |
| 7 | **O-20 第 3 条 BRAM 冒烟（决策点，原定 09-29）** | `elinx/prj/bram_sdp_smoke.ys` | **可行**：`memory_bram` 显式序列 → 1W2R 8192×32 = **128 × altsyncram(M4K)**，rc=0。裸 `synth` 宏有 $mem 双驱动 bug（与写法无关），须用显式序列。**ELINX_SYNTH IP 分支不需要** |

## 二、O-20 第 3 条决策记录（评审口径）

1. **结论**：行为模型 + 显式 `memory_bram -rules brams.txt` + `techmap -map brams_map.v`
   即可映射片上 M4K，`bram_sdp` 不做 `ELINX_SYNTH` IP 例化（§7.19 的 ifdef 分支保留
   作后备，不启用）。
2. **代价**：1W2R = 双读口镜像，128 M4K = 512 Kbit > EQ6HL45（437 Kbit）。指标与
   敏感性表按赛方器件 **EQ6HL130P** 口径算（优化增量 r1 已定）；若第 4 周 PMEM
   实例化后发现资源紧张，先评估砍 B 读口（读口分时）再退 IP 路线。
3. **为什么 1W2R**：设计书 §7.14 PMEM 本就要 2 读口（控制流与校验和并行）；
   且 eLinx 的 $mem 即 1W2R 形状（RD_DATA/RD_DATA_B），单读口写法反而踩工具 bug。

## 三、新增/修改文件清单

```
新增  rtl/common/bram_sdp.v            sim/tb/tb_t00_common.v
新增  sim/tests.manifest  sim/compile.tcl  sim/run_one.tcl  sim/run_regress.ps1
新增  tools_lint.ps1       sw/golden/gen_crc_vectors.py
新增  elinx/prj/bram_sdp_smoke.ys       elinx/prj/_bram_mbram.ys（探针，保留作证据）
改    sim/run_t01.tcl（+acc）  doc_第0周踩坑记录.md（坑 6~9、12~14）
改    README_tools.md  elinx/README.txt
证据  sim/out/regress.csv  sim/out/t00_acc_console.txt
      elinx/prj/bram_sdp_smoke.log  elinx/prj/_bram_mbram.log
```

## 四、下一步（第 1 周剩余 → 第 2 周提前量）

- [x] 09-23 决策点（优化增量 r1 表）：O-01/02/03/06/07/09/15 全部采纳 —— 见下「七」（设计书 v0.5.5）
- [x] 设计书 v0.5 定稿（§7.19 bram_sdp 改「1 写 2 读」、§11 补 memory_bram 序列）—— v0.5.4 已闭环
- [ ] 提前量：第 2 周 `tx_port_buf` / `tx_sn_gen` / `tx_frame_builder` 动工，
      黄金模型帧构造已具备（build_frame 已自检）

## 五、第 2 周提前量（09-22 晚，本批）

| # | 项 | 产出 | 判据与证据 |
|---|---|---|---|
| 8 | `tx_sn_gen`（§7.4/§6.6） | `rtl/tx/tx_sn_gen.v`（128×8 寄存器阵列 generate 展开；snap/commit 分离，commit 才递增；255→1、永不 0；init_all / host_override / sn_pend / err） | Verilator 0E；T02 回绕 300 帧扫描无 0、同拍 commit+snap 旁路、init 清零 |
| 9 | `tx_port_buf`（§7.1/§8.6） | `rtl/tx/tx_port_buf.v`（描述符 256×28 `{valid,q_full,fresh,blk,len,age}`；TX 池 6 块位图分配 + 开放块 `wr_blk`；采样口覆盖 / 队列口块链 FIFO 满拒；commit 与 take 同拍 commit 优先、take 挂起 1 拍 `pending`；统计 ovr/q_ovf/pmem_exhaust） | T02 含 2000 随机事件对照参考模型（位图、满位、块守恒 free+open+queued+inuse=6） |
| 10 | T02 单测 | `sim/tb/tb_t02_tx_buf_sn.v` | `T02 TXBUF PASS`；`REGRESS SUMMARY: 3/3 pass`（T01 77 s 为大头） |
| 11 | 门禁扩展 | `tests.manifest` +T02；`run_regress.ps1` 编译表 +2 个 RTL；`tools_lint.ps1` +3 gate（10 gate） | `LINT GATE: PASS` |

设计决策（需回写设计书 v0.5 时同步）：

1. **主机不选块**：§7.1 只说"统一按块分配"，未定主机如何知道往哪写。本实现由
   `tx_port_buf` 常驻一个开放块 `wr_blk`（建议映射到 `STATUS` 或新增只读寄存器
   `TX_WR_BLK`，待 `regs.yaml` 追加），主机写 PMEM 该块后写 `MSG_WR[port]` 封口。
2. **队列口不另设 per-port FIFO RAM**：一条消息一个块，队列即块链（`next[16]`），
   `depth` 只做上限；与 §7.1 "深度受 TX 池 6 块限制" 一致，省 256×8 项 RAM。
3. `commit_rej` 在 commit 后 2 拍给出（与 `sch_ack` 同延迟）；`host_if` 第 4 周接
   `STATUS.BUF_FULL` 时按此对齐。
4. Verilator 5.006 新坑：`for` 内非阻塞写数组报 `BLKLOOPINIT`（ModelSim 可过），
   寄存器阵列须 generate 展开——记入踩坑清单。

## 六、`tx_frame_builder`（09-22 夜，性能优先口径）

| # | 项 | 产出 | 判据与证据 |
|---|---|---|---|
| 12 | `tx_frame_builder`（§7.3/§6） | `rtl/tx/tx_frame_builder.v`（3 态 FSM：IDLE/SETUP/EMIT；首部 42 B 组合 mux；pass1 走 PMEM A 口 1 字/拍；pass2 走 B 口双字预取；SN/pad/双网 SMAC 字节；blk_free 在末载荷字节即归还） | Verilator 0E；T03 |
| 13 | 向量生成器 | `sw/golden/gen_t03_vectors.py` → `sim/vec/t03_frames.hex`（16 帧：L=8/17/18/19/1470/1471/9/100 + 8 随机；1 帧关 UDP 校验和） | 黄金模型 `build_frame` 单一来源 |
| 14 | T03 | `sim/tb/tb_t03_frame_builder.v`（bram_sdp 真 PMEM + tx_sn_gen 真例化；3 种 rdy 模式：10 拍节拍 / 每拍 / 随机背压；逐字节比对 + 长度 + B 网差异 + blk_free/done 各 1 次 + 线速下 stall=0 + L 越界拒） | `T03 BUILDER PASS`；`REGRESS SUMMARY: 4/4 pass`；LINT 12/12 |

**性能结果（T03 模式 0，125 MHz，10 拍/字节）**：

| 指标 | 设计书 §7.3/§4.1 原口径 | 本实现实测 | 倍数 |
|---|---|---|---|
| pass1（L=1471 校验和） | 11 768 拍 = 117.7 μs（8 拍/字节） | 368 拍 ≈ 2.9 μs（1 字/拍） | 32× |
| start → 首字节 | 轻载 349 拍 = 2.8 μs；满载 ≈118.7 μs | **22~24 拍 ≈ 0.18 μs**（所有 L 恒定） | 15×/500× |
| start → done（L=1471，线速） | ≈ 118.7 + 121.4 μs | 15 000 拍 ≈ 120 μs（纯线上时间，无前置等待） | — |
| 首部存储 | 64×16 header buffer ≈ 1.0 K FF | 无（字段寄存器 + 组合 mux） | 省 ~1 K FF |

设计决策（需回写设计书 §7.3/§8.4 v0.5）：

1. **pass1/pass2 重叠**：pass2 从 SETUP 完成立即发首部，UDP 校验和字段在偏移 40 才需要，
   40 B × 10 拍 = 400 拍 > pass1 最长 368 拍，线速下永不等待；`p1_stall_cnt` 做哨兵
   （T03 断言线速下为 0；每拍 rdy 压力模式下会 >0，属预期）。
2. **PMEM 双读口分工**落地：A 口 pass1、B 口 pass2——正是 §7.14 给 bram_sdp 设 1W2R 的理由。
3. **块早归还**：末载荷字节被接收即 `blk_free`（SN/pad 不读 PMEM），块周转比等 `frame_done`
   早 ≥ 1 字节 + FCS 时间；tx_port_buf 已按此接口。
4. 帧布局按黄金模型（pad 在 SN **之后**，§6.1 表）；§7.3 文字"填充在 SN 之前"与 §6.1 表矛盾，
   以 §6.1 表 + 可执行模型为准，已记问题清单待定稿。
5. ModelSim 坑（vlog-2730 再现）：TB 里 `always` 后置声明的观察寄存器必须前置声明。

下一步（第 3 周提前量）：`mac_tx_if`（节拍/IFG/FCS）+ `tx_rm`（双网分发）→ 用 T03 向量
做端到端 FCS 比对；再 `tx_vl_scheduler`。


## 七、09-23 决策点定稿（设计书 v0.5.5，只动文档 + 3 个校验脚本 + regs.yaml）

优化增量 r1 §7 里「09-23 必须定下来」的 7 条全部采纳并回写，`python tools\run_all.py` **5/5 全绿**（本机实跑）。

| 决策 | 定案 | 回写位置 | 对代码的影响（待办） |
|---|---|---|---|
| **O-01** Lmax 口径 | Lmax = 以太帧长含 FCS（64~1518，A664P7）；判决式 `Σ(Lmax+20)×8/BAG`；载荷 = Lmax−47 | §2.2 / §8.2 / §12.2 T05 / 附录 B、C `lmax` 说明；`bag_model.py` OH 24→20、加 `HDR_OH=47`、`payload_of()/lmax_of()` | T05a/b/c 重算：**T05b BAG 718→828 μs**（旧参数实为 1.15 倍过载，`CFG_SUM` 会放过）；`CFG_SUM` 表项份额由脚本预算（O-27） |
| **O-02** SN/长度字段 | 按 XAPP1130 图 3（本机 `_xapp1130_text.txt` L350 已核）：Payload → Pad(0~16) → SN → FCS；`IP Total Length = 28+L`、`UDP Length = 8+L`，SN/pad 不进 UDP 校验和 | §6.1（含变更记录）/ §6.3 / §6.4 / §6.5 / §7.3 填充规则 / §7.12 P2、P4 | **第 2 周首项**：`afdx_model.py` `build_frame/parse_frame` 两条长度式 + pad 位置；`tx_frame_builder` 同两处 + pad 位置（当前 pad 在 SN 后）；重生成 `t03_frames.hex`、重跑 T03 |
| **O-03** SMAC | `02:00:00 + UDI[15:0] + {IFID[2:0],5'b0}`，A=0x20 / B=0x40 | §6.1 / §6.2 / §7.5；`regs.yaml` `SMAC_CFG` 位域改 `[31:16]=UDI`、`[2:0]/[14:12]`=A/B Interface ID，复位值 `0x0001_2001`（与 UDI `[31:16]` 不重叠） | `smac_of()`、builder 首部 mux 第 9~11 字节、`tx_rm` 改替换第 6 字节（原第 5） |
| **O-06** PMEM 位宽 | 8192×32 bit **单实例** 1W2R，写口带字节使能；pass1 4 B/拍 | §4.3 / §7.7 / §7.19 / §8.6（删「16 个 8 bit 实例」段）/ §9 PMEM 行 | 与 09-22 `bram_sdp` 实现一致，**零改动**；`mac_rx_if` 需 4 字节打包 + `be` |
| **O-07** 主机接口 | 单拍流水：写当拍完成、读 2 拍延迟、每拍可一笔；`host_ack` = cs 下一拍。删 `BURST_ADDR/LEN/DATA` | §4.1 换算表 / §5.1 / §5.4 / §7.14 / §12.1 / §12.4 / 附录 A；`regs.yaml` 删 3 项（21 项）；`regs_pkg.svh` 已重生成 | 全表灌入 0.555 ms → **277.5 μs**；`host_if` 第 4 周按此写；`host_if.v` 壳文件注释已改 |
| **O-09** 接口双模式 | 参数 `IF_MODE`：0 帧包络（现方案）/ 1 GMII 连续字节（`valid` 即 DV，`ready` 忽略/状态） | §2.5 / §3.5 D1 / §4.3 参数表 / §5.3 对照表 / §7.6 / §7.7；R1 降级为低/中；附录 D 第 2 问改问法 | `mac_tx_if`/`mac_rx_if` 各 +~50 行；T01/T02/T08/T17 各加一档 |
| **O-15** 仿真器 | 主力 Questa-Altera Starter（断言/covergroup/覆盖率）；ModelSim 10.x 仅 eLinx 联合仿真取证；断言写法按 O-16（过程式检查器）；回归改后门 `load_hex`（O-17） | 抬头「开发环境」/ §12.1 / §12.4 | `bram_sdp` 行为模型加 `load_hex()` 任务；eLinx `elinx_lib` 在 Questa 下重编 3 个文件 |

第 1 周实现决策同步回写（09-22 五、六节里标「需回写设计书」的全部条目）：

- §7.1：`wr_blk`/`TX_WR_BLK`（**新增只读寄存器 `0x0074`**，`[3:0]` 块号、`[4]` 有效）、队列即块链、`commit_rej` 2 拍、描述符 256×28。
- §7.3：无 header buffer（字段寄存器 + 42 选 1 mux）、3 态 FSM、pass1/pass2 重叠、读口 A/B 分工、块早归还；资源估 1.6K→0.7K LUT。
- §7.4：snap/commit 分离、generate 展开（Verilator `BLKLOOPINIT`）。
- §3.3 / D4 / §8.3 / §8.4：按 T03 实测重写——pass1 368 拍（原 11 768）、start→首字节 22~24 拍（原 349 / ≈118.7 μs）、饱和最大帧 TX 首字节 ≤1.3 μs（IFG 决定）、端到端 ≤0.15 / 0.25 ms；T13 判据同步收紧。
- §8.2：`CFG_SUM` 判决线 `20_000` 笔误 → `2^20`；补 A664P7 抖动合规公式（O-11，T05b 公式值 866.9 μs，取 500 μs 合规线，25.84 μs 为稳态工程目标）。
- `check_doc_numbers.py` 加 O-28 残留规则：`8 cycles per byte` / `Lmax+24` / `含 SN` / `L+9` / `BURST_` / `20_000`（正文任一出现即 FAIL，附录 F 与 §4.1 换算表豁免）。

**未动的（当日）**：RTL、TB、向量、黄金模型——随后在同日第二轮补上，见 §八。

## 八、09-23 第二轮：O-02 / O-03 代码落地（T03 重新打绿）

改动 4 个文件，其余 RTL 未动（builder 尚未接入 `AFDX_top`，第 2 周接线时无旧端口残留）：

| 文件 | 改动 |
|---|---|
| `sw/golden/afdx_model.py` | `build_frame`：`ip_total=28+L`、`udp_len=8+L`，校验和段 = payload 本身，帧 = 首部 + payload + pad(max(0,17−L)) + SN；`smac_of(udi16, ifid3)` = `02 00 00 UDI[15:8] UDI[7:0] {IFID,5'b0}`；`parse_frame` 新增 `pad_zero / sn_pos_ok / ifid / udi`；自测补 L=8/16/17/18 帧长、SMAC A/B、长度字段、SN 位置断言。`AFDX MODEL PASS: 0 errors` |
| `sw/golden/gen_t03_vectors.py` | 头字 0 改 `{vlid16, udi16}`，字 5 低位加 `ifid_a[9:7]/ifid_b[6:4]`；边界例改为 L=8/16/17/18（pad 9/1/0/0 B）。已重生成 `sim/vec/t03_frames.hex`（16 帧） |
| `rtl/tx/tx_frame_builder.v` | 端口 `hdr_udi[15:0]`、`hdr_ifid_a/b[2:0]`（删 `hdr_ifid/hdr_net_a/hdr_net_b`）；`ip_total/udp_len` 去掉 +1；`udp_sum` 删 `sn_term`；首部 mux 偏移 9/10/11 = UDI 高/低/`{IFID_A,5'b0}`，`out_byte_b` 改在偏移 11 替换为 `{IFID_B,5'b0}`；`is_sn = is_last`（SN 在 pad 之后、FCS 之前）。`frame_len`、块早归还、pass1/pass2、预取逻辑均未变 |
| `sim/tb/tb_t03_frame_builder.v` | 对应端口/位宽；B 网比对改为偏移 11 == 0x40，其余字节与 A 网逐字节相同 |

验证（本机）：`run_regress.ps1 -Tests T03` → **PASS**（16 帧 × 3 rdy 模式，stall=0），`tools_lint.ps1` → **LINT GATE PASS**（仅原有 INITIALDLY 警告）。§八 之后 O-02/O-03 的「对代码的影响」列全部关闭；`tx_rm`（接收端 SMAC 第 6 字节替换）尚未有 RTL，随第 3 周接收链一起按新口径实现。

下一个决策点 **09-26**：O-04/O-05（接收链流式校验 + 首部抓取，删「迟到撤销」）、O-08（`INIT_DONE` 表项清零扫描，真 bug）、O-13/O-14（布谷鸟哈希 / 调度器顺序扫描）。

## 九、09-23 第三轮：发送链剩余 RTL（调度器 O-14 / tx_rm / mac_tx_if / tx_pace）+ T04 集成测试

新增/替换 4 个桩模块（原 600 B 壳），全部按设计书 v0.5.5 端口语义，Verilog-2001：

| 文件 | 行 | 要点 |
|---|---|---|
| `rtl/tx/tx_vl_scheduler.v` | ≈210 | **O-14 顺序扫描版**：1 个 24 bit 减法/比较器，128 拍扫一轮；`next_tx/bag_us/port` 阵列（可推 BRAM）+ `valid/inflight` 位图。`due = valid & !inflight & port_ready[port] & !age[23]`，age 最大者入选 → `sch_take` → `sch_ack` → `start_vld`。**BAG 以线上帧起始（`frame_start`）计**：`next_tx = tb_us + bag + 1`（+1 抵消 μs 量化），在途 VL 不重复入选（16 深在途队列，`len_err` 亦出队）。`bag_viol/bag_ovf_cnt`（入选时 age ≥ BAG）、`take_miss_cnt`。cfg 写口 `{valid,bag_us,port}`，写入即到期 |
| `rtl/tx/tx_rm.v` | ≈100 | 纯分发器（SMAC 差异已在 builder 内 mux）：`net_mode[1:0]` = {B,A} 使能，sof 拍锁存；`in_rdy` = 使能路 rdy 之与（两路同步推进 → 天然同拍）；关闭路 vld 恒 0；`frame_start = a_start|b_start`；`frame_done` 按帧序队列把 A/B `done` 合成 1 拍并附 `done_vl` |
| `rtl/tx/mac_tx_if.v` | ≈190 | 64×9 FIFO（{eof,byte}）+ `crc32` + 6 态 FSM。`IF_MODE=0`：`tx_ready` 先于首字节 `PRE_CYC=2` 拍、末字节后 1 拍落；每 `pace_en` 槽 1 字节；`IF_MODE=1`：`tx_valid` 整帧连续、每拍 1 字节，起帧阈值 `START_THRESH=48` B（吸收 builder 偏移 40 等 pass1 的空洞，`underrun_cnt` 监控=0）；两模式共用 FCS（`crc_final` 低字节先发）与 `IFG_BYTES` 槽计数；`link_rdy` 背压在字节边界停 |
| `rtl/tx/tx_pace.v` | 23 | 共享节拍：`IF_MODE=0` 每 `BYTE_SLOT_CYC` 拍 1 脉冲，`IF_MODE=1` 恒 1 |
| `rtl/tx/tx_frame_builder.v` | +3 | 新增输出 `cur_vl`（start 拍锁存，供 tx_rm/SN commit） |

`sim/tb/tb_t04_tx_chain.v`（≈420 行，两个顶层 `tb_t04_tx_chain`/`tb_t04g_tx_chain` = IF_MODE 0/1）：整条发送链 + PMEM + timebase 真实例化，TB 扮演 host_if 与 VL 表。三阶段：单 VL BAG 32 μs 双网 30 帧 → 5 VL BAG 32/64/128/256/512 μs 混合长度（8/16/17/18/Lmax/随机）200 帧 → A-only VL。逐帧查：FCS 残差 0xDEBB20E3（A/B 各自）、帧长 = 42+max(L,17)+1+4、DMAC/SMAC/长度字段/sport、载荷与 pad、SN 每 VL 递增；**同 VL 相邻帧首字节间隔 ≥ BAG（全程）**、单 VL 上界 ≤ BAG+800 拍；字节间隔恒 10 拍（GMII：帧内无空拍）、IFG ≥ 12 槽、包络先于首字节；B 路与 A 路同拍逐字节仅偏移 11 不同、A-only 时 B 无活动；`frame_done` 计数 = 帧数、`bag_viol=0`、`take_miss=0`、`underrun=0`、缓冲计数器无异常。

**SN 提交点定为 `builder.done`**（末字节已入 mac_tx_if FIFO，帧级原子不再丢，§5.3 规则 5），而非线上 `frame_done`：GMII 下 FIFO 内可同时在途多帧，而 `tx_sn_gen` 只有单 pend 槽（§7.4 已知限制）。设计书 §7.4「commit 接 mac_tx_if.frame_done」需按此改口径（记入 09-26 回写清单）。

结果（本机）：`tools_lint.ps1` **LINT GATE PASS**（4 个新模块 + 2 个 TB 顶层加入门 2/3，0 %Error；新模块无 Warning，TB 仅 BLKSEQ 风格项）；`run_regress.ps1` **6/6 PASS**（T00~T04g，`tests.manifest` 加 `T04 default` / `T04g gmii`，`run_regress.ps1` 加同文件多顶层映射 + 新 RTL 列表）。实测：单 VL BAG=32 μs 帧起始间隔 4220~4360 拍（IF_MODE=0）/ 4229~4674 拍（GMII，含 pass1 前置 368 拍），即 **调度开销 ≤ 5.4 μs、无一次违反 BAG**；5 VL 混合 BAG 下 512 μs 的 VL 不饿死。

遗留 / 09-26 一并决策：① §7.2 文本仍是 128 路并行归约树，按 O-14 改写（含 §3.4 行数、§9 资源、D3）；② §7.4 SN 提交点口径；③ `AFDX_top` 尚未接线（host_if 单拍流水 + VL 表 RAM 读口 + 寄存器 `TX_WR_BLK` 等），T01 仍是骨架寄存器页；④ T05 抖动统计（128 VL 满载）待接线后用 `T04` 框架扩展；⑤ 桩模块尚存：`rx_*`、`mac_rx_if`、`mgmt/*`、`stats_regs`。

## 十、09-23 第四轮：原 09-26 决策点提前回写（文档，不改 RTL/TB）

总体设计书升 v0.5.6；`doc/regs.yaml` 同步 CTL/STATUS/ERR 位域与中断描述；增量 r1 §7 和第 0 周内部问题 1 记录采纳结论。旧章节「09-26 待决策」是当时记录，此节为其后续收口。

| 决策 | 本轮口径 | 当前证据 / 下一步 |
|---|---|---|
| O-04/O-05 | RX 在 `mac_rx_if` 边收边计算 CRC/IP/UDP 校验和、缓存首 42 B 与末 5 B，**仅好帧**描述符进入 IC/RM；不再迟到撤销，`INT_STATUS` bit3 改 CRC 错事件、CTL bit6 保留 | CRC 完帧余数用 Python/zlib 独立核对；RX RTL 尚是桩，T08/T17 待做；判决约 15 拍是预算非实测 |
| O-08 | `init_sweep` 清 PSN/RM/哈希 + RX/TX/端口配置 valid + RX 描述符/VL 统计，合计至少 **25 344 写拍**（约 203 μs）；`STATUS.INIT_DONE[13]` 门控 TX/RX_EN | 提案约 21k 漏算配置 valid，已补；`init_sweep` 尚无 RTL，T01/T22 待重测 |
| O-13 | 2 表×2048 桶×2 way 离线布谷鸟；低半区地址映射 `0x3D80+table×4096+bucket×2+way`，原 16384 字区及高半 P2 保留 | 不运行 `fix_addr.py`，逻辑容量仍 8192×32；哈希生成器、RTL、T12 未落地，不能宣称 4096 项摆放总成功 |
| O-14 | 设计书 §7.2/D3/§3.3/§8.3/附录 B 按现有 128 拍扫描 RTL 与帧首 BAG 锚点回写；废除旧轮询切换叙事，原 bit4 为兼容保留 | T04/T04g 在此前工作记录为 6/6 回归的一部分；本轮未重跑 RTL。T05/T13、`NUM_TX_VL<128`、RAM 推断待验证，资源为估算 |

**本轮验证**：`python tools\run_all.py` → `verify_all`/`check_addr`/`check_s9_final`/`gen_regs`/`check_doc_numbers` **5/5 全绿**（仅文档/算术/寄存器对账）。5/5 不代表 RTL 或系统指标已过；T04/T04g 的 6/6 是上轮结果。

**隧道恢复后的补充核对（仍未改 RTL/TB）**：补正 §2.2 目标表、模式 1 每拍 1 B 在 125 MHz 下约为 1 Gbps（不能当 100 Mbps 测值）、前门仅装哈希低半时 26 496 字/理论下界 211.968 μs（连保留高半 34 688 字/277.504 μs）。发现 `bag_model.py` 原来先合计再 round，与 §8.2 写的逐 VL ceil 不符；现改为逐 VL 整数取整，T05a/b/c 的 `CFG_SUM` 分别为 **108 384 / 1 047 168 / 2 064 384**，`check_doc_numbers.py` 对整数份额执行精确比对；`selfcheck_claims.py` 不再打印旧 100 MHz/Lmax+24/一帧抖动上界口径。`python tools\run_all.py --strict`：五项 5/5 + 自查通过，`git -c core.whitespace=cr-at-eol diff --check` 通过（设计书工作树原为 CRLF，未批量改行尾）。这些只是设计与算术自查，非仿真测值。

**补记 O-11 风险**：T05b 若 32 VL 同相启动，队尾至少等待 `31 × 25.84 = 801.04 μs`，超过 500 μs 线；当前 scheduler 无启动相位字段。必须让配置/RTL 的起始错相机制闭环，再含启动瞬态重测 T05；在此之前不可声明满载抖动合规。

**后续顺序**：先完成顶层 TX 接线与 `init_sweep` + T01/T22，再实现 RX 流式校验/布谷鸟映像 + T08/T12/T17，最后用真实时基跑 T05/T13。保护工作区现有未提交改动，不做归零或覆盖。

## 十一、09-23 顶层 TX 前门与初始化扫描续记（实现 + RTL 仿真，非完整 T22）

- **实现**：`AFDX_top.v` 接入真实 `init_sweep` 扫描、TX 端口块缓冲/PMEM/VL 调度/builder/SN/RM/pace/双 MAC；主机用 `CFG_MODE` 配置 VL/端口、从 `TX_WR_BLK` 读取开放块、在 `0x8800~0xA7FF` 写读 PMEM，退出配置后用 `MSG_WR[port]` 提交消息。冷启动开放块 0 对应 `TX_WR_BLK=0x10`，`STATUS.PMEM_FREE=15`。`SMAC_CFG` 复位 `0x0001_2001`（A IFID `[2:0]`、B IFID `[14:12]`、UDI `[31:16]`）；`UDP_CFG` 复位 `0x0000_0142`（校验和默认开）。
- **RTL 仿真证据**：Questa `run_regress.ps1 -Tests T01` → `T01 INIT/REG PASS`（25 344 次写、提前开流拒绝与 `ERR.ACC`、表读写、重复复位与 ALIVE，约 107.7 s）；`T04/T04g` → 2/2 PASS（两档 IF_MODE，138/140 帧，BAG/FCS/SN/载荷/双网/IFG）；`T22a` → PASS（单 VL/单端口、32 B 载荷，经前门配置与 PMEM 写读回，A/B 各一帧、79 B、双 FCS/SN/载荷）。`tools_lint.ps1` 的 LINT-OK 是编译结构自查，不能替代上述 Questa 结果。
- **全量与文档门**：`run_regress.ps1` 一次编译 0 错，已登记 T00/T01/T02/T03/T04/T04g/T22a **7/7 PASS**（总墙钟 122.4 s；`sim/out/regress.csv`，另存 `sim/out/regress_full_20260923.csv`）；T01 在全量运行中约 85 s。`python tools/gen_regs.py --emit` 重生成 `doc/regs_pkg.svh`（`UDP_CFG_RESET=0x00000142`），`python tools/run_all.py --strict` 5/5 + 模型自查通过，源文件限定 `git -c core.whitespace=cr-at-eol diff --check` 通过。`-Tests T00,T22a` 的 `-File` 逗号参数曾不能选中测试，修正参数拆分后复测 2/2 PASS；恢复全量 CSV 至 `sim/out/regress.csv`。这些 7 项与 T22a 均不等于完整 T22 验收。
- **仿真器踩坑**：首次 T22a 编译中 Questa `vlog-2730` 报顶层跨区 wire 先使用后声明；已前置声明后重编 0 错。失败路径 `compile.tcl` 的 `exit 1` 被 Questa 解析为 `unknown switch: 1` 并滞留提示符，改用 `quit -f -code 1`（`run_one.tcl`/`run_t01.tcl` 同步）。首次失败不是 T22a 功能判据。
- **尚未闭环**：`host_if.v` 独立模块、RX 流式校验/查表/回环、`CFG_SUM/CFG_ERR`、管理面仍缺。T22a 中哈希仅写口冒烟；**完整 T22 不可标 PASS**，也未获得 RX 或系统端到端、满载抖动的 RTL 仿真证据。下一步先接 RX/配置判决并补完整 T22，不以黄金模型自查或 lint 代替 RTL 仿真。

## 十二、09-23 RX 流式入口单元与 FCS 线序核查（不等于完整 T08/T22）

- `rtl/rx/mac_rx_if.v` 从第 0 周空壳推进为独立入口：帧包络/GMII 连续 DV 两档；按输入字节同步打包 32 bit PMEM 写口（尾字 4 bit byte enable），FCS/IP/UDP 校验和边收边算，捕获 VLID/IP/端口/SN 和首字节时戳。完整帧检测后，只有好帧在尾字写入可见后脉冲描述符；坏帧报告分类并归还 RX 块，不先放行给 PSN/RM。当前块号由测试环境提供，模块**尚未例化到 `AFDX_top`**。
- `sw/golden/afdx_model.py` 原把 CRC32 数值按网络序放在帧尾，`parse_frame` 也用网络序读，模型相互自洽却不符合 `mac_tx_if` 的线序。纠为低字节先发后，`gen_crc_vectors.py` 同步断言线序；T08a 向量由模型生成 ETH/IP/UDP、独立 `zlib.crc32` 重算线序 FCS（完整帧余数 `0x2144DF1C`），坏 IP/UDP/pad 样本修改字段后重算 FCS，隔离拒绝原因。生成器与黄金模型自检通过；**模型自检不是 RTL 通过的证据**。
- Questa 定点仿真：`T08a`（IF_MODE=0）与 `T08ag`（IF_MODE=1）分别 **PASS，22 帧/档**，覆盖 64~1518 B、末字 byte enable、无块、RX_EN=0、FCS/IP/UDP/长度/首部/pad 异常；`tools_lint.ps1` 含这两档与模块门禁 0 `%Error`。正式 T08 仍要查 lookup/IC/RM/端口状态未受坏帧污染，T22 仍要走顶层前门收发回环。
- 配置判决设计缺口：§8.2/O-27 要求配置脚本写入每 VL 的 Q20 份额，附录 B `w0~w4` 未给存储位域，顶层 `CFG_SUM/CFG_ERR` 仍为 0；下一步需先明确份额前门索引/数据窗口或其他不引入硬件除法的映射、更新 YAML/表规模并补 T05c，不能宣称当前已能拒绝超配。其余 RX 块池、双网 FIFO、PMEM 单写口仲裁与后级链路均待实现。

- **扩展回归证据**：一次编译 0 错、九个独立 Questa 会话（原七项 + `T08a/T08ag`）**9/9 PASS**，总墙钟 166.9 s，见 `sim/out/regress_full_9_20260923.csv`（当时与 `sim/out/regress.csv` SHA-256 均为 `0BAB581DA37EF0E5C2D1F5605169E72300B484BCDC98415974CB207302D94F7B`）；`python tools/run_all.py --strict` **5/5 全绿**，`tools_lint.ps1` exit 0、0 `%Error`，黄金模型自检及限定源文件 `git diff --check` 均 PASS。前文 7/7 是未加入 RX 单元前的历史记录，不代表最新测试清单；**RX 顶层及完整 T22 仍未验收**。

## 十三、09-23 Q20 配置判决：优先前门效率的设计定案与 T05c 单项

- 设计冲突原是 O-27 要求每 VL 写 Q20 份额，但 TX w0~w4 全满、无位域。选 `0x0480~0x04FF` 128 字直访份额表：主机每启用 VL 只多写 1 拍；不挪旧表；不改 `init_sweep` 拍数（复用 TX w0.valid 的 128 拍清 loaded）。相较索引+数据双寄存器少一半配置写拍；`CFG_SUM` 在写 w0.valid/改份额时做减旧加新，不等 128 级扫描。`tools/gen_cfg_shares.py` 用整数 ceil 算配置 CSV、默认拒绝超额映像（仅 T05c 负例显式 `--allow-overload`），保留位非零拒绝写；已启用 VL 的份额缺失或为 0 时拒绝 TX_EN，超 2^20 时 `CFG_ERR[0]`/`STATUS[14]`/`ERR.BAG_OVF` 联动。硬件信任主机份额，不反推 BAG/Lmax，不能宣称防恶意低报。
- Questa **定点证据**：编译 0 错，`T05c` Q20 前门（32/128 VL 的 108384、1047168、2064384，缺项/超配/修复/复位/W1C/保留位读回、阈值等号/大一及连续写口）PASS；原 T22a 已补 VL0 份额 8305 并再 PASS，定点子集 **2/2 PASS**；更新后的 Verilator 门禁 `LINT GATE: PASS (all gates 0 %Error)`。T05b 的 828 μs 是压力参数，不是附录 B `bag_exp` 的 1/2/4/... ms 合法档，满载抖动尚无 RTL 取证；T05c 子项不等于完整 T05/T22。

- **全量回归收口**：首次扩为 10 项时 `9/10`（仅 T01 旧用例未在写 w0.valid 前写 Q20 份额，顶层正确拒绝 TX_EN），失败 CSV 存 `sim/out/regress_full10_first_fail_20260923.csv`，SHA-256 `8DA677A0C6E9ABA29A43C749612218D2E7BAF65508B7059F07C24A3D82CF5B94`；T01 补 VL0 的份额 7047 并单跑 **1/1 PASS**，T05c 新增阈值等号/大一及连续 8 笔/拍前门写后单跑 **1/1 PASS**。随后 Questa 编译 0 错，`T00/T01/T02/T03/T04/T04g/T05c/T08a/T08ag/T22a` **10/10 PASS**（170.6 s），`sim/out/regress_full_10_20260923.csv` 与最新 `sim/out/regress.csv` SHA-256 均为 `5321C95AD14904E0BEBB7C41700DCB3453B87591C08D11642B80BF4A90BA44C8`。严格文档门 5/5，更新后的 lint 0 `%Error`，`fix_addr.py` 针对 15 行新映射的本地副本运行幂等；已保留原未提交工作，未据此宣称 T05b/完整 T08/T22/125 MHz STA 通过。
- **合法 BAG 满载候选（仅解析预算，未拍板为 T05b 测试）**：65 VL × Lmax=1518 B × BAG=8 ms 给出 99.97 Mbps、每 VL Q20=16128、合计 1048320/1048576（比现行 828 μs 压力参数更符合 1/2/4/…/128 ms 档位）。但同相启动队尾至少 64×123.04 μs≈7.875 ms，且构建器/调度开销可能令稳态也超目标；须先设计相位错开并用真实时基完成 T05b RTL 仿真，不把解析“带宽合法”当抖动合格。

## 十四、09-23 RX IC（T09）与 PSN RAM 资源冒烟收口

- **承接入口现状**：此前顶层 RX 块池、双网写 FIFO / 4 深描述符、PMEM 单写口 RX 优先仲裁已接线。`T08b/T08bg` 验证同拍两网获不同块、尾字 byte enable、主机写 ACK 等待落盘、坏 FCS 不出好帧描述符，Questa 两档通过。顶层目前仍直接弹出好帧描述符并归还块；这些只是入口局部证据，不是端口交付。
- **本轮新增**：将第 0 周 `rtl/rx/rx_ic.v` 空壳实现为双网/每 VL 独立 PSN 判决，带 8192×8 PSN 单写口、`init_sweep` 清表、`UDP_CFG.IC_FIRST_ANY` 握手拍锁存、空闲时调试强制、163 bit 描述符 `vld/rdy` 背压。SN=0 重置 PSN；默认首帧仅 SN=1；随后仅接受 +1 / +2（最多丢一帧），255→1 回绕；无效 VL/重复/跨过两帧只输出拒绝结果而不写 PSN。**尚未例化进 `AFDX_top`**，顶层旧 `psn_mem` 仍是初始化占位，后续不得并存两份状态 RAM。
- **黄金模型与 T09**：`sw/golden/afdx_model.py` 新增 `ic_decide()`；`gen_t09_vectors.py` 固定种子产生 **376** 个 Python 判决向量（`sim/vec/t09_ic_cases.hex`），回归选中 T09 时自动生成。`tb_t09_rx_ic.v` 另有独立逐帧参考状态机与定向/确定性随机检查，逐项对比 RTL 的接受/原因/真实 PSN 写回；`T09` 默认 4096 VL 的 **751** 描述符与 `T09s` 缩配 16 VL 的 **753** 描述符均 PASS，含双网隔离、首帧两模式、SN=0、丢一帧、254/255 回绕、上下界、非法缩配索引、输出背压和配置锁存。
- **综合实际踩坑（不可只看 rc）**：首次独立 eLinx 冒烟 rc=0，却把散落的初始化/调试/提交写口展开成 **24576 个 `$dffe`**（留 `elinx/prj/rx_ic_smoke_ff_first.log`）。改为唯一写口并共享同步读写地址后，`rx_ic_probe.ys` 的 `memory_collect` 有 1 个 `$mem`；`rx_ic_smoke.ys` 显式 `memory_bram` 映成 **16 × altsyncram(M4K)**，`select -assert-count 16` 通过、rc=0。只是独立单元 RAM 映射，非顶层资源或 125 MHz 时序证明；§9 的 4 × 18 Kbit 属逻辑容量估计，不能与实测 M4K 个数直接混称。
- **最终门禁（修复 RAM 写口之后重跑）**：Questa 一次编译 0 错，`T00/T01/T02/T03/T04/T04g/T05c/T08a/T08ag/T08b/T08bg/T09/T09s/T22a` **14/14 PASS**（192.9 s），`sim/out/regress_full_14_20260923.csv` 与当时 `sim/out/regress.csv` 的 SHA-256 均为 `6CFEB1E2C9683C195D726EA984BBFD1238992715CF69D68AB5987AB67563BDC2`。Verilator `LINT GATE: PASS (all gates 0 %Error)`（同步补齐旧顶层 TB 的 RX 依赖与 T08b/T09 门）；Python 黄金模型自检 0 错；`python tools/run_all.py --strict` 5/5 + 自查通过，限定源文件 `git diff --check` 通过。
- **仍缺/下一步**：先做 `hash_seed.py` / `rx_vl_lookup` 的离线映像与 T12，再接 `rx_flt → lookup → IC`（必须让 `init_sweep` 复用 IC 的存储体）及 `rx_rm → rx_port_buf`；测坏帧不能污染 PSN/RM、同拍副本只投递一次、块释放守恒，补完整 T08/T10/T17/T22。`host_if` 独立实现、T05b 启动错相/满载抖动、管理面及顶层 STA 均未闭环，不据 14/14 单元/局部 PASS 推断全系统验收。

## 十五、09-23 IC 测试集加固：边界全覆盖、长背压与变异检出

- **为何追加**：上一节 14/14 是阶段回归，不代表“难例已覆盖”。当时 T09/T09s 的 376 个黄金向量和 350 帧随机流程基本逐帧完成，只重点访问少量 VL；没有全表 A/B 地址触达、连续输入堵塞下的交易守恒或复位中断证明。本节在保留第十四节原始记录及 CSV 不变的前提下追加测试。
- **双重判决参考**：`gen_t09_vectors.py` 用独立的模 255 距离公式交叉自检 `afdx_model.ic_decide()` 的 **2 × 256 × 256 = 131072** 种 `(首帧模式, PSN, SN)` 组合；再以固定种子 `0xA664` 生成 **5632** 条实际喂给 RTL 的精选边界/随机向量（两档各 **6007/6009** 个总描述符），比较 `accept/reason/写回 PSN`。软件全组合检验不能冒充 RTL 全组合遍历。
- **逐沿压力测试**：新增 `tb_t09p_rx_ic.v` 的 T09p/T09ps，两档分别连续输入 **10240/2080 帧**、覆盖 **8192/8192 与 32/32** 个双网 PSN 槽；独立 scoreboard 按真实握手排队，逐沿检查帧内容、判决原因、按序恰好一次输出、真实 RAM 写回、堵塞稳定性。`0x9E3779B9` 固定背压种子，51 拍周期性关闭 ready + 随机放行；满配实测 input stall **69386**、output stall **38669** 拍、最长单次保持 **57** 拍，缩配分别 **14032/7795/56** 拍。覆盖所有 6 种满配可达判决，缩配另触达 BAD_VL；检查无效调试地址不能别名 B 网、复位前已握手但未写回的取消、带待消费输出的重扫清全表及无旧输出泄漏。
- **测试真实抓错**：第一次运行新压力用例 T09p/T09ps 各有 **1** 项失败：`rst_sync=1` 且 `init_done` 暂时仍高时 `in_ready` 错误为 1；给 `rtl/rx/rx_ic.v` 的 `in_ready` 加 `!rst_sync` 门控后，T09/T09s/T09p/T09ps **4/4 PASS**。独立临时 Questa 库执行 `python sim/test_t09_mutants.py`，把「丢一帧判错」「拒绝写回错」「B 网地址漏偏移」分别注入临时 RTL；T09ps 均有明确 scoreboard/PSN 错误，**3/3 DETECTED**，生产 RTL 源 SHA 保持不变。报告在 `sim/out/T09_mutants_report.txt`，不是对任意 RTL 错误的完全变异覆盖。
- **资源边界未变**：复位门控修复后复跑 `rx_ic_probe.ys` 得 1 个 `$mem`，`rx_ic_smoke.ys` 得 **16 个 altsyncram(M4K)**，均带计数断言且 exit 0；这仍非顶层资源/125 MHz STA 证明。IC 尚未接入 `AFDX_top`，目前无法用单元压力用例证明坏 FCS 不污染 IC、RM 双网去重、块守恒或端口消息交付；后续必须做真实后级与系统级 T08/T22/满载时序测试。
- **完整回归及证据**：在最终修正的 RTL/向量/压力 TB 上重新一次编译（0 错）+ **16/16 PASS**（193.3 s），非拼接子集。存档 `sim/out/regress_full_16_20260923.csv` SHA-256 `74C6E368E848C4E45F566EAAEF2BCE7BB7B25516D5EDC9A567D994C4FBFD887E`，旧 14 项 CSV 保留为历史。`sim/freeze_regress.py` 校验 manifest/CSV 顺序与全 PASS 并生成 `sim/out/test_evidence_16_20260923.json`，绑定 **44** 份输入（RTL/TB/模型/向量/运行器等）与 **24** 份输出（CSV/console/映射/变异记录）的 SHA-256；只存哈希，尚需把未提交源码本体归档才能干净复现。Verilator lint 及严格文档门 5/5 复跑通过。

### 09-23 深夜：P0-03 FLT 语义过滤落地（v0.5.13）

- **做了什么**：`rx_flt.v` 从空壳实现为语义过滤并接入 `AFDX_top`（`mac_rx_if` -> `rx_vl_lookup` -> `rx_flt`；S1 帧头检查由入口流式承担，S2 判决需 `vl_idx` 故在查表后）。判决序：UNCONF（miss/越界/`w0.valid=0`）-> VLID（`w1.expect_vl` 不符）-> NET（`w0.net_mode` {B,A} 使能位，`2'b00` 视为仅 A）-> LMAX（`len>w0.lmax`，均含 FCS）。块释放移到 FLT 判决后，`lookup_drain` 与 FLT 输出互斥防 `free_pipe` 覆盖；`DROP_CNT 0x1C` 合计、`DROP_CNT_K` `0x40` unconf（归并 NET/VLID）/`0x44` lmax 前门可读、复位清零。
- **怎么验证**：新增 T08d/T08dg（真实 79 B 模型/zlib 帧、IF_MODE=0/1）：PASS x3（A/B 网、判决后重开）、四类拒绝各 1、坏 FCS 不进过滤链、逐帧块池回满 `0xFFC0`、计数读回与复位清零，每帧后 `verdicts/pass/drop` 三计数对账。lint 全门 0 `%Error`；一次编译全量 `REGRESS SUMMARY: 26/26 pass, wall_s=109.7`，CSV 存档 `sim/out/regress_full_26_20260923.csv` SHA-256 `9E18DEBF4EDB77A210A0029CBCA0E92F9788B86E078736F490B24995087474BF`，`freeze_regress.py` 产 `sim/out/test_evidence_26_20260923.json`（88 输入/52 证据哈希）；`run_all.py --strict` 5/5。
- **没覆盖什么**：PASS 帧仍只计数回收块，IC/RM/parse/端口未接，本节只是过滤切片证据、不是完整 T08/T22；FLT 的 `w0/w1` 为行为级组合读，BRAM 化必须与主机读口并成同一物理口；NET/VLID 无独立计数类；入口类拒绝（len/dmac/crc 等）仍只在 `mac_rx_if` 内部计数未接前门；本节未做 FLT 隔离故障注入（下一轮补）；T05b、STA 状态不变。
- **下一步**：把顶层 `psn_mem` 初始化壳并入独立 `rx_ic` 同一存储体，让 FLT PASS 描述符进 IC（P0-04 第一步），再做 RM/端口与最小闭环。
