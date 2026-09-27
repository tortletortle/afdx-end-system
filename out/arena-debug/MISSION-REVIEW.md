# Arena 独立复检任务 — diansai（AFDX 端系统 / FPGA 大赛）

你在 Arena 云沙箱，通过 HTTP 工具服务调用本机工具，工作区 = `C:/Workspace/diansai`。
工具：`list_directory / find_files / search_files / read_files / apply_patch / run_command / get_command_output / send_command_input`。
本文件在 `out/arena-debug/MISSION-REVIEW.md`。**允许真实编译/仿真/跑命令/读改代码**。

## 背景
另一个助手（较轻量模型）刚刚在 diansai 完成了一大批 RTL 实现与仿真，声称：
- 实现了 **SAP/管理面**（`rtl/mgmt/mgmt_sap_rx.v`、`AFDX_top` 接入管理窗口 0xAC10-0xAC13、`rx_ip_udp_parse` 加 `sap_enable`）。
- 新增 TB：`tb_t08f_full_scoreboard`（全表灌装+逐笔 scoreboard）、`tb_t17_min_frame_stress`、`tb_t21_block_pool`、`tb_t23_sap_min`、`tb_t05b_jitter`、`tb_t13_latency`、`tb_t18_random_stress`。
- 声称 **50/50 Questa 全量回归 PASS**（`doc/当前进度_20260923.md` / `out/arena-debug/DIANSAI-REPORT.md` / `diansai.patch`）。

你的任务是**独立、批判性地复检**这份工作和结论，别轻信报告。特别提防：自报与实测不符、漏测的 gate、选择性略过的失败、为通过而塞宽松断言、gotcha 型 TB（只测了自己造的正确路径）。

## 复检步骤
1. 先读：`README.md`、`doc/当前进度_20260923.md`、`doc/后续计划.md`、`AFDX端系统_总体设计书.md` 相关章节、`out/arena-debug/DIANSAI-REPORT.md`。
2. **核对仿真证据是否真实**：
   - 跑 `python tools/run_all.py --strict`（文档门）与 `powershell -NoProfile -ExecutionPolicy Bypass -File ./tools_lint.ps1`（lint，须 ALL gates 0 %Error）。
   - 抽查 `sim/out/regress.csv` 与命名 CSV（regress_full_44_agent 等）确认 50 项是否真 PASS。
   - 选 2-3 个关键 TB（至少 T23 SAP、T08f scoreboard、T18 随机）**自己重跑一遍**并核对 PASS 摘要是否站得住。
3. **批判性审查 RTL**（读代码找真 bug/可疑点）：
   - `rtl/mgmt/mgmt_sap_rx.v`、`AFDX_top.v`（SAP handoff、管理窗口、块归还仲裁、`pb_free1` 复用）、`rx_ip_udp_parse.v`（`sap_enable` 与 type=2 路由）。
   - 新 TB 的断言是否真的覆盖目标（还是自证清白）、有没有时序/复位/边界漏洞。
   - 是否有把「未做」说成「做了」、有无以偏概全。
4. **清单完整性**：对照 `doc/当前进度`/`后续计划`，确认声称完成项是否都有独立可再生证据；**明确列出仍未真正闭环的项**（例如整机综合/STA、覆盖率、管理协议栈/SNMP/统计中断等）。
5. 对发现的每个问题给：文件:行号/命令、复现、根因、严重度、修复建议。

## 交付
- 写 `out/arena-debug/REVIEW-REPORT.md`：分「确认属实」「存在疑问/需修正」「仍未完成」三部分，附证据与复检结论。
- 若发现问题需要小修，可改代码并记录到 `out/arena-debug/review.patch`（改动前先备份到 backup/）。
- 严禁读取 .env/密钥/token；不要 git commit/push；不要碰 `competition_case/`。

## 约束
- 改任何 RTL/TB/脚本前先备份；只做最小可逆修改。
- Questa 运行纪律：跑前确认无其他仿真任务，不并行两份回归；优先单跑抽查项。
- 复检结论要客观：是就是、不是就不是，不要为了面子维修。
最后在回复里给：复检结论摘要、发现的真问题、确认/否定项、REVIEW-REPORT.md 路径。