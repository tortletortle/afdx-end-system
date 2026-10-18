"""Refresh current document entries from an immutable execution checkpoint."""
import argparse
import json
from pathlib import Path
import shutil


def sync(root, checkpoint):
    report = json.loads(checkpoint.read_text(encoding='utf-8'))
    records = report['records']
    now = report['observed_local']
    full = records['full_rtl']
    audits = report['independent_audits']
    complete = full.get('regression_result') == 'PASS' and full.get('return_code') == 0
    assert complete and full['pass_count'] == full['test_count'] == 137
    assert all(row['status'] == 'PASS' for row in audits.values())
    mapped = records['mapped_pipeline']
    synth = records['synthesis']
    def run_summary(key):
        row = records[key]
        return (f"{row.get('regression_result', row.get('status', row.get('observation', 'UNKNOWN')))}"
                f" {row.get('pass_count', '?')}/{row.get('test_count', '?')} rc={row.get('return_code', '?')}")
    rtc_now = run_summary('rtc_hold_original')
    public_now = run_summary('public_repaired')
    reproduction_now = run_summary('reproduction_run')
    rtc_summary = f"T85原隔离正向及六差异负控已完成；增强HOLD/PPS原生产路径：{rtc_now}，证据`{records['rtc_hold_original']['path']}`。"
    public_summary = f"T86原隔离FAIL3保留；PHY/host同步修复后：{public_now}，审计与负控分别看快照。"
    reproduction_summary = f"RTL包r2共816成员逐件哈希PASS；包内T41/T78实际复现：{reproduction_now}，仅为有界入口复现。"
    correspondence = report['root_correspondence']
    root_same = not correspondence['production_mismatches'] and correspondence['manifest_matches_frozen_run']
    new_full = records['current_140_full']
    new_audits = report['current_candidate_audits']
    new_correspondence = report.get('current_candidate_root_correspondence', {})
    new_pass = (new_full.get('regression_result')=='PASS' and new_full.get('return_code')==0
                and new_full.get('pass_count')==new_full.get('test_count')==140
                and all(row['status']=='PASS' for row in new_audits.values())
                and records['current_140_pipeline'].get('status')=='RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING'
                and new_correspondence.get('production_mismatches')==[]
                and new_correspondence.get('manifest_matches_frozen_run') is True
                and len(records['current_140_frontend'].get('stages', [])) == 5
                and all(row.get('verdict') == 'PASS' and row.get('exit_code') == 0
                        and row.get('timed_out') is False for row in records['current_140_frontend']['stages']))
    current_summary = ('root生产源及manifest仍对应冻结137。' if root_same else
                       f"root已变更：{len(correspondence['production_mismatches'])}份生产源、实际manifest {correspondence['root_manifest_count']}项；"
                       f"当前新候选完整回归：{run_summary('current_140_full')}。旧冻结137仅属于旧版证据。")
    current_synth = records.get('current_140_synthesis', {'observation': 'NOT_CREATED'})
    current_probe = records.get('current_140_probe', {'observation': 'NOT_CREATED'})
    current_package = records.get('current_140_package', {'observation': 'NOT_CREATED'})
    current_replay = records.get('current_140_reproduction_review', {'observation': 'NOT_CREATED'})
    execution = records['current_140_execution']
    continuation = records.get('current_140_continuation', {})
    if execution.get('status') == 'FAIL_STOP_NO_RETRY' and continuation.get('status'):
        execution = continuation
    repair_summary = (f"RTC修复队列{records['rtc_repair_pipeline'].get('status')}/{records['rtc_repair_pipeline'].get('current_stage')}；"
                      f"fetch组合环修复队列{records['fetch_loop_pipeline'].get('status')}/{records['fetch_loop_pipeline'].get('current_stage')}。" +
                      (("候选已集成，同版140/140及六审计/前端通过；综合后业务仍开放，原失败保留。" if new_pass else
                        "候选已集成，组合版本仍需完整验证；原失败保留。") if not root_same else
                       "均为独立候选，未集成到root；原失败保留。"))
    snapshot = checkpoint.relative_to(root).as_posix()
    entry = (f"> 当前接管入口：[P00–P12执行表](当前执行表_20261012.md)。核验{now}：" + current_summary +
             f"当前同版完整RTL/六审计/前端全部成立={new_pass}；KeepHierarchy完整综合{current_synth.get('status', current_synth.get('observation'))}，原probe {current_probe.get('status', current_probe.get('observation'))}，编译/加载/业务独立登记。"
             f"当前执行{execution.get('status', execution.get('observation'))}/{execution.get('current_stage')}；旧137/137及旧包复现只属于旧版，旧flatten综合FAIL及全部失败原件保留。"
             "2ms官方负载/起止待确认，完整消息实测6.063448/6.161736ms超2ms另列；完整615A/665仍OPEN。"
             f"现场进程、阶段耗时与路径见`{snapshot}`；[无损交接](新对话交接_20261013.md)。下方旧状态保留为历史。")
    backup = checkpoint.parent / 'before_document_sync'
    backup.mkdir(exist_ok=False)
    for name in ('AFDX项目应用追踪.md', '新对话交接_20261012.md', '赛题最终验收矩阵.md',
                 '当前执行表_20261012.md', '协议差距清单_20261009.json', '615A_交付范围与字段依据_20261012.json'):
        shutil.copy2(root / 'doc' / name, backup / name)
    for name in ('AFDX项目应用追踪.md', '新对话交接_20261012.md', '赛题最终验收矩阵.md'):
        path = root / 'doc' / name
        lines = path.read_text(encoding='utf-8-sig').splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith('> 当前接管入口：'))
        lines[index] = entry
        path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    path = root / 'doc/当前执行表_20261012.md'
    text = path.read_text(encoding='utf-8-sig')
    heading = '## 当前现场和证据'
    start, end = text.index(heading), text.index('## 执行表')
    section = f'''{heading}

核验时间：{now}。当前事实优先于后面的历史记录。

- 完整运行r3实际137/137严格PASS、rc0，534输入/180输出哈希；五独立审计PASS，入口`out/gmii_guard_validation_pipeline_20261013_r5`。50生产源及137manifest对应关系见`{snapshot}`。
- {current_summary} 新候选入口`{records['current_140_pipeline']['path']}`，综合入口`{records['current_140_mapped']['path']}`。不同冻结版本的通过不可拼接。
- 当前候选同run六审计：{'; '.join(name+'='+row['status'] for name,row in new_audits.items())}；完整140、六审计、前端及root对应全部成立：{new_pass}。
- 原r2终态135/137、T15容量原失败定向2/2、审计r3误拒T45成功标题、审计r4误拒T38校验器自测原件均保留。精确标题8正负控及自测精确序列8正负控通过；没有改原日志、RTL或仿真判据，未重跑仿真。
- 综合流水线`out/gmii_guard_mapped_pipeline_20261013_r4`：{mapped.get('status')} / {mapped.get('current_stage')}。候选Default/TX1RX1；前端复用逐源/工具/命令哈希核对，完整综合{ synth.get('status', synth.get('observation')) }。compiled/load/probe/business独立登记。
- {rtc_summary} {public_summary} 原失败及原载荷/帧/49344B读回保留，不集成失败草稿，不删除共活动断言。
- {reproduction_summary} 包准备与有界复现均不代表最终验收或完整manifest复现。
- 原串行后续：{records['serial_followups'].get('status', 'UNKNOWN')}，入口`{records['serial_followups']['path']}`。{repair_summary} 仅快照中现场进程能证明核验瞬间的活动工具。
- T86预期字节负控精确复核：{records['public_exact_negative_review'].get('status', records['public_exact_negative_review'].get('observation'))}；包实际复现独立核对：{records['bundle_reproduction_review'].get('status', records['bundle_reproduction_review'].get('observation'))}。原综合FAIL的组合环Warning和bad allocation Error分别登记，未导出新网表。
- 两项语义开放：2ms官方口径待赛方确认与完整消息实测超2ms分别列；615A字段/流程/665正文未取得。短问题见`doc/需向赛方确认的问题_20261013.md`。

'''
    text = text[:start] + section + text[end:]
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.startswith('更新时间：'):
            lines[i] = f'更新时间：{now}。保留全部工作树修改、冻结候选和失败日志。默认IF_MODE=2、125MHz、TX1/RX1；TX4/RX5显式启用。'
        if line.startswith('| P'):
            columns = line.split('|')
            task = columns[1].strip()
            if task == 'P01':
                columns[3] = f' 实际{correspondence["root_manifest_count"]}项manifest、隔离workspace、原始警告拒绝；旧TB未用端口显式接线 '
            if task in ('P01', 'P02', 'P03', 'P04', 'P06', 'P07', 'P08', 'P10'):
                columns[4] = ' 完整r3严格137/137及五独立审计PASS；同50源五stage前端PASS；证据pipeline_r5 '
                if task not in ('P07', 'P10'):
                    columns[5] = ' 对应RTL集合已通过；规范未决与综合后验证另列 '
                columns[6] = ' 复用同版已通过证据；推进所需综合后场景 '
                if not root_same:
                    columns[5] = f' 当前组合候选完整回归{run_summary("current_140_full")}；旧冻结证据保留，规范和网表缺口另列 '
                    columns[6] = ' 收新同版实际140manifest及独立审计；不拼接旧版本 '
                if new_pass:
                    columns[4] = ' 当前同版完整140/140严格PASS、六独立审计PASS、五前端stage PASS；production_repairs_validation_pipeline_r1 '
                    columns[5] = ' 对应RTL集合已通过；615A规范、官方2ms口径与网表业务单独保持开放 '
                    columns[6] = ' 收当前同版完整综合及代表网表业务；不重跑未受影响RTL测试 '
            if task == 'P05':
                columns[4] = ' 完整r3 T62/T84、INIT_SOURCE/FILE_HOLD独立审计PASS；规范语义仍待核 '
                if new_pass:
                    columns[4] = ' 当前同版完整140 T62/T84、INIT_SOURCE/FILE_HOLD独立审计PASS；规范及完整加卸载仍OPEN '
            if task == 'P09':
                columns[3] = ' 同顶层TX4/RX5、host/TFTP争用；RTC HOLD/PPS修复及公开PHY/host共活动观察已集成 '
                columns[4] = f' 旧完整r3 T83审计PASS；原T85增强{rtc_now}；RTC候选{run_summary("rtc_repaired_directed")}、相邻{run_summary("rtc_repaired_adjacent")}；T86候选{public_now}及独立审计/负控 '
                columns[6] = ' 收集成后的T78/T85/T86及实际140全量、同run独立审计；所选标准615A仍开放 '
            if task == 'P10':
                columns[5] = ' 扩展场景整合后的实际manifest；2ms官方适用负载及起止 '
                scale = records.get('public_scale_reset_repair', {})
                if scale.get('status'):
                    columns[4] = (f' 当前同版完整140/140及六审计PASS；新增公开规模定向队列 '
                                  f'{scale["status"]}，{scale.get("current_stage") or "无活动阶段"}；'
                                  '独立定向不拼成完整142 ')
                    columns[6] = ' 收完整100轮TX/4096项RX及原独立审计，再做mapped案例准入；官方2ms口径另列 '
            if task == 'P11':
                columns[3] = ' 三native脚本支持Default/Tx4Rx5/InitTx4Rx5Timeout50；六业务入口已绑定，严格诊断，实际网表状态另列 '
                columns[4] = f' 当前KeepHierarchy综合 {current_synth.get("status", current_synth.get("observation"))}；mapped {records["current_140_mapped"].get("status", records["current_140_mapped"].get("observation"))}；原flatten综合FAIL保留 '
                columns[6] = ' 定位当前KeepHierarchy的ABC后多驱动及bad allocation；导出一致性/分区等价/地址上限分别核实，不盲重跑 '
                isolated = records.get('native_isolated_module_attempt', {})
                if isolated.get('status'):
                    columns[4] += (f'；完整原版失败保留；同版独立模块映射/完整重组路径 '
                                   f'{isolated["status"]}，已映射{isolated.get("mapped_modules", 0)}/50，'
                                   f'新导出{records.get("native_isolated_module_synthesis", {}).get("status", "NOT_CREATED")}；'
                                   f'原T78短诊断{records.get("native_isolated_module_probe", {}).get("status", "NOT_CREATED")} ')
                    columns[6] = ' 收独立模块映射完整重组及严格导出；实际编译/加载/成本/原判据业务分别收取，保留全部失败 '
            if task == 'P12':
                columns[3] = ' 旧137包r2保留；当前140包状态以快照为准，非最终验收包 '
                columns[4] = f' 当前140包 {current_package.get("status", current_package.get("observation"))}；当前包实际复现 {current_replay.get("status", current_replay.get("observation"))}；旧816成员包T41/T78有界复现{reproduction_now} '
                columns[6] = ' 核对当前140包及最小实际复现；同版本综合/业务/报告齐全后形成最终包 '
            lines[i] = '|'.join(columns)
    text = '\n'.join(lines) + '\n'
    marker = '## 下一阶段及结束条件'
    start = text.index(marker)
    next_section = text.find('\n## ', start + len(marker))
    if next_section == -1:
        next_section = len(text)
    text = text[:start] + f'''{marker}

旧冻结137及五审计已通过，原Default完整综合FAIL（fetch结构组合环及bad allocation）。当前KeepHierarchy综合{current_synth.get('status', current_synth.get('observation'))}，原probe {current_probe.get('status', current_probe.get('observation'))}；编译/加载/业务独立收取。{current_summary} {repair_summary} 当前执行队列为{execution.get('status', execution.get('observation'))}/{execution.get('current_stage')}（原worker与CLI修正续跑分别存档）。结束条件：组合原失败路径稳定→当前实际完整140及六独立审计同run通过→新KeepHierarchy完整综合→分别收编译、加载、成本与原判据业务。旧137不能拼接成140；不提高旧TIMEOUT预算。旧包T41/T78复现仅为两项入口证据。完整615A/665与2ms官方口径仍未决，继续独立工作。

精简运行、进程及证据索引：`{snapshot}`。后面的所有旧运行描述仅作历史检查点，不作为当前现场。
''' + text[next_section:]
    path.write_text(text, encoding='utf-8')
    path = root / 'doc/协议差距清单_20261009.json'
    data = json.loads(path.read_text(encoding='utf-8-sig'))
    data['updated_local'] = now
    cp = data['current_checkpoint']
    new_full = records['current_140_full']
    active_run = (str(Path(new_full['path']).parent).replace('\\', '/')
                  if new_full.get('regression_result')=='RUNNING' else None)
    current_pipeline = records['rtl_pipeline'] if root_same else records['current_140_pipeline']
    current_mapped = mapped if root_same else records['current_140_mapped']
    cp.update(primary_record='doc/当前执行表_20261012.md', current_execution_snapshot=snapshot,
              full_current_regression=('PASS137/137 rc0; same-run five audits PASS; evidence recovery pipeline_r5' if root_same else
                                       'New root candidate140: '+run_summary('current_140_full')+'; old frozen137 PASS retained'),
              active_run=active_run, active_session=None, active_heavy_tools=report['heavy_processes'],
              pipeline={'path': current_pipeline['path'], 'status': current_pipeline.get('status', current_pipeline.get('observation'))},
              mapped_pipeline={'path': current_mapped['path'], 'status': current_mapped.get('status', current_mapped.get('observation')), 'current_stage': current_mapped.get('current_stage')},
              process_observation='Instantaneous actual process inventory in checkpoint; metadata alone is not liveness',
              independent_audits=audits if root_same else new_audits, package=records['package'] if root_same else current_package,
              reproduction_inputs=records['reproduction_inputs'], reproduction_run=records['reproduction_run'])
    cp['production_sources'] = correspondence['production_sources']
    cp['current_manifest_tests'] = correspondence['root_manifest_count']
    cp['historical_root_after_coexist'] = cp.get('historical_root_after_coexist', cp.get('root_after_coexist'))
    cp['root_after_coexist'] = current_summary
    cp['current_140_synthesis'] = current_synth
    cp['current_140_probe'] = current_probe
    cp['current_140_package'] = current_package
    cp['p09_rtc_management_draft']['status'] = 'ENHANCED_ORIGINAL_' + records['rtc_hold_original'].get('regression_result', records['rtc_hold_original'].get('observation', 'UNKNOWN'))
    cp['p11_public_txrx_draft']['status'] = 'REPAIRED_PUBLIC_' + records['public_repaired'].get('regression_result', records['public_repaired'].get('observation', 'UNKNOWN'))
    cp['p09_rtc_management_draft']['enhanced_original_run'] = records['rtc_hold_original']
    cp['p11_public_txrx_draft']['repaired_run'] = records['public_repaired']
    cp['p11_public_txrx_draft']['independent_audit'] = records['public_repaired_audit']
    cp['p11_public_txrx_draft']['payload_negative'] = records['public_payload_negative']
    cp['serial_followups'] = records['serial_followups']
    cp['rtc_hold_repair_pipeline'] = records['rtc_repair_pipeline']
    cp['rtc_hold_repaired_directed'] = records['rtc_repaired_directed']
    cp['rtc_hold_repaired_adjacent'] = records['rtc_repaired_adjacent']
    cp['fetch_start_loop_pipeline'] = records['fetch_loop_pipeline']
    cp['fetch_admission_directed'] = records['fetch_admission_directed']
    cp['synthesis_failure_review'] = records['synthesis_failure_review']
    cp['public_exact_negative_review'] = records['public_exact_negative_review']
    cp['bundle_reproduction_review'] = records['bundle_reproduction_review']
    cp['root_correspondence'] = correspondence
    cp['repair_integration'] = records['repair_integration']
    cp['combined_directed'] = records['combined_directed']
    cp['current_140_full'] = records['current_140_full']
    cp['current_140_pipeline'] = records['current_140_pipeline']
    cp['current_140_mapped'] = records['current_140_mapped']
    cp['current_140_execution'] = records['current_140_execution']
    cp['current_140_continuation'] = records.get('current_140_continuation', {'observation': 'NOT_CREATED'})
    cp['effective_current_execution'] = execution
    cp['current_hierarchy_memory'] = records.get('current_hierarchy_memory', {'observation': 'NOT_CREATED'})
    for name in ('current_140_reproduction_execution', 'current_140_reproduction_preparation',
                 'current_140_reproduction_run', 'current_140_reproduction_review',
                 'public_scale_preparation', 'public_scale_validation',
                 'public_scale_reset_repair', 'public_scale_reset_review',
                 'public_reset_diagnosis', 'native_abc_static_diagnosis',
                 'native_abc_dynamic_diagnosis', 'public_scale_qualified_supplement',
                 'native_fresh_boundary_attempt', 'native_per_module_attempt',
                 'native_isolated_module_attempt', 'native_isolated_module_synthesis',
                 'native_isolated_module_probe'):
        cp[name] = records.get(name, {'observation': 'NOT_CREATED'})
    cp['current_candidate_audits'] = new_audits
    cp['current_candidate_root_correspondence'] = new_correspondence
    cp['current_complete_message_latency'] = report.get('current_complete_message_latency', {'status': 'NOT_COLLECTED'})
    cp['current_candidate_full_rtl_and_audits_pass'] = new_pass
    cp['historical_default_mapped_failure'] = mapped
    cp['active_session_limit'] = 'No tool-session ID inferred from process metadata; actual instantaneous heavy PIDs are recorded separately.'
    cp['independent_followups']['status'] = records['followups']['status']
    cp['public_txrx_queue']['status'] = records['public_queue']['status']
    cp['audit_parser_repair'] = {
        'exact_timeout_title': 'out/full137_audit_title_repair_20261013_r1/REPAIR_REVIEW.json',
        'exact_checker_selftest_sequence': 'out/full137_scale_selftest_repair_20261013_r1/REPAIR_REVIEW.json',
        'simulation_rerun': False, 'failed_evidence_retained': True,
    }
    boundary = (f"Observed {now}; current root {correspondence['production_sources']} production sources/"
                f"{correspondence['root_manifest_count']} manifest items. " + current_summary +
                f" Same-run audits: {', '.join(name+'='+row['status'] for name,row in new_audits.items())}. "
                f"Same-version full RTL/audits/frontend correspondence satisfied={new_pass}. "
                f"Current complete synthesis={current_synth.get('status', current_synth.get('observation'))}; "
                f"mapped cost={current_probe.get('status', current_probe.get('observation'))}. "
                f"See {snapshot}; no full615A, official2ms or mapped-business closure inferred.")
    remaining = {
        'P01_GMII_METRICS': 'Confirm official2ms applicable load/start/end with competition; preserve measured8192B complete-message over2ms separately. Collect current140 terminal and same-version mapped metrics.',
        'P02_SCALE_128_4096': 'Collect current140 terminal and same-run GMII_SCALE audit; then complete same-version synthesis and mapped scale. Official latency definition remains open.',
        'P04_615A_CONTROL': 'Obtain selected normative edition/clauses and mandatory roles/load-unload scope; confirm LUI/LUS/LUR, progress/tag and665 interpretation. Bounded initialization/WRQ/LUR/file transport does not close complete615A.',
        'P06_P7_QUEUED_MESSAGE': 'Collect current140 terminal, same-run TX production audit and complete-message PHY results; then representative same-version mapped TX/RX business. Official2ms applicability and full615A remain separate.',
        'P07_P7_REASSEMBLY': 'Collect current140 terminal, same-run TX/RX and scale audits; validate representative mapped complete messages with default and explicit TX4/RX5 configurations kept distinct.',
        'P05_RTC': 'Collect integrated T85/T87 and adjacent nominal/loss/drift/recovery results in current140; then same-version public RTC mapped lifecycle. Reuse unaffected bounded evidence only with version correspondence.',
        'P10_MAPPED_FUNCTIONAL_EVIDENCE': 'Authorized serial path: current140 plus six audits, fresh full KeepHierarchy synthesis, then compile/load/cost and original representative business separately. Inspect performance causes; do not repeat oldC4 TIMEOUT or only raise budgets.',
        'P11_FINAL_PACKAGE_REPLAY': 'Collect new current140 RTL bundle and verify every member; preserve old816-member bundle and T41/T78 replay as old-version bounded evidence. Final package requires same-version synthesis/business, explicit open semantics, report and clean replay.',
    }
    for row in data['requirements']:
        row.setdefault('historical_evidence_before_live_refresh', {
            key: row[key] for key in ('baseline_version', 'validation', 'remaining_work', 'implementation', 'integration', 'current_evidence_boundary') if key in row
        })
        row['baseline_version'] = (f"Current root: {correspondence['production_sources']} production sources/"
                                   f"{correspondence['root_manifest_count']} manifest items; exact source/manifest hashes and correspondence in {snapshot}. Historical baseline preserved separately.")
        row['current_evidence_boundary'] = boundary
        row['current_verification'] = {'checkpoint': snapshot, 'observed_local': now,
                                      'full_rtl': new_full, 'full_rtl_and_audits_pass': new_pass}
        # Old validation prose described several earlier candidates as current.
        # Preserve it verbatim, while using the live boundary for the current row.
        row['validation'] = boundary
        if row['id'] in remaining:
            row['remaining_work'] = remaining[row['id']]
        if row['id'] == 'P10_MAPPED_FUNCTIONAL_EVIDENCE':
            row['implementation'] = 'Integrated RTC HOLD and fetch-start structural repairs; combined directed3/3 and five frontend stages PASS. Full RTL, full synthesis and mapped steps are separate records in current_checkpoint.'
            row['integration'] = f"Current mapped pipeline: {current_mapped.get('status', current_mapped.get('observation'))}; frozen Default/TX1RX1 path; compile/load/cost/business recorded separately."
        elif row['id'] == 'P11_FINAL_PACKAGE_REPLAY':
            row['implementation'] = 'Hash-bound RTL evidence packager and clean-copy reproduction entry exist. Current bundle state in current_checkpoint; not final acceptance.'
        elif row['id'] == 'P09_TFTP_BLOCK_SIZE':
            row['integration'] = 'Client/fetch/adapter/file_rx, bounded LUR reception and explicit initialization source are integrated. Fixed512B/no-OACK remains; complete selected normative615A remains OPEN.'
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    path = root / 'doc/615A_交付范围与字段依据_20261012.json'
    scope = json.loads(path.read_text(encoding='utf-8-sig'))
    scope.setdefault('historical_revalidation_before_live_refresh', scope.get('current_revalidation'))
    scope['updated_local'] = now
    scope['current_revalidation'] = boundary
    scope['current_candidate_evidence'] = {'checkpoint': snapshot, 'full_run': new_full,
                                          'same_run_audits': new_audits, 'full_rtl_and_audits_pass': new_pass,
                                          'normative_closure': False}
    for operation in scope['implemented_operations']:
        if 'latest_frozen_full_evidence' not in operation:
            continue
        operation.setdefault('historical_frozen_full137_evidence', operation['latest_frozen_full_evidence'])
        if 'current_directed_evidence' in operation:
            operation.setdefault('historical_directed_evidence', operation.pop('current_directed_evidence'))
        if new_pass:
            audit_name = operation['historical_frozen_full137_evidence']['independent_audit'].removesuffix('_AUDIT.json')
            operation['latest_frozen_full_evidence'] = {
                'run': str(Path(new_full['path']).parent).replace('\\', '/'), 'manifest_items': 140,
                'metadata_sha256': new_full['sha256'], 'independent_audit': audit_name+'_AUDIT.json',
                'audit_sha256': new_audits[audit_name]['sha256'],
                'limit': 'Same-run bounded behavior only; normative fields, complete615A and665 remain OPEN.'}
            operation['status'] = 'BOUNDED_IMPLEMENTED_FROZEN_FULL140_PASS_NORMATIVE_OPEN'
    path.write_text(json.dumps(scope, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Current entries, execution table and gaps synchronized from ' + snapshot)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sync(root, args.checkpoint.resolve())
