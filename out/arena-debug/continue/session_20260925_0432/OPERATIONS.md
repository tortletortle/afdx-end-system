# 执行与备份说明

- HTTP MCP initialize 成功；read_files 的工作区为 C:/Workspace/diansai，但 run_command 默认 cwd 回报为桥接服务自身目录。因此所有后续执行均显式 Set-Location C:/Workspace/diansai；未依赖误报的默认目录。
- 修改/生成会覆盖的 RTL、sim、elinx/prj、elinx/sdc、doc、报告、旧补丁、旧 finalize 已先备份到 out/arena-debug/backup/continue_20250925/session_20260925_0432/。该父目录按 MISSION 指定保留 20250925 拼写；本次实际日期是 2026-09-25。
- 首次备份的文件复制成功，但哈希流水线把正在写入的 SHA256.csv 也枚举进去，Get-FileHash 报文件占用，命令 cmd_1790310701203_3 rc=1。未删除该部分清单；修正为先收集文件再写新 SHA256-complete.csv，cmd_1790310711790_4 rc=0。该辅助失败不计作设计验证结果。
- 新覆盖率 runner 在执行前发现自动替换造成 Tcl 路径重复，先备份 run_full_cov_before_pathfix.ps1 后修正；未使用坏路径跑测试。原 sim/run_regress.ps1、原 RTL/TB 未修改。
- prior_synth_full_log_audit.json 等核查输出第二次生成前另存 audit_before_escape_fix/；旧 finalize/synth 原件从未覆盖。
- execute.py 对每个验证子进程保存完整 argv/cwd/真实 rc/耗时/原始合并输出日志/SHA-256，且拒绝覆盖同名日志。返回非零的综合/STA 是预期要保留的失败，不用外层 Python rc=0 代替它们。
- Questa 全量覆盖率编译/50 项各自进程/merge/report 依序执行；最终普通 50 项回归等待 coverage_report_rc.txt 后才启动，随后依序 lint 和文档门。覆盖率数据与最终普通回归分目录，旧证据保留。
- 没有 git commit/push/reset；没有读取或修改 competition_case、.env、密钥/token 文件。沿用现有回归脚本的工具授权环境，不输出授权值。
- 文档旧正文含历史工具包装/编码损坏；本轮只在文件前添加明确的最新状态与后续验收条件，保留旧字节和历史，不把旧报告整份重造。
