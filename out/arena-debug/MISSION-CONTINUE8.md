# Continue8 —— 基于文献与 STA 证据的架构重新设计（设计阶段，不先改 RTL）

在 `C:\Workspace\diansai` 针对当前真正剩余问题做一次**系统级重新设计**，由高级模型完成，先产出设计决策和可审计记录，暂不直接大规模改 RTL。所有记录写入 `out/arena-debug/continue8/`。

## 当前事实基线（必须以文件/日志复核，不得凭记忆）

- continue5：56/56 回归、lint 0 %Error、docgate 5/5；管理面 T14/T15/T16 + GMII 变体已实现。
- continue6：`snmp_lite.walk` 区间译码 + VarBind 编码打一拍，post-map Fmax 39.56→45.85 MHz，WNS −17.279→−13.809 ns；56/56 回归 PASS；8ns SDC 守卫通过。
- continue7：`tx_port_buf` 描述符四银行实验 56/56 PASS，但 Fmax 45.85→45.84、WNS −13.809→−13.815，已字节级回滚；生产 RTL 不保留四银行。
- 当前最差路径：`tx_port_buf:u_txbuf|s1_vld → s1_desc[*]`，约 21.29 ns；整机仍远离 125 MHz；post-map 非签核；71 输入/121 输出未约束。

## 文献与设计文档必须纳入

阅读并引用：
- `doc/AFDX文献目录.md`
- `doc/AFDX文献工程映射.md`
- `doc/AFDX文献主题矩阵.md`
- `doc/AFDX文献研究整理.md`
- `doc/AFDX端系统_基于文献研究的系统架构与数据流优化设计.md`
- `AFDX端系统_总体设计书.md`
- `out/arena-debug/continue6/REPORT.md`
- `out/arena-debug/continue7/REPORT.md`

优先核对文献 ID：L001/XAPP1130、L041、L044、L049、L065、L071、L074、L089，以及文献架构设计中的 D10/D11/D12 决策。文献只能作为设计依据，不能替代本项目 RTL/STA 证据。

## 重新设计任务

产出一个**可实施、可回滚、分阶段验证**的架构方案，至少比较三种方案：

### 方案 A：保持单时钟/单拍接口，做局部流水化
- `tx_port_buf` 的 `s1_vld→s1_desc` 如何拆成 descriptor read / arbitration / writeback 两拍或更多拍；
- 如何保持 host ACK、commit、queue ownership 和 descriptor 可见性语义不变；
- 需要哪些 backpressure/valid-ready/scoreboard 断言；
- 对 T00–T23、T14–T16、GMII 的影响。

### 方案 B：端口状态/描述符分银行 + 明确仲裁协议
- 说明为什么 continue7 的简单 4-bank 失败；
- 给出真正能改善时序的 bank ownership、读写端口、仲裁/旁路、时序边界，而不是重复简单 mux 拆分；
- 说明资源、延迟、吞吐和功能风险。

### 方案 C：结构性流水/队列重构
- 将 `rx_port_buf`/`tx_port_buf` 的状态更新从大组合路径改为事件 FIFO/分阶段提交；
- 评估是否需要 CPDB/统一 descriptor event bus、shadow state、commit queue；
- 明确这是大改动，给出迁移和回滚策略。

也可以提出更优的 D 方案，但必须解释取舍。

## 必须回答的问题

1. 当前 45.85 MHz 的真实根因是什么：按 STA 最差路径、RTL 扇出/组合链、RAM 推断分别解释，不能只说“逻辑太多”。
2. 为什么 continue7 四银行无效，下一次不应重复什么。
3. 哪个方案最可能把关键路径从约 21 ns 降到 8 ns 内；需要几级流水、会增加多少延迟；哪些协议/测试语义必须改写。
4. 功能正确性、吞吐、BAG/Jitter、主机 ACK、块所有权、双网去重、SNMP/TFTP 响应时序如何保持。
5. 设计成功判据：每阶段必须跑哪些测试、如何做 post-map/post-fit、如何记录负收益回滚。
6. 板级 IO/管脚/约束缺失如何影响最终 125MHz 签核，哪些结论在当前环境不能声称。

## 交付物（只写设计记录，不先改 RTL）

- `out/arena-debug/continue8/REDESIGN-ARCHITECTURE.md`：最终推荐方案、三案对比、数据流/时序图、接口契约、风险与阶段计划；
- `out/arena-debug/continue8/DECISION-LOG.md`：每个关键决策、证据、替代方案、否决原因；
- `out/arena-debug/continue8/LITERATURE-TRACE.md`：文献 ID → 设计决策 → 需验证的 RTL/测试证据映射；
- `out/arena-debug/continue8/IMPLEMENTATION-PLAN.md`：按阶段列出文件、备份点、patch、回归、STA、回滚条件；
- `out/arena-debug/continue8/BASELINE.md`：当前基线数字与证据路径；
- `out/arena-debug/continue8/SHA256SUMS.txt`：记录上述设计文件哈希；
- 不修改 `rtl/`、`sim/`、`doc/` 原文件，不生成虚假的 patch；如需临时脚本只能放 continue8/。

## 纪律

- 不读取/回显 `.env`、`*.local.*`、密钥/账号/密码/token；不碰 `competition_case/`、`data/`、`logs/`；不 git commit/push/reset。
- 设计文档必须区分“文献建议”“设计假设”“已验证事实”“待验证项”。
- 不把 post-map 当签核，不把 56/56 当时序通过，不把论文结论当本项目证据。
