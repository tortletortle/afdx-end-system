# tools/ — 检查、建模与生成脚本

返回[工程目录导览](../目录导览_20261001.md) · [工具和复现说明](../README_tools.md)。`run_all.py` 为文档/一致性门；`check_*`、`verify_all.py`、`selfcheck_claims.py` 为核查；`bag_*` 为预算/算术模型；`gen_*` 为配置/寄存器/综合表生成；`fix_addr.py` 属**会写入文件的修复工具**，不能因整理目录而直接运行。

`pack_review_20261003.py` 是历史评阅包脚本，现已加保护：固定输出目录已存在时会退出，不会删除旧 stage 或覆盖 ZIP。新交卷包需用新的版本化输出目录和最终证据，不要复用该历史打包入口。运行校验/生成工具前分清只读与写入动作；不要仅凭工具 rc=0 推断协议合规或综合网表整帧 PASS。

`audit_final_task_state.py` 是当前收口的只读证据审计器：它核对同一 run 的 manifest、源码/脚本哈希、原始日志、六个隔离生成向量、六项独立审计、五 stage 前端和综合失败终态；它不启动 HDL 工具，也不会把局部 PASS 升级为最终验收。当前复核记录见 `../out/final_task_evidence_audit_20261013_r2/REVIEW.json`。
