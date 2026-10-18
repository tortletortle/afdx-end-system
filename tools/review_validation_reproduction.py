"""Bind an actual clean-bundle reproduction to its frozen inputs and tests."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import zipfile


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()


def review(bundle, reproduction, run, tests, out):
    assert not out.exists(), 'New review directory required'
    preparation = json.loads((reproduction/'SOURCE_PREPARATION_REVIEW.json').read_text(encoding='utf-8'))
    meta = json.loads((run/'run_metadata.json').read_text(encoding='utf-8-sig'))
    with zipfile.ZipFile(bundle) as archive:
        manifest = json.loads(archive.read('BUNDLE_MANIFEST.json').decode('utf-8'))
    assert manifest['status'] == 'FULL_RTL_AND_FRONTEND_EVIDENCE_NOT_FINAL_ACCEPTANCE'
    assert preparation['bundle_sha256'] == sha(bundle)
    assert preparation['run_id'] == manifest['run_id']
    assert meta['regression_result'] == 'PASS' and meta['return_code'] == meta['compile_rc'] == 0
    assert [row['id'] for row in meta['tests']] == tests, 'Actual reproduced set differs from requested set'
    assert meta['pass_count'] == meta['test_count'] == len(tests)
    assert set(tests).issubset(manifest['ordered_test_ids'])
    sources = {name[7:]: record for name, record in manifest['members'].items() if name.startswith('source/')}
    copied = preparation['copied_source_sha256']
    generated = preparation['omitted_deterministic_generated_sha256']
    assert set(copied) | set(generated) == set(sources)
    assert not set(copied) & set(generated)
    # Document snapshots remain exact in the extracted root. Production and
    # all copied runtime inputs must also be in the actual runner's freeze.
    verified = {}
    missing_runtime = []
    for rel, digest in copied.items():
        assert digest == sources[rel]['sha256'] == sha(reproduction/rel), 'Extracted source changed: '+rel
        if rel in meta['source_sha256']:
            assert sha(run/'workspace'/rel) == meta['source_sha256'][rel] == digest, 'Actual run input changed: '+rel
            verified[rel] = digest
        elif rel.startswith(('rtl/', 'sim/', 'sw/golden/', 'elinx/AFDX_top_sources')):
            missing_runtime.append(rel)
    assert not missing_runtime, 'Copied functional inputs missing from actual freeze: '+repr(missing_runtime)
    generated_verified = {}
    unexercised_generated = []
    for rel, digest in generated.items():
        assert digest == sources[rel]['sha256']
        if rel in meta['source_sha256']:
            assert digest == meta['source_sha256'][rel] == sha(run/'workspace'/rel), 'Regenerated vector mismatch: '+rel
            generated_verified[rel] = digest
        else:
            # Selected replay need not generate inputs used only by other
            # manifest tests. Record this boundary; never claim full replay.
            assert not (run/'workspace'/rel).exists(), 'Existing regenerated input was omitted from freeze'
            unexercised_generated.append(rel)
    production = [line.strip() for line in (reproduction/'elinx/AFDX_top_sources.f').read_text(encoding='utf-8-sig').splitlines()
                  if line.strip() and not line.lstrip().startswith('#')]
    assert len(production) == len(set(production)) == 50
    assert all(rel in verified for rel in production)
    consoles = {test: sha(run/(test+'_console.txt')) for test in tests}
    report = {'status': 'ACTUAL_BUNDLE_SELECTED_REPRODUCTION_PASS',
              'observed_local': datetime.now().astimezone().isoformat(), 'bundle_sha256': sha(bundle),
              'bundle_run_id': manifest['run_id'], 'bundle_manifest_items': manifest['tests'],
              'preparation_sha256': sha(reproduction/'SOURCE_PREPARATION_REVIEW.json'),
              'actual_metadata_sha256': sha(run/'run_metadata.json'), 'reproduced_test_ids': tests,
              'production_sources_verified': len(production), 'copied_sources_verified': len(copied),
              'actual_copied_runtime_inputs_verified': len(verified), 'regenerated_inputs_verified': len(generated_verified),
              'unexercised_generated_inputs': unexercised_generated,
              'raw_console_sha256': consoles, 'reviewer_sha256': sha(Path(__file__)),
              'limit': 'Selected actual replay only; full manifest and mapped business evidence remain separate. Not final acceptance.'}
    out.mkdir()
    (out/'REVIEW.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ('status', 'reproduced_test_ids', 'production_sources_verified', 'regenerated_inputs_verified')}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--reproduction', required=True, type=Path)
    parser.add_argument('--run', required=True, type=Path)
    parser.add_argument('--tests', required=True, help='Exact ordered comma-separated IDs')
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    review(args.bundle.resolve(), args.reproduction.resolve(), args.run.resolve(), args.tests.split(','), args.out.resolve())
