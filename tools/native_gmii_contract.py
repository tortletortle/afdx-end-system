"""Bind unchanged public-port test bodies to an exact synthesized configuration.

The only permitted binding edit removes the verified AFDX_top parameter
override: mapped netlists have already fixed those values during synthesis.
No stimulus, timing, payload or assertion is transformed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bind_tb(source, contract):
    text = source.decode('utf-8')
    instance = contract['instance']
    assert text.count(instance) == 1, 'Exact original DUT parameter contract changed'
    assert len(re.findall(r'\bAFDX_top\b\s*(?:#\s*\([^;]+?\)\s*)?dut\s*\(', text)) == 1
    assert not re.search(r'\bdut\s*\.', text), 'RTL hierarchy reference is not a public-port case'
    assert not re.search(r'\b(?:force|release)\s+dut\b', text), 'RTL force is not allowed'
    if contract['parameters']:
        assert '#(' in instance
        actual = {k: int(v) for k, v in re.findall(r'\.(\w+)\((\d+)\)', instance)}
        assert actual == contract['parameters'], 'Instance and synthesis parameter mismatch'
        bound = text.replace(instance, 'AFDX_top dut (', 1).encode('utf-8')
        assert bound.replace(b'AFDX_top dut (', instance.encode('utf-8'), 1) == source
        return bound
    assert instance == 'AFDX_top dut ('
    return source


def prepare(candidate, configuration):
    spec_path = candidate/'native_gmii_cases.json'
    spec = json.loads(spec_path.read_text(encoding='utf-8'))
    assert spec['schema'] == 'native-gmii-public-case-contracts-v1'
    selected = {}
    for case, contract in spec['cases'].items():
        if contract['configuration'] != configuration:
            continue
        original = candidate/'input/sim/tb'/f"{contract['tb']}.v"
        destination = candidate/'input/mapped_tb'/original.name
        destination.parent.mkdir(exist_ok=True)
        assert not destination.exists(), 'Never overwrite a prepared test'
        destination.write_bytes(bind_tb(original.read_bytes(), contract))
        selected[case] = dict(contract, original_sha256=sha(original), bound_sha256=sha(destination),
                              bound_tb=destination.relative_to(candidate).as_posix(),
                              binding='Remove only exact parameter override; values fixed in synthesis' if contract['parameters'] else 'Byte-identical original TB')
    return {'configuration': configuration, 'cases': selected,
            'open_coverage': spec['open_coverage'], 'contract_sha256': sha(spec_path)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--configuration', required=True)
    args = parser.parse_args()
    report = prepare(args.candidate.resolve(), args.configuration)
    output = args.candidate/'mapped_case_contracts.json'
    assert not output.exists()
    output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print('Prepared exact public-port bindings:', ','.join(report['cases']) or 'no qualified case for this configuration')
