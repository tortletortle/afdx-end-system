"""Prepare fresh reproduction inputs without changing frozen bundle evidence.

Verify all original source members first, then omit the six deterministic
runtime-generated vector files only in a new workspace. The regression
runner regenerates them; an existing one-shot builder directory would fail.
Preparation is neither a functional reproduction nor an acceptance verdict.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import stat
import zipfile

GENERATED = {
    'sim/vec/t35_frames.hex', 'sim/vec/t35_frames.sha256', 'sim/vec/t35_mapping.csv',
    'sim/vec/tx_fragment_builder/cases.hex', 'sim/vec/tx_fragment_builder/manifest.json',
    'sim/vec/t36_mgmt.hex',
}

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()

def safe_name(name):
    path = PurePosixPath(name)
    assert not path.is_absolute() and '..' not in path.parts and '\\' not in name
    assert path.parts and all(':' not in part for part in path.parts)
    return path

def prepare(bundle, out):
    assert not out.exists(), 'Use a new reproduction directory; never modify extracted evidence'
    with zipfile.ZipFile(bundle) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), 'Duplicate archive members'
        for member in archive.infolist():
            safe_name(member.filename)
            assert not stat.S_ISLNK(member.external_attr >> 16), 'Symbolic link member'
        manifest = json.loads(archive.read('BUNDLE_MANIFEST.json').decode('utf-8'))
        assert manifest['status'] == 'FULL_RTL_AND_FRONTEND_EVIDENCE_NOT_FINAL_ACCEPTANCE'
        assert set(names) == set(manifest['members']) | {'BUNDLE_MANIFEST.json', 'START_HERE.md'}
        sources = {name[7:]: record for name, record in manifest['members'].items() if name.startswith('source/')}
        assert GENERATED.issubset(sources), 'Expected current deterministic generated inputs missing'
        verified = {}
        # Check the frozen members before creating any reproduction output.
        for relative, record in sources.items():
            safe_name(relative)
            digest = hashlib.sha256()
            size = 0
            with archive.open('source/' + relative) as stream:
                for block in iter(lambda: stream.read(1024*1024), b''):
                    digest.update(block)
                    size += len(block)
            assert digest.hexdigest() == record['sha256'] and size == record['bytes'], relative
            verified[relative] = record['sha256']
        out.mkdir(parents=True)
        copied = {}
        for relative, record in sources.items():
            if relative in GENERATED:
                continue
            destination = out / relative
            assert destination.resolve().is_relative_to(out)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open('source/' + relative) as source, destination.open('xb') as target:
                for block in iter(lambda: source.read(1024*1024), b''):
                    target.write(block)
            assert sha(destination) == record['sha256'], relative
            copied[relative] = record['sha256']
        assert not (out / 'sim/vec/tx_fragment_builder').exists(), 'Unexpected one-shot builder input remains'
    report = {
        'status': 'FRESH_INPUTS_HASH_VERIFIED_FUNCTIONAL_REPRODUCTION_PENDING',
        'prepared_local': datetime.now().astimezone().isoformat(),
        'bundle': str(bundle), 'bundle_sha256': sha(bundle), 'run_id': manifest['run_id'],
        'original_source_members_verified': len(verified), 'copied_source_sha256': copied,
        'omitted_deterministic_generated_sha256': {relative: verified[relative] for relative in sorted(GENERATED)},
        'tool_sha256': sha(Path(__file__)), 'final_acceptance': False,
        'full_command': ['pwsh', '-NoProfile', '-File', 'sim/run_regress.ps1', '-OutDir', 'out/reproduction_full_<unique-tag>'],
        'criterion': 'After actual execution, compare every regenerated vector hash and production source hash to these frozen hashes; retain actual manifest and strict result. Preparation alone is not execution.'
    }
    (out / 'SOURCE_PREPARATION_REVIEW.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: value for key, value in report.items() if key not in ('copied_source_sha256', 'omitted_deterministic_generated_sha256')}))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    # The task CLI keeps all reproduction writes inside the project output.
    project = Path.cwd().resolve()
    destination = args.out.resolve()
    assert destination.is_relative_to(project / 'out'), '--out must be a new directory under cwd/out'
    prepare(args.bundle.resolve(), destination)
