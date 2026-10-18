# 仿真器启动问题及运行方式

2026-10-08 对当前环境重新做了对照检查：同一个 Questa 可执行文件、同一工作目录，在受限执行沙箱内启动返回 Win32 623；在沙箱外启动成功，并完成项目 RTL 编译和 5 项仿真。ModelSim 和 eLinx 自带 Verilator 的版本检查在沙箱外也成功。

当前项目使用原有 Questa 流程即可继续仿真。自动化宿主执行仿真时应使用允许启动仿真器的沙箱外执行通道（Codex 中为 `exec_command` 的 `sandbox_permissions="require_escalated"`）。这表示离开执行沙箱，不表示必须以 Windows 管理员身份运行。

也可在普通 Windows PowerShell 中从项目根目录执行：

```powershell
Set-Location C:\Workspace\diansai
& .\sim\run_regress.ps1 -Tests T00,T22g,T16u,T31g,T32g -OutDir out/simulator_recovery_new -VsimPath 'C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe'
```

`OutDir` 必须使用新的目录名。runner 继续读取现有许可证配置，并保存独立源码快照、版本、输入哈希、编译日志和每项仿真结果。

本次新证据位于 `sim/out/simulator_recovery_20261008_r1/`：

- `startup_probe_restricted.json`：受限环境启动失败，错误码 623。
- `startup_probe_host.json`：沙箱外启动检查结果。
- `run_metadata.json`：Questa 版本、当前源码哈希与编译/仿真状态。
- `regress.csv`：T00、T22g、T16u、T31g、T32g，5/5 PASS。

这些结果证明仿真入口已恢复，以及所选的 RTL 功能链路通过；这次没有运行完整 83 项回归，也没有运行实现后网表仿真。
