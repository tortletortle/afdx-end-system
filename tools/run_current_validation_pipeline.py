"""Serial, resumable evidence collection after an already-started directed run.

Does not retry failures, overwrite runs, suppress diagnostics or infer protocol
closure. Each stage is recorded before launch and after its real process exit.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directed', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--frontend-out', type=Path, required=True)
    parser.add_argument('--full-out', type=Path, required=True)
    parser.add_argument('--reuse-directed-checks-from', type=Path)
    parser.add_argument('--public-repair-directed', action='store_true',
                        help='Use T78/T85/T86 repair checks before the actual full manifest; audit scale only on the full run')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    directed = args.directed.resolve()
    out = args.out.resolve()
    frontend = args.frontend_out.resolve()
    full = args.full_out.resolve()
    for path in [out, frontend, full]:
        assert path.is_relative_to(root), 'Output must remain in workspace'
        if path != frontend or not args.reuse_directed_checks_from:
            assert not path.exists(), f'Output exists: {path}'
    assert full.is_relative_to(root/'sim'), 'Full run must be under sim'
    shell = shutil.which('pwsh')
    assert shell, 'PowerShell 7 required (same runtime as interactive runner)'
    out.mkdir(parents=True)
    state = {'schema': 'serial-current-validation-pipeline-v1', 'status': 'WAITING_DIRECTED',
             'directed': str(directed), 'frontend': str(frontend), 'full': str(full),
             'started_local': datetime.now().astimezone().isoformat(),
             'runner_sha256': sha(Path(__file__)), 'stages': [],
             'powershell': shell, 'powershell_sha256': sha(Path(shell)),
             'scope': 'RTL evidence and frontend only; no synthesis/netlist/protocol closure'}

    def save():
        tmp = out/'pipeline_status.json.tmp'
        tmp.write_text(json.dumps(state, indent=2)+'\n', encoding='utf-8')
        tmp.replace(out/'pipeline_status.json')

    def serial_gate():
        command = [shell, '-NoProfile', '-Command',
                   "if(Get-Process -Name vsim,vsimk,iverilog,ivl,vvp,eLinx_synthesis,quartus_sh,quartus_map,quartus_fit -ErrorAction SilentlyContinue){exit 1}"]
        result = subprocess.run(command, capture_output=True,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        assert result.returncode == 0, 'Another heavy tool is active; do not launch'

    def stage(label, command, heavy=False):
        if heavy:
            serial_gate()
        entry = {'name': label, 'command': list(map(str, command)), 'status': 'RUNNING',
                 'started_local': datetime.now().astimezone().isoformat(), 'exit_code': None}
        state['status'] = 'RUNNING'
        state['current_stage'] = label
        state['stages'].append(entry)
        save()
        started = time.monotonic()
        print(f'PIPELINE START {label}', flush=True)
        log = out/(label+'.log')
        env = os.environ.copy()
        env['PYTHONIOENCODING'] = 'utf-8'
        with log.open('wb') as stream:
            proc = subprocess.Popen(entry['command'], cwd=root, env=env, stdout=stream,
                                    stderr=subprocess.STDOUT,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            entry['owned_pid'] = proc.pid
            save()
            entry['exit_code'] = proc.wait()
        entry.update(status='PASS' if entry['exit_code'] == 0 else 'FAIL',
                     elapsed_seconds=round(time.monotonic()-started, 3),
                     ended_local=datetime.now().astimezone().isoformat(), log_sha256=sha(log))
        save()
        print(f'PIPELINE {entry["status"]} {label} rc={entry["exit_code"]}', flush=True)
        assert entry['exit_code'] == 0, f'{label} failed; inspect {log}'

    try:
        save()
        meta_path = directed/'run_metadata.json'
        while True:
            meta = json.loads(meta_path.read_text(encoding='utf-8-sig'))
            if meta.get('regression_result') != 'RUNNING':
                break
            time.sleep(10)
        assert meta['regression_result'] == 'PASS' and meta['return_code'] == 0
        state['directed_metadata_sha256'] = sha(meta_path)
        sources = (directed/'workspace/elinx/AFDX_top_sources.f').read_text().splitlines()
        assert len(sources) == len(set(sources)) == 50
        for rel in sources:
            assert sha(root/rel) == meta['source_sha256'][rel], f'Root RTL changed: {rel}'
        py = sys.executable
        if args.public_repair_directed:
            assert not args.reuse_directed_checks_from
            assert {row['id'] for row in meta['tests']} == {'T78', 'T85', 'T86'}
            stage('directed_public_audit', [py, 'tools/audit_public_txrx.py', '--run', directed])
            stage('frontend', [py, 'tools/run_tx8k_frontend.py', '--run', directed, '--out', frontend,
                               '--audit', 'PUBLIC_TXRX_AUDIT.json'], heavy=True)
        elif args.reuse_directed_checks_from:
            previous_dir = args.reuse_directed_checks_from.resolve()
            previous_path = previous_dir/'pipeline_status.json'
            previous = json.loads(previous_path.read_text(encoding='utf-8'))
            assert previous['directed'] == str(directed) and previous['frontend'] == str(frontend)
            assert previous['directed_metadata_sha256'] == sha(meta_path)
            required = {'directed_tx_audit', 'directed_init_audit', 'directed_coexist_audit',
                        'frontend', 'directed_scale_audit'}
            for entry in previous['stages']:
                if entry['name'] in required:
                    assert entry['status'] == 'PASS' and entry['exit_code'] == 0
                    assert sha(previous_dir/(entry['name']+'.log')) == entry['log_sha256']
                    required.remove(entry['name'])
            assert not required, 'Missing previously passed stage'
            scale = json.loads((directed/'GMII_SCALE_AUDIT.json').read_text(encoding='utf-8'))
            fm_path = frontend/'frontend_metadata.json'
            assert scale['status'] == 'PASS' and scale['baseline_metadata_sha256'] == sha(meta_path)
            assert scale['frontend_metadata_sha256'] == sha(fm_path)
            fm = json.loads(fm_path.read_text(encoding='utf-8'))
            assert len(fm['stages']) == 5 and fm['verdict'] == 'PASS'
            for rel in sources:
                assert sha(frontend/'input'/rel) == fm['rtl_sha256'][rel] == meta['source_sha256'][rel]
            for entry in fm['stages']:
                assert entry['verdict'] == 'PASS' and entry['exit_code'] == 0
                assert sha(frontend/(entry['label']+'.log')) == entry['log_sha256']
                assert sha(frontend/(entry['label']+'.ys')) == entry['script_sha256']
            artifacts = {}
            for name in ['TX_PRODUCTION_AUDIT.json', 'INIT_SOURCE_AUDIT.json',
                         'TXRX_COEXIST_AUDIT.json', 'GMII_SCALE_AUDIT.json']:
                path = directed/name
                report = json.loads(path.read_text(encoding='utf-8'))
                assert report.get('status', report.get('verdict')) == 'PASS'
                artifacts[name] = sha(path)
            state['reused_directed_checks'] = {'previous_pipeline_sha256': sha(previous_path),
                                             'artifacts_sha256': artifacts,
                                             'frontend_metadata_sha256': sha(fm_path)}
            save()
            print('PIPELINE REUSED_HASH_VERIFIED_DIRECTED_CHECKS', flush=True)
        else:
            stage('directed_tx_audit', [py, 'tools/audit_tx8k_production.py', '--run', directed])
            stage('directed_init_audit', [py, 'tools/audit_a615a_init_source.py', '--run', directed])
            stage('directed_coexist_audit', [py, 'tools/audit_txrx_coexist.py', '--run', directed])
            stage('frontend', [py, 'tools/run_tx8k_frontend.py', '--run', directed, '--out', frontend], heavy=True)
            stage('directed_scale_audit', [py, 'tools/audit_gmii_scale.py', '--run', directed,
                                          '--baseline', directed, '--frontend', frontend])
        # Freeze the actual manifest; never concatenate targeted test sets.
        stage('full_regression', [shell, '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                 '-File', 'sim/run_regress.ps1', '-OutDir',
                                 str(full.relative_to(root/'sim')).replace('\\', '/')], heavy=True)
        full_meta = json.loads((full/'run_metadata.json').read_text(encoding='utf-8-sig'))
        for rel in sources:
            assert full_meta['source_sha256'][rel] == meta['source_sha256'][rel], rel
        stage('full_freeze', [py, 'sim/freeze_regress.py', '--csv', full/'regress.csv',
                              '--require-full', '--out', out/'full_evidence.json'])
        stage('full_tx_audit', [py, 'tools/audit_tx8k_production.py', '--run', full])
        stage('full_init_audit', [py, 'tools/audit_a615a_init_source.py', '--run', full])
        stage('full_coexist_audit', [py, 'tools/audit_txrx_coexist.py', '--run', full,
                                    '--frontend', frontend])
        stage('full_file_hold_audit', [py, 'tools/audit_a615a_file_hold.py', full])
        stage('full_scale_audit', [py, 'tools/audit_gmii_scale.py', '--run', full,
                                  '--baseline', full if args.public_repair_directed else directed,
                                  '--frontend', frontend, '--require-full'])
        if any(row['id'] == 'T86' for row in full_meta['tests']):
            stage('full_public_audit', [py, 'tools/audit_public_txrx.py', '--run', full])
        state.update(status='RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING', current_stage=None,
                     full_metadata_sha256=sha(full/'run_metadata.json'))
        print('PIPELINE RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING', flush=True)
    except BaseException as error:
        state.update(status='FAIL_STOP_NO_RETRY', exception=str(error))
        raise
    finally:
        state['updated_local'] = datetime.now().astimezone().isoformat()
        save()


if __name__ == '__main__':
    main()
