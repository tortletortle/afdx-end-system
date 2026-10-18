# sim/ — RTL 仿真入口

当前 `sim/tests.manifest` 为 140 项；当前同版完整运行入口是 `sim/out/production_repairs_full140_20261013_r1`，已记录 140/140 PASS、编译 rc=0，六项独立审计和前端五 stage 也有同版证据。T34p/T35p 是独立公开规模 RTL 动态证据，不能与 140 项拼成 142 项，也不能替代综合、网表编译/加载或综合后业务。历史 137 项和更早 manifest 按各自冻结版本引用。

当前入口为 `sim/run_regress.ps1`。每次运行会创建独立源码快照、编译库和日志目录，拒绝覆盖非空目录；超时只停止本次启动的进程树。需要本机可启动的 Questa 与有效授权，启动限制见 [SIMULATOR_STARTUP.md](SIMULATOR_STARTUP.md)。

从项目根目录运行：

```powershell
# 定向检查；输出目录必须是新的
powershell -ExecutionPolicy Bypass -File .\sim\run_regress.ps1 -Tests T08a,T08b,T09s,T41 -OutDir out/my_unique_check

# 不传 -Tests 时执行当前 tests.manifest 的全部条目
powershell -ExecutionPolicy Bypass -File .\sim\run_regress.ps1 -OutDir out/my_unique_full
```

`bind_scope.tsv` 记录每项测试包含的检查器目标模块；`bind_scope_profiles.tsv` 对应三个 named binder module。运行前 `check_bind_scope.py` 核对全部测试的模块依赖与映射，缺失或过期就停止。每个测试只加载适用的 binder；`none` 表示测试中没有这些目标模块，其业务 scoreboard 照常运行。

修改测试或实例关系后，先在独立候选中生成、审查范围映射，再更新正式文件。不要为了通过检查而随意把测试改成 `none`。`sim/chk/afdx_bind.sv` 是保留的旧全局绑定文件，当前入口不编译它。

结果看独立运行目录中的 `regress.csv`、`run_metadata.json`、`compile_console.txt` 与各测试原始日志。A2/A6/A7/A8/A9/A10/A11 的 `[chk]` 错误也会使严格判据失败。当前 A9 仅检查同一 VL 相邻同 SN 转发在时间戳窗口内的重复情况，不能替代完整 RM golden model。A6 已接入 `free_reasm`，并移除同拍分配对陈旧释放的屏蔽；实际 pool/named binder 正负控与 47 项保护回归通过后合入，记录见 `out/a6_checker_integration_20261012_r1/integration.json`。A6 检查重复分配、同块多次归还和归还空闲块，仍不能替代完整块所有权守恒证明。

当前完成范围见 [项目应用追踪第0节](../doc/AFDX项目应用追踪.md)。RTL 回归通过只证明该快照和这些用例；不等于完整赛题、8 KiB 生产链路或综合后业务已经完成。历史 `out/`、`work/`、波形与编译库不属于源码。
