"""Measure cached-load, zero-time initialization and two original-TB windows.

Consumes a successful, frozen mapped feasibility run. Does not compile again,
change the TB/model/netlist or issue a business verdict. Exact observed times
are required; a requested-time marker alone cannot pass this diagnostic.
"""
import argparse
from datetime import datetime
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
import os


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def measurements(log, expected_ns=(100, 500)):
    markers = []
    for match in re.finditer(r'(?m)^#?\s*AFDX_COST phase=(\w+) wall_us=(\d+) sim=(.*?)\s*$', log):
        value = re.fullmatch(r'(\d+(?:\.\d+)?)\s*(fs|ps|ns|us|ms|s)', match[3])
        assert value, 'Unknown actual simulator time: ' + match[3]
        factor = {'fs': '0.000001', 'ps': '0.001', 'ns': '1', 'us': '1000',
                  'ms': '1000000', 's': '1000000000'}[value[2]]
        markers.append({'phase': match[1], 'wall_us': int(match[2]),
                        'actual_sim_ns': str(Decimal(value[1]) * Decimal(factor))})
    assert [m['phase'] for m in markers] == ['entry', 'initialized', 'window1', 'window2'], 'Missing/duplicate/out-of-order cost markers'
    assert [Decimal(m['actual_sim_ns']) for m in markers] == [0, 0, *expected_ns], 'Actual time does not match requested windows; possible early finish'
    assert all(b['wall_us'] >= a['wall_us'] for a, b in zip(markers, markers[1:])), 'Wall clock moved backward'
    increments = [{'from': a['phase'], 'to': b['phase'], 'wall_seconds': (b['wall_us']-a['wall_us'])/1e6,
                   'sim_ns': str(Decimal(b['actual_sim_ns'])-Decimal(a['actual_sim_ns']))}
                  for a, b in zip(markers, markers[1:])]
    return {'markers': markers, 'increments': increments,
            'limit': 'Two startup windows only; neither steady-state speed nor full-business completion inferred.'}


def run(args):
    root = Path(__file__).resolve().parents[1]
    candidate, original, out = args.candidate.resolve(), args.original_run.resolve(), args.out.resolve()
    assert all(p.is_relative_to(root/'out') for p in (candidate, original, out))
    assert not out.exists(), 'Use a new directory'
    source = read(original/'simulation_status.json')
    synth = read(candidate/'synthesis_status.json')
    contract = read(candidate/'candidate.json')
    assert source['status'] == 'DIAGNOSTIC_COMPLETED_NO_BUSINESS_VERDICT', 'Collect/review original failure first; no automatic retry'
    assert synth['status'] == 'EXPORTED_PENDING_MAPPED_SIMULATION'
    assert source['candidate_sha256'] == synth['candidate_sha256'] == sha(candidate/'candidate.json')
    assert source['vqm_sha256'] == synth['vqm_sha256'] == sha(candidate/'AFDX_top_native.vqm')
    assert source['synthesis_status_sha256'] == sha(candidate/'synthesis_status.json')
    assert source['configuration'] == contract['configuration']
    assert sha(original/'AFDX_top_native.vqm') == synth['vqm_sha256']
    original_case = contract['simulation_cases'][source['case']]
    assert sha(original/(source['top']+'.v')) == original_case['bound_sha256']
    assert sha(original/'afdx_host_bfm.v') == contract['input_sha256']['input/sim/env/afdx_host_bfm.v']
    for name in ('stratix_atoms.v', 'altera_primitives.v'):
        assert sha(original/name) == contract['input_sha256']['input/vendor/'+name]
    for path in (original/'vec').rglob('*'):
        if path.is_file():
            rel = 'input/sim/vec/'+path.relative_to(original/'vec').as_posix()
            assert sha(path) == contract['input_sha256'][rel], 'Original vector changed: ' + rel
    for rel, digest in contract['input_sha256'].items():
        assert sha(candidate/rel) == digest, 'Candidate input changed: ' + rel
    for step in source['steps']:
        assert step['status'] == 'PASS' and step['exit_code'] == 0, 'Original stage not qualified'
        assert sha(original/(step['name']+'.log')) == step['log_sha256']
        assert sha(original/(step['name']+'.stderr.log')) == step['stderr_log_sha256']
    vsim = next(s for s in source['steps'] if s['name'] == 'vsim')
    assert sha(Path(vsim['executable'])) == vsim['executable_sha256']
    expected_args = ['-c', '-voptargs=-O5 +nospecify', '-L', 'elinx_lib', 'work.'+source['top'], '-do', 'do simulation.do']
    assert vsim['arguments'] == expected_args, 'Original simulator command changed'
    shell = shutil.which('pwsh')
    assert shell
    gate = subprocess.run([shell, '-NoProfile', '-Command',
        'if(Get-Process -Name vsim,vsimk,vlog,eLinx_synthesis,abc,iverilog,ivl,vvp,quartus_sh,quartus_map,quartus_fit -ErrorAction SilentlyContinue){exit 1}else{exit 0}'],
        capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
    assert gate.returncode == 0, 'Heavy tools must be serial'
    out.mkdir()
    state = {'status': 'PREPARING', 'started_local': datetime.now().astimezone().isoformat(),
             'candidate_sha256': sha(candidate/'candidate.json'), 'original_status_sha256': sha(original/'simulation_status.json'),
             'runner_sha256': sha(Path(__file__)), 'business_verdict': None,
             'cache_policy': 'Copy exact existing compiled/optimized libraries; no fresh compile or cold-vopt claim.',
             'configuration': source['configuration'], 'scope': source['scope'], 'inputs': {}}

    def save():
        temp = out/'cost_status.json.tmp'
        temp.write_text(json.dumps(state, indent=2)+'\n', encoding='utf-8')
        temp.replace(out/'cost_status.json')

    save()
    try:
        for name in ('work', 'elinx_lib', 'vec'):
            shutil.copytree(original/name, out/name)
        for name in ('AFDX_top_native.vqm', 'stratix_atoms.v', 'altera_primitives.v', 'afdx_host_bfm.v', source['top']+'.v'):
            shutil.copy2(original/name, out/name)
        # Library path relocation only; preserve simulator settings verbatim.
        ini = (original/'modelsim.ini').read_text(encoding='utf-8-sig')
        for lib in ('work', 'elinx_lib'):
            ini, count = re.subn(r'(?m)^'+lib+r'\s*=.*$', lib+' = '+(out/lib).as_posix(), ini)
            assert count == 1, 'Expected exact library mapping: ' + lib
        (out/'modelsim.ini').write_text(ini, encoding='utf-8')
        for path in out.rglob('*'):
            if path.is_file() and path.name != 'cost_status.json':
                rel = path.relative_to(out).as_posix()
                state['inputs'][rel] = sha(path)
                if rel != 'modelsim.ini':
                    assert sha(original/rel) == state['inputs'][rel], 'Copied compiled/input byte mismatch'
        macro = ('onerror {quit -code 1}\nonbreak {quit -code 1}\n'
                 'puts "AFDX_COST phase=entry wall_us=[clock microseconds] sim=[now]"\n'
                 'run 0 ns\nputs "AFDX_COST phase=initialized wall_us=[clock microseconds] sim=[now]"\n'
                 'run 100 ns\nputs "AFDX_COST phase=window1 wall_us=[clock microseconds] sim=[now]"\n'
                 'run 400 ns\nputs "AFDX_COST phase=window2 wall_us=[clock microseconds] sim=[now]"\nquit -f\n')
        (out/'cost.do').write_text(macro, encoding='ascii')
        state['macro_sha256'] = sha(out/'cost.do')
        env = os.environ.copy()
        env['MODELSIM'] = str(out/'modelsim.ini')
        if not env.get('SALT_LICENSE_SERVER'):
            license_result = subprocess.run([shell, '-NoProfile', '-Command',
                "[Environment]::GetEnvironmentVariable('SALT_LICENSE_SERVER','User')"],
                capture_output=True, text=True, creationflags=subprocess.CREATE_NO_WINDOW)
            assert license_result.returncode == 0 and license_result.stdout.strip(), 'Local license unavailable'
            env['SALT_LICENSE_SERVER'] = license_result.stdout.strip()
        command = [vsim['executable'], *expected_args[:-1], 'do cost.do']
        state.update(status='RUNNING', command=command, timeout_seconds=args.timeout_seconds)
        save()
        start_wall = time.time_ns() // 1000
        start = time.monotonic()
        with (out/'vsim.stdout.log').open('xb') as stdout, (out/'vsim.stderr.log').open('xb') as stderr:
            process = subprocess.Popen(command, cwd=out, stdout=stdout, stderr=stderr, env=env,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
            state['owned_pid'] = process.pid
            save()
            try:
                state['exit_code'] = process.wait(timeout=args.timeout_seconds)
            except subprocess.TimeoutExpired:
                state['status'] = 'TIMEOUT'
                kill = subprocess.run([str(Path(env['SystemRoot'])/'System32/taskkill.exe'), '/PID', str(process.pid), '/T', '/F'],
                                      capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
                (out/'owned_tree_timeout.log').write_bytes(kill.stdout+kill.stderr)
                process.wait(timeout=15)
                raise AssertionError('Timeout; owned process tree stopped; no retry')
        state['wall_seconds'] = round(time.monotonic()-start, 6)
        assert state['exit_code'] == 0
        log = (out/'vsim.stdout.log').read_text(encoding='utf-8', errors='replace')
        stderr = (out/'vsim.stderr.log').read_text(encoding='utf-8', errors='replace')
        diagnostic = re.search(r'\*\*\s+(?:Error|Fatal|Warning)\b|(?:Errors|Warnings|Suppressed Warnings):\s*[1-9][0-9]*|\bFAIL\b|\[err\]', log+'\n'+stderr)
        assert not diagnostic, 'Strict diagnostic rejection: '+(diagnostic[0] if diagnostic else '')
        state['measurements'] = measurements(log)
        entry = state['measurements']['markers'][0]['wall_us']
        assert entry >= start_wall
        state['cached_load_to_do_entry_wall_seconds'] = (entry-start_wall)/1e6
        for rel, digest in state['inputs'].items():
            if not rel.startswith(('work/', 'elinx_lib/')):
                assert sha(out/rel) == digest, 'Logical stimulus/model input changed during observation'
        state['status'] = 'COST_WINDOWS_VERIFIED_NO_BUSINESS_VERDICT'
    except BaseException as error:
        if state['status'] != 'TIMEOUT':
            state['status'] = 'FAIL'
        state['error'] = str(error)
        raise
    finally:
        state['ended_local'] = datetime.now().astimezone().isoformat()
        state['logs'] = {p.name: sha(p) for p in out.glob('*.log')}
        save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--original-run', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--timeout-seconds', type=int, default=900)
    args = parser.parse_args()
    assert 60 <= args.timeout_seconds <= 900, 'Bounded cost observation only'
    run(args)
