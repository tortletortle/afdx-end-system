# rtl/ — 当前工程 Verilog 源码

返回[工程目录导览](../目录导览_20261001.md) · [总体设计书](../AFDX端系统_总体设计书.md)。本目录为生产 RTL：`top/` 顶层，`tx/` 发送链路，`rx/` 接收链路，`mgmt/` SNMP/615A/RTC 等管理功能，`common/` 公共模块。

当前生产 RTL 已绑定到同版 140 项回归及六项独立审计；`sim/out/production_repairs_full140_20261013_r1` 是证据入口。RTL 动态通过不等于综合、网表编译/加载或综合后业务通过；当前 KeepHierarchy 综合仍失败。重跑时先核对 `sim/tests.manifest`、输入快照和证据目录，不要覆盖既有日志。具体方法见[工具说明](../README_tools.md)与[项目收口主控](../doc/项目收口主控_20261013.md)。
