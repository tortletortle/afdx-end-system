# Continue7-finalize — QSF 修复与 post-map STA 验收

## 结论

已确认并使用正确器件配置：`FAMILY "Stratix IV"`、`DEVICE EP4SGX230HF35C2`。修复后 `quartus_map` 成功完成（0 errors，84 warnings，47:31），随后两次 TimeQuest 脚本均成功，`check_sdc_8ns` 守卫确认实际时钟约束为 `clk=8.000 ns`。

`tx_port_buf` 描述符四银行方案的 post-map 结果为 **45.84 MHz / WNS -13.815 ns / Endpoint TNS -700108.256 ns**。相对 continue6 的 **45.85 MHz / WNS -13.809 ns / Endpoint TNS -724179.500 ns**：Fmax 下降 0.01 MHz，WNS 恶化 0.006 ns，TNS 虽改善 24071.244 ns，但关键 Fmax/WNS 没有收益。因此按任务纪律判定为负收益，并依据 `timing_step1.patch` 反向回滚 `rtl/tx/tx_port_buf.v`。回滚后文件 SHA-256 与 `backup/step1/tx_port_buf.v` 完全一致。

本轮没有重跑已经完成的 56 项回归；沿用 `raw/step1_regress.log` 的 **56/56 PASS（473.8 s）** 功能证据。

## 执行结果

| 项目 | 结果 |
|---|---|
| 初始阻塞 | `Family name "Cyclone IV GX" is illegal` |
| 实际 map 器件族 | Stratix IV |
| 实际器件 | EP4SGX230HF35C2 |
| quartus_map | 成功，0 errors / 84 warnings，47:31 |
| SDC 守卫 | PASS，`clk=8.000 ns` |
| post-map Fmax | 45.84 MHz |
| post-map WNS | -13.815 ns |
| Endpoint TNS | -700108.256 ns |
| 最差路径 | `tx_port_buf:u_txbuf|s1_vld` → `tx_port_buf:u_txbuf|s1_desc[0]` |
| 最差路径数据延迟 | 21.292 ns |
| 与 continue6 的 Fmax 差值 | -0.01 MHz |
| 与 continue6 的 WNS 差值 | -0.006 ns |
| 决策 | 负收益，已回滚四银行方案 |

## 回滚核验

- 回滚后的 `rtl/tx/tx_port_buf.v` SHA-256：`349f7dde3b98587cb02cd63b393a3a434683ebc16f1211aaed63df8f64cbb9ff`
- `backup/step1/tx_port_buf.v` SHA-256：`349f7dde3b98587cb02cd63b393a3a434683ebc16f1211aaed63df8f64cbb9ff`
- 两者相同；四银行实验未进入最终 RTL。

## 约束与诚实边界

- 以上数字全部来自 **post-map** 网表，不包含布局布线延迟，不是最终时序签核。
- 设计仍有 71 个未约束输入端口和 121 个未约束输出端口；内部同钟 Fmax/WNS 可用于本轮相对比较，但整机 I/O 时序未闭合。
- 125 MHz 目标未达成。
- TNS 改善但 Fmax/WNS 轻微恶化；未选择性隐瞒指标，也未宣称收敛。
- 未重跑 56 项回归，未并行运行两份 Questa 或两份 `quartus_map`，未执行 `git commit/push/reset`。

## 证据索引

- 原器件族错误：`raw/step1_map.log`
- 修复后 map：`raw/step1_map_retry.log`、Quartus `output_files/AFDX_top.map.summary`
- 功能回归：`raw/step1_regress.log`、`raw/step1_regress.csv`
- STA：`raw/step1_sta.log`、`step1_sta/post_map_fmax.rpt`、`step1_sta/post_map_setup.rpt`
- SDC：`step1_sta/post_map_sdc.rpt`、`step1_sta/post_map_sdc_tns_guard.rpt`
- TNS/未约束项：`raw/step1_tns.log`、`step1_sta/post_map_setup_summary.rpt`、`step1_sta/post_map_unconstrained.rpt`
- 实验补丁与回滚基准：`timing_step1.patch`、`backup/step1/tx_port_buf.v`

