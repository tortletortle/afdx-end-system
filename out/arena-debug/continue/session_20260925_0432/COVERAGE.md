# 全 manifest 代码覆盖率（2026-09-25）

**DONE：50/50 插桩功能测试 PASS，50 个非空 UCDB，vcover merge/report 均 rc=0。** 不是只运行旧四例，不新增或减少 manifest 测试，也不使用历史 CSV 代替本轮结果。

- 编译：compile_full_cov.tcl 使用 `vlog -sv +cover=sb +notimingcheck`，所有当前 RTL 和 manifest 对应 TB；编译 rc=0、Errors=0。
- 执行：run_full_cov.ps1 是当前 sim/run_regress.ps1 的独立副本，保留相同源清单、TB 映射、golden 生成、600s 每例超时和 verdict 检查；run_full_cov.tcl 使用 `vsim -coverage`，在 run -all 前注册 `coverage save -onexit`。
- 每项独立 vsim，严格串行。覆盖率 runner 总 rc=0、wall_s=389.22。50 份 console、CSV 和 UCDB 均在 coverage/。精确命令与子进程 rc 见 commands.jsonl。
- 合并明确列举 T00..T23g 等全部 50 个实际 ID（不是编号连续的 50 个）；没有把 full50.ucdb 再作为输入。merge rc=0、Errors=0/Warnings=0；report rc=0。

## 工具原始统计

coverage/merged_summary.txt：**BY INSTANCES，1083 instances，包含 TB**。

| 类型 | bins | hits | misses | 百分比 |
|---|---:|---:|---:|---:|
| Branches | 57608 | 35798 | 21810 | 62.14% |
| Statements | 86985 | 64040 | 22945 | 73.62% |

工具 filtered-view total=67.88%。这是工具按覆盖类型权重给出的数，不是把上述命中数直接相除的总命中率。

**范围限制**：仅 statement+branch 代码覆盖率；不是 RTL-only、去重后的设计单元覆盖率、functional covergroups、condition/expression/toggle/FSM 覆盖率或适航认证。扩展测试也扩展了实例分母，因此不能把 67.88% 与旧四例 71.72% 直接比较成质量退步/提升。未配置人为排除来抬高百分比。T14/T15/T16 不在当前 manifest，未交付管理协议不会因这 50 项通过而变成完成。

正常最终回归会重新编译未插桩 work 库，但不覆盖本目录 UCDB。复跑应先给本次目录做备份或使用新的 session 路径；execute.py 拒绝覆盖已有顶层日志。coverage_db_inventory.json 与最终 SHA256SUMS.txt 绑定数据库字节；acceptance_audit.json 核对 CSV、manifest 顺序、ID 集合和原始日志失败行。
