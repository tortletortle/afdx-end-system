# Continue3 任务

在 `C:\Workspace\diansai` 完成一个可验证的工程改进，优先围绕 `out/arena-debug/continue2/STA.md` 中已实测的 125 MHz 时序瓶颈，或覆盖率/综合证据缺口。先阅读 `DIANSAI-REPORT.md`、`REVIEW-REPORT.md`、`continue2/SYNTH.md`、`continue2/STA.md`，独立选择一个最小可逆目标。

要求：
- 改源码前备份到 `out/arena-debug/continue3/backup/`。
- 不读取或回显 `.env`、`*.local.*`、密钥/账号/密码/token；不碰 `competition_case/`、`data/`、`logs/`；不 git commit/push/reset。
- 必须实际运行相关 lint/仿真/综合/STA；工具或许可证失败要保留原始日志并如实写明。
- 所有产出写入 `out/arena-debug/continue3/`：`REPORT.md`、patch、原始日志、命令记录、SHA256SUMS.txt。
- 不把局部通过写成整机通过，不伪造 PASS。
