# Continue6 — P0 post-map 时序收敛报告

## 结论

本轮保留两项改动：补齐 Quartus 工程的 4 个管理面 RTL 源文件，以及对 `snmp_lite` 的两步结构优化。最终 56/56 全量回归通过，8.000 ns SDC 守卫通过，post-map Fmax 从可比较的 Step 1 **39.56 MHz** 提升到 **45.85 MHz**（+6.29 MHz，+15.9%），WNS 从 **-17.279 ns** 改善到 **-13.809 ns**（+3.470 ns）。尚未达到 125 MHz，不能宣称时序收敛。

## 基线与步骤对照

| 阶段 | 56 项回归 | clk 守卫 | Fmax | WNS | Endpoint TNS | 决策 |
|---|---:|---:|---:|---:|---:|---|
| 任务输入中的历史参考（continue4/5） | 历史值 | 8 ns | 42.15 MHz | 约 -15.72 ns | 未提供 | 仅参考；当时 QSF 未包含新增管理面模块，不能与完整设计严格横比 |
| 当前完整 RTL 基线 | 56/56，469.1 s | 未到 STA | N/A | N/A | N/A | QSF 缺少 `stats_regs/snmp_lite/a615a_tftp/rtc_sync`，补齐后未优化 `walk` 的 map 运行 30 分钟仍未完成，人工终止；保留失败日志 |
| Step 1：`walk()` 696 项比较链改为区间译码 | 56/56，567.3 s | 8.000 ns | 39.56 MHz | -17.279 ns | 未采集 | 保留；完整设计首次可在 25:31 完成 map，最差路径转移到 SNMP 响应写口 |
| Step 2：VarBind 编码字段打一拍 | 56/56，552.8 s | 8.000 ns | **45.85 MHz** | **-13.809 ns** | **-724179.500 ns** | 保留；Fmax/WNS 均单调改善，最差路径转移到 `tx_port_buf` |

## 改动说明

1. **工程闭合（非性能归因步骤）**：`AFDX_top.qsf` 补入四个已被顶层实例化但此前未列入 Quartus 的 RTL 文件。否则当前完整 RTL 无法综合。
2. **Step 1，仅处理 `snmp_lite.walk()`**：原实现把 696 个目录项逐项比较并形成优先链；目录实际由连续区间组成，改为等价区间译码。功能回归覆盖 GET/GETNEXT/SET、STATS_BLOCK、多 VarBind 与 GMII 变体。
3. **Step 2，仅处理 SNMP 响应编码写口**：在 `E_VBT` 先锁存当前 VarBind 的 tag/string/value/length，后续周期再写响应 RAM，切断 `err_st → 多级译码 → 256 路 rsp 写数据` 长组合路径。

## 最终最差路径与下一步

Step 2 的最差路径为 `tx_port_buf:u_txbuf|s1_vld → s1_desc[*]`，数据延迟 21.286 ns，WNS -13.809 ns。下一轮应只处理该路径（描述符存储/读端口流水或分银行），完成全量回归和 STA 后再决定保留或回滚。

## 诚实边界

- 所有数字均为 **post-map**，没有布局布线延迟，不是最终时序签核。
- SDC 报告确认 `create_clock clk 8.000 ns`；但设计仍有 71 个未约束输入端口和 121 个未约束输出端口。内部同钟 Fmax/WNS 有效，整机 I/O 时序并未闭合。
- Step 2 Endpoint TNS 很大，原因是报告按大量端点累计；应与 WNS、路径类型一起解读。Step 1 当时未运行 summary，之后网表已被 Step 2 覆盖，故不伪造其 TNS。
- 未并行运行两份 Questa；未执行 git commit/push/reset；未读取受限敏感文件或受限目录。

## 证据索引

- 回归：`raw/baseline_regress.log`、`raw/step1_regress.log`、`raw/step2_regress.log`、`raw/step2_regress.csv`
- map/STA：`raw/*_map.log`、`raw/*_sta.log`、`step1_sta/`、`step2_sta/`
- SDC 守卫：`step1_sta/post_map_sdc.rpt`、`step2_sta/post_map_sdc.rpt`
- 补丁：`timing_step1.patch`、`timing_step2.patch`、`fixes.patch`

