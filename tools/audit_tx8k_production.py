"""Audit frozen production TX results and independently decode their vectors."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def checksum(data):
    data += bytes(len(data) % 2)
    n = sum(struct.unpack('!' + str(len(data)//2) + 'H', data))
    while n >> 16:
        n = (n & 65535) + (n >> 16)
    return (~n) & 65535


def verify_phy_sequence(actual, expected):
    assert len(actual) == len(expected), 'PHY frame count'
    for raw, golden in zip(actual, expected):
        assert raw == golden, 'PHY bytes/order/length differ from independent oracle'
        assert raw[:8] == bytes.fromhex('55555555555555d5'), 'preamble/SFD'
        assert struct.unpack('<I',raw[-4:])[0] == zlib.crc32(raw[8:-4]), 'FCS'
        assert checksum(raw[22:42]) == 0, 'IPv4 checksum'


def audit_recovery(workspace, run, t82, expected_phy, output_hashes):
    """Decode full failed messages independently, including unsent UDP tails."""
    vectors=workspace/'sim/vec/t82_recovery/cases.hex'
    words=iter(int(w,16) for w in vectors.read_text(encoding='ascii').split())
    assert next(words)==4
    ident,sn,frames,app_bytes=18,51,0,0
    records=[]
    for case,(wanted_length,wanted_offset,wanted_fault) in enumerate(((8192,0,0),(8192,1472,1),(2048,1472,1),(32,0,0))):
        length,offset,fault,nframes=next(words),next(words),next(words),next(words)
        assert (length,offset,fault,nframes)==(wanted_length,wanted_offset,wanted_fault,2+(offset!=0))
        apps=[bytes(next(words) for _ in range(length))]
        for n in (32,33):
            assert next(words)==n
            apps.append(bytes(next(words) for _ in range(n)))
        for m,app in enumerate(apps):
            assert app==bytes((case*43+m*17+j*29+9)&255 for j in range(len(app)))
        emitted_messages=([0] if offset else [])+[1,2]
        for m in emitted_messages:
            app=apps[m]
            pseudo=bytes.fromhex('c0a80101c0a80102')+struct.pack('!BBH',0,17,len(app)+8)
            udp=struct.pack('!HHHH',0x1234,0x5678,len(app)+8,0)
            udp=udp[:6]+struct.pack('!H',checksum(pseudo+udp+app) or 65535)
            complete=udp+app
            assert checksum(pseudo+complete)==0
            n=1472 if m==0 else len(complete)
            phy_length=next(words)
            pair=[bytes(next(words) for _ in range(phy_length)) for _ in range(2)]
            for net,raw in enumerate(pair):
                body=raw[8:-4]
                assert raw[:8]==bytes.fromhex('55555555555555d5')
                assert struct.unpack('<I',raw[-4:])[0]==zlib.crc32(body)
                assert body[:6]==bytes.fromhex('030000000100')
                assert body[6:14]==bytes.fromhex('0200001234200800' if net==0 else '0200001234400800')
                ip=body[14:34]
                assert checksum(ip)==0
                assert ip[:2]==bytes([0x45,12]) and ip[8:10]==bytes([255,17])
                assert ip[12:20]==bytes.fromhex('c0a80101c0a80102')
                assert struct.unpack('!HHH',ip[2:8])==(20+n,ident+m,0x2000 if m==0 else 0)
                assert body[34:34+n]==complete[:n]
                assert not any(body[34+n:-1]) and body[-1]==sn
                assert len(body)==max(60,35+n)
                expected_phy[net].append(raw)
            sn+=1;frames+=1;app_bytes+=n-(8 if m==0 else 8)
        records.append({'case':case,'failed_length':length,'failed_offset':offset,'fault_kind':fault,
                        'frames_per_net':nframes,'successor_bytes':[32,33]})
        ident+=3
    assert next(words,None) is None and (frames,app_bytes)==(10,3188)
    assert len(re.findall(r'T82 RECOVERY_DONE .*errors=0',t82))==4
    assert 'T82 RECOVERY_TOTAL cases=4 frames_per_net=10 bytes=3188 injected=4 sn_errors=0' in t82
    for case,r in enumerate(records):
        assert f'T82 RECOVERY_DONE index={case} failed_app={r["failed_length"]} offset={r["failed_offset"]} fault={r["fault_kind"]} frames={r["frames_per_net"]} errors=0' in t82
    for net,name in enumerate(('t82_tx_a.hex','t82_tx_b.hex')):
        p=run/'metrics'/name
        actual=[bytes.fromhex(line) for line in p.read_text(encoding='ascii').splitlines()]
        verify_phy_sequence(actual,expected_phy[net])
        assert len(actual)==60
        output_hashes[name]=sha(p)
    # Known correct input must pass; known corruption must be rejected. These
    # controls operate in memory and never alter frozen captures or inputs.
    good=expected_phy[0]
    verify_phy_sequence(good,good)
    flipped=bytearray(good[0]);flipped[50]^=1
    bad_inputs={'payload_corruption':[bytes(flipped)]+good[1:],
                'missing_frame':good[:-1], 'extra_frame':good+[good[-1]],
                'reordered_frames':[good[1],good[0]]+good[2:],
                'truncated_frame':[good[0][:-1]]+good[1:]}
    repaired=bytearray(flipped)
    repaired[-4:]=struct.pack('<I',zlib.crc32(repaired[8:-4]))
    bad_inputs['payload_corruption_with_valid_FCS']=[bytes(repaired)]+good[1:]
    for label,bad in bad_inputs.items():
        try:verify_phy_sequence(bad,good)
        except AssertionError:pass
        else:raise AssertionError('negative control accepted: '+label)
    output_hashes['recovery_vectors']=sha(vectors)
    return {'cases':records,'frames_per_net':frames,'application_bytes':app_bytes,
            'combined_frames_per_net':60,'combined_application_bytes':62304,
            'negative_controls_rejected':list(bad_inputs),
            'fault_injection':'internal launch metadata only; public resource/descriptor/stats and complete PHY verdicts'}


def audit(run):
    metadata_path = run / 'run_metadata.json'
    meta = json.loads(metadata_path.read_text(encoding='utf-8-sig'))
    assert meta['regression_result'] == 'PASS' and meta['return_code'] == 0
    assert meta['compile_rc'] == 0 and meta['compile_result'] == 'PASS'
    workspace = run / 'workspace'
    for rel, expected in meta['source_sha256'].items():
        assert sha(workspace / rel) == expected, rel
    output_hashes = {}
    logs = ['compile_console.txt'] + [t['console_log'] for t in meta['test_results']]
    for name in logs:
        p = run / name
        text = p.read_text(encoding='utf-8', errors='replace')
        assert re.search(r'Errors: 0, Warnings: 0', text), name
        # T45 deliberately verifies timeout behavior; its exact successful
        # title is not a runner timeout. Remove only that unique verdict from
        # the diagnostic scan, preserving every other TIMEOUT/FAIL token.
        if name == 'T45_console.txt':
            text, titles = re.subn(r'^# T45 TFTP TIMEOUT CONTRACT PASS checks=\d+ events=\d+ images_ok=\d+\s*$', '', text, flags=re.M)
            assert titles == 1, 'Missing/duplicate exact T45 success verdict'
        assert not re.search(r'\*\* (?:Error|Fatal|Warning)|\b(?:FAIL|TIMEOUT)\b', text), name
        output_hashes[name] = sha(p)
    for test in meta['test_results']:
        assert test['result'] == 'PASS' and test['simulator_exit_code'] == 0
    t82 = (run/'T82_console.txt').read_text(encoding='utf-8')
    assert 'Loading work.afdx_bind_full' in t82
    assert len(re.findall(r'T82 MESSAGE_DONE .*errors=0', t82)) == 18
    assert len(re.findall(r'T82 TX8K GMII PASS ', t82)) == 1
    assert 'cases=18 frames_per_net=50 bytes=59116' in t82

    # Read serialized oracle input without calling the vector generator.
    vectors = workspace/'sim/vec/t82_tx8k/cases.hex'
    words = iter(int(w, 16) for w in vectors.read_text(encoding='ascii').split())
    def byte_string(count):
        return bytes(next(words) for _ in range(count))
    assert next(words) == 18
    sn = 1
    expected_phy=[[],[]]
    total_frames = total_bytes = 0
    cases = []
    for message in range(18):
        length, enabled, frames = next(words), next(words), next(words)
        app = byte_string(length)
        assert app == bytes((message*19+j*37+3) & 255 for j in range(length))
        reassembled = bytearray()
        for f in range(frames):
            physical_length = next(words)
            a, b = byte_string(physical_length), byte_string(physical_length)
            expected_phy[0].append(a);expected_phy[1].append(b)
            for net, raw in enumerate((a, b)):
                assert raw[:8] == bytes.fromhex('55555555555555d5')
                body = raw[8:-4]
                assert struct.unpack('<I', raw[-4:])[0] == zlib.crc32(body)
                assert body[:6] == bytes.fromhex('030000000100')
                assert body[6:12] == bytes.fromhex('020000123420' if net == 0 else '020000123440')
                assert body[12:14] == bytes.fromhex('0800') and body[-1] == sn
                ip = body[14:34]
                assert checksum(ip) == 0 and ip[:2] == bytes([0x45,12])
                ip_length, ident, flags = struct.unpack('!HHH', ip[2:8])
                assert ident == message and ip[8:10] == bytes([255,17])
                assert ip[12:20] == bytes.fromhex('c0a80101c0a80102')
                assert flags == (0x2000 if f+1<frames else 0) | (len(reassembled)//8)
                n = ip_length-20
                if f+1<frames:
                    assert n == 1472 and n % 8 == 0
                else:
                    assert 1 <= n <= 1479
                assert len(body) == max(60, 35+n)
                assert not any(body[34+n:-1])
                if net == 0:
                    payload = body[34:34+n]
                else:
                    assert body[34:34+n] == payload
            reassembled.extend(payload)
            sn = 1 if sn == 255 else sn+1
        sport, dport, udp_length, udp_sum = struct.unpack('!HHHH', reassembled[:8])
        assert (sport,dport,udp_length) == (0x1234,0x5678,length+8)
        assert reassembled[8:] == app
        pseudo = bytes.fromhex('c0a80101c0a80102')+struct.pack('!BBH',0,17,length+8)
        assert checksum(pseudo+reassembled) == 0 if enabled else udp_sum == 0
        cases.append({'message':message, 'application_bytes':length, 'frames':frames})
        total_frames += frames
        total_bytes += length
    assert next(words, None) is None
    assert total_frames == 50 and total_bytes == 59116
    recovery=None
    if 'T82 RECOVERY_TOTAL' in t82:
        recovery=audit_recovery(workspace,run,t82,expected_phy,output_hashes)
    else:
        assert 'T82 RECOVERY_TOTAL' not in (workspace/'sim/tb/tb_t82_tx8k_gmii.v').read_text(encoding='utf-8'), 'Missing required recovery result'
    output_hashes['vectors'] = sha(vectors)
    output_hashes['metadata'] = sha(metadata_path)
    latencies = [dict(zip(('message','application_bytes','A_ns','B_ns'), map(int,m)))
                 for m in re.findall(r'T82 LATENCY index=(\d+) app=(\d+) commit_call_to_last_A_ns=(\d+) B_ns=(\d+)', t82)]
    target = run/'TX_PRODUCTION_AUDIT.json'
    assert not target.exists(), 'Refusing to overwrite audit'
    result = {'verdict':'PASS', 'audit_script_sha256':sha(Path(__file__)),
              'frozen_input_count':len(meta['source_sha256']),
              'regression_tests':len(meta['test_results']),
              'oracle_cases':cases, 'frames_per_net':total_frames,
              'application_bytes':total_bytes, 'output_sha256':output_hashes,
              'latencies':latencies,
              'recovery':recovery,
              'limitations':['opt-in TX chain4; not a full manifest regression',
                             'commit task call to last PHY byte is a measured upper bound, not exact accepted-edge timing',
                             'no complete synthesis/netlist evidence from this audit']}
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(f'TX PRODUCTION AUDIT PASS tests={len(meta["test_results"])} frames_per_net={total_frames} bytes={total_bytes}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', type=Path, required=True)
    audit(parser.parse_args().run.resolve())
