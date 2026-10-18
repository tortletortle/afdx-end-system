"""Package two completed public scale runs without changing the full140 baseline.

Build and independently replay file auditors only. HDL reproduction is a later,
explicit execution in a fresh directory prepared from the resulting archive.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile

from native_gmii_contract import bind_tb
from prepare_validation_reproduction import GENERATED, safe_name


STATUS = 'PUBLIC_SCALE_TWO_DIRECTED_RTL_RUNS_NOT_FULL142_NOT_MAPPED'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_result(meta, case):
    require(meta['compile_result'] == meta['regression_result'] == 'PASS', case + ' verdict')
    require(meta['return_code'] == meta['compile_rc'] == meta['vlog_errors'] == 0, case + ' exit')
    require(meta['pass_count'] == meta['test_count'] == meta['tests_completed'] == 1, case + ' count')
    require(len(meta['tests']) == len(meta['test_results']) == 1, case + ' inventory')
    row = meta['test_results'][0]
    require(row['id'] == meta['tests'][0]['id'] == case, case + ' identity')
    require(row['result'] == 'PASS' and row['simulator_exit_code'] == 0, case + ' simulator')


def verify(bundle):
    """Validate every member, plus frozen source and production correspondence."""
    with zipfile.ZipFile(bundle) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'Duplicate archive member')
        for name in names:
            safe_name(name)
        manifest = json.loads(archive.read('SUPPLEMENT_MANIFEST.json'))
        require(manifest['status'] == STATUS and manifest['final_acceptance'] is False, 'Scope')
        require(set(manifest['cases']) == {'T34p', 'T35p'}, 'Exact directed case set')
        require(set(names) == set(manifest['members']) | {'SUPPLEMENT_MANIFEST.json'}, 'Member inventory')
        digests = {}
        for name, record in manifest['members'].items():
            data = archive.read(name)
            digest = hashlib.sha256(data).hexdigest()
            require(digest == record['sha256'] and len(data) == record['bytes'], 'Member hash: ' + name)
            digests[name] = digest
        baseline = json.loads(archive.read('evidence/base_full140_metadata.json'))
        require(baseline['regression_result'] == 'PASS' and baseline['return_code'] == 0
                and baseline['pass_count'] == baseline['test_count'] == 140, 'Full140 baseline')
        require(digests['evidence/base_full140_metadata.json'] == manifest['base_metadata_sha256'], 'Baseline hash')
        for case, contract in manifest['cases'].items():
            prefix = 'cases/' + case + '/'
            meta = json.loads(archive.read(prefix + 'evidence/run_metadata.json'))
            check_result(meta, case)
            require(digests[prefix + 'evidence/run_metadata.json'] == contract['qualification_metadata_sha256'], case + ' metadata binding')
            for relative, digest in meta['source_sha256'].items():
                safe_name(relative)
                location = 'recorded_generated/' if relative in GENERATED else 'workspace/'
                require(digests[prefix + location + relative] == digest, case + ' source: ' + relative)
            source_list = archive.read(prefix + 'workspace/elinx/AFDX_top_sources.f').decode('utf-8').splitlines()
            require(len(source_list) == len(set(source_list)) == 50, case + ' production inventory')
            for relative in source_list:
                require(meta['source_sha256'][relative] == baseline['source_sha256'][relative], case + ' production: ' + relative)
            tb_rel = 'sim/tb/' + contract['tb'] + '.v'
            tb = archive.read(prefix + 'workspace/' + tb_rel)
            require(bind_tb(tb, contract) == tb, case + ' public binding')
            require(hashlib.sha256(tb).hexdigest() == contract['bound_sha256'], case + ' TB hash')
            for relative, digest in contract['dependency_sha256'].items():
                require(meta['source_sha256'][relative] == digest, case + ' dependency: ' + relative)
    return manifest


def build(root, supplement, baseline, out):
    require(out.is_relative_to(root / 'out') and not out.exists(), 'Use a new directory under project/out')
    qualified = supplement / 'qualified_supplement/QUALIFIED_SUPPLEMENTAL_CONTRACTS.json'
    spec = read(qualified)
    require(spec['status'] == 'QUALIFIED_SUPPLEMENT_PREPARED_NOT_NATIVE_REGISTERED_NOT_MAPPED', 'Qualification scope')
    require(spec['base_full_metadata_sha256'] == sha(baseline / 'run_metadata.json'), 'Baseline changed')
    require(read(supplement / 'pipeline_status.json')['status'] ==
            'PUBLIC_FULL128TX100ROUNDS_AND4096RX_VARIANTS_PASS_MAPPED_PENDING', 'Directed execution incomplete')
    out.mkdir(parents=True)
    entries = {}

    def add(name, path):
        safe_name(name)
        require(name not in entries and path.is_file(), 'Missing/duplicate file: ' + name)
        entries[name] = path

    add('evidence/base_full140_metadata.json', baseline / 'run_metadata.json')
    add('evidence/qualified_contracts.json', qualified)
    add('evidence/reset_repair_review.json', supplement / 'REPAIR_REVIEW.json')
    add('evidence/directed_pipeline_status.json', supplement / 'pipeline_status.json')
    add('tools/pack_public_scale_supplement.py', Path(__file__))
    # The packaged preparation command needs exactly these two imported helpers.
    for relative in ('tools/native_gmii_contract.py', 'tools/prepare_validation_reproduction.py'):
        add(relative, root / relative)
    audit_replays = {}
    for case, contract in spec['cases'].items():
        run = root / contract['qualification_run']
        workspace = run / 'workspace'
        meta = read(run / 'run_metadata.json')
        check_result(meta, case)
        require(sha(run / 'run_metadata.json') == contract['qualification_metadata_sha256'], case + ' metadata changed')
        prefix = 'cases/' + case + '/'
        for relative, digest in meta['source_sha256'].items():
            safe_name(relative)
            path = workspace / relative
            require(path.resolve().is_relative_to(workspace.resolve()) and sha(path) == digest, case + ' input: ' + relative)
            location = 'recorded_generated/' if relative in GENERATED else 'workspace/'
            add(prefix + location + relative, path)
        for name in ('run_metadata.json', 'regress.csv', 'compile_console.txt', case + '_console.txt'):
            add(prefix + 'evidence/' + name, run / name)
        for name in ('compile_console.txt', case + '_console.txt'):
            log = (run / name).read_text(encoding='utf-8')
            require('Errors: 0, Warnings: 0' in log and not re.search(
                r'\*\* (?:Error|Fatal|Warning)|\bFAIL\b|\[err\]|\[chk\]', log), case + ' raw diagnostics')
        metrics = workspace / 'sim/out/metrics'
        auditor = 'check_vl128_phy.py' if case == 'T34p' else 'check_t35_coverage.py'
        replay = out / 'audit_replay' / case
        replay.mkdir(parents=True)
        if case == 'T34p':
            audit_name = 'T34p_phy_audit.json'
            result = replay / audit_name
            args = [workspace / 'sim' / auditor, run / (case + '_console.txt'), '--test-id', 'T34', '--rounds', '100',
                    '--capture-a', metrics / 't34_vl128_a.hex', '--capture-b', metrics / 't34_vl128_b.hex',
                    '--cycles-a', metrics / 't34_vl128_a_cycles.txt', '--cycles-b', metrics / 't34_vl128_b_cycles.txt', '--out', result]
        else:
            audit_name = 'T35p_coverage_check.json'
            result = replay / 'coverage_check.json'
            args = [workspace / 'sim' / auditor, run / (case + '_console.txt'),
                    '--mapping', workspace / 'sim/vec/t35_mapping.csv', '--frames-hash', workspace / 'sim/vec/t35_frames.sha256',
                    '--frames', workspace / 'sim/vec/t35_frames.hex', '--out-dir', replay,
                    '--phy-a', metrics / 't35_phy_a.hex', '--phy-b', metrics / 't35_phy_b.hex',
                    '--cycles-a', metrics / 't35_phy_a_cycles.txt', '--cycles-b', metrics / 't35_phy_b_cycles.txt']
        command = [sys.executable, *map(str, args)]
        p = subprocess.run(command, capture_output=True, encoding='utf-8')
        (replay / 'auditor.log').write_text(p.stdout + p.stderr, encoding='utf-8')
        require(p.returncode == 0, case + ' file audit failed: ' + p.stdout + p.stderr)
        require(read(result) == read(run / audit_name), case + ' independent audit changed')
        require(sha(run / audit_name) == contract['independent_audit_sha256'], case + ' original audit changed')
        audit_replays[case] = {'return_code': p.returncode, 'original_and_replayed_json_equal': True,
                              'result_sha256': sha(result), 'command': command}
        add(prefix + 'evidence/' + audit_name, run / audit_name)
        add(prefix + 'evidence/replayed_audit.json', result)
        add(prefix + 'evidence/replayed_auditor.log', replay / 'auditor.log')
        for capture in sorted(metrics.iterdir()):
            if capture.is_file():
                add(prefix + 'evidence/metrics/' + capture.name, capture)
    guide = out / 'START_HERE.md'
    guide.write_text('''# 公开端口规模补充复现包

本包对应同版50份生产RTL的两个独立完整入口：T34p为128条VL、100轮、A/B各12800帧；T35p为全部4096个RX索引及A/B重复消除、主机读回。原始严格日志、PHY捕获及再次执行的文件审计随包保留。

它是完整140项基线之外的两项公开观察变体，不是完整142项回归、网表业务、完整综合、100Mbps吞吐或最终验收。128VL场景使用16B应用载荷。原完整综合失败及615A/665、官方2ms口径仍按项目台账单列。

先解出tools目录中的三个Python脚本，再从一个项目目录准备全新输入（路径可用绝对路径）：

```powershell
python tools/pack_public_scale_supplement.py --prepare PUBLIC_SCALE_SUPPLEMENT.zip --out out/public_scale_reproduction_r1
```

准备只校验和解包，不运行HDL。全新workspace中省略六类确定性生成向量；原文件保存在recorded_generated，runner按原生成器重建。

在准备目录内依次进入cases/T34p/workspace和cases/T35p/workspace，串行运行：

```powershell
pwsh -NoProfile -File sim/run_regress.ps1 -OutDir out/reproduction_r1
```

环境需要Python、Questa/ModelSim及原runner的工具路径。保留新run_metadata、严格CSV和独立审计，逐件比较生产源及实际重新生成的向量哈希。包内已完成的原运行不等于这次解包后的实际执行。source中的历史文档仅是冻结输入，不替代本文件的范围说明。
''', encoding='utf-8')
    add('START_HERE.md', guide)
    manifest = {'schema': 'public-scale-supplement-v1', 'status': STATUS, 'final_acceptance': False,
                'prepared_local': datetime.now().astimezone().isoformat(), 'base_metadata_sha256': sha(baseline / 'run_metadata.json'),
                'cases': spec['cases'], 'file_audit_replays': audit_replays,
                'members': {name: {'sha256': sha(path), 'bytes': path.stat().st_size} for name, path in entries.items()}}
    bundle = out / 'PUBLIC_SCALE_SUPPLEMENT.zip'
    with zipfile.ZipFile(bundle, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, path in entries.items():
            archive.write(path, name)
        archive.writestr('SUPPLEMENT_MANIFEST.json', json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    verify(bundle)
    report = {'status': 'PACKAGE_AND_FILE_AUDIT_REPLAYS_PASS_HDL_REPRODUCTION_PENDING',
              'bundle_sha256': sha(bundle), 'bundle_bytes': bundle.stat().st_size, 'members': len(entries) + 1,
              'cases': list(spec['cases']), 'scope': STATUS, 'file_audit_replays': audit_replays,
              'tool_sha256': sha(Path(__file__))}
    (out / 'PACKAGE_REVIEW.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'file_audit_replays'}))


def prepare(bundle, out):
    manifest = verify(bundle)
    require(not out.exists(), 'Use a new reproduction directory')
    with zipfile.ZipFile(bundle) as archive:
        for name in archive.namelist():
            target = out / name
            require(target.resolve().is_relative_to(out.resolve()), 'Extraction path')
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as stream:
                stream.write(archive.read(name))
    # Verify the actual extracted files, not just the source ZIP.
    for name, record in manifest['members'].items():
        require(sha(out / name) == record['sha256'], 'Extracted hash: ' + name)
    for case in manifest['cases']:
        workspace = out / 'cases' / case / 'workspace'
        require(not (workspace / 'sim/vec/tx_fragment_builder').exists(), 'One-shot generated directory remains')
    report = {'status': 'EXTRACTED_HASH_VERIFIED_TWO_DIRECTED_RUNS_NOT_EXECUTED',
              'bundle_sha256': sha(bundle), 'members_verified': len(manifest['members']), 'scope': STATUS}
    (out / 'PREPARATION_REVIEW.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--supplement', type=Path)
    actions.add_argument('--verify', type=Path)
    actions.add_argument('--prepare', type=Path)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.verify:
        verified = verify(args.verify.resolve())
        print('PUBLIC_SCALE_ARCHIVE_VERIFIED members=' + str(len(verified['members']) + 1))
    else:
        require(args.out is not None, '--out required')
        project = Path.cwd().resolve()
        destination = args.out.resolve()
        require(destination.is_relative_to(project / 'out'), '--out must be under cwd/out')
        if args.prepare:
            prepare(args.prepare.resolve(), destination)
        else:
            require(args.baseline is not None, '--baseline required')
            build(project, args.supplement.resolve(), args.baseline.resolve(), destination)
