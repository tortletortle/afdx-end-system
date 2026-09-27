# Continue5 执行命令清单与重现指南

## 1. 变体与回归用例重现

```powershell
# 定向运行管理面及 GMII 变体用例 (6 项)
cd C:\Workspace\diansai\sim
powershell -ExecutionPolicy Bypass -File .\run_regress.ps1 -Tests T14,T15,T16,T14g,T15g,T16g

# 全量 56 项回归验证 (56 项)
powershell -ExecutionPolicy Bypass -File .\run_regress.ps1
```

## 2. 覆盖率采集与解析 (基于已完成的 53 项基线)

```powershell
# 1. 采集全量 UCDB (在编译时加入 +cover=sb 并保存单用例 ucdb)
cd C:\Workspace\diansai\sim
powershell -ExecutionPolicy Bypass -File .\run_regress.ps1 -Coverage

# 2. 合并 53 项 UCDB 数据库
vcover merge -out C:\Workspace\diansai\out\arena-debug\continue5\coverage_merged_completed53.ucdb C:\Workspace\diansai\out\arena-debug\continue5\ucdb\*.ucdb

# 3. 导出明细与汇总报告
vcover report -byfile -details -output C:\Workspace\diansai\out\arena-debug\continue5\raw\vcover_details_completed53.txt C:\Workspace\diansai\out\arena-debug\continue5\coverage_merged_completed53.ucdb
vcover report -summary -branch C:\Workspace\diansai\out\arena-debug\continue5\coverage_merged_completed53.ucdb > C:\Workspace\diansai\out\arena-debug\continue5\raw\vcover_summary_b_completed53.txt
vcover report -summary -statement C:\Workspace\diansai\out\arena-debug\continue5\coverage_merged_completed53.ucdb > C:\Workspace\diansai\out\arena-debug\continue5\raw\vcover_summary_s_completed53.txt

# 4. 解析生成 coverage_metrics.json
python C:\Workspace\diansai\out\arena-debug\continue5\raw\parse_coverage.py
```

## 3. 静态检查与门禁校验

```powershell
cd C:\Workspace\diansai

# Verilator 代码 Lint
powershell -ExecutionPolicy Bypass -File .\tools_lint.ps1

# 文档与数值同源对账门禁 (严格自查模式)
python tools\run_all.py --strict
```
