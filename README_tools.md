# 工具包说明

> 更新：2026-10-02。本页只说明**仓库里实际存在**的脚本及用法。现行状态见[收口总览](doc/收口总览_20261001.md)／[项目当前状态](doc/项目当前状态_20260929.md)；过期进度见[历史归档](doc/历史/README.md)；文档导航见[文档索引](doc/README.md)。

## 布局与前提

- **仓库根就是工作区根**：`AFDX端系统_总体设计书.md`、`README.md`、本文件和 `tools_lint.ps1` 都在根目录；校验脚本在 `tools/`，寄存器 YAML 在 `doc/`，仿真脚本在 `sim/`。
- 所有命令都在仓库根执行（Windows PowerShell）。文档校验只需 Python 3.8+ 标准库；RTL 检查另需 Verilator、Questa/ModelSim，综合冒烟需 eLinx。
- 目录已经归位，**不要再执行旧版说明里的 `Move-Item` 平铺迁移命令**（见文末历史说明）。

## 先跑这个

```
python tools\run_all.py --strict
```

一次跑完下表 5 个文档校验器，`--strict` 另跑 `selfcheck_claims.py`；末行「5/5 全绿，自查通过」且退出码 0 才算过。改了设计书、地址表或寄存器之后必须重跑。它只证明文档自洽、数字可复算，**不等于 RTL 验收**。

## 脚本一览

| 脚本 | 作用 | 跑成功的判据 |
|---|---|---|
| `tools/verify_all.py` | 全文一致性：章节编号、交叉引用、45 张表列数、T00~T22/D1~D9/R1~R9、§9 表规模与正文对账、模板 8 端口方向位宽、脚本路径唯一性、硬件化措辞（只罚肯定式） | 末行「全部通过，0 处问题」，exit 0 |
| `tools/check_addr.py` | §7.14 地址表逐行复核：区间跨度 = 声明字数、无重叠、PMEM 2 KB（0x200 字）对齐；§8.6 三池区间须在 PMEM 行内、互不重叠、字数 = 块数 × 0x200 | 「校验到 14 行；合计 53408 字（209 KB）… 错误 0 处」 |
| `tools/fix_addr.py` | §7.14 地址表生成器：按「项数 × 每项字数」连续排布并重算 §9 规模。**要改地址就改这个脚本里的 LAYOUT，不要手打区间** | 打印新表并回写文档 |
| `tools/check_s9_final.py` | §9 每行按「项 × 位」反算 Kbit 与 18 Kbit 块数，并核对合计行 | 「行数 13 … 错误 0」+ 两行 ok 合计 |
| `tools/check_s9.py` | §9 的旧版抽查（保留备查，日常用 `check_s9_final.py`） | 只读 |
| `tools/run_all.py` | 一键跑完 5 个校验器；`--strict` 另运行 `selfcheck_claims.py` 且自查失败会令命令失败 | 「5/5 全绿」，严格模式还需「自查通过」 |
| `tools/bag_model.py` | §8.2 判决式的唯一实现（`bag_budget.py`、`check_doc_numbers.py` 都从这里取数，避免两份算法飘开） | 被引用，不单独跑 |
| `tools/check_doc_numbers.py` | 把 §8.2 正文写死的 T05a/b/c 数字逐条重算对账 | 「全部一致：文档里的 §8.2 数字都可由判决式复算」 |
| `tools_lint.ps1` | Verilator lint 门（顶层 + TX/RX 单模块 + 已登记 TB；含 `mac_rx_if`/`rx_ic`、T08a/T08b/T09/T09p）。**注意**：eHiWay Verilator 有路径参数 bug（带路径前缀的文件被当 module 名），脚本已内置 `-f` 响应文件绕开，勿改成裸命令行 | 末行 `LINT GATE: PASS`，exit 0 |
| `sim/run_regress.ps1` | 一键回归（§12.4 骨架）：读 `sim/tests.manifest`，一次编译 + 每用例独立 vsim 会话（600 s 超时保护），产出 `sim/out/regress.csv` 与逐用例 console 日志。`-Acc` 开波形可见性（vopt +acc，见踩坑 7），`-Tests T09,T09s,T09p,T09ps` 选 IC 黄金/压力的满配和缩配四项 | `REGRESS SUMMARY: n/n pass`，exit 0；CSV 在 sim/out/regress.csv |
| `tools/gen_cfg_shares.py` | 直访式 TX Q20 份额配置 CSV：`python tools/gen_cfg_shares.py --n 128 --lmax 1518 --bag-us 8000 --out sim/vec/t05c_cfg_shares.csv`；默认拒绝超配生产映像，`--allow-overload` 仅生成 T05c 负例；先写 `0x0480+VL`，再写 TX w0.valid；`--selftest` 覆盖 T05a/b/c 与 T22a 数字 | `CFG_SUM=2064384/1048576, REJECT BAG_OVF`；T05c Questa 子项 PASS 才是硬件拒绝证据，不含 T05b 抖动 |
| `sw/golden/gen_t08a_vectors.py` | T08a/T08ag：ETH/IP/UDP 取模型帧体、zlib 独立按低字节先发生成 FCS；22 帧/档包含坏 FCS/IP/UDP/格式/pad/长短帧等；生成 `sim/vec/t08a_frames.hex` | `T08a vectors: 22 cases`；Questa `-Tests T08a,T08ag` 两档通过才算 RTL 单元证据，不能等同完整 T08/T22 |
| `rtl/rx/rx_ic.v` + `sim/tb/tb_t09_rx_ic.v` | T09/T09s：全深度 4096 VL 与缩配 16 VL 两档；TB 参考状态机 + `sw/golden/afdx_model.py` 的 `ic_decide` 生成的 5632 个边界/固定种子判决向量，逐项核对双网 PSN、首帧严格/宽容、SN=0、丢一帧、回绕、调试写、背压/拒绝不写回；上游须只给校验合格描述符 | `-Tests T09,T09s` 单元仿真通过；未接入顶层 lookup/FLT/RM，不等于完整 T08/T22 |
| `sim/tb/tb_t09p_rx_ic.v` | T09p/T09ps：连续 ready/valid 生产者 + 逐沿独立 scoreboard；满配 **10240 帧触达 8192/8192** A/B PSN 槽，缩配 **2080 帧触达 32/32**，51 拍周期性停顿叠加随机 ready；检查顺序、准确一次输出、背压稳定、真实 RAM 写回、复位中断、全表重扫/挂起输出取消、缩配越界索引别名 | `-Tests T09p,T09ps` 两档通过；不代替顶层后级与端到端测试 |
| `sw/golden/gen_t09_vectors.py` | 用第二套模 255 差值规则对 **2×256×256 = 131072** 个 Python 判决组合交叉核对；生成 `sim/vec/t09_ic_cases.hex`（**5632** 条 RTL 向量，固定种子 `0xA664`），选中 T09/T09s 时自动生成，脚本失败则中止仿真 | `python sw/golden/afdx_model.py` 自检 0 错；生成器输出 131072 oracle checks / 5632 RTL vectors；**软件全穷举不等于 RTL 全穷举** |
| `sim/test_t09_mutants.py` | 独立临时 work 库依次注入「丢一帧判错」「拒绝写回错」「B 网地址漏偏移」3 个 RTL 错误，要求 T09ps 每次报 FAIL；只修改临时 RTL，不改源文件及日常 sim/work，原始 SHA 留在 `sim/out/T09_mutants_report.txt` | `python sim/test_t09_mutants.py` → `T09 MUTATION SUMMARY: 3/3 detected`，退出码 0；只证明这 3 种故障能抓住 |
| `sim/test_t08c_mutants.py` | 顶层 T08c 隔离故障注入：过早 ACK/丢写、未锁存待决数据、未锁存待决地址；只改临时 RTL，报告 `sim/out/T08c_mutants_report.txt` | 3/3 检出、退出码 0；**与回归串行运行**，不要并行 |
| `sim/tb/tb_t08e_top_ic.v` | T08e/T08eg：顶层 lookup→FLT→IC 链；真实 79 B 帧改 SN 并在 TB 内重算 FCS，逐判决对独立参考模型、核对 `u_rxic.psn_mem` 与逐帧块守恒；含 A/B 偏斜争用与 RX_EN 关断 drain 扫描 | `-Tests T08e,T08eg` 两档 `T08e TOP IC PASS`；RM/端口未接，不等于完整 T08/T22 |
| `sim/test_t08e_mutants.py` | 顶层 IC 接线的 5 个隔离故障（IC_EN 失效、IC 拒绝漏计合计、拒绝写 PSN、A/B PSN 混用、丢一帧误拒），跑 `tb_t08eg_top_ic`；报告 `sim/out/T08e_mutants_report.txt` | `T08e MUTATION SUMMARY: 5/5 detected`、退出码 0；与回归串行 |
| `sim/tb/tb_t10_top_rm.v` | T10/T10g：顶层 lookup→FLT→IC→RM 链；A/B 副本偏斜/先后、SkewMax 内外、RM 开关、IC 旁路、IC 拒绝不污染、（IF_MODE=0）早到迟判副本；逐判决对独立 RM 模型、核对 `u_rxrm.rm_mem` 与逐帧块守恒、逐 SN 交付次数 | `-Tests T10,T10g` 两档 `T10 TOP RM PASS`；解析/端口未接，不等于完整 T08/T22 |
| `sim/test_t10_mutants.py` | 顶层 RM 的 7 个隔离故障（不删重复、单边窗口、忽略 seen、重复改写表项、RM_EN 失效、IC 旁路不进 RM、RM 丢弃漏计合计），跑 `tb_t10_top_rm`；报告 `sim/out/T10_mutants_report.txt` | `T10 MUTATION SUMMARY: 7/7 detected`、退出码 0；与回归串行 |
| `sim/tb/tb_t11_top_port.v` | T11/T11g：顶层 RM→`rx_ip_udp_parse`→`rx_port_buf`；采样交付/读清/覆盖/pin、深度 3 队列与溢出、五类解析丢弃、访问错误、复位；主机前门读描述符并在运行期逐字节读回 PMEM 载荷 | manifest 登记，随 `sim/run_regress.ps1` 运行；builder 同拍抢读口的延后 ACK 无定向激励 |
| `sim/tb/tb_t21_block_pool.v` | T21/T21g：顶层真实 79 B 帧走 lookup→FLT→IC→RM→parse→`rx_port_buf`，用队列深度 10 占满 RX 块 6..15；第 11 帧验证 `NO_BLK`、`rx_exh_cnt`、无 PMEM 写/无入队；随后 `MSG_RD` 逐项释放并验证恢复帧 | `-Tests T21,T21g` 两档 `T21 BLOCK-POOL PASS`；这是块池耗尽/恢复定向证据，不等于完整 T08 全表逐笔 scoreboard |
| `sim/test_t11_mutants.py` | 顶层解析/端口的 13 个隔离故障（fresh 不读清、已读覆盖不 pin、旧 pin 泄漏、队列深度失效、出队不前移、初始化不清、目的端口/方向检查缺失、载荷长度字段错、描述符返回清后值、端口丢弃漏计合计、运行期载荷读缺失、非 RX 端口 MSG_RD），跑 `tb_t11_top_port`；报告 `sim/out/T11_mutants_report.txt` | `T11 MUTATION SUMMARY: 13/13 detected`、退出码 0；与回归串行 |
| `sim/test_t11i_mutants.py` | v0.5.17 顶层 RX 事件中断的 9 个隔离故障（bit0 不置、bit1/bit2 互换、CRC 位只接 A 网、W1C 压过同拍事件、`INT_ENABLE` 不掩 8 位、`host_irq` 忽略使能/软件中断位、事件脉冲粘连、队列满不置事件），跑 `tb_t11i_top_int`；报告 `sim/out/T11i_mutants_report.txt` | `T11i MUTATION SUMMARY: 9/9 detected`、退出码 0；与回归串行 |
| `sim/test_t22_mutants.py` | v0.5.17 TX→RX 回环的 6 个隔离故障（重复副本块不回收、哈希命中恒 0、载荷长度取错字段、IC PSN 不回写、TX 不附 FCS、RX 载荷写地址错一拍），跑 `tb_t22_top_loopback`；报告 `sim/out/T22_mutants_report.txt` | `T22 MUTATION SUMMARY: 6/6 detected`、退出码 0；与回归串行，单例可跑数分钟 |
| `sim/test_t12_mutants.py` / `sim/test_t12_top_mutants.py` | 哈希查找单元 / 顶层查找的隔离故障注入，报告分别在 `sim/out/T12_mutants_report.txt`、`sim/out/T12_top_mutants_report.txt` | 以脚本末行 SUMMARY 全部检出且退出码 0 为准；同样不要与回归并行 |
| `sim/freeze_regress.py` | 对命名的**完整**回归 CSV 做 manifest 同序/全 PASS 校验，记录 runner 实际 RTL/TB、向量、脚本及各用例/综合/变异报告的 SHA-256；保存 JSON 便于比对未提交源码与证据 | 完整运行后执行，例如最新一轮：`python sim/freeze_regress.py --csv sim/out/regress_full_26_20260923.csv --out sim/out/test_evidence_26_20260923.json`；只绑定摘要，不等于打包可复现源码或完成交付 |
| `elinx/prj/rx_ic_smoke.ys` | eLinx 单模块 RAM 映射冒烟，显式 `memory_bram` 并断言 8192×8 PSN 映成 16 × altsyncram(M4K)，防止 rc=0 但扩成万级 FF；只覆盖独立 `rx_ic` | `eLinx_synthesis.exe -s elinx/prj/rx_ic_smoke.ys -l elinx/prj/rx_ic_smoke.log` 返回 0 且 `stat` 有 16 × altsyncram；不代替顶层综合/STA |
| `_conv.py`（仓库根） | 把赛方的 xlsx / rar 变成可读文本：xlsx 用标准库 `zipfile` 解 `sharedStrings.xml`+`sheet1.xml` 出 CSV 与 `_conv_report.txt`，rar 调 7-Zip 解压并就地打印文本文件内容。不需要 Excel、不装第三方包，`python _conv.py` | 打印 `report lines=N bytes=M`，产物落在同目录 |
| `tools/gen_regs.py` | `doc/regs.yaml` → `doc/regs_pkg.svh`（地址 localparam + 访问位图），并反向核对附录 A / A.1~A.3 | 「YAML 自检：通过 / 主表对账：一致 / 位域表对账：一致」 |
| `tools/bag_budget.py` | 按 §8.2 判决式算逐 VL ceil 的 CFG_SUM、饱和 BAG、单帧时间和等效线上需求；**单帧时间不是普遍抖动上界** | 打印三组用例 |
| `tools/selfcheck_claims.py` | 独立复核 C1 前门配置量/初始化扫描量、C2 T05 Q20 整数、C3 同相启动排队风险（模型非 RTL 实测） | 打印 C1/C2/C3 与待验证风险 |
| `tools/check_sizes_add.py` | 给 verify_all 追加检查用的一次性补丁脚本，平时不跑 | — |

## 与文档的对应关系

- 寄存器只有一处真值：`doc/regs.yaml`。附录 A 与 A.1~A.3 由 `gen_regs.py` 生成/核对，RTL 里的 `ADDR_*`
  与 `ACC_*` 在 `doc/regs_pkg.svh`。改寄存器就改 YAML，然后跑 `python tools\gen_regs.py --emit`。
- 地址表只有一处真值：`tools/fix_addr.py` 的 LAYOUT。§7.1 的 PMEM 基址、§8.6 的三池区间、
  `TFTP_DEST_BASE` 都由它广播，改完必须跑 `check_addr.py`。
- §9 的每个数字必须能被 `check_s9_final.py` 反算出来。上一版这里连错过三次（1.61/1.78/1.30 Mbit），
  以及 §8.2 的「99.84 Mbps」（实为 8.96 Mbps，差 11.2 倍）和 §8.3 把「拍」当「μs」用（1471×8 拍 = 117.7 μs，
  不是 11.8 μs）——有脚本之后这类错一跑就现形。

## 验证边界（重要）

文档脚本仅保证**内部自洽与算术正确**。RTL 已有单元/局部接线仿真；以 `sim/tests.manifest`
与最新 `sim/out/regress.csv` 为准，单项 PASS 不可推导系统端到端、满载抖动或时序达标。
T08b 只证明 RX 双网入口、PMEM 写口和描述符落盘；T12f 证明顶层哈希查找；T08d 证明 FLT 语义过滤已接顶层；
T08e 证明 IC 已接在 FLT 之后（T09/T09p 为 IC 单元级），T10 证明 RM 已接在 IC 之后，T11 证明 RM→解析→RX 端口交付与主机读回（定向切片）。完整 T08/T21/T22、SAP/中断、T05b 满载抖动和 125 MHz STA 均待验证。
IC 单元已独立映射 M4K，不能将其单元器件数当作顶层时序或资源验收结论。

## 历史说明（2026-09-21 平铺时期，已失效）

早期 Bridge 的 apply_patch 不能建目录，脚本曾以 `tools_*.py`、`doc_regs.yaml` 平铺在根目录，旧版本页附带 `mkdir` + `Move-Item` 归位命令。现在 `tools/`、`doc/` 已归位（根目录的 `tools_lint.ps1` 是正式位置，不需要移动），**旧迁移命令不要再执行**。

脚本仍保留按「自身同级 → 上一级 → 当前工作目录 → 家目录」查找 `AFDX端系统_总体设计书.md` 的兼容逻辑；2026-09-21 已修掉重复 `_find` 定义和 `import bag_model` 在平铺时解析失败的问题。

以下脚本在旧版说明里出现过，但 2026-09-24 核对**不在本仓库**，不要按旧说明直接调用：

- `tools/md2docx.py`：Markdown → Word，依赖 python-docx；.docx 需另行生成/下载。
- `tools/_sync_push.py` / `tools/_sync_verify.py`：早期隧道同步脚本。注意远端 `read_files` 的 `version:` 哈希与本地内容哈希不可直接比较，同步结果只能逐行比对确认。


