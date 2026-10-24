# formal 环境状态（2026-10-24 夜更新）

> 等级说明：BAG 形式结论本轮标 **F**（不宣称）。pool/RM 有界 BMC 仍为 **I**。

## 块 1：oss-cad-suite

| 项 | 值 |
|---|---|
| 安装路径 | `C:\Tools\oss-cad-suite`（仓库外） |
| yosys | `0.70+157` |
| sby | `v0.70-9-g79fc9ed` |
| 求解器 | boolector 等 |
| Windows | 未 BLOCKED；`.sby` 注释用 ASCII |

## 块 2：BAG 有界 BMC（C4）

| 项 | 值 |
|---|---|
| wrapper | `bag_formal_top` in `tx_vl_scheduler_bag.sv`（无 bind；只读 RTL） |
| 参数 | `NUM_TX_VL=4`，`CYCLES_PER_US=1`，`BAG_US=4` |
| cover | PASS；**第二次 grant/pop 最早 ~step 26–27** |
| bmc20 | PASS — **vacuous（空真）**：depth 20 < 第二次事件 step，断言未武装。**不得作为 BAG 证据引用** |
| bmc40 | FAIL（step ~27）；见 `bag_bmc40_CE_ANALYSIS.md` |
| 归因 | 主因 **(a) wrapper**（ghost/采样）；**(b)** `next_tx`/`bag_arr` 不复位已记录；**(c) 未排除（VCD 未能解码 start_vld/next_tx）** |
| 宣称等级 | **F** — cover 可达；bmc20 空真；bmc40 反例未收成 PASS；**不宣称任何 BAG 形式结论** |
| 证据 | `formal/bag_cover/`、`bag_bmc20/`、`bag_bmc40/`、`bag_bmc40_CE_ANALYSIS.md`、`bag_bmc20_FAIL_NOTE.md` |

## 块 2b：rx_block_pool（历史）

有界 depth 40 PASS — **I**（见既有 `pool_bmc/`）。

## 块 2c：rx_rm（历史）

bmc20/bmc40 PASS — **I**（见既有 `rm_bmc20/` / `rm_bmc40/`）。

## 注意

- 勿把 bmc20 vacuous PASS 写进报告当 BAG 证明。
- 未改 `rtl/tx/tx_vl_scheduler.v`。
