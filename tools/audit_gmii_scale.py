"""Bind GMII scale/metrics/RTC evidence to one frozen regression and RTL frontend.

The frontend is only read_verilog/hierarchy or isolated proc/check evidence.
Neither this audit nor its scale workloads close the complete-message 2 ms gap.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


REQUIRED = {'T34p', 'T35p', 'T41', 'T42', 'T43', 'T16r', 'T16a', 'T16b'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def remove_expected_checker_selftest_lines(name, log):
    # T38 deliberately feeds malformed frames to the passive checker and
    # requires exact error-counter deltas. Accept only its seven documented
    # diagnostics in exact order, never a generic [chk] waiver.
    if name not in ('T38_console.txt', 'T38g_console.txt'):
        return log
    mode = 0 if name == 'T38_console.txt' else 1
    verdict = f'T38 MAC LENGTH CHECKER PASS (IF_MODE={mode} fcs=5 nofcs=6 exact_error_deltas=1)'
    assert len(re.findall(r'^# ' + re.escape(verdict) + r'\s*$', log, re.M)) == 1, name
    expected = [
        'A3 total len 63 (incl FCS; expected 64..1518)',
        'A3 total len 1518 (incl FCS; expected 64..1518)',
        'A12 FCS got c358ab01 want 7de041a4',
        'A12 FCS got de24fd99 want 5e24fd99',
        'A3 total len 59 (no FCS; expected 60..1514)',
        'A3 total len 1515 (no FCS; expected 60..1514)',
        'A3 total len 1518 (no FCS; expected 60..1514)',
    ]
    pattern = r'^#\s+\[chk\] (A(?:3|12) [^\r\n]+) t=\d+\s*$'
    assert re.findall(pattern, log, re.M) == expected, 'T38 self-test diagnostic sequence changed: ' + name
    return re.sub(pattern, '', log, flags=re.M)


def invoke(args):
    result = subprocess.run([sys.executable] + list(map(str, args)),
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout.strip())


def audit(run, baseline, frontend, require_full):
    target = run / 'GMII_SCALE_AUDIT.json'
    assert not target.exists(), 'Refusing to overwrite audit'
    workspace = run / 'workspace'
    metadata = json.loads((run/'run_metadata.json').read_text(encoding='utf-8-sig'))
    assert metadata['compile_result'] == metadata['regression_result'] == 'PASS'
    assert metadata['compile_rc'] == metadata['return_code'] == 0
    rows = metadata['test_results']
    ids = {row['id'] for row in rows}
    assert REQUIRED <= ids and len(ids) == len(rows), 'missing/duplicate required tests'
    assert all(row['result'] == 'PASS' and row['simulator_exit_code'] == 0 for row in rows)
    hashes = {'run_metadata.json': sha(run/'run_metadata.json')}
    for name in ['compile_console.txt'] + [row['console_log'] for row in rows]:
        log = (run/name).read_text(encoding='utf-8')
        assert 'Errors: 0, Warnings: 0' in log, name
        log = remove_expected_checker_selftest_lines(name, log)
        assert not re.search(r'\*\* (?:Error|Fatal|Warning)|\bFAIL\b|\[err\]|\[chk\]', log), name
        hashes[name] = sha(run/name)

    source_list = (workspace/'elinx/AFDX_top_sources.f').read_text().splitlines()
    assert len(source_list) == len(set(source_list)) == 50, 'production source list'
    previous = json.loads((baseline/'run_metadata.json').read_text(encoding='utf-8-sig'))
    fm = json.loads((frontend/'frontend_metadata.json').read_text(encoding='utf-8'))
    assert previous['compile_result'] == previous['regression_result'] == 'PASS'
    assert fm['source_list_sha256'] == sha(workspace/'elinx/AFDX_top_sources.f')
    assert set(fm['rtl_sha256']) == set(source_list), 'frontend source inventory'
    for rel in source_list:
        digest = metadata['source_sha256'][rel]
        assert digest == previous['source_sha256'][rel] == fm['rtl_sha256'][rel], rel
        assert sha(workspace/rel) == sha(baseline/'workspace'/rel) == sha(frontend/'input'/rel) == digest, rel
    assert len(fm['stages']) == 5
    for stage in fm['stages']:
        assert stage['verdict'] == 'PASS' and stage['exit_code'] == 0 and not stage['timed_out']
        assert not stage['warnings'] and not stage['errors']
        assert sha(frontend/(stage['label']+'.log')) == stage['log_sha256']
        assert sha(frontend/(stage['label']+'.ys')) == stage['script_sha256']

    # Rerun the frozen independent checkers in a disposable directory. Existing
    # audit files and every original capture remain untouched.
    with tempfile.TemporaryDirectory(prefix='gmii_scale_audit_') as td:
        scratch = Path(td)
        freeze_args = [workspace/'sim/freeze_regress.py', '--csv', run/'regress.csv',
                       '--out', scratch/'evidence.json']
        if require_full:
            freeze_args.append('--require-full')
        invoke(freeze_args)
        evidence = json.loads((scratch/'evidence.json').read_text(encoding='utf-8'))
        tx_records = {}
        for test, rounds in (('T33p', 16), ('T34p', 100)):
            if test not in ids:
                continue
            prefix = test[:3].lower() + '_vl128'
            invoke([workspace/'sim/check_vl128_phy.py', run/(test+'_console.txt'),
                    '--capture-a', run/'metrics'/(prefix+'_a.hex'),
                    '--capture-b', run/'metrics'/(prefix+'_b.hex'),
                    '--cycles-a', run/'metrics'/(prefix+'_a_cycles.txt'),
                    '--cycles-b', run/'metrics'/(prefix+'_b_cycles.txt'),
                    '--rounds', rounds, '--test-id', test[:3], '--out', scratch/(test+'.json')])
            tx_records[test] = json.loads((scratch/(test+'.json')).read_text())
            recorded = json.loads((run/(test+'_phy_audit.json')).read_text())
            assert tx_records[test] == recorded, 'TX audit changed: '+test
            hashes[test+'_phy_audit.json'] = sha(run/(test+'_phy_audit.json'))
        rx_args = [workspace/'sim/check_t35_coverage.py', run/'T35p_console.txt',
                '--mapping', workspace/'sim/vec/t35_mapping.csv',
                '--frames-hash', workspace/'sim/vec/t35_frames.sha256',
                '--frames', workspace/'sim/vec/t35_frames.hex',
                '--phy-a', run/'metrics/t35_phy_a.hex', '--phy-b', run/'metrics/t35_phy_b.hex',
                '--cycles-a', run/'metrics/t35_phy_a_cycles.txt',
                '--cycles-b', run/'metrics/t35_phy_b_cycles.txt', '--out-dir', scratch/'rx']
        invoke(rx_args)
        rx = json.loads((scratch/'rx/coverage_check.json').read_text())
        assert rx == json.loads((run/'T35p_coverage_check.json').read_text())
        assert rx['if_mode'] == 2 and rx['requested'] == rx['covered'] == rx['coverage_bits'] == 4096
        assert (scratch/'rx/coverage_bitmap.bin').read_bytes() == bytes([255])*512
        for name in ('coverage_bitmap.bin', 'deliveries.csv', 'mapping.csv', 'coverage_check.json'):
            assert sha(scratch/'rx'/name) == sha(run/'T35p_coverage'/name), name
            hashes['T35p_coverage/'+name] = sha(run/'T35p_coverage'/name)

        controls = []
        original = (run/'T35p_console.txt').read_text(encoding='utf-8')
        damaged, count = re.subn(r'(T35_DELIVERY index=0 .*payload=)([0-9a-fA-F])',
                                lambda m: m[1]+('1' if m[2]=='0' else '0'), original, count=1)
        assert count == 1
        bad_host = scratch/'bad_host.txt'
        bad_host.write_text(damaged, encoding='utf-8')
        frames = (run/'metrics/t35_phy_a.hex').read_text(encoding='ascii').splitlines()
        bad_frames = scratch/'missing_frame.hex'
        bad_frames.write_text('\n'.join(frames[:-1])+'\n', encoding='ascii')
        cycles = (run/'metrics/t35_phy_a_cycles.txt').read_text(encoding='ascii').splitlines()
        end = int(cycles[0].split()[1])
        cycles[1] = f'{end+1} {end+72}'
        bad_cycles = scratch/'bad_ifg.txt'
        bad_cycles.write_text('\n'.join(cycles)+'\n', encoding='ascii')
        for label, flag, path, reason in (
                ('host_payload_corruption', None, bad_host, 'T35 coverage audit failed:'),
                ('missing_PHY_input_frame', '--phy-a', bad_frames, 'PHY capture does not contain every selected index'),
                ('PHY_IFG_violation', '--cycles-a', bad_cycles, 'continuity/IFG mismatch')):
            bad_args = list(rx_args)
            bad_args[1 if flag is None else bad_args.index(flag)+1] = path
            bad_args[bad_args.index('--out-dir')+1] = scratch/label
            result = subprocess.run([sys.executable]+list(map(str,bad_args)), capture_output=True, text=True)
            assert result.returncode != 0 and reason in result.stdout+result.stderr, label
            controls.append(label)

    with (run/'metrics/t42_gmii.csv').open(encoding='ascii', newline='') as handle:
        metrics = list(csv.DictReader(handle))
    assert [row['direction'] for row in metrics] == ['tx_a', 'tx_b', 'rx_a']
    for row in metrics:
        calculated = int(row['verified_payload_bytes'])*8000/(int(row['window_cycles'])*int(row['clock_period_ns']))
        assert int(row['clock_period_ns']) == 8 and calculated >= 100
        assert abs(calculated-float(row['payload_mbps'])) <= 0.000001
    hashes['metrics/t42_gmii.csv'] = sha(run/'metrics/t42_gmii.csv')
    rtc = {}
    for test in ('T16r', 'T16a', 'T16b'):
        lines = (run/(test+'_console.txt')).read_text().splitlines()
        rtc[test] = [line for line in lines if 'METRIC' in line or ' PASS ' in line]
        assert any(' PASS ' in line for line in rtc[test]), test
    report = {'status': 'PASS', 'scope': evidence['scope'],
              'limits': '128VL uses16B payload scale load; T42 throughput uses16VL/1024B. RTC scenarios are separate. Not complete615A, all coexistence, complete synthesis, netlist business or complete-message2ms closure.',
              'test_count': len(rows), 'manifest_count': len([line for line in (workspace/'sim/tests.manifest').read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]),
              'production_sources': 50, 'frozen_inputs': len(evidence['source_sha256']),
              'rtl_baseline': str(baseline), 'frontend': str(frontend),
              'frontend_metadata_sha256': sha(frontend/'frontend_metadata.json'),
              'baseline_metadata_sha256': sha(baseline/'run_metadata.json'),
              'tx': tx_records, 'rx': rx, 'rx_negative_controls_rejected': controls,
              'throughput': metrics, 'rtc': rtc,
              'source_sha256': evidence['source_sha256'],
              'output_sha256': dict(evidence['evidence_sha256'], **hashes),
              'auditor_sha256': sha(Path(__file__))}
    target.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(f'GMII_SCALE_AUDIT_PASS tests={len(rows)} manifest={report["manifest_count"]} production_sources=50')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--frontend', type=Path, required=True)
    parser.add_argument('--require-full', action='store_true')
    args = parser.parse_args()
    audit(args.run.resolve(), args.baseline.resolve(), args.frontend.resolve(), args.require_full)
