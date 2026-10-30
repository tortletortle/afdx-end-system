入口是 `doc/submit/00_先读.md`。

现行锚点：150/150 Questa FSE + ModelSim SE 逐项一致 @ `51f117d`；提交包 commit 见 `doc/submit/00_先读.md`。

旧长文在 `doc/历史/README_长文_20261030.md` 与 `doc/历史/README_未提交_20261030.md`，标明历史，不作为现行数字。

## 怎么跑（从 `doc/submit/00_先读.md` 摘）

```powershell
powershell -File sim/run_smoke.ps1                          # 含 T92，一次全绿，约 14 分钟
powershell -File sim/run_regress.ps1 -Tests T92,T93,T94,T95 # 封装四项，约 5 至 7 分钟
```

1. 安装/确认：Questa 或 ModelSim SE；路径不要写死进脚本正文（用参数 / 环境变量）。
2. 冒烟：`powershell -File sim/run_smoke.ps1`（含 T92、T88；一次全绿）
3. 全量：`sim/run_regress.ps1` → `python sim/freeze_regress.py --require-full`
4. 门级：核心 T88b（Quartus 功能 VO + ModelSim SE）S1–S3（见测试报告 §6）
5. eLinx 综合：核心 `python tools/run_baseline_full140_synth.py`；封装 `python tools/run_afdx_app_top_synth.py --out out/app_top_synth_<tag>`。eLinx 综合器是 32 位进程（地址空间约 2 GB），运行前关闭无关程序，一次只开一个综合实例
6. eLinx GUI 行为仿真（人工）：打开 `elinx/gui_afdx/AFDX_top.epr` → Settings 指向 ModelSim → Simulation Top=`tb_gate_public_loopback` → Run Behavioral Simulation。步骤见 `doc/eLinx_一键仿真步骤.md`。
