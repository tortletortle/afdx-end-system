# 管理面范围裁定 —— continue2（2026-09-25）

## 1. 客观现状（本轮实测，非转述）

| 文件 | 行数 | 内容 | 在 `AFDX_top.v` 中被例化？ |
|---|---:|---|---|
| `rtl/mgmt/snmp_lite.v` | 7 | `module snmp_lite; // TODO endmodule`，**无端口** | **否**（grep 命中 0） |
| `rtl/mgmt/a615a_tftp.v` | 6 | 同上，仅壳 | **否** |
| `rtl/mgmt/rtc_sync.v` | 6 | 同上，仅壳 | **否** |
| `rtl/top/stats_regs.v` | 7 | 同上，仅壳（文件**存在**，旧报告"缺失"的说法此前已纠正） | **否** |

`sim/tests.manifest`（50 项）中 **T14 / T15 / T16 各 0 条**。
`AFDX_top.v` 里对 `snmp_lite|a615a_tftp|rtc_sync|stats_regs` 的引用数为 **0**。

## 2. 与设计书的关系

- 《AFDX端系统_总体设计书》§7.16（SNMP 精简代理）、§9（统计寄存器页 0x0100~0x01FF）、
  ARINC 615A TFTP、RTC 同步都**仍是设计书要求项**，四个文件自己的注释也写明
  "第 0 周骨架 —— 仅模块壳，未例化（§13 第 4/5 周展开）"。
- 本轮**没有**收到书面的需求豁免/范围裁剪文件。

## 3. 裁定：`OPEN_SPEC_GAP`（不是 DONE，也不是 OUT_OF_SCOPE）

**不能标 DONE**：四个模块是无端口空壳，未例化、无 TB、无 manifest 用例，
顶层地址页 0x0100~0x01FF 的统计语义由 `AFDX_top` 内的少量计数器临时承担，不等于 §9 的统计页。

**不能标 OUT_OF_SCOPE**：没有任何书面豁免；设计书要求仍然有效。

因此本轮的正式状态是 **`OPEN_SPEC_GAP`：整机目标未完成，缺口已登记、未关闭**。
本轮**不**把它计入交付，也**不**用 50/50 功能回归或覆盖率去冲抵它。

## 4. 为什么本轮没有实现它们（诚实说明，不是借口）

本轮优先级由 `MISSION-CONTINUE2.md` 指定为：目标 1 顶层综合 > 目标 2 STA > 目标 3 覆盖率/管理面。
目标 1、2 都从 BLOCKED 推进到了有实测结论（综合 rc=0；STA 拿到 Fmax 42.56 MHz 的反证），
并且**发现并修复了一个会让整机主机接口读全 0 的真实回归缺陷**。
在 125 MHz 时序已证明不收敛的前提下，先补 T14–T16 协议只会增加不收敛的逻辑量，
工程上应先做时序收敛与架构分银行，再展开管理协议。该判断已写入 `doc/后续计划.md`。

## 5. 关闭该缺口的最小可验收定义（给下一轮）

1. `stats_regs`：按 §9 定义端口，接 `AFDX_top` 0x0100~0x01FF 页，TB `T14` 校验
   帧/字节/丢弃计数与直方图分桶，含复位清零与读清语义。
2. `snmp_lite`：GET/GETNEXT/SET + STATS_BLOCK 只读组，走 `mgmt_sap_rx` 的 SAP 描述符通路，
   TB `T15` 用真实 SAP 帧驱动，校验 PDU 编解码与错误码。
3. `a615a_tftp` + `rtc_sync`：TFTP RRQ/WRQ/DATA/ACK 状态机与 PPS 对时，TB `T16`。
4. 三条用例进 `sim/tests.manifest`（50 → 53），全量回归与 lint/docgate 同时通过。
