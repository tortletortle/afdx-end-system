# Arena 修复任务 — diansai（按 REVIEW-REPORT 修问题）

你在 Arena 云沙箱，通过 HTTP 工具服务调用本机工具，工作区 = `C:/Workspace/diansai`。
工具：`list_directory / find_files / search_files / read_files / apply_patch / run_command / get_command_output / send_command_input`。
本文件在 `out/arena-debug/MISSION-FIX.md`。**允许真实编译/仿真/跑命令/改代码**。

## 背景
独立复检（`out/arena-debug/REVIEW-REPORT.md`）发现上一轮工作的问题，按严重度给你：
**B1(高) 顶层综合崩溃**、**B2(高) sync_fifo 多驱动冲突**、**B3(高) T05b 抖动判据放水**、
**B5(中高) SAP 块归还仲裁无公平性→RX 流水线饿死风险**、**B4(中高) 错相/同相措辞错**、
**B6/B7(中) T18 名不副实+去重断言漏网**、**B8(中) RTL 仿真当 STA**、**B9/B10/B11(低)**。
先读 `REVIEW-REPORT.md` 完整内容（每项有文件:行号、复现、修复建议）。

## 修复要求（按优先级，能做几个做几个，宁缺毋滥）
1. **B2（必做，最实）**：修 `rtl/common/sync_fifo.v` 的多驱动冲突——`rd_data` 被同一 `$mem` 的
   `RD_DATA` 与 `RD_DATA_B` 两个读端口同时驱动。改为单一读端口或显式分离两个 rd_data 信号。
   用 `Select-String elinx\prj\sub_sync_fifo.log -Pattern ERROR` 复现，修完重跑 `tools_lint.ps1` 和该模块综合。
2. **B3（必做）**：T05b 抖动判据要诚实——把 `sim/tb/tb_t05b_jitter.v:221` 的 867 阈值改回 **500 μs 合规线**，
   并实现**起始相位错开**（`send_message` 循环按 `i*BAG/NVL` 错开提交相位）让启动抖动真正达标；
   若修不达标就如实标 FAIL/WAIVED，不许用宽松阈值硬判 PASS。同步修正 `doc/当前进度:189` 的「同相/错相」措辞。
3. **B5（必做）**：给 SAP 块归还仲裁加公平性——`AFDX_top.v:597-599` 的固定优先级改为**轮转/带老化计数**，
   避免 SAP pending 被普通 RX 归还饿死→RX 流水线停摆；补一个 TB 场景：SAP pending 期间持续灌普通 RX 归还，
   断言 `mgmt_free_take` 有界延迟。
4. **B4**：修正文档里「错相」为「同相」（或已实现真错相后如实说明）。
5. **B6/B7**：T18 改成**真随机压力**（`$urandom(seed)` 驱动长度/间隔/背压），并把去重断言改为精确
   `deliver_cnt == prev_deliv + 1`；若只做定向环回就改名为 `tb_t18_directed_loopback`，别叫随机压力。
6. **B1（尽力）**：顶层综合崩溃（memory_map `invalid vector<T> subscript`）。先复现 `AFDX_top_synth.ys`；
   若能把大容量存储改 eLinx BRAM 硬核或换可综合写法就修；若是 eLinx/Yosys 工具本身限制，**如实登记**
   （`doc/当前进度` 改 `[ ] 部分完成`，明确顶层综合未通过），不要把失败写成成功。
7. **B8/B9/B10/B11**：订正报告/文档——RTL 仿真≠STA（改「时序收敛未验证」）、综合表格改为脚本自动生成或修正路径、
   T23 补负例、同步文档门自述。

## 强约束
- 改任何 RTL/TB/脚本前先备份到 `out/arena-debug/backup/`；只做最小可逆修改。
- 每修一项：跑对应测试 + `tools_lint.ps1` + 文档门；**收尾必须整跑一次全量回归，确认 50 项仍全绿（或如实记录新增 FAIL 及原因）**。
- Questa 纪律：跑前确认无其他仿真任务，不并行两份回归。
- 严禁读取 .env/密钥/token；不要 git commit/push；不要碰 `competition_case/`。
- **不许造假/放宽判据来强行 PASS**：测不过就如实登记为 FAIL/WAIVED 并说明根因。

## 交付
- 更新 `out/arena-debug/DIANSAI-REPORT.md`：每项修复一节，含 before/after、复现命令、仿真/综合结果。
- 生成 `out/arena-debug/fixes.patch`（`git diff`，可 `git apply -R` 回滚）。
最后回复给：修了哪些、每项结果、还剩哪些没修/修不动及原因。