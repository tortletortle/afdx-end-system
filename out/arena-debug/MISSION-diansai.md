# Arena 推进任务 — diansai（AFDX 端系统 / FPGA 大赛）· 第二轮：把剩余项做完

你在 Arena 云沙箱，通过 HTTP 工具服务调用本机工具，工作区 = `C:/Workspace/diansai`。
工具：`list_directory / find_files / search_files / read_files / apply_patch / run_command / get_command_output / send_command_input`。
本文件在 `out/arena-debug/MISSION-diansai.md`。**允许真实编译/仿真/跑命令/改代码**，遵守下方约束。

## 现状（上一轮已登记）
- TX/RX 主链路 + T22 回环已实现，**36/36 Questa PASS**。
- **T21 块池耗尽/反压/恢复/归还已做**：新增 `sim/tb/tb_t21_block_pool.v`，T21/T21g 2/2 PASS，manifest/runner 已接入，文档已更新（见 `doc/当前进度_20260923.md`、`doc/后续计划.md`）。**不要重复做 T21。**

## 本轮目标：把剩余项按优先级做完（每项都要有 Questa 仿真证据 + 文档登记）
1. **完整 T08（全表灌装 + 逐笔 scoreboard）**：把现有 T08 子集扩成「配置全表灌装 + 逐笔 scoreboard」验收，覆盖正常/未配置/碰撞/摆放失败配置，坏帧/错误配置不污染后级状态。缺实现则最小实现，补真实帧 TB + scoreboard。
2. **P0-02 / T17（主机长稳/混合读写）**：持续饱和双网写口下的等待上界、主机读写交错、最小帧/双网冲击、长稳；有实测最大/平均/失败样本。
3. **SAP / 管理面最小闭环**：SAP→mgmt 投递的最小可复现闭环（若时间够）。
4. **T05b 合法满载抖动**、**T13 端到端时延**、**T18 长时随机**：按目标矩阵补量测证据（配置、起止点、样本量、均值/最大）。
5. **整机综合/STA 与覆盖率报告**：按交付要求取证；拿不到许可或跑不动就如实写明，不拿历史空壳冒烟。
6. 每完成一项：跑对应 Questa、在 `sim/out/` 留命名 CSV/console + SHA-256，更新 `doc/当前进度`/`doc/后续计划` 如实登记。

## 强约束（可回滚 & 不破坏既有证据）
- 改任何 RTL/TB/向量/脚本前，先把原文件复制到 `out/arena-debug/backup/`；只做最小可逆修改。
- **Questa 运行纪律**：回归脚本会停同名仿真器进程；跑前确认没有其他仿真任务，**不要并行跑两份回归**；优先单跑针对性测试，收尾再跑一次全量确认 36/36 + 新增项不回归。
- 严禁读取/回显 `.env`、密钥/账号/密码、token 原文；不要碰 `competition_case/`。
- 不要 git commit / push；不要删除他人未提交的 doc 修改。
- 拿不到 Questa 许可或仿真跑不动时**如实写明原因**，不要伪造 PASS/证据。

## 交付物（写入本机工作区）
- 更新 `out/arena-debug/DIANSAI-REPORT.md`：本轮每项一节，含证据（文件:行号、命令、配置、CSV/console 摘要、SHA-256）、根因/改动、仿真结果、边界与遗留。
- 更新 `out/arena-debug/diansai.patch`（`git diff` 生成，可 `git apply -R` 回滚）。
最后在回复里给摘要：做了哪些、仿真结果、文件绝对路径、还剩哪些。
