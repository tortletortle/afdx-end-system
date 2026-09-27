# Continue7-finalize —— 修复 QSF 器件族并完成 STA 验收

在 `C:\Workspace\diansai\out\arena-debug\continue7\` 接续上一轮 claude-opus-5 因 `Family name "Cyclone IV GX" is illegal` 中断的工作。

## 现状（已核实）
- step1 已完成：`tx_port_buf` 描述符拆 4 bank（256 路 mux → 4×64 + 4:1），`timing_step1.patch` + `backup/step1/tx_port_buf.v` 就位，`raw/step1_regress.log` = **56/56 PASS（473.8s）**，功能已通过。
- **阻塞点**：`raw/step1_map.log` 报 `Error (20004): Family name "Cyclone IV GX" is illegal` —— 本轮复制/重建 Quartus 工程时 QSF 器件族被设错。**正确工程器件**（continue6 已验证）：`FAMILY "Stratix IV"`、`DEVICE EP4SGX230HF35C2`；生产 `elinx/prj/quartus/AFDX_top.qsf` 已是正确的。

## 本轮目标（不要重跑已完成的 56 项回归）
1. **修复 QSF 器件族**：把 continue7 STA 用的 Quartus 工程 QSF 改成 `FAMILY "Stratix IV" / DEVICE EP4SGX230HF35C2`（或直接复用生产 `elinx/prj/quartus/AFDX_top.qsf` 的正确配置 + 4 个管理面 RTL 源，参照 continue6 做法）。
2. **跑一轮 post-map STA**：`quartus_map` → `quartus_sta`，必须过 `check_sdc_8ns` 守卫（`clk=8.000`），记录 Fmax/WNS/TNS 与最差路径。
3. **对比 continue6（Fmax 45.85 MHz / WNS −13.809）**，判断 tx_port_buf 分银行是否有收益：
   - 有收益 → 保留进 `fixes.patch`；
   - 负收益 → 用 `timing_step1.patch` 反向回滚 `tx_port_buf`，保留失败日志，报告里如实写。
4. 完成 `REPORT.md`、`RESULTS.json`、`SHA256SUMS.txt`、`COMMANDS.md/jsonl`。

## 纪律（强制）
- 不读取/回显 `.env`、`*.local.*`、密钥/账号/密码/token 原文；不碰 `competition_case/`、`data/`、`logs/`；不 `git commit/push/reset`；
- 不并行跑两份 Questa / 两份 quartus_map；不伪造时序收敛；post-map 非签核，如实标注。