"""Make omitted vendor named ports explicit empty connections, without ties.

Only known primitive instances are transformed. Original connected expressions,
parameters and every other byte are preserved; removing inserted bytes must
reconstruct the entire input stream. Vendor simulation models remain unchanged.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def interfaces(paths):
    result = {}
    for path in paths:
        raw = path.read_text(encoding='utf-8-sig')
        raw = re.sub(r'/\*.*?\*/|//[^\n]*', '', raw, flags=re.S)
        for match in re.finditer(r'\bmodule\s+(\w+)\s*\((.*?)\)\s*;', raw, re.S):
            ports = [name.strip() for name in match[2].split(',')]
            if not all(re.fullmatch(r'\w+', name) for name in ports):
                continue  # Only non-ANSI primitive interfaces are supported.
            assert match[1] not in result, 'Duplicate vendor module interface'
            assert len(ports) == len(set(ports)), 'Duplicate primitive port'
            result[match[1]] = ports
    assert result, 'No vendor primitive interfaces'
    return result


def normalize(source, models, destination, review):
    assert not destination.exists() and not review.exists()
    ports_by_type = interfaces(models)
    header = re.compile(rb'^  (\w+) (\\[^\s]+|\w+) \(\r?\n$')
    connection = re.compile(rb'^    \.(\w+)\(')
    source_digest, restored_digest = hashlib.sha256(), hashlib.sha256()
    counts, added_ports = Counter(), Counter()
    examples = []
    total_instances = changed_instances = inserted_bytes = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    details = review.with_suffix('.instances.jsonl')
    assert not details.exists()
    with source.open('rb') as src, destination.open('xb') as dst, details.open('x', encoding='utf-8') as audit:
        line_number = 0
        for line in src:
            line_number += 1
            source_digest.update(line)
            match = header.fullmatch(line)
            if not match or match[1].decode() not in ports_by_type:
                dst.write(line)
                restored_digest.update(line)
                continue
            kind, instance = match[1].decode(), match[2].decode()
            first_line = line_number
            body = [line]
            connected = []
            while True:
                next_line = next(src)
                line_number += 1
                source_digest.update(next_line)
                port = connection.match(next_line)
                assert port, f'Unsupported primitive instance syntax at {line_number}'
                connected.append(port[1].decode())
                body.append(next_line)
                if next_line.rstrip(b'\r\n').endswith(b');'):
                    break
            assert len(connected) == len(set(connected)), 'Duplicate instance connection'
            declared = ports_by_type[kind]
            assert set(connected) <= set(declared), f'Unknown port for {kind}'
            missing = [name for name in declared if name not in connected]
            original = b''.join(body)
            total_instances += 1
            counts[kind] += 1
            if missing:
                last = body[-1]
                newline = b'\r\n' if last.endswith(b'\r\n') else b'\n'
                assert last.endswith(b');' + newline)
                prefix = b''.join(body[:-1]) + last[:-len(b');' + newline)]
                insertion = b',' + newline + (b',' + newline).join(b'    .' + name.encode() + b'()' for name in missing)
                transformed = prefix + insertion + b');' + newline
                restored = transformed[:len(prefix)] + transformed[len(prefix) + len(insertion):]
                assert restored == original, 'Round-trip changed an original expression'
                inserted_bytes += len(insertion)
                changed_instances += 1
                added_ports.update(kind + '.' + name for name in missing)
                row = dict(source_line=first_line, cell=kind, instance=instance, existing_ports=connected,
                           inserted_empty_ports=missing, original_sha256=hashlib.sha256(original).hexdigest(),
                           transformed_sha256=hashlib.sha256(transformed).hexdigest())
                audit.write(json.dumps(row) + '\n')
                if len(examples) < 8:
                    examples.append(row)
                dst.write(transformed)
                restored_digest.update(restored)
            else:
                dst.write(original)
                restored_digest.update(original)
    assert restored_digest.hexdigest() == source_digest.hexdigest() == sha(source)
    assert destination.stat().st_size == source.stat().st_size + inserted_bytes
    data = dict(status='EXPLICIT_EMPTY_VENDOR_PORTS_INSERTED_NOT_COMPILED',
                source=str(source), source_sha256=sha(source), output=str(destination), output_sha256=sha(destination),
                restored_sha256=restored_digest.hexdigest(), model_sha256={str(p): sha(p) for p in models},
                model_interfaces=ports_by_type, primitive_instances=total_instances,
                changed_instances=changed_instances, inserted_bytes=inserted_bytes,
                instances_by_type=dict(counts), inserted_empty_ports=dict(added_ports), examples=examples,
                full_change_index=str(details), full_change_index_sha256=sha(details),
                scope='Omitted named ports become explicit .port() only. No signal ties, expression/parameter/model/TB changes. Compilation/loading/business remain unproven.')
    review.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--model', type=Path, action='append', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--review', type=Path, required=True)
    args = parser.parse_args()
    report = normalize(args.source.resolve(), [p.resolve() for p in args.model], args.out.resolve(), args.review.resolve())
    print(json.dumps({key: report[key] for key in ('status', 'primitive_instances', 'changed_instances', 'inserted_bytes')}))
