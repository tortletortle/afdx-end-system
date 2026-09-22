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

- [ ] 09-23 决策点（优化增量 r1 表）：O-01/02/03（帧格式）、O-06（PMEM 位宽——
      本日 1W2R 结论已给出输入）、O-07（主机接口）、O-09、O-15 —— 多为文档定稿项
- [ ] 设计书 v0.5 定稿（§7.19 表把 bram_sdp 描述「简单双口」改为「1 写 2 读」，
      与 §7.14 对齐；§11 补 memory_bram 序列说明）
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

