# eLinx 一键仿真步骤（评委入口）

> 权威源清单：`elinx/AFDX_top_sources.f` ↔ `elinx/gui_afdx/AFDX_top.epr` DesignSrcs（48 文件，无 `sync_fifo`/`host_if`）。  
> 仿真顶：`tb_gate_public_loopback`（T88b，新增系统场，非原矩阵）。  
> 机制说明：`out/p3_elinx_20261021_191614/MECHANISM.md`。

## A. GUI 点击路径（人工）

1. 打开 eLinx → `File` → `Open Project` → `elinx/gui_afdx/AFDX_top.epr`。
2. 确认 Design Sources 与 `AFDX_top_sources.f` 一致（差异表见 `out/p3_elinx_*/EPR_DIFF.md`）。
3. Simulation Sources：目标为 `sim/tb/tb_gate_public_loopback.v`，Simulation Top = `tb_gate_public_loopback`。
4. `Tools` / `Settings` → **3rd Party Simulators**：设 `ModelSimInstallPath` 为本机 `vsim.exe` 所在目录（**不要**依赖仓库内写死的 `intelFPGA` 路径）。
5. `Flow` → `Run Simulation` → **Run Behavioral Simulation**。  
   eLinx 会重写 `AFDX_top.sim/sim_1/behav/{AFDX_top.do,run_sim.bat}` 并调用 ModelSim。
6. 控制台应出现 `T88b GATE PUBLIC LOOPBACK PASS`，且编译 `Errors: 0`。

### 截图占位清单（人工补）

| # | 内容 | 文件名建议 |
|---|---|---|
| 1 | 工程已打开，Sources 树可见 48 个 RTL | `shots/elinx_sources.png` |
| 2 | Settings 中 ModelSim 路径 | `shots/elinx_modelsim_path.png` |
| 3 | Run Behavioral Simulation 菜单 | `shots/elinx_run_behav.png` |
| 4 | 仿真控制台 PASS 行 | `shots/elinx_pass.png` |

## B. 命令行等价（可复现）

```powershell
# 仿真器路径参数化，禁止写死本机绝对路径进脚本正文
$env:ELINX_VSIM = '<path-to>\vsim.exe'   # 或 -VsimPath
powershell -NoProfile -ExecutionPolicy Bypass -File sim/run_elinx_behav.ps1 `
  -OutDir out/p3_elinx_<ts>/behav `
  -TbModule tb_gate_public_loopback `
  -VsimPath $env:ELINX_VSIM
```

- 脚本从 `AFDX_top_sources.f` **生成** `OutDir/AFDX_top_behav.do`（与 epr 同源），再跑 vsim。  
- **不是**手改 `gui_afdx/.../AFDX_top.do` 冒充对齐。  
- GUI 仍应用一次「Run Behavioral Simulation」刷新检入的 `.sim` 产物；命令行日志作为可复现旁证。

## C. 验收句式

- **P（命令行）**：在由 `AFDX_top_sources.f` 生成的 behav 脚本上，当前 48 源满配编译 0 error，T88b S1+S2 PASS（日志指 `out/p3_elinx_*/behav/`）。  
- **I（GUI）**：GUI 点击路径已写明；截图待人工。  
- **禁止写出**：门级全量；SDF；eLinx 原生网表 PASS；手改陈旧 `.do` 已代表 eLinx 工程。
