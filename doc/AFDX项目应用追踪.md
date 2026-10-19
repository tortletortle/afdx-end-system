# AFDX 项目应用追踪

> 当前接管入口：[P00–P12执行表](当前执行表_20261012.md)。核验2026-10-13T12:18:42.458888+08:00：root已变更：2份生产源、实际manifest 140项；当前新候选完整回归：PASS 140/140 rc=0。旧冻结137仅属于旧版证据。当前同版完整RTL/六审计/前端全部成立=True；KeepHierarchy完整综合FAIL，原probe NOT_CREATED，编译/加载/业务独立登记。当前执行FAIL_STOP_NO_RETRY/keep_hierarchy_complete_synthesis_and_cost；旧137/137及旧包复现只属于旧版，旧flatten综合FAIL及全部失败原件保留。2ms官方负载/起止待确认，完整消息实测6.063448/6.161736ms超2ms另列；完整615A/665仍OPEN。现场进程、阶段耗时与路径见`out/continuation_checkpoint_20261013_r2_inflight/CHECKPOINT.json`；[无损交接](新对话交接_20261013.md)。下方旧状态保留为历史。


更新：2026-10-12

> 本文件是面向当前工程实施、验证和答辩的主入口。文献是设计依据之一，不是当前实现证据；当前状态必须回到 RTL、TB、manifest、日志、综合和 STA 报告核对。

## 0. 执行分工与验收规定（2026-10-11）

本节记录用户确认的执行分工。此次仅更新规定，下方历史状态表未重新核验，不因本节更新而成为当前版本的完成证据。实际模型配置及调度须由主线程应用；文档更新不代表正在运行的智能体已经切换模型，也不代表已启用新的自动任务。

### 0.1 默认分工

| 工作 | 默认负责 | 交付与边界 |
|---|---|---|
| 按指定命令编译、运行仿真、等待工具结束、保存原始日志 | 脚本；需要判断时由 Luna 执行 | 使用既定版本、配置及验收条件；记录退出码和实际结果 |
| 提取失败位置、整理结果、复现已明确的问题、执行接口明确的小范围修复 | Luna | 提交代码差异、复现步骤、结果及未覆盖范围 |
| 对齐赛题和规范、制定方案、设计跨模块接口、判断 golden/测试预期是否正确 | 高级模型总控 | 明确依据、假设、接口契约和验收条件后再派发 |
| 复杂根因诊断、公共 PMEM 仲裁、资源生命周期、协议范围及阶段验收 | 高级模型总控 | 审查源码与原始证据，分别判断模块、顶层和综合后验证范围 |

高级模型在方案选择、疑难诊断和验收节点介入。仿真计算由仿真器完成；工具运行期间避免无新信息的频繁日志轮询。

### 0.2 执行和证据规则

1. 每个任务写清目标、起始源码版本、允许修改的文件、接口契约、验收条件及交付证据。每个文件同一时段只有一个写入者，公共接口由总控集成。
2. 仿真失败后先用针对性小例定位和复现。相同失败且没有新增证据时调整诊断方法；候选稳定、相关定向检查通过后再运行完整回归。重型综合与仿真集中排队，避免争抢本机资源。
3. 修改 golden、测试预期或判据必须提供赛题/规范依据并经总控复核。不得通过削弱断言、跳过失败项或改变协议预期制造通过结果。
4. 本文件是持续维护的进度入口。验证结论必须注明源码版本、配置、原始证据路径、覆盖内容和未覆盖边界；历史日志和快照保留。源码变化后检查受影响证据，不把旧 PASS 自动延伸到新版本。
5. 文献按具体问题查找，分别登记背景参考、设计依据、拟采用、已实现及已验证收益。论文结果不能替代本工程实测；常规代码错误先依据源码、波形及接口契约定位。
6. 无人值守运行由主线程在明确的目标、截止时间和权限范围内启用。到任务交接点检查账号共享额度；五小时剩余约 20%–30% 时减少新派发，必要时保存现场等待刷新。重置卡不得默认自动兑换，每次使用须有用户明确确认。

### 0.3 本轮接续状态（2026-10-12 01:17，本地时间）

下表区分冻结回归基线与当前工作树。下方历史状态表尚未逐条重验，不能覆盖本节边界。

| 项目 | 实际状态与证据 | 边界 |
|---|---|---|
| RX 后续分片字节搬移及源块复用 | `sim/out/rx_copy_t60_r7`：T60 PASS，35 项检查；636 B 全部经公开 host 读回；18 片覆盖超过 16 个源表项的复用 | 单个 2 KiB 目标块，当前应用上限 2006 B；不是完整 8 KiB |
| 相邻 RTL 保护回归 | `sim/out/rx_copy_adjacent_r1`：26/26 PASS；T59 独立回归 PASS | 仅对应各自冻结输入，不自动延伸至后续修改 |
| 搬移基线全量回归 | `sim/out/rx_copy_full_r1/regress.csv`：123/123 PASS，wall 4752 s，原会话 28782 已以 rc=0 结束；metadata 同为 PASS/123 completed/123 pass | 仅搬移基线；不包含本轮 checksum/drain/仲裁改动。T35/T35g 为 IF_MODE=0/1，不能代替默认 IF_MODE=2 全表业务 |
| 重组后 UDP 长度与 checksum | `sim/out/rx_udp_directed_r1`：T64/T64a/T64b（1/0/5 读响应延迟）PASS；T60 PASS 85 checks，包含坏/零 checksum、长度、奇数长度及策略 | 顶层有效用例为 636/635 B；2006 B 上限仅 checker 单元覆盖；当前新版本未做完整 129 项回归 |
| 短超时与取消 | 本地 P7 2005 附件 2 印刷页 119 已核图；生产禁用原 524 µs 固定计时。新 T60 已通过 1.04 ms 片间隔、disable drain、checker 在途立即重开取消保持及后续恢复 | 赛题未指定 P7 版次，不声称所有版次认证；不外推未覆盖取消时序 |
| 重组期间配置归属 | 顶层新增 `reasm_hold_w0`；T65 PASS 671 checks，跨 VL cover=608 周期。私有变异体恢复错误 `prs_w0=rm_hold_w0` 后，公开消息计数/描述符检测失败；simulator 0 Error / 0 Warning | 首轮 T65 的测试台复位启动错误保留于 directed_r1；negative control 位于 `out/rx_copy_followup_20261011/t65_metadata_mutant_prep/logs`，未修改生产文件 |
| PMEM 争用与推进 | directed_r1：T66 PASS 655 checks（copy req/grant=80/10、check=1296/162）；T67 PASS 657 checks（copy wait/grant=80/10，host commit=6054），均公开核对 636 B | 持续 host 读/合法 TX 开放块写用例；不外推所有 TX builder/SAP/RX 组合压力与无限时长公平性 |
| 历史r7编译 | `out/rx_copy_followup_20261011/compile_r7/vlog.txt`：生产清单 41 个源及 T60/T64（含 0/1/5 响应延迟版本）/T65/T66/T67，0 Error / 0 Warning；输入哈希同目录 | 只证明编译；未证明动态行为或综合可行。r4 为命令源根目录错误，r6 为 T67 未命名块内变量声明兼容错误，均保留；r7 已修正 |
| 综合故障诊断 | C3完整综合已于2026-10-11 22:53:32结束：rc1、1573.92s，在42.30 TECHMAP再次报bad allocation，未导出VQM。原始文件缓存独立完整映射通过，未修改该生产RTL | 保留层级仅推迟内存失败，不能声称解决。prefine已rc0导出113348555字节IL、481.113s，但含617条Warning记录，不是综合PASS。中间规模adapter123411、dgram56158、重组43666 cells，优先验证动态字节写等价优化；尚无顶层综合网表/业务PASS |

原始证据和下一步见 `out/rx_copy_followup_20261011/SYNTHESIS_DIAGNOSIS.md`。新工作树首轮定向 directed_r1 为 11/12（T65 测试台复位启动错误，不能标整轮 PASS）；T65 独立 r2 为 1/1 PASS。随后同一冻结候选 `sim/out/rx_udp_protection_r1`：34/34 PASS、rc0、332.7 s；CSV SHA-256 `F340C59896B4690C02F2FEF8A5051ADF72B5234C41A5A6C1C83D8193CD7BDB06`。C2（41源）PREPARED；C3 Frontend PASS、rc0、13.01 s，完整Synthesis已FAIL rc1/1573.92s，旧session27716已不存在；prefine诊断session23460已rc0结束；该历史阶段无重型工具在跑；最新执行状态以§0.13为准。baseline退出码丢失，原wrapper rc0不能作为成功证据；后续脚本已修正退出码与日志尾部序列化问题。完整129项新版本回归、8 KiB TX/RX生产接线、真实GMII 615A/TFTP全流程和综合后业务仍开放。

### 0.4 2026-10-12 01:17 优化候选接入（历史检查点，后续见§0.6–0.7）

- 合入4处有限修改：adapter/dgram/orchestrator 的动态字节写改固定字节使能；rx_reassembly 的掩码与完成判决改固定宽度移位/归约。原件与候选完整备份及SHA见 out/bitmap_bytewrite_integration_20261012_r1/integration.json。
- 局部prefine cells：adapter123411→62979、dgram56158→21536、orchestrator31313→14389；3候选均完成局部native映射并导出非空VQM，最终CHECK无Warning。它们不是顶层综合/器件利用率结果。
- 实际RTL miter：dgram9216 checks、orchestrator2304 checks通过；adapter最终保留写法4608可达写检查+1536读位置检查及start/download/abort覆盖通过；bitmap5128掩码+20480完成判决通过。原始全10bit adapter miter在强制索引512时有明确反例，保留FAIL；复位后的FSM归纳只支持U_WAIT索引0..511，不能声称任意内部状态或四态等价。详见out/wide_write_equiv_20261012_r1/ACTUAL_RTL_FINDINGS.md。
- 额外adapter读索引候选虽行为检查通过，但native逻辑量增加，已舍弃，未合入。
- 当前工作树与旧34/34及123/123快照已不同；当前37项保护回归已PASS37/37、rc0、263.4s（sim/out/bitmap_bytewrite_protection_r1），41个当前生产源哈希均匹配冻结PASS快照；不是完整129项。C3历史整机综合仍FAIL；新顶层综合、129项完整回归、8KiB TX/RX生产接线及完整GMII管理业务仍开放。C4已从本37-PASS快照冻结（out/bitmap_bytewrite_c4_noflatten_20261012_r1，candidate SHA256 7cff05d895f217bffc1b44199b700bfa11f60be793c10362c52ce7d37265e11c）；Frontend PASS/rc0/5.42s；C4已跨过旧42.30内存故障点，但ABC重接后出现4条driver-driver冲突，最终CHECK有26439条多驱动Warning，验收拒绝。01:46确认PID17948后在问题VQM导出期间主动停止，raw rc=-1/1349.36s；这是结构诊断停止，不是再次bad allocation。无完整VQM/综合后业务PASS。详见该目录ROOT_REVIEW.md及ROOT_REVIEW_STATUS.json，下一步用tx_rm小例分阶段定位映射流程。完整回归编译0Errors/2条既有Warning(A9常量截断及bind作用域)，A9私有真实RTL正负控已完成（out/a9_activation_fix_20261012_r1/runs/20261012T014624_524778e9）：原常量使计数器不采样；13bit常量修复可抓到故意重复转发，但实际RX合法timestamp超窗刺激暴露cycle-gap误报。时间戳候选已通过私有真实RTL正负控和阈值/回绕检查（out/a9_timestamp_fix_20261012_r1/runs/20261012T014743_d40b656f）。随后合入A9 timestamp修复、bind out_ts、compile -mfcu/-cuname与严格[chk]判据（out/a9_checker_integration_20261012_r1/integration.json），生产41RTL未改。新37项保护回归sim/out/a9_checker_protection_r1已结束：rc1/280s，18/37 PASS、19项elaboration FAIL，编译0Errors/0Warnings；所有19项失败日志均有vopt-10717目标模块不在该TB层级及Error loading design。此轮不能标37/37，正在按DUT范围修复绑定加载；原始失败保留。不声称旧绑定监视器覆盖有效。

### 0.5 2026-10-12 接续诊断

- RX8KiB私有scatter-copy helper实际Questa独立验收PASS：out/rx8k_mover_20261012_r1/runs/20261011T175344Z_2d0cc8487f7646328a2c9f02e321cf4f，compile/sim均rc0、0Errors/0Warnings，唯一TB_RESULT=PASS。RTL SHA07f93335ec10cd0a11436f40b1d21b0aa5fa9f6d1cecceab88a9302b89432386。覆盖字节偏移组合、边界、多块非连续目标、PMEM背压/延迟、取消与复位；这是独立helper，尚未生产接线，当前RX应用上限仍2006B。实际runner版本与当前runner差异见ROOT_RUN_NOTE.md。
- C4综合诊断：相同生产tx_rm源独立native映射（out/txrm_native_repro_20261012_r1）rc0/1.282s，各阶段CHECK无Warning；与C4整机中相同规模tx_rm出现重复ABC生成net驱动形成对照。尚未定论根因，准备从C4 preabc精确提取该模块再测，区分输入上下文与跨模块映射流程。C4导出的109254226字节VQM末行截断，不能当作完整综合网表。

- 新最小综合对照：out/txrm_c4_il_repro_20261012_r1，精确C4 preabc tx_rm含原autoidx3049595，独立native映射rc0/0.312s、各阶段CHECK无Warning；全局autoidx值或该模块输入单独不足以复现多驱动。双tx_rm同次ABC到before_merge仍CHECK正常，后续无top的HANDLE_INIT_REG访问异常；stats_regs精确IL重读因缺失carry wire失败，均保留于out/txrm_multimodule_repro_20261012_r1，不能当作整机映射通过。

- 绑定作用域修复：私有四类代表T08a/T08b/T09s/T41实际PASS4/4、rc0/18.2s（out/bind_scope_validation_20261012_r1/sim/out/profiles_r1）。实际整机rx_rm负控于activation_fixture_r2确认A9.errors=1且严格判据FAIL；r1漏core层级路径失败保留。已合入8个仿真入口/审计/绑定配置文件（out/bind_scope_integration_20261012_r1），当前新37保护回归sim/out/bind_scope_protection_r1运行中，生产41RTL未改。
- ABC分阶段诊断：out/c4_closed_il_abc_repro_20261012_r1私有副本只补69个单次生产、无读取的COUT声明以便IL重载；ABC前CHECK无Warning；整批ABC后立即CHECK再次出现19612个多驱动Warning并bad allocation，rc1/76.469s。因此补声明未解决问题，已将损坏出现点定位在ABC阶段，尚未进入cells_map/merge2lcell；具体根因仍待排查。新准备保留完整60module上下文、分别映射tx_rm/stats_regs的小例，排队待保护回归结束。

### 0.6 2026-10-12 02:24 当前验收检查点

- 绑定修复后正式保护回归sim/out/bind_scope_protection_r1已PASS37/37、rc0、293.2s，compile0Errors/0Warnings，CSV SHA256 ca7a1e50c721676be498c2c440a944de4d343de85d135ed40dc26166cc6c0550。41生产RTL同时匹配本次PASS快照及C4冻结输入；新增修改仅仿真入口/检查器/配置与文档/打包后缀。旧18/37失败仍保留作绑定范围诊断。
- 四类代表私有PASS4/4及真实rx_rm A9负控errors1/strict FAIL已独立完成。不是完整129项，也不代表每项都有绑定监视器；none保留业务scoreboard。两个打包器已补.tsv后缀，静态inventory含8/8依赖，未新生成ZIP。
- 综合：保留60模块输入上下文，仅分别映射tx_rm/stats_regs的CHECK -assert均通过（out/c4_selected_abc_repro_20261012_r1，rc0/20.266s）。逐模块推广时第五个参数化mac_rx_if出现45个结构问题（out/c4_permodule_abc_repro_20261012_r1，rc1/14.172s），故逐模块调用尚不能作为修复。新全新进程单MAC对照排队/运行；没有顶层native或综合后业务PASS。
- RX8KiB仅独立helper通过，生产接线、完整GMII管理业务及完整129回归仍开放。账号五小时剩余约26%，按§0.2第6条的资源规则减少新增派发，优先脚本运行与现有疑难诊断；未使用重置卡。

### 0.7 2026-10-12 02:41 接续运行入口

- 当前源码完整129回归已启动：sim/out/bind_scope_full129_r1，created_local02:31:55，统一工具session97293；本检查点已完成36/129，其中PASS=36、非PASS=0，当前项T12fg；尚未完成整轮验收，等待最终rc/CSV/metadata。T01已PASS/336.7s，其长段是ALIVE计时检查，不是卡死。期间不并行启动重型综合或第二个Questa会话。
- 同一个失败MAC在全新eLinx进程、相同60模块输入下单独ABC实际rc0/13.375s，前后CHECK -assert无Warning（out/c4_single_mac_abc_repro_20261012_r1）。同进程逐模块方案仍失败；只能据此把共享进程状态列为方向，未定论具体厂商根因。私有新进程逐模块runner已准备于out/c4_fresh_process_mapping_20261012_r1；root静态核对60模块/11blackbox/49逻辑模块及冻结输入哈希通过（ROOT_STATIC_REVIEW.json），修正模块end截取、copy选择上下文和端口声明匹配；当前runner SHA256 c9b07a3da596285acf8b3137dca63df1cde488748a4c7ba11de21276882471db。尚未启动该runner，模块导出流须先以失败MAC实跑确认，再做49模块及组装后CHECK/native/mapped业务。
- 长回归新发现：T23/T23g严格FAIL，均为A6 free-of-free blk15；原TB持续force pb_free1/id15而未分配对应普通消息，虽业务打印PASS仍必须判FAIL。源码与原始日志诊断见out/t23_legal_ownership_fix_20261012_r1/ROOT_FAILURE_DIAGNOSIS.json。Luna仅准备真实普通消息+公开MSG_RD碰撞的私有TB修复，未合入、未仿真；保留A6和两次碰撞要求，完整129继续收集其余问题。此前“非PASS=0”为02:41历史检查点，已被本条后续结果更新。
- 本次共享额度复核五小时已用87%、剩余13%；按§0.2第6条仅保留当前单项修复派发及脚本长回归，不新增探索任务、不使用重置卡。综合小例尚未排队启动，先处理当前回归失败并等待重型工具释放。
- 最新可宣称：正式37保护PASS、四类代表PASS、A9实际负控有效、RX8KiB独立helperPASS。不能宣称：完整129已过、顶层native已过、8KiB TX/RX生产链路或完整615A已完成。

### 0.8 2026-10-12 02:58 长回归与修复接续

- 统一工具session97293仍运行；最新完成72/129、PASS=70，已知严格FAIL仅T23/T23g，当前T27（合法BAG全档长场景，日志有持续仿真时间/收帧推进）。本次完整回归尚未结束，不可标PASS129。
- T23私有候选已完成源码审查修正：真实采样端口6/7分配与公开MSG_RD；碰撞当拍两活动owner互异且已分配，允许后续合法块号复用；禁用SAP负例映射port5；保留SN2/SN3连续wire及原合法IFG，独立host线程安排两次碰撞，实际SAP握手逐字节/两次EOP检查。候选SHA256 4c7e64b17748558163562e44f3f37f4b742c2cd28fac2fef1f70a81c8ec18f64。ROOT_CANDIDATE_REVIEW.json冻结302个文件至out/t23_legal_ownership_fix_20261012_r1/validation_workspace；生产TB未改、候选尚未仿真。
- 受限串行接续已实际启动：工具session26910，queue PID39932，当前WAITING_FOR_FULL129_OWNER_EXIT；持有原长回归owner PID23236的进程句柄等待其退出。截止2026-10-12T05:26:50.3524566+08:00。仅在整轮129完成且无T23/T23g之外新失败时，核对冻结哈希后运行私有T23/T23g；失败停止并保留日志，成功也须root审查后才可合入。不会并行启动第二个Questa、不会自动合入生产或启动综合。状态见该目录queue_status.json，原full129失败记录保留。
- A6源码覆盖复审发现未接入free_reasm且同拍分配同ID时屏蔽free-of-free；已在sim/README.md和ROOT_A6_SCOPE_REVIEW.json记录边界。当前完整回归仍使用原冻结检查器，未临时改判据；这些边界需后续独立正负控补齐，不能以当前A6启用或回归结果冒充完整所有权证明。

- A6补齐私有候选已准备：out/a6_release_coverage_fix_20261012_r1，新增free_reasm/ID观测并移除同拍分配对陈旧释放的屏蔽，active/保留binder同步候选；配有合法正控和3个故意违规负控，对比旧/新monitor计数。仅PREPARED，未编译/未仿真/未合入；TB直接驱动checker输入，不能替代真实pool/top证明。必须先实际正负控，再实际binder激活及受影响保护回归。原full129和T23串行队列输入均未修改。

### 0.9 2026-10-12 07:27 接续核验（覆盖§0.8运行状态）

- 原full129已于03:55:28结束，工具session97293实际rc1；metadata为129完成/127 PASS/2 FAIL，wall5012.3s，compile rc0/0Errors/0Warnings。失败仅T23/T23g；长场景T27/T34均通过。证据sim/out/bind_scope_full129_r1；这是一轮完整执行且失败的回归，不能写129/129 PASS。
- T23队列session26910已实际rc1结束，03:55:54状态STOPPED_REVIEW_REQUIRED；私有r1 T23/T23g分别errors22/23，无生产合入。日志首个失败是sample6未收到消息；源码核对发现初始VL误映射SAP5而非sample6。已准备out/t23_legal_ownership_fix_20261012_r2，仅修初始映射并补两个rx_error=0连接；302文件冻结，候选SHA d57e48bfb044e316d73495c727e1938b33f2f88dc46aa2a79ae47025845b1a86，尚待仿真。
- 上轮自动审批因额度耗尽未执行写入；07:22读取账号ordinaryUsageAllowed=true，五小时used2%，额度已恢复，未使用重置卡。历史任务已自行结束，无需重启长回归。
- 本轮Luna分工：A6私有单元runner修复及正负控实际执行；fresh-process mapping runner只读审查。仿真/重综合仍串行；生产RTL不因这些私有诊断改变。
### 0.10 2026-10-12 07:27 修复定向结果

- T23 r2真实Questa严格2/2 PASS，rc0、13.4s，compile及两个仿真均0Errors/0Warnings；每个模式实际2次真实PB1/SAP归还碰撞、2个完整8B载荷流、禁用SAP R_SAP一次，最终块池FFC0。允许已释放块后续合法复用（IF_MODE0 SAP blocks8,6；IF_MODE1 blocks8,9）。证据out/t23_legal_ownership_fix_20261012_r2/validation_workspace/sim/out/t23_legal_r2。root核对生产旧SHA与候选SHA后仅合入sim/tb/tb_t23_sap_min.v，详情INTEGRATION.json。不能把旧127/129与此次2/2拼成同版本129/129。
- A6单元正负控在批准启动方式下实际PASS：runs/20261012T072722_40ee95f8，compile/positive/negative均rc0且0Errors/0Warnings；合法errors0/旧0，故意3违规errors3/旧0，诊断严格匹配两次free-of-free6、一次two-frees6。仅unit controls，真实binder/top保护仍待验证，候选未合入。首次沙箱WinError623保留于072543_b0aa073d，不是工具已损坏。
- fresh-process MAC r2实际native rc0且导出单module，但runner接口判据失败；根因module_interface误把cell内LUT参数计为模块接口，正在修复作用域识别。未认定整机映射通过，原失败保留。
### 0.11 2026-10-12 07:34 映射诊断接续

- MAC r3通过fresh process映射、前后CHECK assert、单module导出及48条真实参数/端口完整匹配；runner仅subset状态PARTIAL_ONLY mapped1/49，不能称整机PASS。证据out/c4_fresh_process_mapping_mac_trial_20261012_r3；runner SHA93f6d5625e531e73f07937f3dfa4c6b39244f8a9e12bd9d7c241b8d117c3a0d1。原误判r2保留；接口解析仅排除cell/process内部声明，不忽略真正模块参数或端口变化。
- 完整49逻辑模块逐个新进程映射已启动，工具session29979，out/c4_fresh_process_mapping_all_20261012_r1，单module120s超时；重综合/仿真不并行。全部导出后还需49+11黑盒合并CHECK及native后续映射/业务验证，不能先称通过。
- RX8KiB只读接口审查见out/rx8k_integration_review_20261012_r1.md；按当前8192应用字节坐标加42B头需要5个2KiB目标块（4块最多8150应用字节），现helper仅4块且生产单块copy/checksum/11bit聚合长度/host单块回收都需同步修改。该报告是方案建议，新增host aperture和五块helper未实现，8KiB赛题确切语义仍须据原题确认，不能视为新增实现证据。
### 0.12 2026-10-12 07:49 当前接续状态

- 完整fresh-process映射r2已实际49/49导出、session55810 rc0，合并49逻辑+11原黑盒共60module，whole_postabc.il 160401355B、SHA32529047f7d06697fd3defe5d20cb1b31ee7588d6eecea7d919023f4330bd097。随后native whole CHECK -assert -noinit实际PASS、rc0/12.813s/无Warning/Error。证据out/c4_fresh_postmap_20261012_r1/runs/postmap_20261012_074730_454037/whole_check；不是仅各模块检查。69个未使用COUT声明补齐仍为诊断IL变更，未宣称生产RTL等价。
- native后处理首轮session31321已rc1结束；cells_map/io_map CHECK通过，但merge2lcell后插入CHECK报95712个used-no-driver。该CHECK位于dffeas临时伪类型与恢复之间，正审查插桩位置并重新验证；不是结构问题已豁免。原失败/无效产物保留，无完成VQM/器件利用率/映射后业务PASS，不得把旧C4拒收网表作为结果。新runner SHA7dcc412f8773578c11774d88aadd86348ab2425369fac40aebdbf29c2c1c1826。
- A6真实pool+named full binder已在runs/20261012T075229_909ea606实际通过严格正负控，runner rc0：compile/positive rc0且0Errors/0Warnings；candidate负控rc1、唯一预期fatal、恰好一条A6 free-of-free诊断和errors1；legacy同刺激rc1、唯一预期fatal、errors0且无A6诊断。首轮目录/+acc问题及第二轮onfinish退出传播失败均保留；最终runner SHAe8c9cde5944f51282c12ed6bfbc38768646186b6a5ed7dbea4423a85aa382938。47项私有保护回归已启动，session60519，out/a6_bind_activation_20261012_r1/validation_workspace/sim/out/a6_pool_protection_r1；仍未合入生产A6，不能把绑定正负控当作完整资源所有权证明。
- 五目标块scatter helper已真实独立Questa PASS，compile/sim rc0且0Errors/0Warnings，唯一TB_RESULT=PASS；证据out/rx8k_mover5_20261012_r1/runs/20261011T234710Z_3580f759575b481c9faa49ef1def7d33，RTL SHA2a8348a5c44c35a09902805c8c7a23897841427b636ad252984e0e51b3c3ce27。覆盖8150/8151/8192逻辑容量及第5目标边界/异常输入和既有握手/取消/reset；多job的2048B是源块边界测试，不是合法Ethernet片或生产8KiB端到端。生产41RTL仍与C4冻结一致；RX上限仍2006B。
- A6补强已在47/47保护PASS、实际session60519 rc0、354.7s后合入三个checker/binder文件；freeze_regress核验307输入哈希及56证据哈希，compile为0Errors/0Warnings、47仿真均0Errors；21个用例存在未连接端口等Warning，当前regress判据只要求Errors=0，不能称零警告。已逐项复核并记录out/a6_checker_integration_20261012_r1/ROOT_WARNING_ACCEPTANCE.json：当前配置下为未用输出/参数关闭输入/T60完整向量的数组预留长度，没有发现告警对应活动悬空输入；146个现存TB/向量文件匹配冻结哈希，原告警保留。生产41RTL与C4保持一致，全部47个RTL快照文件亦未变。合入备份、原始绑定正负控及保护证据见out/a6_checker_integration_20261012_r1/integration.json。原full129仍保留127/129、rc1，不能拼接成新版本129/129；本次合入不改变该历史结论。
- 修正稳定类型边界后的postmap（session43481，runs/postmap_20261012_080208_585471）已FAIL_STOP/rc1：whole及稳定类型后处理CHECK全通过，Warning/ERROR=0，但Verilog导出达到48个module marker后触发600s时限，未完成最终VQM/IL。原失败保留。依据ROOT_EXPORT_BUDGET_REVIEW.json仅增加postmap预算至900s并在VQM前保存诊断检查点，所有结构/警告/完成/最终产物判据保留；runner SHA72111f2380c16f578a400233c673a7db2a0006f9deb3d5fa4d2a8c4c2dc3ec08，session15288已启动新独立重跑。业务接续审查位于out/c4_diagnostic_mapped_business_20261012_r1/ACCEPTANCE_PLAN.md，不伪造旧C4综合状态。
- 此次postmap导出前稳定类型下的CHECK均已通过；原95712条无驱动告警没有在恢复类型后的检查复现，支持检查位置错误这一诊断。导出前native STAT（ROOT_PREEXPORT_STAT.json）层次总计305929cells，其中207630 stratix_lcell、97191 dffeas、1108 stratix_ram_block；只是该诊断映射表示的单元计数，不是器件利用率/fit/时序验收，尚待完整导出及业务验证。
- 8k语义与生命周期复核见out/rx8k_scope_and_lifecycle_review_20261012_r1.md：本地2005 P7排队消息明确application data，UDP SAP和TFTP DATA块是不同条款；不把三者混成单一限制。生产重组已逐job复制并归还源块；首片缺失时暂停复制、共享10块源池耗尽和恢复是后续五目标链接入需处理的风险，未宣称已实现。

### 0.13 2026-10-12 本轮执行摘要（持续更新）

- **已完成并合入**：A6新增重组归还观测、移除陈旧归还屏蔽；实际绑定正负控通过，47项私有保护回归47/47 PASS、rc0、354.7s。21个用例的Warning已按冻结源码/向量逐项复核，不能表述为整轮零Warning。备份与验收见out/a6_checker_integration_20261012_r1。
- **已定位并跨过**：49模块新进程ABC映射与合并整体CHECK通过；native后处理稳定类型CHECK通过。此前95712条无驱动是检查处于临时类型窗口所致，恢复类型后不复现。
- **已完成导出**：900s轮session15288已rc0；native后处理622.844s、无Warning/Error。证据out/c4_fresh_postmap_20261012_r1/runs/postmap_20261012_081404_241809：VQM184704345B、SHA ddfacaa22505edd71a02f733d4f39697dc18a989e32dcd4a4ae7ef50fd860536；最终IL155805585B、SHA2d0b699849110c9c6c19d5b03b16d38e548eb1ade501c1e95f5159694fec202d。状态仍为诊断导出待业务，未升级旧C4状态。
- **原始导出产物独立检查失败，已保留**：最终IL独立重新加载在35095行parser FAIL；导出前IL也在34778行失败，均为`cell`裸名称`expected_len[0]~I`缺RTLIL标识符转义，共4954处。原始VQM实际Questa编译rc2、1Error/0Warnings：38个参数化模块的转义名称与左括号之间缺空白，首个错误在第4行。session97604已结束，厂商模型编译通过，VQM失败后未进入TB/加载/业务。两个runner准备缺陷（审查字段文本/快照复制清单）已修复并保留失败记录，未改变验收判据。
- **当前私有命名修正版结构与编译已通过，加载仍失败**：`out/c4_identifier_canonicalization_20261012_r3/manifest.json`绑定原始post-VQM final IL和VQM；仅对4954个IL单元ID补转义、对38个模块及其引用统一名称。native实际rc0、22.109s，改名前后全结构CHECK通过；另以新进程重读最终canonical IL再次CHECK PASS、rc0、10.203s。独立复核`out/c4_identifier_canonicalization_review_20261012_r1`确认VQM95处名称编辑可逆变换逐字节还原原文件；IL完整cell/wire/connect/parameter及属性值多重集一致，33模块属性仅次序变化；41生产RTL仍匹配C4。r1仅rename未更新celltype导致CHECK失败的记录也保留；r2显式chtype后通过但输入为preexport，最终配对候选采用r3。实际未过滤firstpass `firstpass_T42_20261012_084626_066845`已结束（session15072 rc1）：厂商/VQM/TB编译全部rc0、0Errors/0Warnings，vsim加载rc12、429.047s、非超时，Errors1/Warnings4140612，无run0成功标记及业务结果。
- **加载根因与处理**：上述唯一Error是`vopt-14408`，Starter将建议容量5000与本设计208740 non-OEM instances的性能提示报告为可降级错误。`out/c4_warning_review_20261012_r2/ROOT_WARNING_REVIEW.json`逐条核对完整未过滤load.log：14408一次；13162四次；2685共302683次；2718共3837925次；未解释记录0。所有单元缺口按精确厂商模型/配置审核：579 RAM相关clear参数均none，206326 lcell的495参数/连接组在已连接输入0/1穷举且缺省Z时有效输出无新增X；另外11个逻辑模块实例缺口全部为未消费output。该结论不涵盖已连接网自身X/Z传播或业务正确性。本机`vopt -help Messages`明确支持`-warning 14408`及按消息限制重复打印；拟仅对这份已绑定产物执行容量提示降级与2685/2718显示次数限制，保留原始全日志、其他错误及未审警告仍阻断。旧逐警告inline状态文件膨胀至1769446588B，已准备/应用有界流式日志处理，逐原文匹配的Warning Review已接入；root修正清单实际字段unresolved_examples及capacity_errors仅含line/text两处schema匹配，且有界限制匹配字典。预检查实际通过（16个绑定文件），runner SHA782557ee32676bf20b67ab6dd6e0a18b500236f005aa259db476a40bf01d1b0d。第二次加载firstpass_T42_20261012_091512_185671（session86111）已结束rc1：厂商/VQM/TB编译均PASS、0Errors/0Warnings；实际vsim rc0、270.391s、完整加载且唯一run0标记，但日志仍有1条Error(vsim-16154)容量性能提示，故验收保持FAILED。另旧parser未识别结尾Suppressed Warnings后缀；已修正格式识别、按Warning严重性锚定、将onerror/onbreak放入真实do宏。r3 ROOT_WARNING_REVIEW.json绑定该实际失败及本机官方vsim帮助，仅新增-warning 16154，所有其他错误仍阻断。r3预检查20文件实际PASS，runner SHA28db60bf4a525db75fef2be6a91468704b4b668ac937862224bad2f41e33eaef。第三轮firstpass_T42_20261012_092325_647851（session8842）已实际rc0，READY_FOR_BUSINESS_SIMULATION_NOT_RUN；加载Errors0，容量与接口警告按绑定原文逐条审核，未审警告0，唯一FIRSTPASS_LOAD_ZERO_OK及正确top加载记录完整。Warning inventory 72是stdout与工具log两份物理记录之和，不能当工具原生告警数量；native summary见stage_metadata.json。随后独立T42业务接续已启动（session1700，1800s预算），使用相同编译库/网表和TB默认参数；原firstpass状态保持不变，当前无业务PASS。业务进程实际内存读取（Get-Process，经批准宿主环境）：vsimk PID34588，CPU70.125s，WorkingSet0.985GiB、Private1.182GiB；只是本次运行时刻快照，不是峰值或器件资源。T42业务接续脚本/验收计划已准备于out/c4_mapped_business_continuation_20261012_r1，待实际加载及新诊断审核通过后运行。
- **615A 陈旧资料已纠正**：`doc/615A_控制文件与接入设计_20261009.md`新增当前状态覆写；源码确认 client/adapter/file_rx/fetch 及 LUR parser/orchestrator 已接入，init_tx 未接入。`out/a615a_current_scope_review_20261012_r1/ROOT_SCOPE_REVIEW.json`绑定13文件及14条历史定向PASS。T57已有GMII完整文件读回；T62已有两文件编排，但LUR是直接完整SAP文件而非TFTP接收，且两文件未在编排会话释放前逐字节核验。不得把已有功能写成未实现，也不得把部分场景拼成完整615A。
- **额度接续点**：本轮账号五小时已用95%、周已用62%，按§0.2减少新派发，不使用重置卡。T42业务session1700继续自主执行，1800s超时及结果落盘由脚本负责；最近实际vsimk CPU650.890625s、Private1.166GiB、WorkingSet0.958GiB，无新失败日志，不等于业务已PASS。接续操作与禁止改动的活动文件见out/c4_mapped_business_continuation_20261012_r1/RESUME.md及RESUME_CHECKPOINT.json。T43接续已准备（out/c4_mapped_t43_continuation_20261012_r1），未运行，须等待T42结束后串行排队。
- **仍未关闭**：当前版本129项完整回归、TX/RX完整8k生产链路、完整GMII 615A流程及最终同版本网表业务。旧完整回归仍为127/129，不能拼接新定向结果冒充129/129；五块helper独立PASS不能当生产8k已完成。

### 0.14 2026-10-12 12:28 交接核验（覆盖此前运行中状态）

- **T42 业务已结束，结果是超时，未通过**：`firstpass_T42_20261012_092325_647851/business_continuation_20261012_092945_905962.json`为`FAILED_STOP`；实际stage为`TIMEOUT`、rc1，耗时1804.766s，09:59:57结束。1800s预算到期后仅终止所属进程树，taskkill rc0；本次核验原PID23000/34588均已不存在。未生成`t42_gmii.csv`，没有业务PASS或完整结束摘要。旧session1700已失效，不再等待它。
- **加载成功仍有效**：同目录原`business_status.json`保持`READY_FOR_BUSINESS_SIMULATION_NOT_RUN`，表示编译和加载通过；业务结果另存在上述continuation文件。不能把加载状态当业务通过，也不能用缺失的会话句柄猜结果。
- **当前卡点**：映射网表业务执行未完成，Starter有设计规模性能警告。原运行没有仿真时间进度，尚不能区分整体执行慢、某阶段停滞或零时间事件问题；超时不证明功能正确或错误。下一步使用已准备的100us进度版诊断，保留完整TB和判据，先建立实际仿真时间推进证据，再决定预算与修复方向。
- **完整交接**：见`doc/新对话交接_20261012.md`，包含实际证据、接续命令、版本哈希、剩余工作与禁止误读的历史记录。本次仅核验并交接，未启动新的长仿真；T43仍未运行。
- **仍开放四项**：当前版本完整129回归、TX/RX完整8KiB生产链路、完整选定GMII 615A控制流程、最终同版本网表业务验证。此前额度95%是09时历史快照，不能作为此刻额度。

### 0.15 2026-10-12 13:56 细粒度诊断及 Tcl 修复

- 100us进度版已在13:26:13因诊断切换主动停止：`business_continuation_20261012_131209_769330.json`实际stage FAILED、rc1、836.907s、非超时，没有完成100us标记。宿主按所属PID26992进程树终止成功；原日志与终止证据保留在`out/c4_t42_resume_diagnostic_20261012_r1`。
- finer r1实际于13:35:16结束：stage FAILED、rc1、312.328s、Errors1、非超时；原始宏执行`run 0 ns`后在proc的`set actual_time [now]`报`invalid command name "now"`。本次是诊断脚本失败，不能当RTL业务失败或停滞结论。stage预算900s；continuation继承的600s字段陈旧，按原始stage/argv认定。
- 最小Tcl仿真`out/c4_t42_time_probe_20261012_r2/RESULT.json`已PASS，验证`$::Now`带单位时间、0/1/4/8/56/100/1000ns完成标记及未来目标拒绝。r1 probe的`puts`只写stdout导致transcript判据失败，r2改为`echo`，两版证据均保留。
- 新runner/plan准备于`out/c4_mapped_t42_fine_progress_20261012_r2`，仅修正时间读取及实际预算元数据；保留完整T42激励、CSV/指标/警告及验收门。准备状态不等于实际业务通过。接续预算900s，原firstpass及r1 runner/plan全部冻结。T43尚未实际运行。

### 0.16 2026-10-12 14:47 T42/T43细粒度终态与RX五块接口接续

- **T42 fine r2实际超时**：`firstpass_T42_20261012_092325_647851/business_continuation_20261012_135849_468155.json`为FAILED_STOP；stage TIMEOUT、rc1、预算900s、实际934.515s，14:14:36结束。最后完成1us，没有完成10us；没有独立T42 PASS、CSV或完整结束Errors/Warnings摘要。终态封存于`out/c4_t42_resume_diagnostic_20261012_r1/fine_r2_terminal_review.json`。原加载PASS仍有效，但不是业务PASS。
- **T43独立编译及加载PASS**：`firstpass_T43_20261012_141723_521623`全部编译阶段PASS；load rc0、304.891s，14:24:01结束，Errors0/Warnings36/Suppressed Warnings4140578，唯一FIRSTPASS_LOAD_ZERO_OK、正确top、未审核警告0。绑定正确r3警告审核及冻结C4 canonical产物。
- **T43 fine r2实际超时**：`business_continuation_20261012_142805_882717.json`为FAILED_STOP；stage TIMEOUT、rc1、预算900s、实际938.109s，14:43:50结束。完成0/1/4/8/56/100/1000ns后，每1us连续完成至8us；1–8us每步约90.55–95.02墙钟秒，没有完成9us，无业务PASS和结束摘要。这提供严重运行缓慢的实际证据，不能证明Starter容量限制为唯一原因，也不能排除后续停滞。超时终止的RPC/EOF/Fatal不作为此前RTL根因。
- **终态和进程**：session32562已收集rc1；按明确名称及PID25700查询无活动重型工具，释放唯一Questa槽。终态、逐步墙钟和原始日志/runner/plan哈希封存于`out/c4_t43_resume_diagnostic_20261012_r1/fine_r2_terminal_review.json`。C4仍是分模块映射后组装的诊断零延迟网表，不是生产单遍综合或形式等价/fit/STA结果。
- **RX8KiB接续**：两个基础模块的五块checksum/原子pool实现正在收集交付，测试尚未运行。跨模块生产合同与接线继续推进；默认单块行为保留，完整8192B应用加42B头需五个2KiB物理块。未完成的新工作不能记PASS。

### 0.17 2026-10-12 18:46 RX8KiB生产GMII验收通过（历史检查点；当前见§0.18–0.19）

- **Step 1实际PASS**：`out/rx8k_acceptance_20261012_r8`绑定448项输入；同一冻结版本units 9/9（232 cases）、生产8192B smoke 1/1及完整GMII矩阵28/28均rc0、Errors0/Warnings0，运行前后输入不变。独立审计见`STEP1_AUDIT.json`，逐项核对运行输出SHA、原生摘要、case终态及当前生产RTL哈希。
- **公开链路证据**：`AFDX_top`参数IF_MODE2/FCS_MODE2/RX_REASM_CHAIN_BLOCKS5，其他参数为生产默认；公开PORT_DESC、0x8580..0x858F链元数据及PMEM逐字节读回167755字节，2378119 checks。覆盖2006/2007/8150/8151/8191/8192及顺序/tail-first/shuffle、checksum拒收/显式策略关闭、重叠回收、块池耗尽后稀疏链恢复、disable/reset及新数据报恢复。copy154接受/153完成/1reset中止，checker29接受/28完成/1reset中止。
- **修复与证据保护**：旧r1–r7包及失败日志保留；修正SAP参考模块命名、测试可选端口Z连接和监视器握手/初始复位边界，去除未用于外部探测的全量+acc，补全顶层未使用SAP输出端口连接。未放宽case、载荷、资源或Warning判据。
- **默认兼容回归运行中**：`sim/out/rx8k_r8_legacy_compat_20261012_r1`，选取16项公共存储/复位、端口、块池、SAP、legacy重组/checksum及争用/短帧回归。结果须以其实际终态为准，不与独立units拼成完整129项PASS。
- **计划仍未完成**：本次仅关闭RX8KiB opt-in生产GMII验收门槛。完整TX8KiB、选定615A控制会话、当前全量回归、规模指标、同版本综合与网表业务及最终可复现交付仍需完成。§0.16的T42/T43历史业务TIMEOUT继续保留，旧C4不覆盖本轮RTL。

### 0.18 2026-10-12 19:37 RX当前版本、兼容及源清单闭环

- **r11实际RX PASS**：`out/rx8k_acceptance_20261012_r11`冻结451项输入；units9/9、232 cases，8192B smoke，完整GMII28/28、167755B公开读回、2378119 checks，均rc0、Errors0/Warnings0。`STEP1_AUDIT.json`绑定全部输入、输出及原始终态，copy154/153/1 reset中止、checksum29/28/1 reset中止与原判据一致。
- **同版本默认兼容PASS**：`sim/out/rx8k_legacy_compat_20261012_r4`选定16项全PASS、264.3s、rc0；编译及16个原始日志Errors0/Warnings0。r11下`COMPATIBILITY_AUDIT.json`核对174项共同输入。旧兼容r1的checksum展开失败、r2定向PASS、r3的旧共同快照PASS均保留；不拼成当前完整回归。
- **前端修复与复验**：eLinx r1在重组器动态内存切片报错；r2越过该处后，在metadata末成员的不可选第六块切片报越界。两模块改为固定切片函数，非法索引保留X；r10/r11各自重验全部RX场景。`out/rx8k_sourceflow_20261012_r1/frontend_r3`从r11冻结45源执行默认chain1和chain5前端，均rc0/零警告，耗时13.063/24.703s。它是read_verilog/hierarchy/stat诊断，不是完整综合PASS。
- **实际入口同步**：生产清单45项已同步3个eLinx脚本、2个QSF；回归复制并绑定`.f`，native准备只接受回归快照内清单及匹配哈希。`audit_sources.py`实际PASS；历史GUI runs/失败输入未覆盖。
- **边界**：生产默认`RX_REASM_CHAIN_BLOCKS=1`保留，8192B验收配置为IF_MODE2/FCS_MODE2/chain5，其余参数生产默认。r11不含随后新增的独立TX模块/T80；当前完整候选、TX整机、615A控制流程、规模指标、完整综合及网表业务仍开放，T42/T43历史TIMEOUT不重跑、不改写。

### 0.19 2026-10-12 19:37 TX分片构帧及正式T80入口

- **实现**：新增`rtl/tx/tx_fragment_frame_builder.v`，接收最多8192B应用、四个稀疏TX块、完整IP载荷偏移及头字段。第一片计算整个UDP的checksum，非末片IP载荷1472B按8B对齐，末片最多1479B；UDP头仅在第一片，逐片IP checksum/ID/MF/offset、双网SMAC、pad/SN均显式生成。整片数据先暂存再输出，避免PMEM延迟引起GMII帧内空拍；取消需排空已接受的PMEM读。该模块尚未接入`AFDX_top`，没有替代生产TX单块路径。
- **独立实跑**：`out/tx_fragment_builder_20261012_r2`实际PASS，30条黄金消息/76个分片，每片背压及双网GMII各跑一次，加4类非法描述符、在途取消、取消后完整黄金帧恢复，共158 cases、1371315 checks；编译/仿真rc0、Errors0/Warnings0，输入前后不变。长度1/2/8/17/1471/1472/2007/2048/2049/2943/2944/4096/6144/8191/8192，checksum开/关及计算值零时线上FFFF均覆盖。r1测试台同拍复位释放导致首个ready检查误报，失败保留；r2等待复位门控稳定并强化恢复载荷对账，未削弱断言。
- **正式回归入口PASS**：T80已登记`sim/tests.manifest`、编译源和黄金生成入口，绑定审计为mac_tx_if profile。`sim/out/tx_fragment_builder_t80_20261012_r1`1/1 PASS、17s、rc0，158 cases/76 fragments/1371315 checks，加载了正式MAC binder，Errors0/Warnings0。当前manifest变为130项，全量未运行。
- **审计和前端**：`out/tx_fragment_builder_20261012_r2/BUILDER_AUDIT.json`核对独立/正式结果、共同RTL及黄金源SHA、原始摘要和binder加载；同目录frontend read_verilog/hierarchy/proc/check/stat实际rc0、零警告。该静态诊断未做完整综合/映射。
- **下一实现门槛**：完成TX整消息预留/公开host写入契约、14位长度、消息块链与队列节点区分、逐片真实BAG调度/SN/ID及最终消费者后的块释放，再运行生产顶层GMII消息重组/逐字节对账。直接构帧/MAC PASS不能记为TX8KiB生产通过。外部取消已开始的GMII帧前必须先完成该帧；此调度合同待顶层实现验证。

### 0.20 2026-10-12 TX8KiB生产接入与严格定向回归

- **生产接入已实跑**：`TX_MESSAGE_CHAIN_BLOCKS=4`选择完整消息store/launch/fragment builder，最多四个2KiB TX块。新增公开0x8590–0x8593预留、块列表、所有权、取消窗口，14位完整长度和独立端口FIFO；每片真实调度/BAG/SN，消息内IP ID保持，末片交给下游后整链回收。默认TX1旧路径保留；详细合同在`doc/接口契约.md`的TX接口增量。
- **最新冻结定向PASS**：`sim/out/tx8k_production_20261012_r4`14/14、197.5s、rc0，编译及14个原始日志Errors0/Warnings0。清单T04/T04g/T22/T22g/T22a/T24/T24g/T25/T25g/T43/T31/T31g/T81/T82。T81为14 cases/1013 checks；T82为18消息、每网50帧、59116B应用、259946 checks，完整A/B GMII逐字节/FCS及公开资源、统计、负例恢复均核对。`TX_PRODUCTION_AUDIT.json`复核快照全部哈希并独立解析黄金帧、IP分片重组及UDP校验，不只读取wrapper PASS。当前manifest为132项，全量尚未运行。
- **修复及边界覆盖**：首片统计减去8B UDP头，SOF长度FIFO与实际MAC完成事件对应；reserve拒绝结果改为保持型并设置ERR.ACC；失败申请解除host build lock，管理接管与同拍reserve互斥；有排队消息时类型切换拒绝，避免孤立队列/在途链；首片在途时完整消息描述符仍公开可见。T81增加队列类型切换、在途切换、非法端口/type/SAP长消息；T82增加公开非法长度、高位、重复reserve、错误commit、延后读结果、cancel恢复及逐消息TX_FRAME/TX_BYTE核对。
- **旧运行保留**：r1两项PASS是初始生产接入；r2的14项wrapper PASS含旧TB未接端口/向量数组溢出warning，严格审计拒绝，不能写零warning。TB显式接错误输入0、PMEM写byte enable、scheduler可选端口，并把管理向量容器扩大至4096以容纳2101词；没有过滤warning或降低判据。r3严格14/14通过但前端首次拒绝store嵌套动态索引；r4改固定选择函数、隔离descriptor读索引并重新实跑。各快照和原始失败日志保留。
- **工具入口**：生产清单49项同步三个eLinx脚本、两个QSF；`out/tx8k_sourceflow_20261012_r1/audit_sources.py`实际49源一致PASS。`frontend_r1`的read_verilog错误保留；`frontend_r2`从r4冻结49源执行默认TX1/RX1、TX4/RX5的read_verilog/hierarchy/stat及独立store proc/check/stat，三项rc0/零warning PASS，耗时15.422/23.328/9.969s。这不是完整综合/网表业务PASS。
- **时延差距实测**：T82合法1ms BAG下，8192B六片提交调用至A/B末字节为6.069592ms（checksum关）/6.167880ms（开）。这是含主机调用等待的上界口径，非精确准入沿；六片跨至少五个BAG间隔，当前配置不能证明完整消息<=2ms。该问题进入R08/P10开放项，不改BAG、不改测量定义来消除失败。
- **同版本RX复验PASS**：`out/txrx8k_acceptance_20261012_r2`冻结462输入，与r4的206项共同运行输入哈希一致（COMMON_REVISION_AUDIT.json）；units9/9、232 cases、8192B smoke、完整GMII28/28，167755B公开读回/2378119 checks，均rc0/零warning，`STEP1_AUDIT.json`对账快照、全部输出与copy154/153/1 reset中止、checksum29/28/1 reset中止。默认单块兼容`sim/out/txrx8k_legacy_compat_20261012_r1`16/16 PASS、303.4s、rc0，编译及每项原始日志零warning；同包`COMPATIBILITY_AUDIT.json`对账180项共同输入。T01完整ALIVE测试228s正常，未缩短长时覆盖；两组定向不能拼成132/132。
- **仍开放**：公开cancel只取消开放writer，已提交帧靠reset清除；内部非法builder metadata故障尚无整机恢复证据。TX4与RX5同时活动/管理争用、完整615A控制流程、规模指标、132项全回归、完整综合/当前网表业务、最终复现包均未完成。当前证据是同版两个方向分别实跑，不能称同时双向8KiB压力已过；后续RTL修改需新候选。T42/T43旧C4 mapped业务TIMEOUT保持，当前RTL T43 PASS不改写历史mapped终态。

### 0.21 2026-10-12 P05 完整 LUR 传输、文件保持与恢复

当前生产源仍49项、manifest仍132项。根目录已修改P05 RTL/TB/黄金输入，不再与§0.20的TX r4/RX r2共同候选相同；旧TX/RX结果只覆盖各自冻结版本。goal“完成计划书”继续active。

- **文件保持检查点**：`sim/out/a615a_file_hold_20261012_r4`3/3 PASS、64.2s、rc0、零Errors/Warnings；T58为184checks，T62为1603checks、1560B公开同会话读回、两次确认/一次保持文件中止。`FILE_HOLD_AUDIT.json`核对499冻结输入。r1未声明变量、r2旧帧数/标题误判、r3错误busy地址的失败保留。此检查点的客户端线上格式仍有后续发现的缺陷，不作为完整TFTP报文正确的证明。
- **完整控制文件接入**：AC87[1:0]=3启用显式配置端点`TARGET.LUR`的WRQ octet/no-options。服务器去TFTP头、按512B块组装完整控制文件，再经同步LOAD字读口pump给parser一次整文件SOP/EOP；解析/结果消费期间保持图像，拒绝替换请求，末块重复补ACK，错TID不改变图像。完整接口、容量与恢复见接口契约顶部；文件名为项目目标标识，非标准固定名称。
- **真实客户端发送缺陷已定位并修复**：`mgmt_bidx_mux`原把组合读客户端套用SNMP同步BRAM的下一字节预取，导致首字节丢失、尾字节X和UDP checksum污染。修复为当前客户端索引；T57/T62恢复真实PHY偏移。`a615a_lur_transport_20261012_r3`5/5 PASS及独立审计确认两网各13帧完整载荷、前导/SFD、FCS、IP/UDP校验和。r1/r2原始失败与X帧保留；旧T57/T62偏移PASS不能继续当正确线格式证据。
- **跨所有权中止修复**：编排器进入终态当拍busy下降，顶层原丢失file_ack/job_abort；两种脉冲均独立路由。DONE/FAILED可无reset start，保持策略在start锁存，文件确认前不提前统计/取下一文件。控制文件中止还须保持已被管理TX复制器接管的稳定ACK/ERROR直到消费，否则可卡住MT_BYTE。
- **当前严格验证PASS**：`sim/out/a615a_lur_transport_20261012_r7`同版14/14 PASS、230.3s、rc0，编译与14项原始日志Errors0/Warnings0，冻结501项输入。清单T16/T16u/T25/T25g/T45/T55/T57/T62/T58/T63/T75/T76/T77/T78；T62为1651checks、每网26帧、533B两块LUR及1560B数据文件公开读回、两次确认/一次保持文件中止、5控制异常恢复场景。`FILE_HOLD_AUDIT.json`审核全部冻结输入/rc/唯一PASS/绑定、完整双网PHY前导/FCS/IP/UDP校验和、精确RRQ/ACK/ERROR载荷及目的TID，包括响应复制期间中止后的恢复；捕获及审计器哈希绑定。r5/r6的wrapper14/14含T16/T16u旧端口/向量warning，严格拒绝，失败记录保留；r7补齐端口、扩容向量后整组重跑，未拼接。
- **同候选前端PASS**：`out/a615a_lur_frontend_20261012_r1`从r7冻结49源，默认TX1/RX1与TX4/RX5 read_verilog/hierarchy/stat、独立store/orchestrator proc/check均rc0/零warning，14.640/23.860/10.156/0.437s。全部49生产RTL与当前根目录逐项哈希一致。本轮未再改RTL；这仍不是完整综合或TX4/RX5同时业务PASS。当前没有活动重型工具。
- **仍开放**：init_tx未接top，LUI/LUS与完整选定加/卸载仍需实现及依据；LUS三字节进度/版次相关语义保持未决。当前是完整LUR文件传输和受限取件流程，不能关闭P05整个阶段。后续P09共存、P10规模/指标/完整132项、P11同候选完整综合/网表业务、P12可复现包均需推进；旧C4 T42/T43 mapped TIMEOUT保留、不重跑。

### 0.22 2026-10-12 P09 TX 构帧失败整链回收

当前49生产源、manifest132项、goal“完成计划书”仍active。新候选为`sim/out/tx_error_recovery_20261012_r4`；§0.20 TX/RX与§0.21 LUR旧结果保留，不能替代本轮候选验证。

- **真实根因与修复**：launch遇builder error回IDLE，旧store只有成功fragment_done回收，非末片会遗留在途队头/整链，末片虽已出队仍遗留载荷块。新增fragment_error，按准入时记录的message_port/message_dequeued区分两种状态；失败只回收对应消息，非末片移除其FIFO队头，末片不再次出队。将同拍移除结果折入捕获commit/take的队列更新，保留后继和请求；申请仅使用旧free_map，不能同拍重用回收块。非法/重复事件不释放；error优先于done。
- **SN生命周期补齐**：原SN只在done提交，失败会留下挂起snapshot，下一片申请触发协议错误。新增cancel，按当前VL释放挂起且不消耗SN；同拍cancel/request重新建立唯一挂起，cancel优先于commit。四个实际例化已显式接线，T02补取消/同拍申请/错误VL/成功恢复用例，旧SN回绕与随机2000事件保持。
- **公开合同**：0x8594只读`{bad_completion_count,failed_message_count}`，各16位饱和计数、rst_sync清零；默认chain1读0。低16位只计合法构帧失败整消息回收，高16位计非法成功/失败事件。0x8593仍只取消开放writer。已发送的前序片不会撤回；失败且未SOF的片不计TX_FRAME/TX_BYTE，已成功前序片仍按实际帧/应用字节计数。详细见接口契约TX增量。
- **严格冻结验证**：r4为23/23 PASS、399.8s、rc0，508冻结输入，编译和全部原始日志Errors0/Warnings0。清单T02/T03/T04/T04g/T22/T22g/T22a/T16/T16u/T24/T24g/T25/T25g/T43/T31/T31g/T57/T62/T58/T63/T80/T81/T82。T81为25cases/10074checks，逐拍块守恒、FIFO节点唯一/可达/尾部及所有者检查；覆盖非末/末片、非法/重复事件、同拍commit执行与捕获/take/reserve、满队列与后继、error/done竞争。
- **整机恢复与实际PHY审计**：T82保留原18消息/每网50帧/59116B，增加四种故障（8192B首片header拒绝、8192B后续非末片reader拒绝、2048B末片reader拒绝、32B单末片header拒绝），各保留两条排队后继；恢复每网10帧/3188B，合计每网60帧/62304B、275072checks。故障选择只用内部launch时机，资源/descriptor/统计判决走公开host，线上逐字节走外部黄金。`TX_PRODUCTION_AUDIT.json`核对全部冻结哈希/rc/日志/绑定、实际A/B捕获与完整黄金，独立复算前导/SFD、FCS、IP与完整UDP校验和/ID/MF/SN/载荷；校验器拒绝六种负控制（内容损坏、缺帧、多帧、换序、截帧、内容损坏但FCS重算正确）。部分成功前序片未冒充整消息完成。
- **同候选P05保护**：同r4的`FILE_HOLD_AUDIT.json`通过，T62为1651checks、每网26完整TFTP控制/取件帧、533B两块LUR、1560B公开读回及5控制恢复场景；不是整套615A验收。T16u私有TFTP LOAD/UPLOAD标签仍不代表标准615A卸载。
- **前端与当前源绑定**：`out/tx_error_frontend_20261012_r1`从r4冻结49源，默认TX1/RX1、TX4/RX5 read_verilog/hierarchy/stat，独立store/orchestrator proc/check均rc0/零warning，耗时14.813/24.468/10.672/0.469s。`ROOT_CURRENT_RUNTIME_AUDIT.json`核对61项根目录运行输入与r4，含49生产RTL；本轮末尾仅更新文档，没有再改RTL。不是完整综合，不是同时TX4/RX5动态业务通过。
- **早期证据**：r1 T81为25cases/2071checks；r2 T02/T81 2/2 PASS并加强FIFO守恒；r3六项PASS与四种整机故障恢复，但尚无实际PHY输出文件和正式审计。r4为完整捕获/正式审计候选；这些不同验证输入不能拼成全manifest。
- **后续仍开放**：P09 TX4/RX5同时活动、管理争用、disable/重新使能与其他异常；P05 init_tx/LUI/LUS/完整选定加卸载；P10 128活动TX/4096RX、完整132项、指标；P11完整综合/当前网表业务；P12复现包。合法1ms BAG下8192B六片完整消息约6.07..6.17ms，2ms差距保持OPEN。旧C4 mapped T42/T43 TIMEOUT保留、不重跑。本检查点无活动重型工具，所有session终态已收集。

## 1. 赛方边界与项目子集

| 项目 | 当前约束/选择 | 证据与边界 |
|---|---|---|
| MAC 接口 | 组委会确认 GMII；A/B 双网 8 bit 字节口；125 MHz 是项目仿真时钟选择 | 赛方问答明确 GMII；未单独规定时钟频率或 100 Mbps 字节节拍；其他节拍是项目仿真模式 |
| 仿真环境 | 参赛者自建激励、回环、检查器和参考模型 | 赛方不提供参考仿真环境；Python 黄金模型只作辅助，最终以 RTL/Questa 波形和日志为准 |
| 主体目标 | AFDX End System，不是交换机或真实 PHY 产品 | 设计书与赛题边界 |
| SNMP/615A/RTC | 采用项目限定子集；当前已有 SAP 最小 handoff，完整协议仍是 OPEN_SPEC_GAP | 赛方仅答“参考协议规范要求”，未给字段级细则 |
| 官方认证 | 不声称完整 ARINC 664/615A 认证，不声称通过官方一致性套件 | 项目自建验证矩阵和 golden vectors |

## 2. 状态枚举

- `PROPOSED`：方案提出，尚未冻结。
- `ACCEPTED`：方案已选定，但未形成充分实现证据。
- `IMPLEMENTED`：RTL/脚本已有实现。
- `TOP_LEVEL_VERIFIED`：顶层 RTL 有针对性证据。
- `SYNTHESIS_VERIFIED`：当前顶层有可审阅综合证据。
- `STA_VERIFIED`：明确器件/约束下有时序报告。
- `OPEN_SPEC_GAP`：项目子集或标准边界尚未确定。
- `HISTORICAL`：旧快照，不作为当前状态。

## 3. 需求追踪主表

证据中的 `T*` 指 `sim/tests.manifest` 测试；`L*` 指 [AFDX文献目录](AFDX文献目录.md)；`OPEN` 表示尚未证实。

| ID | 工程问题/需求 | 来源与文献 | RTL/脚本 | 测试/证据 | 状态 | 未覆盖边界 | 下一步 |
|---|---|---|---|---|---|---|---|
| REQ-FRAME-01 | 64–1518 B 帧、FCS、UDP/IP、padding、SN 位置 | 设计书；L001/L008 | `tx_frame_builder.v`、`mac_tx_if.v`、`mac_rx_if.v` | T03、T08a、T22 | TOP_LEVEL_VERIFIED | 仅项目帧格式，不是官方互操作认证 | 固化 frame scoreboard |
| REQ-FRAME-02 | 赛方主接口为 GMII；字节节拍由项目仿真模型定义 | 赛方问答；L088/L089 | `mac_tx_if.v`、`mac_rx_if.v` | T04g、T08ag、T22g | TOP_LEVEL_VERIFIED | 当前波形/测试契约仍需和组委会接口注释对应；125 MHz 不是赛方指定值 | 固化 GMII 仿真接口契约 |
| REQ-TX-01 | 最多 128 条 TX VL，按 BAG 整形 | 设计书；L001/L041/L063/L064 | `tx_vl_scheduler.v`、`tx_port_buf.v` | T02、T04/T04g、T05b | TOP_LEVEL_VERIFIED | 合法 BAG 全档和长期公平性仍需统一报告 | 完成全档 T05 矩阵 |
| REQ-TX-02 | SN 提交式递增与 1–255 回绕 | 设计书；L001/L008/L064 | `tx_sn_gen.v` | T02、T03、T22 | TOP_LEVEL_VERIFIED | 多 VL 长时回绕统计 | 增加长时 SN 断言 |
| REQ-TX-03 | 双网复制与网络标识 | 设计书；L001/L005 | `tx_rm.v`、`mac_tx_if.v` | T04/T04g、T22 | TOP_LEVEL_VERIFIED | 真实 PHY 不在项目范围 | 保持 A/B scoreboard |
| REQ-RX-01 | 双网入口、CRC/IP/UDP/长度检查、坏帧隔离 | L001/L002/L007 | `mac_rx_if.v`、`rx_pmem_queue.v` | T08a/T08ag/T08b/T08bg | TOP_LEVEL_VERIFIED | 完整全错误矩阵仍需合并 | 补统一 RX scoreboard |
| REQ-RX-02 | 4096 RX VL 配置、哈希读写和提交门 | 设计书；L039/L045/L047 | `rx_vl_lookup.v`、`AFDX_top.v` | T08f/T08fg、T12 全系列 | TOP_LEVEL_VERIFIED | 全表逐帧收发未证明 | 补全表 live-frame 测试 |
| REQ-RX-03 | FLT 对未配置、VLID、NET、LMAX 做判决 | 设计书；L002/L039/L045 | `rx_flt.v` | T08d/T08dg | TOP_LEVEL_VERIFIED | 配置读口 BRAM 化待定；统计归类需冻结 | 收敛配置读口和计数语义 |
| REQ-REL-01 | IC 维护每 VL/每网 PSN，拒绝错误序列 | L001/L007/L008/L077 | `rx_ic.v` | T08e/T08eg、T09/T09p | TOP_LEVEL_VERIFIED | 顶层全错误组合仍需 scoreboard | 补 IC/RM 联合断言 |
| REQ-REL-02 | RM A/B 去重、SkewMax、首个有效副本交付 | L077/L078/L079/L080；RM 形式化资料 | `rx_rm.v` | T10/T10g、T22 | TOP_LEVEL_VERIFIED | 多帧迟到副本、两网交替领先、network babbling 仍需专门验证 | 明确历史窗口/迟到策略 |
| REQ-RX-04 | 解析后进入采样/队列端口并主机读回 | L007/L044/L049 | `rx_ip_udp_parse.v`、`rx_port_buf.v` | T11/T11g、T21、T22 | TOP_LEVEL_VERIFIED | 完整 T08 逐帧 scoreboard 尚未完成 | 统一端口/块所有权检查 |
| REQ-HOST-01 | RX/主机 PMEM 争用、延迟 ACK、复位取消 | 设计书；L009/L044 | `AFDX_top.v`（译码在顶层；`host_if.v` 空壳未例化） | T08c/T08cg、T17/T17g | TOP_LEVEL_VERIFIED | `host_if.v` 不是已划分落地模块 | 长时主机/RX 交错测试；独立 `host_if` 仍开放 |
| REQ-HOST-02 | 块池耗尽不写空块，释放后恢复 | L010/L016；项目决策 | `rx_block_pool.v`、`rx_pmem_queue.v` | T21/T21g、T22 | TOP_LEVEL_VERIFIED | 长时多端口所有权仍需验证 | 做全链路 block conservation |
| REQ-MGMT-01 | SAP descriptor handoff 和管理块归还 | 设计书；L044/L074 | `mgmt_sap_rx.v`、`AFDX_top.v` | T23/T23g | TOP_LEVEL_VERIFIED | 不等于 SNMP/615A/RTC 完整实现 | 固化 SAP 子集说明 |
| REQ-MGMT-02 | SNMP 项目子集（至少状态读取/错误处理边界） | 赛方；RFC1157/RFC3416；L046/L074 | `snmp_lite.v` | T14（当前不作为完成证据） | OPEN_SPEC_GAP | BER、GET/SET/Trap、MIB 范围未冻结 | 决定子集并写测试 |
| REQ-MGMT-03 | 615A/TFTP 项目子集（加载/块/校验/提交） | 赛方；L074 | `a615a_tftp.v` | T15（当前不作为完成证据） | OPEN_SPEC_GAP | 完整协议报文和重传未实现 | 定义最小配置加载子集 |
| REQ-MGMT-04 | RTC/PPS 同步和失步状态 | 赛方；L006/L075 | `rtc_sync.v` | T16（当前不作为完成证据） | OPEN_SPEC_GAP | 同步协议、收敛和统计未冻结 | 明确是否纳入交付 |
| REQ-PERF-01 | 合法 BAG 全档启动/稳态 jitter | L001/L006/L067/L084 | `tx_vl_scheduler.v`、仿真脚本 | T05b/T05bg | TOP_LEVEL_VERIFIED | 当前为特定压力配置；不能外推所有档位 | 完成 1–128 ms 全档矩阵 |
| REQ-PERF-02 | 端到端硬件回环时延 | L006/L018/L068/L084 | `sim/tb`、`AFDX_top.v` | T13/T13g、T22 | TOP_LEVEL_VERIFIED | 样本量、P99、背压场景需正式报告 | 输出指标 CSV/报告 |
| REQ-PERF-03 | 长时/高负载随机压力 | L068/L070/L071/L081 | `sim/tb`、回归脚本 | T17/T18 | TOP_LEVEL_VERIFIED | 不能外推 10 万帧、长时和 4 端口持续并发 | 统一样本量和持续时间 |
| REQ-IMPL-01 | 当前顶层可综合 | L085/L089（方法参考） | eLinx 工程 | 局部子模块综合；顶层状态以最新进度为准 | OPEN | 顶层综合网表/资源报告冲突或未形成 | 重新建立 active revision |
| INT-IMPL-02 | 项目自选 125 MHz 时钟下的 STA/CDC/复位工程分析（非赛题明示验收条件） | 项目设计基线；赛方仅明确要求基于 FPGA 仿真，未指定 125 MHz 或 STA | eLinx/约束/报告 | 无完整顶层 STA 证据 | ACCEPTED | WNS/TNS/Fmax/关键路径未知；板级 IO 签核不在本项目赛题范围 | 仅在声称 125 MHz 收敛时补 post-fit STA；不计为赛题缺项 |
| REQ-QUAL-01 | lint、回归、日志和输入输出可复现 | 赛方；L070/L071 | `tools/`、`sim/` | lint、`run_all.py --strict`、最新回归快照 | PARTIAL | 覆盖率口径含 TB；清洁环境归档未完全封存 | 固化 manifest/工具/哈希清单 |

## 4. 架构决策状态

| 决策 | 当前状态 | 当前采用/事实 | 主要依据 | 未覆盖边界 |
|---|---|---|---|---|
| D10 发送起始错相 | IMPLEMENTED / TOP_LEVEL_VERIFIED | 按 VL/BAG 进行错相提交，T05b 有特定压力证据 | L001/L064/L067/L084 | 全 BAG 档、STA、标准认证 |
| D11 块所有权与释放 | IMPLEMENTED / TOP_LEVEL_VERIFIED | RX block pool、端口读回、耗尽/恢复和 SAP handoff 已有局部证据 | L010/L016/L044；T21/T22/T23 | 完整 T08 全链路长期守恒 |
| D12 双网 RM 仲裁 | IMPLEMENTED / TOP_LEVEL_VERIFIED | IC 后 RM、A/B 去重、SkewMax/seen 状态 | L077-L080；T10/T22 | 迟到历史窗口、network babbling、形式化验证 |
| D13 PMEM/主机仲裁 | IMPLEMENTED / TOP_LEVEL_VERIFIED | RX 优先、pending/延迟 ACK、主机写读回 | L009/L044；T08c/T17 | 无限时长公平性、完整混合事务 |

## 5. 当前证据边界

### 0.23 2026-10-12 单顶层 TX4/RX5 与 host/TFTP 共存

`sim/out/txrx_coexist_20261012_r3`已收终态rc0：严格24/24 PASS、740.3s、514冻结输入；编译及全部原始日志Errors0/Warnings0。该候选manifest133项，不能把24项写成完整回归。T83为单生产DUT、TX_MESSAGE_CHAIN_BLOCKS4/RX_REASM_CHAIN_BLOCKS5、默认PHY GMII，3独立reset/config场景、2907720checks：有效8192B接收；坏完整UDP拒绝后8192B恢复；5/6片接收时关闭RX及重组，再恢复。每case同时提交8192B业务TX、保留64B旧RX文件并重复host读，同时进行520B被动TFTP WRQ/DATA/ACK交换。每网18业务帧+9管理帧；RX应用24576B，实际公开host读回49344B。

`TXRX_COEXIST_AUDIT.json`独立核对实际A/B完整PHY、精确字节/每VL次序、IP/UDP/FCS、连续字节周期、IFG>=12和每VL合法1ms BAG、host图案及冻结输入；8已拒绝负控制包含有效FCS的payload损坏、缺/多/乱序/截断帧、IFG和host损坏。case0真实tx_copy351/tx_check129/tx_host1/rx_host827/simultaneous_rx1519；case1同类争用并执行12copy/2check；case2缺片时未运行UDP checker，TX重叠主要是管理请求，恢复可在TX结束后完成，不声称全部恢复均同时活动。

同run的`TX_PRODUCTION_AUDIT.json`和`FILE_HOLD_AUDIT.json`通过；T82仍18正常消息/50帧/59116B及4恢复/10帧/3188B，275072checks；T62仍1651checks、每网26帧、1560B公开读回和5控制恢复。49生产RTL与`out/tx_error_frontend_20261012_r1`四项前端逐项匹配，仍非完整综合。初始化接入前根目录52项关键输入精确匹配，保存`ROOT_BEFORE_INIT_HASHES.json`；随后P05顶层初始化源接入开始，当前根目录已不再等于此候选，不能把r3直接延伸到新RTL。

T83 r1 FAIL为测试台VL1配置stride和仅关闭RX未关闭重组两处错误，已在r2修正；r2单项rc0/零warning PASS但无新增host/cycle导出，不替代r3正式审计。r1自然rc1退出，未杀进程，STOP_NOTE追加了澄清。失败证据全部保留。

P09全场景、P05完整615A、P10规模/指标/全manifest、P11同版完整综合及网表业务、P12复现仍开放。8192B六片合法1ms BAG完整消息2ms差距未关闭；T83首业务字节至末字节时间也不是提交时延。下一步P05固定9B初始化源公开接入、字段显式提供、共享上传缓冲所有权和异常恢复验证。

### 0.24 2026-10-12 P05 固定9B初始化源生产接入与受限验证

顶层实例化a615a_init_tx，AC59高16位version/低16位status由调用者显式提供，AC58 bit0生成/bit1取消。硬件自动占用既有file_mem的preload通道、逐字节写9B、独立commit并核对发布；数据为u32BE9、version、status、空描述长度0。busy含挂起start，阻止host preload/释放和LUR/单fetch抢占；abort/CTL bit9 disable/reset取消部分文件。生成完成后文件仍host持有，AC4E/4F公开读回、AC40写5发起既有WRQ；peer/name/TID由host提供。空闲源abort不释放已发布文件，不代替AC40作业中止。详见接口契约。

生产源入口同步为50（.f、3个.ys、2个QSF），manifest134/bind full86。T84初步r2终态rc0、1/1 PASS、21.6s、93checks，两次WRQ/每网4帧/18B初始化载荷；独立只读解码FCS/IP/UDP/完整文件名及所有9B字段通过。r1仅捕获路径错误，零时刻Errors1/Warnings2，失败保留，改用runner已有out/metrics。随后T84增加disabled start、空闲abort保持和reset边界，r3已收终态rc0：严格14/14 PASS、645.7s、515冻结输入、编译与全部原始日志Errors0/Warnings0。T84为109checks/2WRQ/每网4帧/18B文件载荷/5控制边界；r2仍是较早93checks子集，不代替r3。

当前root已改变，§0.23的49RTL前端及24项共存只属于修改前候选。新r3复验T83同顶层共存3cases/2907720checks与T82恢复275072checks、T62保持1651checks，四份INIT_SOURCE/TXRX_COEXIST/TX_PRODUCTION/FILE_HOLD审计均PASS。`out/a615a_init_frontend_20261012_r1`五项前端全部rc0/零warning：默认/TX4RX5 hierarchy/stat及store/orchestrator/init proc/check，27.391/46.328/20.078/0.609/0.063s；50源逐项匹配r3，仍非完整综合。新独立INIT_SOURCE_AUDIT严格核对冻结输入/零warning/双网完整FCS/IP/UDP及显式文件名/TID/9B数据，4个已拒绝负控含有效FCS的文件损坏、缺帧、交换作业和截断帧；正式PASS。T84的ID遵循TX4 message_store从0，SN从1，不沿用其它场景的消息ID起点。

`ROOT_CURRENT_RUNTIME_AUDIT.json`核对根目录380项运行输入与r3一致（50生产RTL及sim/golden/source-flow）；文件审计工具/前端runner的运行后扩展与文档另记，不称全515根目录匹配。root原t15向量只有40cases，而冻结runner生成54cases；旧件先备份到`out/a615a_root_vector_sync_20261012_r1/before`，再同步已审计的t15/t82/tftp_error生成文件，sync_metadata记录前后SHA，不修改已通过RTL/TB。所有工具session终态已收，当前无活动重型工具。

接入只证明受限初始化编码源与显式WRQ传输，不是被动标准LUI RRQ端点、完整LUI/LUS或完整615A。P05/P09全部覆盖、P10/P11/P12及完整消息2ms差距继续OPEN。不得重跑旧C4mapped业务TIMEOUT。

### 0.25 2026-10-12 P10 PHY规模扩展及BAG启动修复（历史检查点，终态见当前执行表）

新增T33p/T34p/T35p，当前manifest137/bind full89/mac4/none40/rx_ic4，生产清单仍50。4096RX mode2接收7×55+D5及完整64B帧，实际PHY/周期捕获与独立向量逐帧核对，4096索引全部公开host读回，A/B去重及512B coverage bitmap对账。128TX mode2捕获完整双网PHY，独立复算IP/UDP/FCS/载荷/SN并检查连续字节、IFG、合法1ms BAG及50us相位漂移，7负控拒绝。

`gmii_scale_directed_20261012_r1`终态1/2 PASS/rc1：T35p完整4096 PASS/68.9s，T33p虽TB PASS但独立审计拒绝X。根因已核实普通VL6/7映射到管理SAP保留port6/7，仅这两VL各16帧UDP源端口/checksum/FCS为X；PHY测试改用普通port16..143，128VL/16B载荷及判据保持。`gmii_scale_txpilot_20261012_r1`严格1/1 PASS/rc0/84.4s，每网2048帧/32768B，phase13.344us、IFG最小685cycles，7负控拒绝；当时50RTL与初始化r3一致。根因证据`out/gmii_scale_failure_review_20261012_r1/ROOT_CAUSE.json`。

`gmii_scale_metrics_20261012_r1`当时正在运行（session26374，现已终态rc1），RTC T16r/T16a/T16b已PASS/零warning，但100rounds T34p实际部分捕获在62轮超过50us（52.192us）。调度器等BAG到期再构帧造成启动开销逐轮累积，不能以16轮通过替代100轮。完整终态待收，不启动第二个Questa。

当前root已改3个生产文件scheduler/mac/top：PHY允许提前128cycles准备，但不改原next_tx截止点；MAC只在IDLE起帧时检查队头frame_permit，到期前禁止发出，帧内不受permission下降影响。模式0/1仍lead0/guard0。T41新增完整帧保持32cycles和帧内permission下降检查；备份/精确patch及合同在`out/gmii_bag_guard_20261012_r1`。**此修复尚待功能与50源前端验证，先前初始化14/14和前端只属于修改前版本。**

后续：收当前8项终态→新修复短验证/T33p→100rounds及TX4/RX5/初始化/LUR恢复相邻保护→50源前端/统一严格审计→当前137项完整回归。`tools/audit_gmii_scale.py`已新增统一冻结/完整TX/RX审计及RX负控入口，当前尚未运行成功。P05/P09完整范围、2ms完整消息、P11完整综合与新网表业务、P12仍OPEN；不重跑旧C4 TIMEOUT，不要求实际上板。

### 可以直接用于项目/答辩的内容

- 赛方明确 GMII、自建激励、自建回环和自建验证环境；
- TX/RX 主要 RTL 路径和 50/50 manifest 回归快照；
- T08e/T10/T11/T21/T22/T23 等定向测试；
- L077-L080 的 RM/SkewMax 论文和形式化建模资料；
- L071/L087 的端系统符合性/自动化测试方法；
- L084 的确定性仿真外部对照；
- L089、TI PHY 手册的 GMII/RGMII/接口时序参考。

### 仍不能宣称完成的内容

- 完整 ARINC 664 Part 7 官方认证；
- 完整 ARINC 615A、SNMP、RTC；
- 官方一致性测试套件或官方 golden vector 通过；
- 全表逐帧 T08/T22；
- 10 万帧/长时/持续 4 端口压力；
- 当前顶层完整综合、资源和 125 MHz STA；
- 完整 RTL-only 覆盖率签核。

### 仅作背景、不能直接作为 AFDX 合规证据

- 普通千兆以太网/图像传输论文 L090-L094；
- 特定商业 FPGA、MAC、PHY、PCIe、Linux 或 RTOS 平台方案；
- 论文作者声称的“通过测试/满足指标”；
- D 级 CAJ 题名线索。

## 6. 下一步验收顺序

1. 冻结项目子集：GMII、支持的 SNMP/615A/RTC 范围和不支持项。
2. 完成 T08/T22 统一逐帧 scoreboard。
3. 按 L077-L080 复核 RM 多帧迟到、历史窗口和 network babbling 边界。
4. 完成合法 BAG 全档、T13 指标 CSV、T17/T18 样本量与持续时间说明。
5. 重新建立当前顶层综合/仿真 active revision 与资源报告；CDC/复位检查作为工程质量项，125 MHz post-fit STA 仅在对外声称该频率收敛时补，不列为赛题缺项。
6. 固化 manifest、工具版本、源码/向量/日志哈希和清洁环境复跑包。
7. 管理面若不纳入本阶段，明确写成项目限定子集和 OPEN_SPEC_GAP，不用 T23 冒充 T14–T16。

## 7. 2026-09-28 设计优化待办（OPT-1~12；状态按项，非全表 PROPOSED）

> 依据：[第三轮文献补充与设计优化建议](AFDX端系统_第三轮文献补充与设计优化建议_20260928.md)。下表只登记问题和方案，**不改变 §3/§4 的现有状态**。状态 `IMPLEMENTED` 只表示**代码可见、未逐项对专用 T**（尺子等级 I），**不是已验证、不是 P**。标已验证须按当前 `sim/tests.manifest` 完成受影响定向，并在最终候选跑完整回归。post-fit STA 只用于核实项目是否达到自选的 125 MHz 目标，不是赛题硬门槛。
>
> **与同日文档的分工**：A01–A05（SNMP 事务/请求覆盖/时序、T13、判决门）已由 [文献依据与修复建议](AFDX_文献依据与修复建议_20260928.md)、[三篇文献正文复核与修复映射](AFDX_三篇文献正文复核与修复映射_20260928.md) 及 [文献落地验证清单 CSV](AFDX_文献落地验证清单_20260928.csv) 细化到用例级；OPT-2~5 **以该 CSV 为验收用例来源**，此处只登记对应关系，不另立判据。OPT-1、OPT-6~10 为本轮新增、上述文档未覆盖的项。
>
> **OPT-5 时序**：原 WNS 问题现由时序收敛刀（`tx_vl_scheduler` 减 lane）单独处理，**待那刀结果更新**；本表不把该刀写成已收敛。

| 编号 | 优先级 | 问题（证据） | 方案 | 文献 | 状态 |
|---|---|---|---|---|---|
| OPT-1 | P1 | RM 只记 last_sn，迟到副本会重复交付（`rx_rm.v:110`；`tb_t10_top_rm.v:282-285` 自认 limitation）→ REQ-REL-02／D12 缺口 | RM_ST 33→41 bit，加 8 bit 已交付位图；超出窗口由策略位决定；配置检查 `SkewMax < 127·BAG` | L105/L107/L137 | IMPLEMENTED（部分：`rx_rm.v` 41 bit 表项代码可见；越窗策略位 / SkewMax 配置检查未找到。未逐项对 T，非已验证） |
| OPT-2 | P1 | SNMP SET 非原子（A01，`snmp_lite.v:532-537`） | P_RESOLVE2 只校验和暂存；新增 P_COMMIT，仅在 err_st==0 时统一写入 | L116；CSV `SET_ATOMIC_1/N`、`SET_PRECHECK` | IMPLEMENTED（`snmp_lite.v` 已有 P_COMMIT。代码可见，未逐项对 T，非已验证） |
| OPT-3 | P1 | 请求覆盖（A02，`snmp_lite.v:367-375`） | `!have_pkt` 门控＋`snmp_busy_drop` 计数 | L116；CSV `REQ_BURST/REQ_CONTEXT/QUEUE_BOUNDARY/RESET_RECOVERY` | IMPLEMENTED（`snmp_lite.v` 已有 `have_pkt` 门控。代码可见，未逐项对 T，非已验证） |
| OPT-4 | P1 | 回归假绿（A04）、T13 无断言（A03） | 每个 TB 输出唯一 VERDICT 行，runner 严格判定；T13 加时延阈值；为 OPT-1~3 各配 1 个变异体 | L117/L001；CSV `VERDICT_GATE`、`LATENCY_GATE` | IMPLEMENTED（`sim/regress_verdict.ps1` + mutant 脚本代码可见。未逐项对 T，非已验证） |
| OPT-5 | P2 | WNS −1.735 ns，最差路径 `oid_len→vl_stat_mem`（A05） | OID 逐字节增量求 pfx_ok 和 g/l/i；walk() 单独占一拍 | L115；CSV `GETNEXT_PIPE`、`POSTFIT_CHECK` | PROPOSED（OID 时序部分未按本方案落地；调度器时序另见时序收敛刀，待结果） |
| OPT-6 | P2 | 0924 文档写 D10“调度器内置 26 μs×i 偏置”，RTL 无此逻辑（`tx_vl_scheduler.v:18`），实际为主机错相提交（T05b `:162`） | A：定义为主机契约并修正 0924 文档（推荐）；B：phase_lock 硬件相位栅格 | L099–L101/L135 | PROPOSED |
| OPT-7 | P2 | 设计书 §8 写“任一池可借公共池”，TX 未实现（`tx_port_buf.v:19`）；RX 借用无上限 | 文档对齐为“仅 RX 借用”；RX 加 `borrow_cap`；日后 TX 借用采用 DT 阈值 | L121/L122 | PROPOSED |
| OPT-8 | P3 | RTC 仅 P 环（`rtc_sync.v:79`），频偏 f ppm 时稳态误差约 f·2^log2_avg μs；设计书 F5“分数微调”未兑现 | PI 伺服＋分数累加器；SYNC_LOSS 时 holdover | L133/L134 | IMPLEMENTED（变体：FLL，非方案 PI；`rtc_sync.v` 代码可见。未逐项对 T，非已验证） |
| OPT-9 | P3 | `pps_in` 未做 CDC 签核（`rtc_sync.v:15`） | SDC／同步器识别＋MTBF 计算＋最小脉宽约束 | L132 | PROPOSED |
| OPT-10 | P3 | 覆盖率 67.82%，无形式证据 | SymbiYosys 有界证明：块池守恒、RM 不重复、IC 拒绝不写 RM | L136 | PROPOSED（仍无 `.sby`） |
| OPT-11 | — | 调度器顺序扫描 1.02 μs／轮 | 不实施；VL ≥ 1024 时改时间轮 | L135 | DEFERRED |
| OPT-12 | — | 配置 FF 阵列 | 待 post-fit 资源报告确认是瓶颈后，再做 BRAM 化 | L125–L127 | DEFERRED |

**文档与代码不一致（待收口）**：D10 描述（0924 两份文档）；公共池借用（设计书 §8 第 490/972 行）；F5 分数微调（设计书 §2.1）；RM 迟到副本（§7.11／REQ-REL-02）。
