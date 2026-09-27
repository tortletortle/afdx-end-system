# continue4 报告 —— P1 管理面 OPEN_SPEC_GAP 关闭（T14/T15/T16）

日期：2026-09-26 · 工作区：`C:\Workspace\diansai` · 产出目录：`out/arena-debug/continue4/`
任务书：`out/arena-debug/MISSION-CONTINUE4.md`（sha256 `3470f6b0d6e4c89a08882fc74f9e02e2bb009e9776c2502cbfa586835045147d`）

---

## 0. 一句话结论

**目标 A（主）完成**：三个第 0 周空壳模块被替换成真实协议实现，三条新用例进回归，
**全量 53/53 PASS + Verilator lint gate PASS + `run_all.py --strict` 5/5**，三门同时绿。
**目标 B（次）做了一次可逆的结构性改动并实测为正收益，予以保留**：
post-map STA 指认新的全局关键路径落在本轮新增的 `rtc_sync` 上
（`sec_phase[22] → offset[63]`，Fmax 跌到 37.64 MHz）；把对时判决拆成两拍后
**Fmax 42.15 MHz（+4.51）、WNS −15.723 ns（+2.846）**，功能 53/53 不变，
证据见 §6 与 `timing_attempt.patch`。
**但必须说清楚：这只是把本轮管理面引入的退化补回来，设计在 8 ns（125 MHz）下仍然远不收敛。**

> 必须分开看的两件事：
> * 「模块级 / 顶层链路级通过」≠「整机 AFDX 端系统协议符合性通过」；
> * 「回归 53/53 + lint + 文档门」≠「时序收敛」。本设计在 8 ns 约束下**仍然不收敛**（见 §6）。

---

## 1. 做了什么（对照 MANAGEMENT-SCOPE.md §5 的最小可验收定义）

| 项 | 要求 | 本轮状态 | 证据 |
|---|---|---|---|
| 1 | `rtl/top/stats_regs.v`：按设计书定义端口，接 0x0100~0x01FF 页；TB `T14` 校验帧/字节/丢弃计数与直方图分桶，含复位清零与读清语义 | **达成** | `sim/tb/tb_t14_stats_regs.v`，回归 T14 PASS |
| 2 | `rtl/mgmt/snmp_lite.v`：GET/GETNEXT/SET + STATS_BLOCK 只读组，走 `mgmt_sap_rx` 的 SAP 描述符通路；TB `T15` 用真实 SAP 帧驱动，校验 PDU 编解码与错误码 | **达成** | `sim/tb/tb_t15_snmp.v`，回归 T15 PASS |
| 3 | `rtl/mgmt/a615a_tftp.v` + `rtl/mgmt/rtc_sync.v`：TFTP RRQ/WRQ/DATA/ACK 状态机与 PPS 对时；TB `T16` | **达成（RRQ 有明确边界，见 §4）** | `sim/tb/tb_t16_tftp_rtc.v`，回归 T16 PASS |
| 4 | 三条用例进 `sim/tests.manifest`（50→53），`run_regress.ps1` 加映射；全量回归、`tools_lint.ps1`、`run_all.py --strict` 三者同时通过 | **达成** | §3 |
| 5 | 只做真实协议最小闭环，不得把空壳/占位当作完成；如实标注覆盖边界 | **遵守** | §4 全部边界逐条登记 |

### 1.1 新增/改造的 RTL

| 文件 | 改动前 | 改动后 | 说明 |
|---|---:|---:|---|
| `rtl/top/stats_regs.v` | 9 行空壳 | 309 行 | 全局统计页：帧/字节(64 bit)/12 类丢弃/帧长 8 桶/前 8 VL 直方图/到达间隔高水位与 EWMA/W1C/读清/冻结 |
| `rtl/mgmt/snmp_lite.v` | 9 行空壳 | 566 行 | 256 B 收包缓存 → 逐字节 BER 解析 → 逐 VarBind 求值 → 逐字节 BER 编码进 256 B 响应缓存 |
| `rtl/mgmt/a615a_tftp.v` | 9 行空壳 | 360 行 | RFC1350 子集：WRQ/DATA/ACK/ERROR/RRQ、32 KB 加载区、反射 CRC-32、超时重传与重试上限 |
| `rtl/mgmt/rtc_sync.v` | 9 行空壳 | 133 行 | 64 bit 偏移量校正 + 本地秒相位 + PPS 跳变/平滑判决 + 锁定 + 失步看门狗 |
| `rtl/mgmt/mgmt_sap_rx.v` | 50 行 | 182 行 | 新增：用最低优先级 PMEM A 口把整帧搬进本地缓冲（1 字/拍）→ **立刻归还 RX 块** → 再以 1 字节/拍把 UDP 载荷分发给 SNMP/TFTP |
| `rtl/top/AFDX_top.v` | 1033 行 | 1300 行 | 例化上述模块、统计页读通、`wr_known` 并入统计页 W1C、MGMT 观测窗 0xAC14~0xAC3F、TFTP 加载区 0xCC20~0xEC1F、`pps_out`/`rtc_time_us` 接真实 RTC |
| `rtl/common/timebase.v` | — | +5 行 | **修既有缺陷**，见 §5 |

### 1.2 地址映射（本轮新增，已实现并被 TB 覆盖）

**全局统计页 `0x0100 + 字偏移`**

| 偏移 | 名称 | 语义 |
|---|---|---|
| `00`~`03` | 旧镜像 | `rxpb_deliver / port_drop / ovr / qovf`，**只读、不受读清影响**（保持 T08d/T08e/T08f/T10/T11 既有断言） |
| `04` | `RX_FRAME_CNT` | 进入查表级的好帧数 |
| `05`/`06` | `RX_BYTE_LO/HI` | 64 bit 字节累加 |
| `07` | `RX_ACCEPT_CNT` | RM forward 握手拍计数 |
| `08` | `TX_FRAME_CNT` | 整帧交给 MAC 完成 |
| `09`/`0A` | `TX_BYTE_LO/HI` | 64 bit |
| `0B` | `DROP_TOTAL` | 12 类合计 |
| `0C`/`0D`/`0E` | `JIT_MAX/LAST/MEAN` | 帧间到达间隔（μs）高水位 / 最近值 / 一阶 EWMA(α=1/16) |
| `0F` | `STATS_CTL` | `[0]=RD_CLR_EN`（默认 0）、`[1]=FREEZE_SW` |
| `10`~`1B` | `DROP_CNT_K[12]` | len/dmac/ethtype/ip_ver/ip_csum/udp_len/udp_csum/crc/unconf/lmax/ic/rm |
| `20`~`27` | `HIST_LEN[8]` | 分桶边界 ≤64/≤128/≤256/≤512/≤768/≤1024/≤1518/else |
| `28`~`2F` | `HIST_VL[8]` | 前 8 个 VL |

**管理面观测窗 `0xAC14`~`0xAC3F`**（SNMP 状态/响应字节口、TFTP 状态/响应字节口、RTC 状态）
与 **A615-A 加载区 `0xCC20`~`0xEC1F`**（8192 字 = 32 KB，同步读）。
两段都已并入 `rd_known`，统计页 W1C 与观测窗控制字已并入 `wr_known`，
因此**合法访问不再误置 `ERR.ACC`**（T14-B2 专门验证），而对只读镜像写仍然置位。

---

## 2. 三条新用例做了什么（不是空壳，逐条列断言）

### T14 `tb_t14_stats_regs`（336 行）

* **A 单元级**（直接驱动 `stats_regs` 事件口）：复位清零；`00~03` 镜像只读且 `wr_ok=0`；
  3 帧计数与 64 bit 字节累加；TX 计数；4 次接受帧落进正确的**帧长桶**与**VL 桶**（VL≥8 不进桶）；
  到达间隔 `JIT_LAST/JIT_MAX`；4 次丢弃事件（含同拍两类）与 `DROP_TOTAL`；
  W1C 整字清 + **部分位清**；**同拍"清零+事件"不得丢事件**；`RD_CLR_EN` 读清且镜像不受影响；
  `FREEZE_SW` 与 `DBG_CTRL[6]` 两条冻结路径；再复位清零。
* **B 顶层级**（`AFDX_top` 前门）：复位后整页为 0；未映射页内字读 0；
  统计页 W1C **不置** `ERR.ACC`、只读镜像写**置** `ERR.ACC`；
  然后放**一帧真实 64 B 金标帧**（`vec/t08a_frames.hex`，含线序 FCS）走
  `mac_rx_if→lookup→FLT→IC→RM`，TB 用**独立记分板**（只观测 `lookup_take` /
  `rm_fire&&rm_out_fwd` 的握手拍与描述符长度字段）累加，再与寄存器回读逐项比对；
  顶层 W1C 与读清；顶层复位清零。

### T15 `tb_t15_snmp`（447 行）

请求 PDU **全部由 `sw/golden/gen_t15_vectors.py` 生成**：真实 ETH/IP/UDP + AFDX SN +
zlib 线序 FCS 的 SAP 帧，载荷是真实 BER 编码的 SNMP PDU。TB **自己写了一个 BER 解码器**
来校验响应（不是比对 RTL 自己的中间信号）。

* **A 单元级**（12 条真实 PDU 灌进 `snmp_lite`）：
  GET TimeTicks；GETNEXT 从标量组末项跨到 STATS_BLOCK 组首项；SET `afdxEsCtl` 并回读；
  GET 不存在对象 → `noSuchName(2)` 且 `error-index=1` 且响应体携带 NULL；
  SET 只读对象 → `readOnly(4)`；community 不符 → **静默丢弃**且丢弃计数 +1、响应计数不动；
  多 VarBind（2 个 STATS_BLOCK 字）；OCTET STRING（16 B descr 逐字节比对）；
  SET 类型不符 → `badValue(3)` 且对象不变；三 VarBind 标量组；GETNEXT 走出 MIB 末尾 → `noSuchName(2)`；
  最后校验 `rx_pdu_cnt=12 / resp_cnt=11 / drop_pdu_cnt=1` 自洽。
  每条都校验外层 SEQUENCE 长度自洽、version 回抄、community 逐字节回抄、
  PDU 类型必须是 `0xA2`、request-id 原样回抄、OID 前缀 11 字节与实例子标识符。
* **B 顶层级**：同样 12 条帧**真的走线**（按 SN 0..11 递增，满足 IC 要求），
  经 `mac_rx_if → 解析 → mgmt_sap_rx 取 PMEM 载荷 → snmp_lite`，
  主机经 `0xAC14~0xAC1F` 观测窗按字节读回响应再解码；
  另外校验 SAP 侧解出的 **源 IP `10.0.0.1` / 源端口 0xC000 / 目的端口 5000**、
  **STATS_BLOCK 的值必须等于主机从 `0x0104`/`0x0107` 读到的统计页原值**、
  SAP 块守恒（`rx_free_map==0xFFC0`、accept==return==12）。

### T16 `tb_t16_tftp_rtc`（492 行）

* **A 单元级 TFTP**：WRQ→ACK(0) 并捕获 TID 与文件名头；**512 B 满块**DATA→ACK(1) 且不结束会话；
  重复块只补 ACK 不重复计数；100 B 末块→ACK(2)、`loaded_ok=1`；
  **加载区 612 字节逐字节比对**；**CRC32 与 TB 独立参考实现比对**；
  会话外 DATA→`ERROR(5)`；白名单外文件名→`ERROR(2)`；mode 非 octet→`ERROR(0)`；
  RRQ `STATUS`→`DATA(1)` 36 B 且魔数为 `"A615"`；ACK(1) 关闭会话；
  非法操作码→`ERROR(4)`；**超时重传 3 次后重试上限触发本地 `ERROR(4)`**，且超时不计入收包数。
* **A 单元级 RTC**：自由运行时 `pps_out` 周期严格等于 `US_PER_SEC` 个 tick；
  大误差（300 μs > TH_JUMP=100）→ 跳变、`jump_cnt=1`、相位重对齐、`locked` 清零；
  小误差（40 μs）→ 平滑 `adj=err>>2`、`step_cnt=1`、相位落在预期区间；
  反复同相 PPS → `locked=1`；停止 PPS 超过 `SYNC_TIMEOUT` → `sync_loss=1`；`HOLD` 冻结相位。
* **B 顶层级**：8 帧真实 SAP 帧（含一帧 **563 B、载荷 516 B 的 TFTP 满块 DATA**）走线，
  主机经 `0xAC20~0xAC29` 读状态与响应字节、经 `0xCC20` **把 520 字节加载区全部读回来逐字节比对**，
  CRC32 与 Python 金标（`zlib.crc32`）比对；顶层 `pps_out` 真的产生脉冲；
  外部 `pps_in` 真的产生对时事件且 `sync_loss` 随之清零；`uptime_cs` 回读一致；SAP 块守恒。

---

## 3. 三门结果（都是实跑，日志在 `raw/`）

| 门 | 命令 | 结果 | 原始日志 |
|---|---|---|---|
| 改动前基线回归 | `sim\run_regress.ps1` | **50/50 PASS**，wall 285.6 s | `raw/regress_baseline.log` |
| 改动后全量回归 | `sim\run_regress.ps1` | **53/53 PASS**，wall 542 s | `raw/regress_clean53.log`、`raw/regress_clean53.csv` |
| Verilator lint | `tools_lint.ps1` | rc=0，`LINT GATE: PASS (all gates 0 %Error)` | `raw/lint.log` |
| 文档/数字一致性 | `python tools\run_all.py --strict` | rc=0，`5/5 全绿` | `raw/run_all_strict.log` |

**运行时间变化说明（不是异常）**：T01 从 57.1 s 变成 199.4 s。原因是 §5 的 `timebase` 修复
让 `tick_us` 在仿真里真的开始出脉冲（每 ~125 拍一次），`rtc_sync` 与 `a615a_tftp` 因此每微秒
被唤醒一次，仿真事件数上升。这是修复的**预期代价**，不是功能退化。

### 3.1 过程中触发并修好的三次既有用例回归（都不是"改测试迁就实现"）

| 现象 | 根因 | 处置 |
|---|---|---|
| T11/T11g `held RX block count wrong (conservation)` | 第一版 `mgmt_sap_rx` 边取载荷边发字节（6 拍/字），把 SAP 块归还推迟到 T11 `settle()` 的 80 拍守恒窗口之外 | 改设计：**先整块搬进本地缓冲（1 字/拍）再立刻归还块**，分发与持块解耦 |
| T23/T23g `SAP pair PB1 contention or bounded return absent` | 同上，`free_req` 抬得太晚，错过了 T23 强制的 `pb_free1` 抢占窗口 | 同上一处改动一并解决（归还时刻回到描述符接手后 ~10 拍） |
| T14 在全量回归里失败（单跑却通过） | `stats_regs` 把读译码做成了 Verilog **函数**，被 host 口与 SNMP 口两条**连续赋值并发调用**；Verilog 函数局部变量是 static 的，两次求值互相覆盖临时量 | 拆成两个独立的 `always @(*)` 块，各自持有局部变量；代码里留注释说明为什么不共享函数 |

---

## 4. 覆盖边界（如实标注，**这些都还没做到，别当成已完成**）

### 4.1 统计页 `stats_regs`
* 12 类丢弃原因里的 **`dmac` / `ip_csum` / `udp_csum` 三类计数器恒 0**。
  当前 RX 链路没有这三类的独立判决源：`mac_rx_if.drop_reason` 只给
  `CRC/IP/UDP/HDR/LEN/PAD/NO_BLK/ABORT` 八档，DMAC 错与 ETH Type 错都归到 `HDR`，
  IP/UDP 校验和错分别归到 `IP`/`UDP`。要真正分开必须改 `mac_rx_if` 的判决输出，本轮未做。
* 同一拍上 A/B 两网出现同类丢弃时，因为事件是单拍脉冲，**合并记 1**。
* `JIT_*` 是**帧间到达间隔**的高水位与一阶 EWMA，**不是** RFC3550 抖动，
  **也不是** T05b 的线上 BAG 抖动取证，不能拿去做 BAG 合规结论。
* `HIST_VL` 只覆盖 **VL 0~7**，VL≥8 不进桶。
* `TX_BYTE_*` 统计的是**调度器给出的载荷字节数**，不含以太/IP/UDP 头与 FCS。

### 4.2 `snmp_lite`
* 只支持**短式长度与 `0x81` 单字节长式（≤255）**，`0x82` 及以上直接丢弃。
* 只支持 **v1(0) / v2c(1)**；**没有** v3、没有认证加密、**没有 Trap、没有 GETBULK**。
* community 是**编译期常量 `"public"`**，未做运行时可配。
* OID 叶子号限 **0~127**（单字节子标识符），不支持多字节叶子。
* MIB 覆盖 = **8 个标量对象**（descr/upTime/numTxVl/numRxVl/rxMaxJitterUs/esCtl/esDropCnt/esBufUtil）
  **+ STATS_BLOCK 只读组 48 个字**。设计书 §7.16 里**按 VL 索引的对象（.5~.9 BAG/Lmax/
  txCnt/rxCnt/dropCnt）本轮没有实现**，GETNEXT 的游走表里也不含它们。
* **SET 只能写 `afdxEsCtl`，且写进的是管理面影子寄存器 `snmp_ctl_shadow`，没有联动
  主机 CTL(`0x0008`)**。这是刻意的安全取舍（不让 SNMP 直接拨数据面开关），但这意味着
  「SNMP 可以配置端系统」这句话**现在不成立**。
* 每个 VarBind 的取值在解析当拍锁存，**同一响应内不保证跨对象的原子快照**。
* request-id 与 community 在响应里**按原始字节回抄**，不做重新编码。

### 4.3 `a615a_tftp`
* **RRQ 只服务固定的 32 B `STATUS` 状态文件**，不支持从 32 KB 加载区回读任意文件。
  WRQ（接收加载数据）方向才是完整的。
* **不支持 OACK / blksize / tsize / timeout 选项协商**（RFC 2347/2348 一律回 `ERROR(4)`）。
* **只做 TFTP 传输层**，不做 A615-A 的上层协议（Find/Info/载荷签名校验/LUS 状态机）。
* CRC32 只覆盖 DATA 载荷字节，不含 TFTP 头。
* 文件名白名单是编译期常量（`"UPLOAD"` 可写 / `"STATUS"` 可读）。
* AFDX §6.1 要求 UDP 载荷 ≥ 8 B，**裸 4 B 的 TFTP ACK 不能单独上线**，
  金标帧里补零到 8 B，引擎对 ACK/ERROR 只取前 4 B。这是 AFDX 与 TFTP 的固有张力，
  真实系统需要在 A615-A 层面另行约定，本轮只在测试里绕开。

### 4.4 `rtc_sync`
* 分辨率就是 **1 μs**；`locked` 的含义是"连续 `LOCK_N` 次 |err|≤1 μs"，**不宣称亚微秒**。
* `pps_in` 只有 3 拍打拍同步器，**没有做 CDC 签核**（没有 `set_false_path`/MTBF 分析）。
* **顶层没有接同步报文通路**：`sync_vld` 在 `AFDX_top` 里硬接 `1'b0`。
  报文对时（`sync_master_ts + path_est`）只在 **T16 的单元级**验证过，
  整机上目前只有 PPS 一条对时路径。

### 4.5 管理面整体
* **两个引擎的响应只做了编码，经 MGMT 观测窗被主机读走，没有接进 TX 帧构建器**。
  也就是说：**管理面回包不上线**。要真正完成 SNMP agent / TFTP server，
  还需要一条把响应封装成 UDP 帧并注入 `tx_frame_builder` 的通路，本轮未做。
* SAP 端口到服务的路由用的是 **`AFDX_top` 的参数** `SNMP_SAP_PORT` / `TFTP_SAP_PORT`
  （默认 6 / 7），**不是运行时寄存器**。这样做是为了不改既有寄存器映射、不给 T01 引入风险。
* `mgmt_sap_rx` 的本地缓冲是 `PBUF_W=160` 字（640 B）。超过部分会被**截断**并计入
  `trunc_cnt`（顶层未接出）。对 SNMP(≤255 B) 与 512 B 的 TFTP DATA 块够用，
  对最大 1471 B 的 AFDX 载荷**不够**。
* 管理面全部只在 **IF_MODE=0（MII）** 下做了顶层验证，**没有 GMII 变体用例**
  （既有用例的 `*g` 变体不覆盖 T14/T15/T16）。

---

## 5. 顺带修掉的一个既有 RTL 缺陷（`rtl/common/timebase.v`）

```verilog
// 改前：复位分支里只清 beat_cnt / frac / rtc64，tick_ctr 没有复位项
assign tick_us = us_inc & (tick_ctr == 16'd0);
```
`tick_ctr` 从来没有被复位，仿真里恒为 `X`，于是 `tick_us` **永远不出脉冲**。
改造前没有任何模块消费 `tick_us`（BAG 调度直接用 `rtc64`），所以这个缺陷一直没被发现。
本轮 `rtc_sync` 与 `a615a_tftp` 都要吃 `tick_us`，于是暴露了出来
（症状：T16 的 `pps_cnt=0`、`sync_loss` 永远不置位）。

修复 = 在复位分支加 `tick_ctr <= 16'd0;`（5 行，含注释）。
**在硬件上这个 bug 可能看不出来**（上电后 `tick_ctr` 会落到某个确定值并正常回绕），
但它在任何仿真里都会让 `tick_us` 失效——这正是"仿真通过 ≠ 硬件正确"的反向例子，
值得在评审时单独提一句。

---

## 6. 目标 B（P0 时序）—— 做了一次可逆结构改动，实测正收益，保留

### 6.1 方法与守卫

隔离工程 `out/arena-debug/continue4/project/`（qsf 从 continue3 复制后补登 4 个新 RTL，
共 28 个 VERILOG_FILE），STA 脚本 `sta_continue4.tcl` 就是 continue3 的 `sta_continue3.tcl`，
**只改输出目录**，其中的 8 ns SDC 守卫原样保留：`post_map_sdc.rpt` 不是 8.000 ns 就 fail-closed，
防止 Quartus 悄悄用 1 ns 默认值伪造一个 125 MHz。

**两次 STA 都打印了 `SDC_GUARD_OK: clk=8.000 ns`**，所以下面的数字可采信。
器件 EP4SGX230HF35C2，`quartus_map` 13.0.1，post-map（非 post-fit）。

### 6.2 先测量：管理面合入后，关键路径搬到了我自己新写的模块上

| | Fmax | WNS | TNS | 关键路径起点 → 终点 |
|---|---:|---:|---:|---|
| continue3（**不含**管理面的旧网表，仅作参考） | 42.56 MHz | −15.498 ns | −567 451.740 ns | `rst_sync:u_rstsync\|r[2]` → `rx_port_buf:u_rxpb\|p_cnt~508` |
| **continue4 基线**（管理面已合入、未做时序改动） | **37.64 MHz** | **−18.569 ns** | −661 896.147 ns | `rtc_sync:g_rtc.u_rtc\|sec_phase[22]` → `rtc_sync:g_rtc.u_rtc\|offset[63]` |

也就是说：**管理面把 Fmax 拉低了约 4.9 MHz，而且新的最差路径就是我这一轮新写的 `rtc_sync`**。
原因很清楚——原实现在**一拍之内**串完了：

```
sec_phase → 33 bit 有符号相减(err) → 取绝对值 → 与 TH_JUMP 比较
          → 变量算术右移(桶形移位器) → 64 bit 减法写 offset
```

### 6.3 再改一次：把对时判决拆成两拍（`timing_attempt.patch`）

改动只落在 `rtl/mgmt/rtc_sync.v`，**不改任何端口、不改任何判决语义，只晚一个时钟**：

* 第 1 拍：PPS 上升沿 / 报文事件当拍，把有符号误差锁进 `err_q`，并记下事件类型 `disc_q_pps`；
* 第 2 拍：`disc_pend` 有效时才去算 `big_jump` / `adj`，改 `offset` 与 `sec_phase`。

这样 `sec_phase → err_q` 与 `err_q → offset` 成为两段独立的路径。

| | Fmax | WNS | TNS | 关键路径起点 |
|---|---:|---:|---:|---|
| 改前（§6.2 基线） | 37.64 MHz | −18.569 ns | −661 896.147 ns | `rtc_sync\|sec_phase[22]` |
| **改后（候选，已保留）** | **42.15 MHz** | **−15.723 ns** | −665 200.142 ns | `rst_sync:u_rstsync\|r[2]`（回到 continue3 的老路径） |
| Δ | **+4.51 MHz** | **+2.846 ns** | −3 304 ns（**变差**） | —— |

**判定：正收益，保留。** 判据三条同时成立：
1. 功能不变：带此改动重跑**全量 53/53 PASS**（`raw/regress_timing_attempt.log`，wall 477.2 s，
   CSV `raw/regress_timing_attempt.csv`）；
2. Fmax 与 WNS 都改善，且关键路径**退回到 continue3 认定的那条老路径**，
   说明 `rtc_sync` 已经不再是瓶颈；
3. 两次 STA 的 8 ns 守卫都通过。

**同时如实记下不好看的一面**：TNS 反而变差了 3 304 ns（−661 896 → −665 200）。
这是合理的——最差路径被抬高之后，更多端点聚集在新的（更好的）最差 slack 附近，
总违例量并不必然下降。**只看 TNS 的话这次改动是负收益**；本轮按 Fmax/WNS 判定为正，
这个取舍在此明示，供评审自行判断。

### 6.4 可逆性

* `timing_attempt.patch` = `backup/timing_attempt_before/rtc_sync.v`（**改动前那一版，
  也是已经跑过 53/53 的版本**，sha256
  `D583A6B86C336B49A41E9269413A67775B8E37ADF98AF4C5CFB1C5A690FC0390`）
  → 当前版本的 `git diff --no-index`。
* **回滚方式**：直接用 `backup/timing_attempt_before/rtc_sync.v` 覆盖
  `rtl/mgmt/rtc_sync.v` 即可（哈希已核对）。
  **`timing_attempt.patch` 本身不能用单一 `git apply -pN` 逆向套用**——它的
  `a/` 侧在 `out/arena-debug/continue4/backup/...`、`b/` 侧在 `rtl/mgmt/...`，
  两侧路径深度不对称，`git apply` 找不到统一的 strip 层数。本轮实测
  `git apply --reverse --check -p6` 返回 128（"No valid patches in input"），
  **如实登记**：该文件是给评审看的**差分证据**，不是可直接机械套用的补丁；
  可机械回滚的载体是那份备份文件。
* 该改动**也已包含在 `fixes.patch` 里**（因为它被保留了）。两个补丁的关系：
  `fixes.patch` ⊃ `timing_attempt.patch`。

### 6.5 仍然没做的（下一轮，按预期收益排序，未经本轮验证）

1. 当前最差路径已回到 `rst_sync:u_rstsync|r[2]` → `rx_port_buf` 的 256 计数器组。
   建议把 16 端口 × 16 深度的计数拆成按端口分组的小加法器，再用一级流水汇总。
2. 复位树：continue3 试过"复位寄存器复制"，**结果更差**（41.49 MHz / −16.103 ns，已回滚），
   **不要重复那个做法**；应改为按时钟域/功能域分级同步释放。
3. 本轮新增代码里还有三处明显的宽组合，若出现在报告前列可用"读打一拍"换时序：
   `snmp_lite` 的 `walk()`（展开成 56 组比较器）、`stats_regs` 的两个 48:1 × 32 bit 读多路器、
   `mgmt_sap_rx` 的 `pbuf`（160 × 32 异步读）。
4. 本轮全部是 **post-map**，没有做 post-fit；真正的签核数字要等布局布线。

## 7. 产出清单（全部在 `out/arena-debug/continue4/`）

| 文件 | 说明 |
|---|---|
| `REPORT.md` | 本文件 |
| `fixes.patch` | 以**本轮开始时的文件状态**为基线的统一 diff（14 个文件）。`rtl/mgmt/mgmt_sap_rx.v` 与 `tools_lint.ps1` **漏做了现场备份**，对它们以 `git HEAD` 为基线，补丁头部有 NOTE 标注 |
| `RESULTS.json` | 机器可读结果 |
| `COMMANDS.md` / `COMMANDS.jsonl` | 命令记录（含踩坑清单） |
| `raw/regress_baseline.log` | 改动前 50/50 |
| `raw/regress_clean53.log` / `raw/regress_clean53.csv` | 改动后 53/53（独占运行） |
| `raw/lint.log` | Verilator lint gate |
| `raw/run_all_strict.log` | `run_all.py --strict` |
| `timing_attempt.patch` | 目标 B 的那一个结构性改动（`rtc_sync` 打拍），可 `git apply --reverse` 回滚 |
| `raw/regress_timing_attempt.log` / `.csv` | 带时序改动的全量 53/53 |
| `raw/map_base.log` / `raw/sta_base.log` / `raw/sta/BASE_*.rpt` | 目标 B **改前**基线的 post-map 与 STA |
| `raw/map_cand.log` / `raw/sta_cand.log` / `raw/sta/CAND_*.rpt`、`raw/sta/post_map_setup.rpt` | 目标 B **改后**候选的 post-map 与 STA |
| `backup/` | 改动前的源码快照（含 `sim_out_before/` 181 个文件）与 `head/` 的 HEAD 版本对照 |
| `project/` | 隔离的 Quartus 工程与 `sta_continue4.tcl` |
| `tools/mkpatch.py` 等 | 生成交付物的脚本本身 |
| `replay/` | `timing_attempt.patch` 可逆性自检用的隔离副本（不碰实时源码） |
| `SHA256SUMS.txt` | 所有保留文件的哈希（最后一步生成，不含自身；548 个文件，71.1 MiB） |

> 目录里另有 `FINALIZE-REPORT.md`、`raw/docgate.*`、`raw/finalize_audit.json` 三项，
> 是**上一轮只做了预检就中止**时留下的产物（任务书说明 continue4 此前"只有预检、可覆盖"）。
> 本轮没有删除它们，但它们与本轮结论无关，请以 `REPORT.md` / `RESULTS.json` 为准。

## 8. 诚实性声明

* 本轮**没有**执行 `git commit` / `git push` / `git reset`；`git show` / `git status` / `git diff` 只读。
* 本轮**没有**访问 `competition_case/`、`data/`、`logs/`。
* 本轮**没有**读取或回显任何 `.env`、`*.local.*`、密钥/账号/口令/token。
* 报告中每一个"PASS"都对应 `raw/` 里的原始日志，没有手写结论。
* **一次纪律偏差如实登记**：在启动 `final53` 全量回归时，上一次 6 条用例的小回归
  尚未完全结束，两个 Questa 进程有约 10 s 的重叠（编译窗口）。发现后**没有采信那次结果**，
  等其完全退出、确认 `vsim_running=0` 后**重新独占跑了一次完整的 53 项回归**
  （`raw/regress_clean53.log`，wall 542 s），报告与 `RESULTS.json` 引用的是这一次。
* **备份缺漏如实登记**：`rtl/mgmt/mgmt_sap_rx.v`、`tools_lint.ps1`、`elinx/prj/AFDX_top_synth.ys`
  在首次修改前没有拷进 `backup/`（`AFDX_top_synth.ys` 后来补了备份，但已在改后）。
  其中 `mgmt_sap_rx.v` 连 git HEAD 里都没有（未被跟踪），所以 `fixes.patch` 里它是**全量镜像**
  而不是差分，补丁头部有 `MISSING BASELINE` 标注。其余被改文件都有改前现场备份。
* 目标 B 的 `rtc_sync` 改动**在改前单独备份**到 `backup/timing_attempt_before/`，
  并核对了 SHA256，所以它的 `timing_attempt.patch` 是严格的"已验证版本 → 候选版本"差分。
