| 子模块 | 实际 RTL 路径 | 全日志核验 | Cells（仅统计） |
|---|---|---|---:|
| `crc32` | `rtl/common/crc32.v` | **PASS** | 352 |
| `init_sweep` | `rtl/top/init_sweep.v` | **PASS** | 152 |
| `mac_tx_if` | `rtl/tx/mac_tx_if.v (依赖: rtl/common/crc32.v)` | **PASS** | 983 |
| `mgmt_sap_rx` | `rtl/mgmt/mgmt_sap_rx.v` | **PASS** | 373 |
| `rst_sync` | `rtl/common/rst_sync.v` | **PASS** | 3 |
| `rx_block_pool` | `rtl/rx/rx_block_pool.v` | **PASS** | 959 |
| `rx_flt` | `rtl/rx/rx_flt.v` | **PASS** | 852 |
| `sync_fifo` | `rtl/common/sync_fifo.v` | **PASS** | 1433 |
| `timebase` | `rtl/common/timebase.v` | **PASS** | 506 |
| `tx_frame_builder` | `rtl/tx/tx_frame_builder.v` | **PASS** | 5430 |
| `tx_pace` | `rtl/tx/tx_pace.v` | **PASS** | 42 |
| `tx_sn_gen` | `rtl/tx/tx_sn_gen.v` | **PASS** | 7626 |

仅子模块日志：12/12 PASS；判据=源码存在+全日志无 `^ERROR`+执行成功标记。
**不包含大容量存储子模块或 AFDX_top；不代表顶层综合/STA。**
