<!-- rendered from AFDX端系统_测试报告.md using C:/Workspace/diansai/out/p8_freeze_225cd91/metrics.json commit=225cd91be4f6a4b332db1674b44761bca367bd67 -->

# AFDX 端系统测试报告（提交版）

> 数字一律双花括号 metric 锚点（对照 `out/p8_freeze_225cd91/metrics.json`）。历史全量计数等只允许出现在历史附录并注明版本。

## 1. 验证环境

- 仿真器：Questa（功能全量）；ModelSim SE（门级）。
- TB：`sim/tb` + `env` BFM + `chk` bind；独立黄金模型见 `sw/golden/`。
- 时钟：与 GMII 线速拍一致。

### 1.1 Runner 说明（harvest）

`sim/run_regress.ps1` 的 `Run-Vsim`：若日志已出现 `$finish` 与 `Errors: N` 而进程未退出，grace 后收割并返回 0，**不改 TB 判据**。用于消除个别用例（如历史冒烟 T42）「日志已 PASS、墙钟 TIMEOUT」的假失败。  
本冻结全量 N=`144` 在带 harvest 的 runner 上得到；与历史全量（旧 runner、不同 N）**不可直接等同**。

### 1.2 判据独立性表

| 类别 | 代表 T | 外置模型/脚本 | TB 内自比 |
|---|---|---|---|
| 有外置 Python/golden | T09、T12 族、T35、T42/T43 向量、T89 metrics_check、SNMP wire | 是 | 兼有 |
| 主要 TB 记分板 | T00–T08、T10/T11、T13/T13w、T22、T88 | 部分 | 是 |
| 负控变异 | T08c/e、T09、T10、T11、T12、T22 mutants | 注入故障期望 FAIL | — |

## 2. 如何复现

1. 冒烟：`powershell -File sim/run_smoke.ps1`
2. 全量：`run_regress.ps1` → `freeze_regress.py --require-full`
3. 门级：导出 functional VO 后按 `run_gate_t88b.ps1` / 计划 P2
4. eLinx：`tools/run_baseline_full140_synth.py`（commit 改为本冻结）

**需按本机修改**：`SALT_LICENSE_SERVER`、Questa/ModelSim/`eLinx_synthesis` 安装路径（勿写死进包）。

## 3. 需求 → T → 实测 → 不能推出

| 需求/指标 | T | 实测（metric） | 不能推出 |
|---|---|---|---|
| 端到端时延（单 VL 最大帧） | T13 | 243416 ns | 网络端到端；XAPP RX 参考界（非赛题项） |
| 争用最差时延 | T13w | 453752 ns | 任意 BAG 档 |
| 饱和抖动 | T05b | startup 2 μs / steady 0 μs | 合法 BAG 全档 |
| GMII 吞吐/时延 | T42 | tx 16.08 μs；rx 12.936 μs | 板级 |
| GMII 指标场（IF_MODE=2） | T89 | tx 15536 ns；rx 160 ns；jit 72 ns；本场景 40+Σ=141 μs | 满配吞吐未测；与 T13w 同配置 |
| IC | T09 | accept 1759 / reject 4248 | 全错误笛卡尔积 |
| RM | T10 | fwd 56 dup 46 skew 3 | babbling |
| 全量 | manifest | 144/144 | 认证套件 |

T13 / T13w / T05b 为 IF_MODE=0（或各 TB 标明）；T89 为 IF_MODE=2，**分列**，不混用。

## 4. 全量清单

由 `regress.csv` 自动生成（打包时附）。汇总：PASS `144` / N `144`。

## 5. 指标章

### 5.1 T42

- 吞吐与时延：见 §3 metric 行。
- 抖动 max：`5.016` μs。

### 5.2 T89（ns）

| 项 | 值 |
|---|---|
| max_tx | 15536 ns |
| max_rx | 160 ns |
| max_jit | 72 ns |
| 本场景 40+Σ | 141 μs |
| 满配 VL 吞吐 | **未测** |

图：吞吐/时延/抖动占位（由 VCD 绘制，非 GUI 截屏；VCD sha256 见图注）。缺图清单见文末。

## 6. 综合后仿真章

- 门级 T88b：S1=PASS S2=PASS S3=PASS
- VO sha256：`2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46`
- **eLinx GUI 行为仿真（人工，2026-10-23）**：工程 `elinx/gui_afdx/AFDX_top.epr`，顶层 `tb_gate_public_loopback`，ModelSim SE `C:/modeltech64_2020.4/win64`；控制台 `T88b GATE PUBLIC LOOPBACK PASS`，`Errors: 0`。归档 `out/p3_elinx_gui_20261023/`（截图、`AFDX_top.do`、`run_sim.bat`、`transcript`）。等级：**P（GUI 行为）**；≠ 门级 VO；≠ Fit/STA。

## 7. 质量证据

| 项 | 值 |
|---|---|
| 变异杀死 | null/null |
| lint %Error | null（含 BLKLOOPINIT 豁免则见 FREEZE 说明） |
| 覆盖率 | 未跑（本轮 FREEZE 标明） |
| 形式 BMC | 有界 I；见 `formal/ENV_STATUS.md` |

## 8. 缺陷与修复记录

（定稿时从 git log 挑真实缺陷：根因、修复、回归 T。骨架阶段不填编年史。）

## 9. 边界与未覆盖

- 满配 VL 吞吐未测
- ModelSim SE 全量逐项对比本轮未跑
- 覆盖率本轮未跑
- Fmax 未闭合（I）

## 缺图清单（人工补）

- [x] eLinx GUI 截图：`out/p3_elinx_gui_20261023/shots/`（sources / modelsim_path / pass）
- [ ] T88 / T89 / T10 波形 PNG（VCD→脚本；注明 VCD sha256）
