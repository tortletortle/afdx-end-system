# sim/ — RTL 仿真入口

返回 [根目录导览](../目录导览_20261001.md) · [工具说明](../README_tools.md)。`tb/`、`bfm/`、`chk/`、`vec/`、`tests.manifest` 是测试及向量源；`out/` 为不同日期的运行证据，不能把旧结果拼接成新一次全量；`work/`、`work_iso/` 是仿真编译库，不当作 RTL 源文件。

**安全复现当前版：**先按 `README.md` 与 `README_tools.md` 查看隔离运行入口、源版本和输出 tag。旧 `sim/run_regress.ps1` 可能按进程名停止所有仿真器并覆盖固定 `sim/out/`：不要在有其他 Questa 工作时把它当默认命令。RTL PASS 不等于综合网表整帧、post-fit STA 或比赛全部指标 PASS。
