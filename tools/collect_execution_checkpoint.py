"""Collect compact, live execution facts without starting any heavy tool.

Use a new output directory. Historical runs and evidence are never edited.
An immutable snapshot includes source correspondence, actual process inventory,
stage costs and limitations; it does not infer acceptance from a stage name.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


RECORDS = {
    'full_rtl': 'sim/out/gmii_guard_full137_20261013_r3/run_metadata.json',
    'rtl_pipeline': 'out/gmii_guard_validation_pipeline_20261013_r5/pipeline_status.json',
    'recovery': 'out/t15_capacity_recovery_pipeline_20261013_r3/pipeline_status.json',
    'mapped_pipeline': 'out/gmii_guard_mapped_pipeline_20261013_r4/pipeline_status.json',
    'synthesis': 'out/gmii_guard_native_default_20261013_r1/synthesis_status.json',
    'mapped_probe': 'out/gmii_guard_native_default_20261013_r1/sim_T78_Feasibility_cost_r1/simulation_status.json',
    'cost_review': 'out/current_mapped_cost_review_20261013_r2/REVIEW.json',
    'package': 'out/gmii_guard_rtl_bundle_20261013_r2/PACKAGE_REVIEW.json',
    'reproduction_inputs': 'out/gmii_guard_bundle_reproduction_20261013_r2/SOURCE_PREPARATION_REVIEW.json',
    'reproduction_run': 'out/gmii_guard_bundle_reproduction_20261013_r2/sim/out/bundle_smoke_20261013_r1/run_metadata.json',
    'followups': 'out/independent_followups_20261013_r2/followup_status.json',
    'public_queue': 'out/public_txrx_validation_queue_20261013_r1/queue_status.json',
    'rtc_directed': 'out/p09_rtc_management_draft_20261013_r1/workspace/sim/out/t85_directed_20261013_r1/run_metadata.json',
    'rtc_negative': 'out/p09_rtc_management_draft_20261013_r1/workspace/sim/out/t85_negative_20261013_r1/run_metadata.json',
    'public_directed': 'out/p11_public_txrx_draft_20261013_r1/workspace/sim/out/t86_directed_20261013_r1/run_metadata.json',
    'serial_followups': 'out/serial_followups_20261013_r3/followup_status.json',
    'rtc_hold_original': 'out/p09_hold_pps_original_20261013_r1/workspace/sim/out/hold_pps_original_20261013_r1/run_metadata.json',
    'public_repaired': 'out/public_txrx_observer_validation_20261013_r2/workspace/sim/out/phy_host_repaired_20261013_r2/run_metadata.json',
    'public_repaired_audit': 'out/public_txrx_observer_validation_20261013_r2/workspace/sim/out/phy_host_repaired_20261013_r2/PUBLIC_TXRX_AUDIT.json',
    'public_payload_negative': 'out/public_txrx_observer_validation_20261013_r2/workspace/sim/out/phy_host_negative_20261013_r2/run_metadata.json',
    'rtc_repair_preparation': 'out/rtc_hold_validation_preparation_20261013_r1/PREPARATION.json',
    'rtc_repair_pipeline': 'out/rtc_hold_validation_pipeline_20261013_r2/pipeline_status.json',
    'rtc_original_unit': 'out/rtc_hold_unit_original_20261013_r1/workspace/sim/out/rtc_hold_unit_original_20261013_r1/run_metadata.json',
    'rtc_repaired_directed': 'out/rtc_hold_repaired_validation_20261013_r1/workspace/sim/out/rtc_hold_repaired_directed_20261013_r2/run_metadata.json',
    'rtc_repaired_adjacent': 'out/rtc_hold_repaired_validation_20261013_r1/workspace/sim/out/rtc_hold_adjacent_20261013_r2/run_metadata.json',
    'fetch_loop_pipeline': 'out/fetch_start_loop_validation_20261013_r1/pipeline_status.json',
    'fetch_admission_directed': 'out/fetch_start_loop_repair_20261013_r1/workspace/sim/out/fetch_admission_directed_20261013_r1/run_metadata.json',
    'synthesis_failure_review': 'out/current_synthesis_failure_review_20261013_r1/REVIEW.json',
    'public_exact_negative_review': 'out/public_txrx_exact_negative_review_20261013_r1/REVIEW.json',
    'bundle_reproduction_review': 'out/gmii_guard_bundle_reproduction_review_20261013_r1/REVIEW.json',
    'repair_integration': 'out/production_repairs_integration_20261013_r1/INTEGRATION_REVIEW.json',
    'combined_directed': 'sim/out/production_repairs_directed_20261013_r1/run_metadata.json',
    'current_140_pipeline': 'out/production_repairs_validation_pipeline_20261013_r1/pipeline_status.json',
    'current_140_full': 'sim/out/production_repairs_full140_20261013_r1/run_metadata.json',
    'current_140_frontend': 'out/production_repairs_frontend_20261013_r1/frontend_metadata.json',
    'current_140_mapped': 'out/production_repairs_hierarchical_mapped_20261013_r1/pipeline_status.json',
    'current_140_execution': 'out/production_repairs_execution_20261013_r1/pipeline_status.json',
    'current_140_package': 'out/production_repairs_rtl_bundle_20261013_r1/PACKAGE_REVIEW.json',
    'current_140_synthesis': 'out/production_repairs_native_hierarchy_default_20261013_r1/synthesis_status.json',
    'current_140_probe': 'out/production_repairs_native_hierarchy_default_20261013_r1/sim_T78_Feasibility_cost_r1/simulation_status.json',
    'current_140_continuation': 'out/production_repairs_delivery_continuation_20261013_r1/pipeline_status.json',
    'current_hierarchy_memory': 'out/current_hierarchy_memory_observation_20261013_r1/observation_status.json',
    'current_140_reproduction_execution': 'out/production_repairs_bundle_replay_execution_20261013_r1/pipeline_status.json',
    'current_140_reproduction_preparation': 'out/production_repairs_bundle_reproduction_20261013_r1/SOURCE_PREPARATION_REVIEW.json',
    'current_140_reproduction_run': 'out/production_repairs_bundle_reproduction_20261013_r1/sim/out/current_bundle_selected_20261013_r1/run_metadata.json',
    'current_140_reproduction_review': 'out/production_repairs_bundle_reproduction_review_20261013_r1/REVIEW.json',
    'public_scale_preparation': 'out/public_scale_case_preparation_20261013_r1/REVIEW.json',
    'public_scale_validation': 'out/public_scale_case_validation_20261013_r1/pipeline_status.json',
    'public_scale_reset_repair': 'out/public_scale_reset_repair_20261013_r1/pipeline_status.json',
    'public_scale_reset_review': 'out/public_scale_reset_repair_20261013_r1/REPAIR_REVIEW.json',
    'public_reset_diagnosis': 'out/continuation_diagnosis_20261013_r1/reset_probe_r3/RESET_REVIEW.json',
    'native_abc_static_diagnosis': 'out/continuation_diagnosis_20261013_r1/abc_probe/STATIC_ARTIFACT_REVIEW.json',
    'native_abc_dynamic_diagnosis': 'out/continuation_diagnosis_20261013_r1/abc_probe/PROBE_STATUS.json',
    'public_scale_qualified_supplement': 'out/public_scale_reset_repair_20261013_r1/qualified_supplement/QUALIFIED_SUPPLEMENTAL_CONTRACTS.json',
    'native_fresh_boundary_attempt': 'out/native_boundary_continuation_20261013_r2/pipeline_status.json',
    'native_per_module_attempt': 'out/native_per_module_mapping_20261013_r1/pipeline_status.json',
    'native_isolated_module_attempt': 'out/native_isolated_module_mapping_20261013_r1/pipeline_status.json',
    'native_isolated_module_synthesis': 'out/production_repairs_native_isolated_modules_default_20261013_r1/synthesis_status.json',
    'native_isolated_module_probe': 'out/production_repairs_native_isolated_modules_default_20261013_r1/sim_T78_Feasibility_isolated_modules_cost_r1/simulation_status.json',
}
FIELDS = (
    'schema', 'status', 'regression_result', 'current_stage', 'current_test',
    'tests_completed', 'test_count', 'pass_count', 'return_code', 'compile_rc',
    'exception', 'error', 'wall_seconds', 'wall_seconds_per_sim_microsecond',
    'configuration', 'vqm_bytes', 'vqm_sha256', 'diagnostics', 'outcome_class',
    'archive', 'archive_sha256', 'members', 'tests', 'bounded_reproduction_status',
    'observed_predecessor_terminal', 'observed_mapped_terminal',
    'architecture', 'large_address_aware', 'new_netlist_exported',
    'error_count', 'complete_cases', 'only_production_difference', 'root_rtl_changed',
    'production_sources_verified', 'copied_sources_verified', 'reproduced_test_ids',
    'samples', 'process_observed_maxima', 'limits', 'terminal_diagnostics',
    'observed_continuation_terminal', 'bundle_manifest_items', 'bundle_sha256',
    'regenerated_inputs_verified', 'unexercised_generated_inputs',
    'actual_public_runs', 'tx_phy_audit_sha256', 'rx_coverage_audit_sha256',
    'actual_results', 'preabc_missing_wire_count', 'observed_public_scale_terminal',
    'mapped_modules', 'module_count', 'prepared_modules', 'added_terminal_declarations',
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def compact(data):
    result = {key: data[key] for key in FIELDS if key in data}
    if 'tests' in result and isinstance(result['tests'], list):
        result['test_count'] = len(result.pop('tests'))
    for group in ('stages', 'steps'):
        if group in data:
            result[group] = [{key: row[key] for key in (
                'name', 'label', 'verdict', 'status', 'exit_code', 'timed_out', 'owned_pid', 'process_id',
                'wall_seconds', 'elapsed_seconds', 'started_local', 'ended_local',
                'first_diagnostic', 'diagnostic_file', 'error', 'log_sha256',
            ) if key in row} for row in data[group]]
    return result


def collect(root, out):
    assert out.is_relative_to(root / 'out') and not out.exists()
    report = {'schema': 'afdx-live-execution-checkpoint-v1',
              'observed_local': datetime.now().astimezone().isoformat(),
              'collector_sha256': sha(Path(__file__)), 'records': {},
              'final_acceptance': False}
    raw = {}
    for name, relative in RECORDS.items():
        path = root / relative
        if not path.exists():
            report['records'][name] = {'path': relative, 'observation': 'NOT_CREATED'}
            continue
        content = path.read_bytes()
        data = json.loads(content.decode('utf-8-sig'))
        raw[name] = data
        report['records'][name] = dict(path=relative,
            sha256=hashlib.sha256(content).hexdigest(), **compact(data))
    run = raw.get('full_rtl', {})
    sources = (root / 'elinx/AFDX_top_sources.f').read_text(encoding='utf-8-sig').splitlines()
    sources = [line.strip() for line in sources if line.strip() and not line.startswith('#')]
    mismatches = [relative for relative in sources
                  if not (root / relative).exists()
                  or sha(root / relative) != run.get('source_sha256', {}).get(relative)]
    manifest = root / 'sim/tests.manifest'
    ids = [line.split()[0] for line in manifest.read_text(encoding='utf-8').splitlines()
           if line.strip() and not line.lstrip().startswith('#')]
    report['root_correspondence'] = {
        'production_sources': len(sources), 'production_mismatches': mismatches,
        'root_manifest_count': len(ids), 'root_manifest_sha256': sha(manifest),
        'manifest_matches_frozen_run': sha(manifest) == run.get('source_sha256', {}).get('sim/tests.manifest'),
        'limit': 'Production source and manifest correspondence only; not a new regression or all-runtime-input audit',
    }
    shell = shutil.which('pwsh')
    assert shell, 'PowerShell7 required for actual process inventory'
    inventory = subprocess.run([shell, '-NoProfile', '-Command',
        '$ErrorActionPreference="Stop"; @(Get-Process -Name vsim,vsimk,vlog,eLinx_synthesis,abc,iverilog,ivl,vvp,quartus_sh,quartus_map,quartus_fit -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,StartTime,CPU,WorkingSet64) | ConvertTo-Json -Compress'],
        capture_output=True, text=True, encoding='utf-8',
        creationflags=subprocess.CREATE_NO_WINDOW, timeout=30)
    assert inventory.returncode == 0, inventory.stderr
    report['heavy_processes'] = json.loads(inventory.stdout.strip() or '[]')
    if isinstance(report['heavy_processes'], dict):
        report['heavy_processes'] = [report['heavy_processes']]
    report['process_scope'] = 'Instantaneous Get-Process inventory; RUNNING metadata alone does not prove liveness'
    run_dir = root / 'sim/out/gmii_guard_full137_20261013_r3'
    report['independent_audits'] = {}
    for name in ('TX_PRODUCTION', 'INIT_SOURCE', 'TXRX_COEXIST', 'FILE_HOLD', 'GMII_SCALE'):
        path = run_dir / (name + '_AUDIT.json')
        if path.exists():
            data = json.loads(path.read_text(encoding='utf-8-sig'))
            report['independent_audits'][name] = {
                'path': path.relative_to(root).as_posix(), 'sha256': sha(path),
                'status': data.get('status', data.get('verdict', 'UNKNOWN')),
            }
        else:
            report['independent_audits'][name] = {'status': 'NOT_CREATED'}
    current_run = root / 'sim/out/production_repairs_full140_20261013_r1'
    report['current_candidate_audits'] = {}
    report['current_complete_message_latency'] = {'status': 'CURRENT_SAME_RUN_AUDIT_NOT_CREATED',
        'measurement': 'Host commit task call to complete last PHY byte; legal1ms BAG; official applicability/start/end separately unresolved'}
    for name in ('TX_PRODUCTION', 'INIT_SOURCE', 'TXRX_COEXIST', 'FILE_HOLD', 'GMII_SCALE', 'PUBLIC_TXRX'):
        path = current_run / (name + '_AUDIT.json')
        row = {'path': path.relative_to(root).as_posix(), 'status': 'NOT_CREATED'}
        if path.exists():
            audit = json.loads(path.read_text(encoding='utf-8-sig'))
            row.update(sha256=sha(path), status=audit.get('status', audit.get('verdict', 'UNKNOWN')))
            if name == 'TX_PRODUCTION' and row['status'] == 'PASS':
                assert audit['output_sha256']['metadata'] == report['records']['current_140_full']['sha256'], 'Latency audit is not bound to current same-run metadata'
                large = [item for item in audit['latencies'] if item['application_bytes'] == 8192]
                assert len(large) == 2 and len({item['message'] for item in large}) == 2
                exceeds = all(item['A_ns'] > 2_000_000 and item['B_ns'] > 2_000_000 for item in large)
                report['current_complete_message_latency'].update(status='CURRENT_SAME_RUN_MEASURED_OVER_2MS' if exceeds else 'CURRENT_SAME_RUN_MEASUREMENT_REQUIRES_REVIEW',
                    audit_path=row['path'], audit_sha256=row['sha256'], latencies=large,
                    over_2ms_on_both_networks=exceeds)
        report['current_candidate_audits'][name] = row
    if 'current_140_full' in raw:
        latest = raw['current_140_full']
        report['current_candidate_root_correspondence'] = {
            'production_mismatches': [p for p in sources if sha(root/p)!=latest['source_sha256'].get(p)],
            'manifest_matches_frozen_run': sha(manifest)==latest['source_sha256'].get('sim/tests.manifest'),
        }
    report['open_semantics'] = {
        'latency_acceptance': 'Official applicability and start/end events await competition clarification',
        'measured_complete_message': '8192B/six fragments/1ms BAG: 6.063448ms checksum-off and 6.161736ms checksum-on in guard directed r3; exceeds2ms under that measurement',
        '615a': 'Published scope verified; normative LUI/LUS/LUR/progress/tag/load-unload/665 clauses still unconfirmed',
        'netlist': 'Compilation, loading, time-advance observation and business verdict remain separate',
    }
    out.mkdir()
    (out / 'CHECKPOINT.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    lines = ['# 当前执行证据快照', '', f"核验：{report['observed_local']}。本文件不是最终验收通过声明。", '',
             '| 阶段 | 实际记录 | 证据 |', '|---|---|---|']
    for name, row in report['records'].items():
        state = row.get('status', row.get('regression_result', row.get('observation', 'UNKNOWN')))
        if name in ('full_rtl', 'reproduction_run') and 'pass_count' in row:
            state += f"; {row['pass_count']}/{row.get('test_count', '?')} PASS"
        if row.get('current_stage'):
            state += '; ' + row['current_stage']
        if row.get('current_test') and row.get('regression_result') == 'RUNNING':
            state += '; ' + row['current_test']
        lines.append(f"| {name} | {state} | `{row['path']}` |")
    lines += ['', f"现场重型进程：{len(report['heavy_processes'])}（vsim/vsimk为同一Questa会话的父子进程）。",
              f"生产源对应：{len(sources)}项，差异{len(mismatches)}；root manifest {len(ids)}项，是否同冻结manifest：{report['root_correspondence']['manifest_matches_frozen_run']}。",
              '', '未决：赛方2ms口径与完整消息实测超2ms分别登记；完整615A规范与必验业务待核实；短网表成本观察不代表业务通过。',
              '保留所有历史失败，不重复旧C4 mapped TIMEOUT；重型工具串行。', '']
    (out / 'CHECKPOINT.md').write_text('\n'.join(lines), encoding='utf-8')
    print(json.dumps({'checkpoint': str(out / 'CHECKPOINT.json'),
                      'full': report['records']['full_rtl'],
                      'heavy_processes': report['heavy_processes'],
                      'root_correspondence': report['root_correspondence']}, ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    collect(Path(__file__).resolve().parents[1], args.out.resolve())
