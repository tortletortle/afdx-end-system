# formal 环境状态（2026-10-19）

> 等级：**I**（有界 BMC 证据 + 准备件）。  
> **不宣称**：已形式化证明 BAG 合规 / WCTT / 全池「分配+空闲≡10」无界证明 / 125 MHz。

## 块 1：oss-cad-suite

| 项 | 值 |
|---|---|
| 安装路径 | `C:\Tools\oss-cad-suite`（仓库外） |
| 发布 | `oss-cad-suite-windows-x64-20261019.tgz`（tag `20261019`） |
| 激活 | `. C:\Tools\oss-cad-suite\environment.ps1` |
| yosys | `0.70+157` |
| sby | `v0.70-9-g79fc9ed` |
| 求解器 | z3 / boolector / yices（`bin\`） |
| 官方 demo | `examples/quickstart/demo.sby` → **PASS** |
| Windows | **未 BLOCKED**；`.sby` 注释请用 ASCII（GBK 解码会炸） |

## 块 2：BAG（仍等时序刀）

| 文件 | 状态 |
|---|---|
| `tx_vl_scheduler_bag.sv` | 已写（bind 草稿）；yosys 免费版对 `bind` 不友好，定稿跑时宜改 wrapper（见 pool） |
| `bag.sby` | RTL 路径仍注释；**未跑** |
| 阻塞 | `rtl/tx/tx_vl_scheduler.v` 工作树仍脏、未 commit |

## 块 2b：rx_block_pool 有界 BMC（本续作）

| 项 | 值 |
|---|---|
| 命题 | P1 `free_map[5:0]==0`；P2 alloc `blk>=6`；P3 同拍 A/B `blk` 互异 |
| 配置 | `CHAIN_ENABLE=0`；wrapper `pool_formal_top`；`$initstate → assume rst` |
| 命令 | `sby -f pool.sby`（于 `formal/`，需激活套件） |
| 引擎 | smtbmc **boolector**，depth **40** |
| 结果 | **DONE (PASS, rc=0)**，约 4 s |
| 证据目录 | `formal/pool_bmc/`（含 `PASS`；本地工作区，主线提交时可剔除 workdir） |
| RTL | **只读** `rtl/rx/rx_block_pool.v`；未改任何 `.v` |
| 边界 | 有界 depth 40；未证 CHAIN；未证顶层 free 仲裁；≠「空闲+在持≡10」全系统 |

## 块 2c：rx_rm 有界 BMC（本续作）

| 项 | 值 |
|---|---|
| 命题 | 主表项 forward 后，同 VL0、同 sn、`|Δts|≤`**当前帧** skew 的再输出必须 `out_fwd==0` |
| 配置 | `NUM_RX_VL=2`；VL0；scalar ghost；behind hist 不入 ghost；`skew_exp≤4` |
| 命令 | `sby -f rm.sby bmc20` / `bmc40`（于 `formal/`，需激活套件） |
| 引擎 | smtbmc **boolector** |
| 结果 | bmc20 **PASS**（~12 s）；bmc40 **PASS**（~354 s） |
| 证据目录 | `formal/rm_bmc20/`、`formal/rm_bmc40/`（含 `PASS`） |
| RTL | **只读** `rtl/rx/rx_rm.v`；未改任何 `.v` |
| 边界 | 有界 depth 40；仅 VL0；不证 late_dup/hist 全路径；≠无界证明；≠ T10 剧本替代 |
| FAIL 史 | `formal/rm_bmc20_FAIL_NOTE.md`（全为 wrapper 误建模，非 RTL） |

## 块 3

见 `doc/形式验证落地评估_20261019.md`（续作已补 pool / RM BMC）。

## 注意

- 勿对半改的 `tx_vl_scheduler.v` 跑 `bag.sby`。  
- 未执行 git add/commit（产物留工作树）。  
- 未跑综合 / Fit / STA。
