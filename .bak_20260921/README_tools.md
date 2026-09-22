# 工具包说明

先跑这个（等价于把下面 5 个校验一次跑完，退出码 0 才算过）：

```
python tools\run_all.py
```
（eLinx + ModelSim 环境，只需要 Python 3.8+，全部只用标准库）

用法：把本目录当作工作区根，`AFDX端系统_总体设计书.md` 放在上一级（即 `../AFDX端系统_总体设计书.md`），
在仓库根目录下执行 `python tools\xxx.py`。四个校验脚本改了文档或地址表之后必须重跑，退出码 0 才算过。

| 脚本 | 作用 | 跑成功的判据 |
|---|---|---|
| `tools/verify_all.py` | 全文一致性：章节编号、交叉引用、45 张表列数、T00~T22/D1~D9/R1~R9、§9 表规模与正文对账、模板 8 端口方向位宽、脚本路径唯一性、硬件化措辞（只罚肯定式） | 末行「全部通过，0 处问题」，exit 0 |
| `tools/check_addr.py` | §7.14 地址表逐行复核：区间跨度 = 声明字数、无重叠、PMEM 2 KB 对齐 | 「校验到 14 行；合计 53408 字（209 KB）… 错误 0 处」 |
| `tools/fix_addr.py` | §7.14 地址表生成器：按「项数 × 每项字数」连续排布并重算 §9 规模。**要改地址就改这个脚本里的 LAYOUT，不要手打区间** | 打印新表并回写文档 |
| `tools/check_s9_final.py` | §9 每行按「项 × 位」反算 Kbit 与 18 Kbit 块数，并核对合计行 | 「行数 13 … 错误 0」+ 两行 ok 合计 |
| `tools/check_s9.py` | §9 的旧版抽查（保留备查，日常用 `check_s9_final.py`） | 只读 |
| `tools/run_all.py` | 一键跑完 5 个校验器，逐条打印 PASS/FAIL 与最后一行结论 | 「5/5 全绿」，exit 0 |
| `tools/bag_model.py` | §8.2 判决式的唯一实现（`bag_budget.py`、`check_doc_numbers.py` 都从这里取数，避免两份算法飘开） | 被引用，不单独跑 |
| `tools/check_doc_numbers.py` | 把 §8.2 正文写死的 T05a/b/c 数字逐条重算对账 | 「全部一致：文档里的 §8.2 数字都可由判决式复算」 |
| `tools/_conv.py` | 把赛方的 xlsx / rar 变成可读文本：xlsx 用标准库 `zipfile` 解 `sharedStrings.xml`+`sheet1.xml` 出 CSV 与 `_conv_report.txt`，rar 调 7-Zip 解压并就地打印文本文件内容。不需要 Excel、不装第三方包，可放在目标机器上直接 `python _conv.py` | 打印 `report lines=N bytes=M`，产物落在同目录 |
| `tools/_sync_push.py` / `tools/_sync_verify.py` | 隧道同步用：前者抓远端正文造精确 hunk 并推差异（新文件走 Add、已存在走 Update），后者分块抓回远端**逐行比内容**。远端 `read_files` 的 `version:` 哈希带行号前缀，与本地内容哈希永不相等，**只能用逐行比对判定** | push 末行「逐行全等 ✓」；verify 末行「全部逐行一致」 |
| `tools/gen_regs.py` | `doc/regs.yaml` → `doc/regs_pkg.svh`（地址 localparam + 访问位图），并反向核对附录 A / A.1~A.3 | 「YAML 自检：通过 / 主表对账：一致 / 位域表对账：一致」 |
| `tools/bag_budget.py` | 按 §8.2 的判决式算 CFG_SUM、饱和 BAG、抖动上界、构建器吞吐（T05a/b/c 的数字都出自这里，不许手填） | 打印三组用例 |
| `tools/selfcheck_claims.py` | 复核设计书里「声称但没算」的三条：配置总线加载时间、BAG 判决式、满载抖动 | 打印 C1/C2/C3 |
| `tools/check_sizes_add.py` | 给 verify_all 追加检查用的一次性补丁脚本，平时不跑 | — |
| `tools/md2docx.py` | Markdown → Word（表格、标题、代码块），交付用 | 打印段/表数量 |

## 与文档的对应关系

- 寄存器只有一处真值：`doc/regs.yaml`。附录 A 与 A.1~A.3 由 `gen_regs.py` 生成/核对，RTL 里的 `ADDR_*`
  与 `ACC_*` 在 `doc/regs_pkg.svh`。改寄存器就改 YAML，然后跑 `python tools\gen_regs.py --emit`。
- 地址表只有一处真值：`tools/fix_addr.py` 的 LAYOUT。§7.1 的 PMEM 基址、§8.6 的三池区间、
  `TFTP_DEST_BASE` 都由它广播，改完必须跑 `check_addr.py`。
- §9 的每个数字必须能被 `check_s9_final.py` 反算出来。上一版这里连错过三次（1.61/1.78/1.30 Mbit），
  以及 §8.2 的「99.84 Mbps」（实为 8.96 Mbps，差 11.2 倍）和 §8.3 把「拍」当「μs」用（1471×8 拍 = 117.7 μs，
  不是 11.8 μs）——有脚本之后这类错一跑就现形。

## 还没验证的东西（重要）

这套脚本只保证**文档内部自洽与算术正确**。RTL 一行都还没编译过、没仿真过，所有性能数字
（抖动 22.4 μs、TX 首字节 3.5 μs/118.7 μs、端到端 ≤0.35 ms）目前是设计目标，不是测量值。
`tools/lint.sh` 依赖的 Verilator 在你本机若没装，就先在 eLinx/ModelSim 里把 `AFDX_top` 空壳编译起来。

## 落地方式（Bridge 的 apply_patch 不能建目录，所以这次是平铺到工作区根）

本批文件平铺在仓库根，前缀就是它们该去的目录。跑一次即可归位（PowerShell）：

```
mkdir tools, doc -Force
Move-Item tools_*.py tools\
Move-Item doc_regs.yaml doc\
python tools\verify_all.py ; python tools\check_addr.py ; python tools\check_s9_final.py ; python tools\gen_regs.py --emit
```

归位前后都能跑：脚本按「自身同级 → 上一级 → 当前工作目录 → 家目录」的顺序找 `AFDX端系统_总体设计书.md`，
`doc_regs.yaml` 同理（`doc/regs.yaml` 或根目录的 `doc_regs.yaml` 都认）。已实测平铺与归位两种布局都能跑通。
本批脚本只用 Python 3.8+ 标准库，不需要 pip 装任何东西。
另外 `md2docx.py` 没随本批推送——它依赖 python-docx（你机器上不一定装了），而且 .docx 是二进制，
Bridge 的 apply_patch 只收文本，Word 文件请在对话里下载。


