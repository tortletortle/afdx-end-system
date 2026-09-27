# 管理面核查与正式验收边界（2026-09-25）

状态：**OUT_OF_SCOPE_FINALIZE / OPEN_SPEC_GAP**。这是本次收口交付的范围声明，不是总体设计书需求豁免，不表示整机完成。

| 模块 | 实际代码 | 设计书要求 | 结论 |
|---|---|---|---|
| snmp_lite | rtl/mgmt/snmp_lite.v，9 行、无端口空壳、未例化 | §7.16 BER / GET / GETNEXT / SET / MIB / 响应注入；T14 | 未实现、未验收 |
| a615a_tftp | rtl/mgmt/a615a_tftp.v，同上 | §7.17 RRQ/WRQ/DATA/ACK/ERROR、重传/重复包/块号回绕、615A 加载 CRC；T15 | 未实现、未验收 |
| rtc_sync | rtl/mgmt/rtc_sync.v，同上 | §7.15 时间戳同步、跳变/平滑/频率调整/SYNC_LOSS、≤1µs；T16 | 未实现、未验收 |
| stats_regs | **rtl/top/stats_regs.v 确实存在**，9 行空壳、未例化 | §7.18 满配 per-VL 统计 RAM、事件 FIFO、原因分类计数 | 未实现完整统计面；纠正旧报告“缺失” |

证据：management_audit.json（扫描 rtl/*.v 的非注释引用，仅模块声明）；spec_excerpts.txt；sim/tests.manifest 不含 T14/T15/T16。顶层已有局部统计寄存器和 mgmt_sap_rx，不等于以上完整模块已实现。

后续验收不可只修改文档：须正式定稿协议/寄存器接口，实现请求→状态/数据更新→响应的端到端闭环，新增 T14/T15/T16 独立 TB 与负例、超时/重传/重复/回绕/失步测试，纳入 manifest 和覆盖率；或取得正式书面需求豁免。当前没有豁免，整机要求仍开放。
