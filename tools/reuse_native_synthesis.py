"""Reuse an exported native netlist only for identical synthesis inputs.

New tests or reports do not require repeating an unchanged complete synthesis.
Compare every production input, exact normalized commands, configuration and
tool hashes. Preserve original evidence and explicitly mark reuse, not rerun.
This operation does not run a simulator or claim netlist business acceptance.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import time


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def normalized_script(directory):
    return (directory / 'AFDX_top_native.ys').read_text(encoding='ascii').replace(
        directory.as_posix(), 'EXACT_CANDIDATE_ROOT').replace('\r\n', '\n').strip()


def qualify(previous, candidate):
    assert previous != candidate
    old, new = read(previous / 'candidate.json'), read(candidate / 'candidate.json')
    original = read(previous / 'synthesis_status.json')
    front = read(candidate / 'frontend_status.json')
    assert old['schema'] == new['schema'] == 'native-phy-candidate-v1'
    assert original['status'] == 'EXPORTED_PENDING_MAPPED_SIMULATION' and original['exit_code'] == 0
    assert not original.get('diagnostics'), 'Unreviewed synthesis diagnostics cannot be reused'
    assert original['candidate_sha256'] == sha(previous / 'candidate.json')
    assert original['script_sha256'] == sha(previous / 'AFDX_top_native.ys')
    assert sha(previous / 'synthesis.log') == original['log_sha256']
    assert sha(previous / 'AFDX_top_native.vqm') == original['vqm_sha256']
    assert front['status'] == 'PASS' and front['exit_code'] == 0
    assert front['candidate_sha256'] == sha(candidate / 'candidate.json')
    for field in ('top', 'configuration', 'parameter_policy', 'mapping_profile',
                  'hierarchy_policy', 'synthesis_executable_sha256',
                  'abc_executable_sha256', 'abc_pthread_dll_sha256', 'rtl_sources'):
        assert old[field] == new[field], 'Synthesis input policy changed: ' + field
    for relative, digest in new['input_sha256'].items():
        assert sha(candidate / relative) == digest, 'New candidate frozen input changed: ' + relative
    proof = {}
    for relative in old['rtl_sources']:
        name = 'input/' + relative
        expected = old['input_sha256'][name]
        assert expected == new['input_sha256'][name] == sha(previous / name) == sha(candidate / name), relative
        proof[relative] = expected
    assert normalized_script(previous) == normalized_script(candidate), 'Exact synthesis commands differ'
    assert sha(Path(new['synthesis_executable'])) == new['synthesis_executable_sha256']
    assert sha(Path(new['abc_executable'])) == new['abc_executable_sha256']
    assert sha(Path(new['abc_executable']).parent / 'pthreadVC2.dll') == new['abc_pthread_dll_sha256']
    return original, proof


def reuse(previous, candidate):
    started = time.monotonic()
    original, proof = qualify(previous, candidate)
    status_path = candidate / 'synthesis_status.json'
    netlist = candidate / 'AFDX_top_native.vqm'
    assert not status_path.exists() and not netlist.exists(), 'Never overwrite stage evidence'
    shutil.copy2(previous / 'AFDX_top_native.vqm', netlist)
    assert sha(netlist) == original['vqm_sha256']
    state = {
        'status': 'EXPORTED_PENDING_MAPPED_SIMULATION', 'stage': 'Synthesis',
        'execution': 'REUSED_EXACT_SOURCE_TOOL_AND_NORMALIZED_COMMANDS_NOT_RERUN',
        'exit_code': 0, 'diagnostics': [], 'candidate_sha256': sha(candidate / 'candidate.json'),
        'script_sha256': sha(candidate / 'AFDX_top_native.ys'),
        'runner_sha256': sha(Path(__file__)), 'recorded_local': datetime.now().astimezone().isoformat(),
        'original_candidate': str(previous), 'original_status_sha256': sha(previous / 'synthesis_status.json'),
        'original_log': str(previous / 'synthesis.log'), 'original_log_sha256': sha(previous / 'synthesis.log'),
        'original_synthesis_wall_seconds': original['wall_seconds'],
        'reuse_copy_wall_seconds': round(time.monotonic() - started, 3),
        'vqm_sha256': sha(netlist), 'vqm_bytes': netlist.stat().st_size,
        'production_sha256': proof,
        'normalized_synthesis_script_sha256': hashlib.sha256(normalized_script(candidate).encode('ascii')).hexdigest(),
        'scope': 'Original complete synthesis reused by exact correspondence; compilation/loading/business remain unverified for this new candidate',
    }
    status_path.write_text(json.dumps(state, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: value for key, value in state.items() if key != 'production_sha256'}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    previous, candidate = args.previous.resolve(), args.candidate.resolve()
    assert previous.is_relative_to(root / 'out') and candidate.is_relative_to(root / 'out')
    reuse(previous, candidate)
