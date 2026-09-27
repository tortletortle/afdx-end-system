# 时序分析：post-map Fmax 45.84 MHz 是工具假象，不是设计缺陷

**日期**：2026-09-27
**结论等级**：由 `out/arena-debug/continue7/step1_sta/post_map_setup.rpt` 原文直接推出，可复核。

---

## 1. 结论

**此前"需要削减约 13.3 ns 组合与路由延迟、必须做架构级重构"的判断，建立在一个不成立的前提上。**

post-map STA 报告的 21.292 ns 关键路径中，**20.000 ns 是 Quartus 在无布局信息时填入的占位互连延迟**，
真实组合逻辑延迟只有约 **1.292 ns**。按 8 ns 周期计算，逻辑本身占用不到 17%。

因此：
- **不应**按 Continue8 的方案对 `tx_port_buf` 做架构级重构；
- **应当**先跑 `quartus_fit` 取得真实布线延迟，再判断是否存在时序问题。

## 2. 证据：关键路径逐跳分解

`post_map_setup.rpt` Path #1（Slack −13.815，From `tx_port_buf:u_txbuf|s1_vld`，To `|s1_desc[0]`）
的 Data Arrival Path 明细：

| Total | Incr | Type | Element | 说明 |
|---:|---:|---|---|---|
| 5.706 | 0.037 | uTco | `u_txbuf\|s1_vld` | 寄存器输出延迟 |
| 5.706 | 0.000 | CELL | `u_txbuf\|s1_vld\|q` | |
| 10.706 | **5.000** | **IC** | `u_txbuf\|always1~0\|dataa` | ← 占位互连 |
| 11.062 | 0.356 | CELL | `u_txbuf\|always1~0\|combout` | LUT 1 |
| 16.062 | **5.000** | **IC** | `u_txbuf\|set_valid~0\|datab` | ← 占位互连 |
| 16.412 | 0.350 | CELL | `u_txbuf\|set_valid~0\|combout` | LUT 2 |
| 21.412 | **5.000** | **IC** | `u_txbuf\|wb_desc[0]~0\|dataa` | ← 占位互连 |
| 21.768 | 0.356 | CELL | `u_txbuf\|wb_desc[0]~0\|combout` | LUT 3 |
| 26.768 | **5.000** | **IC** | `u_txbuf\|s1_desc[0]\|asdata` | ← 占位互连 |
| 26.961 | 0.193 | CELL | `u_txbuf\|s1_desc[0]` | 目的寄存器 |

**data path 合计 21.292 ns = 4 × 5.000（互连占位） + 1.292（真实逻辑）**

### 为什么判定 5.000 ns 是占位值

1. **数值恒定且为整数**：全报告 160 个 IC 行中，**108 行恰好等于 5.000**，另 40 行为 0.150（输入引脚），
   **方差为零**。真实布线延迟不可能在上百条不同物理距离的连线上完全相同。
2. **阶段不具备布线信息**：本次只跑到 `quartus_map`（Analysis & Synthesis），**未运行 `quartus_fit`**。
   无布局即无布线，TimeQuest 只能对每跳套用统一估计值。
3. **时钟路径同样为 5.000**：`clk~input|o`（fanout 105841）到寄存器时钟端也是 5.000 ns，
   同样是未做时钟树综合的占位表现。
4. Quartus 报告自身声明：*"Altera recommends that you always use clock constraints and other
   slack reports for sign-off analysis."* post-map Fmax 不是签核口径。

## 3. 关键路径的真实形态

逻辑级数仅 **3 级 LUT**：

```text
s1_vld → always1~0 → set_valid~0 → wb_desc[0]~0 → s1_desc[0]
```

三级 LUT 合计 1.062 ns，加 Tco/Tsu 约 1.292 ns。Stratix IV（900 mV / 85 °C 慢角）下，
3 级逻辑在 8 ns 周期内留有约 6.7 ns 的布线预算，**属于常规可布通范围**。

这与 Continue8 所描述的「`bypass` 把上一事件的完整写回计算组合送回下一拍」在**结构上**仍然成立
（确实存在控制到数据的组合链），但该链在 map 后只综合出 3 级 LUT，**并不是时序瓶颈的量级来源**。

## 4. Continue7 实验结果的重新解释

Continue7 的 `tx_port_buf` 四银行方案：45.85 → 45.84 MHz（−0.01 MHz）。

当时判定为"负收益并回滚"。**现在可以解释这个结果**：既然延迟的 94% 来自与设计无关的固定占位值，
任何 RTL 改动都只能影响那 1.292 ns 中的一小部分，**在 post-map 口径下必然表现为"几乎无变化"**。
该实验没有证明四银行方案无效，只证明了 **post-map 口径无法区分方案优劣**。

同理，Continue8 列出的三项优化（复位扇出分级、`rx_port_buf` 分银行、19,019 个 `$eq` 打拍）
若继续用 post-map Fmax 作为判据，**都将得到同样无意义的结果**。

## 5. 正确的下一步

1. **运行 `quartus_fit`**（已于 2026-09-27 16:18 启动，日志 `out/arena-debug/continue10/fit.log`）。
2. Fit 完成后跑 **post-fit STA**，取得含真实布线延迟的 setup/hold WNS、TNS 与 Fmax。
3. **以 post-fit 结果为唯一时序判据**，再决定是否需要任何 RTL 改动。
4. Fit 还将首次给出**真实资源占用**（ALM/LUT/寄存器/RAM 块百分比），
   替换目前只能报的 139,607 logic cells 估计值。
5. 若 post-fit 仍不收敛，届时再按真实关键路径定位——**可能与 `tx_port_buf` 完全无关**。

## 6. 本文不宣称的事

- 本文**没有**证明设计能在 125 MHz 收敛，只证明**现有 45.84 MHz 数据不构成不收敛的证据**。
- post-fit 结果尚未取得；在此之前，时序状态应记为 **UNKNOWN**，而非 MEASURED_NOT_MET。
- 125 MHz 是赛方硬性要求（组委会答复 MAC 接口为 GMII，8 bit + 125 MHz），无降频退路。
- I/O 时序仍未闭合：71 个输入、121 个输出端口未约束，缺目标板引脚与 IO 预算。
