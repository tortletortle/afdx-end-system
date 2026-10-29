# submit/figs

PNG 由 `doc/figs/*.mmd` 用 mermaid-cli 渲染。正文引用本目录 PNG，不依赖在线 mermaid。

| 文件 | 源 | 用途 |
|---|---|---|
| `fig1_dataflow.png` | `doc/figs/fig1_dataflow.mmd` | 总体数据流（2.1） |
| `fig2_block_owner.png` | `doc/figs/fig2_block_owner.mmd` | RX 块所有权（2.2.3） |
| `fig3_tftp_615a.png` | `doc/figs/fig3_tftp_615a.mmd` | TFTP/615A（可选） |
| `fig_design_flow.png` | `doc/figs/fig_design_flow.mmd` | 设计流程（1.6） |
| `fig_app_top.png` | `tools/gen_app_top_fig.py`（PIL，非 mermaid） | 评测封装 afdx_app_top 框图（2.1） |
| `fig_tx_modules.png` | `doc/figs/fig_tx_modules.mmd` | TX 模块框图（2.2.3） |
| `fig_rx_modules.png` | `doc/figs/fig_rx_modules.mmd` | RX 模块框图（2.2.3） |
| `fig_mgmt_modules.png` | `doc/figs/fig_mgmt_modules.mmd` | 管理面框图（2.2.3） |

| `S2_manifest_table.png` … `S6_synth_summary.png` | `tools/gen_submit_layout_figs.py` | 排版示意（非终端截屏） |
| `S8_T88_signals.png` / `S9_T90_signals.png` / `S10_T10_signals.png` | `out/p9_freeze_dfac58a/wave_png/` | 调试波形；功能判定以全量回归为准 |

人工仅 4 张（M1–M4）：见 `doc/submit/人工截图清单.md`。推迟到封装测试台与最终冻结后，与演示视频同时补拍；此前正文只留占位。
