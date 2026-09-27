# DIANSAI 本轮执行报告（Arena / T21 增量）

时间：2026-09-24（Asia/Shanghai）  
工作区：`C:/Workspace/diansai`  
MCP：shuncode-bridge / host-exec  

## 1. 摘要

本轮按 `out/arena-debug/MISSION-diansai.md` 优先处理 **P0-04 / T21 块池耗尽、恢复、归还**。未改生产 RTL；新增顶层 Questa TB `sim/tb/tb_t21_block_pool.v`，把现有 RX 链路真实走到 `rx_port_buf`，补齐可重复证据：

1. 队列端口深度配置为 10，占满 RX 块池 `6..15`；
2. 第 11 帧在块池空时触发 `mac_rx_if` 的 `NO_BLK` 路径和 `rx_exh_cnt=1`；
3. 空池帧期间断言 **无 PMEM 写**、**无新增端口入队/交付**；
4. 主机通过 `MSG_RD` 逐条释放 10 个块，并逐笔读回 payload 验证队列顺序；
5. 释放后再次发送恢复帧，确认交付恢复且 `rx_exh_cnt` 不再增加；
6. IF_MODE=0 与 IF_MODE=1 两档均 PASS。

P0-02/T17、完整 T08 全表灌装逐笔 scoreboard、SAP/管理面最小闭环本轮未继续实现，原因是优先把 T21 做成可复现 Questa 证据，并保守更新文档，不伪造未测项。

## 2. 变更文件与关键位置

### 2.1 新增 T21 顶层 TB

- 文件：`sim/tb/tb_t21_block_pool.v`
- SHA-256：`2164DB121D2516A1BEC67975B3B7F038C7C4950112391276D78EC487277FCB40`
- 关键行：
  - `sim/tb/tb_t21_block_pool.v:1-6`：说明 T21/T21g 验收目标。
  - `sim/tb/tb_t21_block_pool.v:19-26`：例化 `AFDX_top`，保持真实顶层链路。
  - `sim/tb/tb_t21_block_pool.v:57-61`：监测端口交付、`NO_BLK` 脉冲、空池期间 PMEM 写。
  - `sim/tb/tb_t21_block_pool.v:134-151`：配置 hash/RX_VL/端口表，队列深度 10。
  - `sim/tb/tb_t21_block_pool.v:213-234`：占满 10 个 RX 块并验证空池帧 `NO_BLK` / 无 PMEM 写 / 无入队。
  - `sim/tb/tb_t21_block_pool.v:236-253`：`MSG_RD` 逐条归还、payload 逐笔核对、恢复帧验证。
  - `sim/tb/tb_t21_block_pool.v:255-257`：PASS 摘要字段。
  - `sim/tb/tb_t21_block_pool.v:270-271`：`tb_t21_block_pool` / `tb_t21g_block_pool` 两个顶层模块。

### 2.2 Manifest 与回归脚本

- `sim/tests.manifest:25-26` 新增：
  - `T21 tb_t21_block_pool block-pool-exhaust`
  - `T21g tb_t21g_block_pool block-pool-exhaust-gmii`
- `sim/tests.manifest` SHA-256：`9BDE09B9E7100F45D57114905D1EA50DBF20FD662738CEB0924E553063D5A036`
- `sim/run_regress.ps1:76-78`：选中 T11/T21/T22 时也自动生成 T08a 真实帧向量，避免单跑 T21 缺 `vec/t08a_frames.hex`。
- `sim/run_regress.ps1:149`：映射 `tb_t21g_block_pool` 到同一个 TB 文件。
- `sim/run_regress.ps1` SHA-256：`8AAE1564835DEDA21E12188CA3AB5EF11059D8141BC7C1E8BB0ACE3DB9A630C6`

### 2.3 文档更新

- `README.md:16-22`：登记 36 项基线 + T21 增量、T21/T21g 2/2 PASS、38 项全量尝试的工具断连边界，以及 T21 仍未替代完整 T08。
- `README_tools.md:45`：新增 `tb_t21_block_pool.v` 说明和运行判据。
- `doc/当前进度_20260923.md:8-10,20,28,38`：更新 T21 状态、证据、剩余项。
- `doc/后续计划.md:3,47,55-58,96`：将后级接线/T21/T22 对应项改为已完成，同时保留完整 T08 scoreboard、SAP、T17/T18 等后续工作。

对应 SHA-256：

- `README.md`：`95CFCF3FC6B0B21B11453A96D7D4258BD87F6CC8C2B6F1DD073D9CF782F06607`
- `README_tools.md`：`70B8883E4A72BD8515EFF84C1083CB91E39ACD3F287F5F6FBE28308D25FD2A0A`
- `doc/当前进度_20260923.md`：`C56FD54FF202AC82765A2AD3C8704D2A36817E2E6C1EAA768647B262EEB5E842`
- `doc/后续计划.md`：`268E5D27F23F0D1CE3393DE0FD156F888F72BFA1664B57E15149F3879C9F85AA`

## 3. 仿真与检查证据

### 3.1 T21/T21g 定向回归

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Workspace/diansai/sim/run_regress.ps1 -Tests T21,T21g
```

结果：**2/2 PASS**。归档：

- CSV：`sim/out/regress_t21_2_20260924.csv`
  - SHA-256：`A5E7B380A120C98FCC7BF5D5944FF8A303AB7EEE9E206923B28A4D0F84C614FA`
- Console：`sim/out/T21_console_20260924.txt`
  - SHA-256：`6D98E079FF78EF0DC9B25E3AE9DD82FEC1095697E54B12902EE89925735F3BD3`
- Console：`sim/out/T21g_console_20260924.txt`
  - SHA-256：`71B42297D81D0919B3A0F2DD6538C1C92DFD087846B5FE68933E44E6CEA66859`

CSV 摘要：

```text
T21,block-pool-exhaust,tb_t21_block_pool,PASS,...,# T21 BLOCK-POOL PASS (IF_MODE=0 filled=10 no_blk=1 exhaust=1 borrow=4 returned=10 recovery=1 deliver=11 no_pmem_empty=0)
T21g,block-pool-exhaust-gmii,tb_t21g_block_pool,PASS,...,# T21 BLOCK-POOL PASS (IF_MODE=1 filled=10 no_blk=1 exhaust=1 borrow=4 returned=10 recovery=1 deliver=11 no_pmem_empty=0)
```

### 3.2 既有相关子集复核

一次 38 项全量尝试在 T10g 阶段发生 Questa/vish RPC/license 断连并留下 `vsim/vish/vlm` 残进程，不能登记为完整 38/38。清理残进程后，分组复跑如下：

- `-Tests T10g`：1/1 PASS。
- `-Tests T11,T11g,T21,T21g`：4/4 PASS。
- `-Tests T09,T09s,T09p,T09ps,T12c,T12r,T12s,T12h,T12f,T12fg,T22,T22g,T11i,T11ig,T22a`：15/15 PASS。
  - 归档 CSV：`sim/out/regress_tail_15_20260924.csv`
  - SHA-256：`670ABAAB1E935F03AC2EB9210DCA56B137459643521942CDD9C4BFCCBD9D3382`

说明：38 项全量失败是工具/许可/进程断连边界，不作为 RTL FAIL；报告和文档已如实登记，没有伪造完整 38/38。

### 3.3 文档门与 lint

命令：

```powershell
cd C:/Workspace/diansai
python tools/run_all.py --strict
powershell -NoProfile -ExecutionPolicy Bypass -File ./tools_lint.ps1 *> ./sim/out/lint_t21_20260924.txt
```

结果：

- `python tools/run_all.py --strict`：exit 0，末行 `5/5 全绿，自查通过`。
- `tools_lint.ps1`：exit 0，末行 `LINT GATE: PASS (all gates 0 %Error)`。
- `sim/out/lint_t21_20260924.txt` SHA-256：`D558D3F14E3CD4151BEB37DF8B79DD03E7E524D27592A93CED93E7EA30CFC127`

## 4. 根因 / 改动说明

根因：现有 T11 已覆盖采样/队列/覆盖/pin/队列满和解析丢弃，但没有显式把 RX 块池 10 个块全部占满后，证明空池帧不会写 PMEM、不会误入队，且 `MSG_RD` 释放后能恢复。`rx_block_pool` 已有 `exhaust_cnt` / `borrow_cnt` 和 `rx_port_buf` 的两个释放口，生产 RTL 不需要改；缺口是顶层可复现测试证据。

改动：新增最小 TB + manifest/runner 映射。TB 只在仿真层访问层次信号（如 `rx_free_map`、`rx_exh_cnt`、`u_mac_rx_a.drop_cnt`、`rxw_en_a`），没有新增或修改生产 RTL。

## 5. 回滚与备份

修改前已备份到：

- `C:/Workspace/diansai/out/arena-debug/backup/20260924_233351/`

本轮 patch：

- `C:/Workspace/diansai/out/arena-debug/diansai.patch`
- SHA-256：`7B4C16B309348B8102AE182F2A8FCB0F5FE2E9846381FC39AFAB1663DE1032AA`

注意：该 patch 只覆盖本轮相关源码/脚本/文档变更；`sim/out/` 下 generic `regress.csv` 和 console 会被回归脚本覆盖，命名证据文件另行保存。

## 6. 遗留点

1. **完整 T08**：T21 已定向 PASS，但仍不能替代全表灌装 + 逐笔 scoreboard。
2. **P0-02/T17**：仍缺持续饱和双网写口下的等待上界、主机读写交错、最小帧/双网冲击和长稳证据。
3. **SAP/管理面**：SAP→mgmt 最小闭环未做。
4. **性能/交付**：T05b 合法满载抖动、T13/T18、完整顶层综合/STA、覆盖率仍待验。
