<!-- rendered from AFDX端系统_设计文档.md using C:/Workspace/diansai/out/p8_freeze_225cd91/metrics.json commit=225cd91be4f6a4b332db1674b44761bca367bd67 -->

# AFDX 端系统设计文档（提交版）

> 数字一律双花括号 metric 锚点（见 `metrics.json` 的 key），定稿填充。正文不写开发编年史。  
> 冻结：`225cd91be4f6a4b332db1674b44761bca367bd67` · 全量 `144`/`144`。

## 1. 赛题与范围

实现 AFDX（ARINC 664 Part 7）端系统（ES）五类功能：发送调度与流量整形、接收过滤与完整性/冗余管理、主机接口与存储、管理面（SNMP/615A/TFTP）、时间同步（RTC/PPS）。协议子集以赛题与答疑为准；本实现默认 GMII 公开端口（`IF_MODE=2` 指标场另述），仿真时钟对齐 GMII 线速拍。

不宣称完整认证、交换机、对端真 ES 闭环。

## 2. 总体架构

数据流见 `figs/fig1_dataflow`（由 `doc/figs/fig1_dataflow.mmd` 渲染）。顶层模块 `AFDX_top`：TX 链（端口缓冲 → VL 调度/BAG → 帧构建/SN → 双网复制 → MAC）、RX 链（MAC/前导剥离 → 查表 → 过滤 → IC → RM → 重组/解析 → 端口交付）、主机总线与管理 SAP、块池/PMEM。

## 3. 接口

- **GMII**：8-bit 数据 + valid；双网 A/B；ready 语义按赛方答疑（TX ready 可忽略场景有 TB 覆盖）。
- **主机总线**：`host_cs/we/addr/wdata/rdata/ack/irq`；配置表、PMEM、消息队列寄存器映射见附录（`regs.yaml` 生成）。
- **PPS**：`pps_in` / `pps_out`；RTC 微秒计数可读。

## 4. TX 通路

端口消息经 `tx_port_buf` / `tx_message_store` 进入调度；`tx_vl_scheduler` 按 BAG 与份额整形；`tx_frame_builder` 组以太网/IP/UDP/AFDX SN；`tx_rm` 双网复制；`mac_tx_if` 附加前导/FCS/IFG。BAG 错相避免同相突发。

## 5. RX 通路

`mac_rx_if` / `gmii_rx_strip` → `rx_vl_lookup` → `rx_flt` → `rx_ic`（SN 完整性）→ `rx_rm`（SkewMax 去重）→ 重组与 UDP/IP 解析 → `rx_port_buf` 交付主机。判断链顺序固定：过滤 → IC → RM（见工程笔记口径）。

## 6. 存储与块所有权

块池与 PMEM 预算见图 2（`figs/fig2_block_owner`）。RX 块所有权在过滤拒绝、IC 拒绝、RM 重复、交付完成等路径上释放；主机与 RX 写端口仲裁，避免同拍冲突。

## 7. 管理面

- **SNMP**：`snmp_lite`（v1；community/长度策略见模块头注释）。
- **ARINC 615A / TFTP**：加载/卸载状态机与数据报路径见图 3（`figs/fig3_tftp_615a`）。
- **RTC**：PPS 驯服 FLL；漂移与扰动有专用 TB。

当前 RTL **支持** IP 分片重组与 615A 路径（参数/TB 覆盖范围以测试报告为准）；不以过期设计书「未实现」句为准。

## 8. 关键算法

- BAG：每 VL 令牌/年龄与错相偏移。
- 查表：可配置种子哈希，双表多路。
- RM：窗口与 SkewMax；双网先后到达去重。
- 时延界：工程总时延与规范 BAG+抖动+技术时延分列；指标数字见测试报告。

## 9. 时钟复位与参数

系统时钟与 GMII 线速拍一致（仿真）。异步复位经 `rst_sync`。可配置：`NUM_TX_VL` / `NUM_RX_VL`、BAG、Lmax、份额、SkewMax、IC first-any 等，经主机表加载；init_sweep 清表。

## 10. 综合与实现结果

| 项 | 值 | 等级 |
|---|---|---|
| cells | 106241 | P（若 FREEZE 有） |
| altsyncram | 507 | P |
| post-fit Fmax (MHz) | 41.66 | I |
| Setup (ns) | -16.005 | I |

代理器件；非板卡签核。门级 VO sha256：`2801113d07f7f72cf8d9d3a6c737fc0d1fea3669effa1a53551058c85165fb46`。

## 11. 设计取舍与已知边界

| 取舍/边界 | 说明 |
|---|---|
| 预言机与 RTL 同队编写 | 靠变异、独立 Python/golden、双仿真器抬可信度 |
| 满配 VL 吞吐 | 未测 |
| Fmax 相对线速拍 | 未闭合（I） |
| 管理面 SNMP | v1 子集 |
| 评委 TB | 自建矩阵，非官方 A664 套件 |

## 12. 附录

- 寄存器：由 `doc/regs.yaml` 生成（提交包内附）。
- VL 表项格式：见主机接口与 `rx_vl_lookup` / TX 表字定义。
