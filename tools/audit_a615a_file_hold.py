"""Audit one frozen LUR file-hold regression; never overwrite evidence."""
import argparse
import hashlib
import json
import re
import struct
import zlib
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checksum(data):
    data += bytes(len(data) % 2)
    value = sum(struct.unpack('!' + str(len(data)//2) + 'H', data))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return (~value) & 65535


def audit_phy(run):
    expected = [(b'\x00\x04' + n.to_bytes(2, 'big'), 40100) for n in [0, 1, 2, 2]]
    for name in [b'A.BIN', b'C.DE', b'A.BIN']:
        expected.append((b'\x00\x01' + name + b'\0octet\0', 69))
        expected.extend((b'\x00\x04' + n.to_bytes(2, 'big'), 40100) for n in [1, 2])
    t62 = (run/'T62_console.txt').read_text(encoding='utf-8')
    lifecycle = re.search(r'control_cases=[45]\b',t62) is not None
    if lifecycle:
        # An already-committed RRQ from the aborted restart may finish before
        # the negative control exchanges. It is preserved and checked too.
        first_rows = (run/'workspace/sim/out/t62_phy_a.hex').read_text(encoding='ascii').splitlines()
        extra_frame = bytes.fromhex(first_rows[len(expected)])[8:]
        extra_ip_total = int.from_bytes(extra_frame[16:18], 'big')
        if extra_frame[42:14+extra_ip_total] == b'\x00\x01A.BIN\0octet\0':
            expected.append((b'\x00\x01A.BIN\0octet\0',69))
        for op, block, port in [(5,2,40100),(4,0,40100),(4,1,40100),
                                (4,0,40100),(4,1,40100),(4,2,40100),
                                (5,2,40100),(4,0,40100),(4,1,40100),
                                (4,2,40100),(5,5,40101)]:
            payload = struct.pack('!HH',op,block) + (b'TFTP ERR\0' if op==5 else b'')
            expected.append((payload,port))
        if 'control_cases=5' in t62:
            expected.extend([(b'\x00\x05\x00\x02TFTP ERR\0',40100),(b'\x00\x04\x00\x00',40100)])
    streams = []
    capture_hashes = {}
    for net in ['a', 'b']:
        path = run / 'workspace/sim/out' / ('t62_phy_' + net + '.hex')
        rows = path.read_text(encoding='ascii').splitlines()
        capture_hashes[net]=sha(path)
        assert len(rows) >= len(expected), (net, len(rows))
        if lifecycle:
            assert len(rows)==len(expected)
        decoded = []
        for index, row in enumerate(rows):
            phy = bytes.fromhex(row)  # also rejects X/Z or truncated octets
            assert phy[:8] == b'\x55'*7 + b'\xd5', (net, index, 'preamble')
            frame = phy[8:]
            assert len(frame) >= 64 and frame[12:14] == b'\x08\x00'
            assert int.from_bytes(frame[-4:], 'little') == zlib.crc32(frame[:-4])
            ip = frame[14:34]
            assert ip[0] == 0x45 and ip[9] == 17 and checksum(ip) == 0
            total = int.from_bytes(ip[2:4], 'big')
            udp = frame[34:14+total]
            sport, dport, length, csum = struct.unpack('!HHHH', udp[:8])
            assert length == len(udp) and total == length+20
            assert csum != 0 and checksum(ip[12:20] + b'\x00\x11' + udp[4:6] + udp) == 0
            assert sport == 0x3001
            assert all(byte == 0 for byte in frame[14+total:-5]), 'nonzero MAC pad'
            payload = udp[8:]
            if index < len(expected):
                assert (payload, dport) == expected[index], (net, index, payload.hex(), dport)
            else:
                # The final aborted restart may reach PHY before cancellation.
                assert index == len(expected) and (payload, dport) == (b'\x00\x01A.BIN\0octet\0', 69)
            decoded.append((ip, udp, frame[-5], len(phy)))
        streams.append(decoded)
    assert streams[0] == streams[1], 'A/B IP/UDP/SN/frame lengths differ'
    return {'frames_per_net': len(streams[0]), 'complete_phy_fcs_ip_udp_payload': 'PASS',
            'capture_sha256':capture_hashes}


def audit(run):
    meta = json.loads((run / 'run_metadata.json').read_text(encoding='utf-8-sig'))
    assert meta['regression_result'] == 'PASS' and meta['return_code'] == 0
    assert meta['compile_result'] == 'PASS' and meta['compile_rc'] == 0
    for name, digest in meta['source_sha256'].items():
        assert sha(run / 'workspace' / name) == digest, name
    results = {item['id']: item for item in meta['test_results']}
    assert {'T57', 'T58', 'T62'} <= results.keys()
    logs = {}
    for name in ['compile_console.txt'] + [item['console_log'] for item in results.values()]:
        raw = (run / name).read_text(encoding='utf-8', errors='strict')
        assert re.search(r'Errors: 0, Warnings: 0', raw), name
        # T45's successful verdict is literally "TFTP TIMEOUT CONTRACT PASS".
        # Reject actual failure/error markers; runner metadata/exit codes above
        # reject wall-clock timeouts without mistaking the scenario title.
        assert not re.search(r'\*\* (?:Error|Fatal|Warning)|\bFAIL\b|\[err\]|^\s*(?:#\s*)?TIMEOUT\b', raw,re.M), name
        logs[name] = sha(run / name)
    for item in results.values():
        assert item['result'] == 'PASS' and item['simulator_exit_code'] == 0
    t62 = (run / results['T62']['console_log']).read_text(encoding='utf-8')
    assert 'Loading work.afdx_bind_full' in t62
    assert len(re.findall(r'T62 LUR TOP PASS ', t62)) == 1
    assert 'readback_bytes=1560 confirmed_files=2 aborted_files=1' in t62
    assert re.findall(r'T62 FILE_VERIFIED file=(\d+) bytes=520 still_published=1', t62) == ['1', '2', '3']
    t58 = (run / results['T58']['console_log']).read_text(encoding='utf-8')
    assert len(re.findall(r'T58 LUR ORCH PASS ', t58)) == 1
    for case in ['K9', 'K10', 'K11', 'K12']:
        assert 'T58 CASE ' + case in t58
    report = {
        'status': 'PASS', 'run': str(run.resolve()),
        'frozen_inputs': len(meta['source_sha256']),
        'metadata_sha256': sha(run / 'run_metadata.json'),
        'auditor_sha256':sha(Path(__file__)),
        'logs_sha256': logs, 'readback_bytes': 1560,
        'confirmed_files': 2, 'aborted_published_files': 1,
        'scope': 'public GMII/host file hold, abort release, terminal restart; not complete 615A',
    }
    if (run / 'workspace/sim/out/t62_phy_a.hex').exists():
        report['transport_phy'] = audit_phy(run)
        if re.search(r'control_cases=[45]\b',t62):
            for case in ['wrong-name','partial-abort-restart','malformed-complete-hold',
                         'good-recovery-wrong-tid-abort']:
                assert 'T62 CONTROL_CASE '+case in t62
            report['control_lifecycle_cases']=int(re.search(r'control_cases=(\d+)',t62).group(1))
            if report['control_lifecycle_cases']==5:
                assert 'T62 CONTROL_CASE response-copy-abort' in t62
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('run', type=Path)
    args = parser.parse_args()
    report = audit(args.run)
    with (args.run / 'FILE_HOLD_AUDIT.json').open('x', encoding='utf-8') as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
        handle.write('\n')
    print(json.dumps(report, ensure_ascii=False))
