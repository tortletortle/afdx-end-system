# 覆盖率 —— continue2（2026-09-25）：在**改造后**的 RTL 上重新生成

## 1. 为什么必须重跑（而不是引用旧数字）

旧 50 UCDB 在 `out/arena-debug/continue/session_20260925_0432/coverage/`，
是在 `rx_cfg_mem` 还是"组合读大数组"的 RTL 上采集的。本轮 RTL 发生了结构性变化
（6 个 `bram_1w1r` 副本 + PMEM lane 拆分 + `host_rdata` 选择器修复），
旧 UCDB 的实例数与分母已经失效。**引用旧数字会构成失真**，因此本轮重跑。

## 2. 本轮结果（全部 rc=0）

| 项目 | 值 |
|---|---|
| 覆盖率回归 | `out/arena-debug/continue2/coverage/run_full_cov.ps1`，**rc=0**，378 s |
| 用例 | `regress.csv` 50 行，**PASS=50 / FAIL=0** |
| UCDB | **50 个**（每用例一个，`coverage save -onexit`） |
| 合并 | `vcover merge -out full50.ucdb <50 个>` → **rc=0** |
| 报告 | `vcover report -summary full50.ucdb` → **rc=0**，`Errors: 0, Warnings: 0` |

```
Coverage Report Totals BY INSTANCES: Number of Instances 1440
    Branches      58849 bins  36788 hits  22061 misses   62.51%
    Statements    89642 bins  65555 hits  24087 misses   73.12%
Total coverage (filtered view): 67.82%
```

对照上一轮（旧 RTL）：1083 instances / 62.14% / 73.62% / 67.88%。
实例数从 1083 升到 1440，主要来自新增的 6 个 `bram_1w1r` 与 4 个 PMEM lane 实例。

## 3. 边界（必须随数字一起引用）

- **含 TB 实例**：1440 个 instance 里包含 testbench 层次，**不是 RTL-only 覆盖率**。
  分子分母都被 TB 稀释，**不得**与任何 RTL-only 指标或旧四例数字直接比较。
- 只有 **分支（branch）+ 语句（statement）** 两种代码覆盖率。
  **没有**条件/表达式/FSM/toggle 覆盖，**没有**功能覆盖率（无 covergroup/covpoint），
  因此 **67.82% 不是"功能覆盖率"，也不是任何认证指标**。
- 未做覆盖率排除（exclusion）文件，未做 DO-254/ARINC 664P7 结构覆盖分析。
- 原始件：`coverage/full50.ucdb`、`coverage/*.ucdb`（50）、`coverage/vcover_merge.log`、
  `coverage/vcover_rc.txt`、`coverage/merged_summary.txt`、`coverage/regress.csv`、
  `coverage/run_full_cov_console.log`。
