"""Audit frozen one-top TX4/RX5 coexistence using actual PHY, host and cycle captures."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checksum(data):
    # Independent byte-wise folded sum; no vector-generator imports.
    data += bytes(len(data) % 2)
    value = sum((data[i] << 8) + data[i+1] for i in range(0, len(data), 2))
    while value >> 16:
        value = (value & 65535) + (value >> 16)
    return ~value & 65535


def patterned(n, salt):
    return bytes((i*73 + (i//7)*29 + (i//257)*11 + 61 + salt) & 255 for i in range(n))


def decode(raw):
    assert raw[:8] == b'\x55'*7 + b'\xd5', 'preamble/SFD'
    body = raw[8:-4]
    assert len(body) >= 60 and body[12:14] == b'\x08\x00', 'Ethernet length/type'
    assert int.from_bytes(raw[-4:], 'little') == zlib.crc32(body), 'FCS'
    ip = body[14:34]
    assert ip[0] == 0x45 and ip[9] == 17 and checksum(ip) == 0, 'IPv4'
    n, ident, flags = struct.unpack('!HHH', ip[2:8])
    assert n >= 20 and len(body) == max(60, 15+n), 'IPv4/MAC length'
    assert not any(body[14+n:-1]) and body[-1] != 0, 'padding/SN'
    assert not flags & 0x8000, 'IPv4 reserved flag'
    data = body[34:14+n]
    offset, more = (flags & 8191)*8, bool(flags & 8192)
    assert not more or (data and len(data) % 8 == 0), 'fragment alignment'
    return {'vl':int.from_bytes(body[4:6], 'big'), 'ip':ip, 'ident':ident,
            'offset':offset, 'more':more, 'data':data, 'sn':body[-1], 'flags':flags}


def reassemble(frames, app, ports, good=True):
    parsed = sorted((decode(f) for f in frames), key=lambda p:p['offset'])
    joined = bytearray()
    for index, p in enumerate(parsed):
        assert p['offset'] == len(joined), 'fragment gap/overlap'
        assert p['more'] == (index+1 < len(parsed)), 'MF/tail'
        assert p['ip'][12:20] == parsed[0]['ip'][12:20]
        assert p['ident'] == parsed[0]['ident']
        joined.extend(p['data'])
    sport, dport, length, csum = struct.unpack('!HHHH', joined[:8])
    assert (sport, dport, length) == (*ports, len(app)+8), 'UDP ports/length'
    assert joined[8:] == app and csum != 0, 'UDP app/checksum required'
    pseudo = parsed[0]['ip'][12:20] + b'\x00\x11' + length.to_bytes(2, 'big')
    assert (checksum(pseudo+joined) == 0) == good, 'full UDP checksum policy'


def verify_stream(actual, golden, cycles):
    assert len(actual) == len(cycles) == 9, 'PHY/timing frame count'
    buckets = {0x100:[], 0x101:[]}
    previous = {}
    last_end = None
    for raw, (start, end) in zip(actual, cycles):
        p = decode(raw)
        vl = p['vl']
        assert vl in buckets and raw == golden[vl][len(buckets[vl])], 'PHY bytes/order'
        assert end-start+1 == len(raw), 'continuous PHY byte count'
        assert last_end is None or start-last_end-1 >= 12, 'IFG'
        assert vl not in previous or start-previous[vl] >= 125000, 'legal 1ms BAG'
        buckets[vl].append(raw)
        previous[vl], last_end = start, end
    assert [len(buckets[vl]) for vl in buckets] == [6,3], 'per-VL counts'
    return buckets


def verify_host(actual, held, app):
    assert actual == held*129 + app, 'public host readback bytes/order/length'


def rejected(label, action):
    try:
        action()
    except (AssertionError, IndexError, ValueError):
        return label
    raise AssertionError('Known-bad control accepted: '+label)


def audit(run, frontend=None):
    target = run/'TXRX_COEXIST_AUDIT.json'
    assert not target.exists(), 'Refusing to overwrite audit'
    metadata_path = run/'run_metadata.json'
    meta = json.loads(metadata_path.read_text(encoding='utf-8-sig'))
    assert meta['regression_result'] == meta['compile_result'] == 'PASS'
    assert meta['return_code'] == meta['compile_rc'] == 0
    workspace = run/'workspace'
    for rel, digest in meta['source_sha256'].items():
        assert sha(workspace/rel) == digest, rel
    results = {t['id']:t for t in meta['test_results']}
    assert len(results) == len(meta['test_results']) and 'T83' in results
    assert len(meta['tests']) == len(results)
    hashes = {'run_metadata.json':sha(metadata_path)}
    for name in ['compile_console.txt'] + [t['console_log'] for t in results.values()]:
        raw = (run/name).read_text(encoding='utf-8', errors='strict')
        assert re.search(r'Errors: 0, Warnings: 0', raw), name
        # The full manifest includes the successful T45 timeout-contract
        # scenario. Its exact unique title is not a tool/runner timeout.
        if name == 'T45_console.txt':
            raw, titles = re.subn(r'^# T45 TFTP TIMEOUT CONTRACT PASS checks=\d+ events=\d+ images_ok=\d+\s*$', '', raw, flags=re.M)
            assert titles == 1, 'Missing/duplicate exact T45 success verdict'
        assert not re.search(r'\*\* (?:Warning|Error|Fatal)|\b(?:FAIL|TIMEOUT)\b', raw), name
        hashes[name] = sha(run/name)
    assert all(t['result']=='PASS' and t['simulator_exit_code']==0 for t in results.values())
    log = (run/'T83_console.txt').read_text(encoding='utf-8')
    assert 'Loading work.afdx_bind_full' in log
    verdict = re.findall(r'T83 COEXIST PASS cases=3 data_frames_per_net=18 mgmt_frames_per_net=9 rx_app_bytes=24576 checks=(\d+)', log)
    assert len(verdict)==1 and int(verdict[0])>2000000, 'unique complete verdict'
    rows = re.findall(r'T83 CASE_DONE index=(\d+) errors=(\d+) data_frames_A=(\d+) B=(\d+) mgmt_frames_A=(\d+) B=(\d+) host_bytes=(\d+) tx_copy=(\d+) tx_check=(\d+) tx_host=(\d+) rx_host=(\d+) simultaneous_rx=(\d+) copy_jobs=(\d+) check_jobs=(\d+)', log)
    assert len(rows)==3 and [int(r[0]) for r in rows]==[0,1,2]
    vector_path = workspace/'sim/vec/t83_coexist/cases.hex'
    values = iter(int(w,16) for w in vector_path.read_text(encoding='ascii').split())
    def take(n):
        return bytes(next(values) for _ in range(n))
    def pair():
        n = next(values)
        assert 72 <= n <= 1531
        a,b = take(n),take(n)
        assert a[8:19]+a[20:-4] == b[8:19]+b[20:-4], 'A/B content'
        assert a[19]==0x20 and b[19]==0x40
        decode(a);decode(b)
        return a,b
    assert next(values)==3
    records, controls = [], []
    for case in range(3):
        mode,count,prefix,recovery = [next(values) for _ in range(4)]
        assert (mode,count,prefix,recovery) == [(0,7,6,0),(1,13,6,6),(2,12,5,6)][case]
        tx,rx,held = take(8192),take(8192),take(64)
        assert tx==bytes((i*37+case*19+3)&255 for i in range(8192))
        assert rx==patterned(8192,100+case) and held==patterned(64,200+case)
        received = [pair() for _ in range(count)]
        for net in range(2):
            stream = [p[net] for p in received]
            assert [decode(f)['sn'] for f in stream[1:]] == list(range(1,count))
            assert all(decode(f)['vl']==5 and decode(f)['ip'][12:20]==bytes.fromhex('0a0000990a000002') for f in stream[1:])
            assert all(decode(f)['ident']==0x7100 for f in stream[1:1+prefix])
            reassemble(stream[:1],held,(12345,5001))
            if case<2:
                reassemble(stream[1:1+prefix],rx,(12345,5000),good=case==0)
            else:
                missing = {decode(f)['offset'] for f in stream[1:1+prefix]}
                assert missing=={0,1400,2800,4200,7000}, 'explicit missing fragment'
            if recovery:
                assert all(decode(f)['ident']==0x7200 for f in stream[1+prefix:])
                reassemble(stream[1+prefix:],rx,(12345,5000))
        tx_pairs = [pair() for _ in range(6)]
        golden = [{0x100:[p[net] for p in tx_pairs],0x101:[]} for net in range(2)]
        for net in range(2):
            reassemble(golden[net][0x100],tx,(0x1234,0x5678))
            for index,raw in enumerate(golden[net][0x100]):
                p=decode(raw)
                assert p['ident']==0 and p['sn']==index+1 and p['offset']==index*1472
                assert p['ip'][1]==12 and p['ip'][8]==255
                assert p['ip'][12:20]==bytes.fromhex('0a000002c0a80102')
                assert raw[8:14]==bytes.fromhex('030000000100')
                assert raw[14:20]==bytes.fromhex('020000172d20' if net==0 else '020000172d40')
        file_app=bytes((i*11+7)&255 for i in range(520))
        requests=[b'\x00\x02UPLOAD\0octet\0', b'\x00\x03\x00\x01'+file_app[:512], b'\x00\x03\x00\x02'+file_app[512:]]
        for index in range(3):
            request=take(next(values))
            p=decode(request)
            assert p['vl']==0x100 and p['sn']==index+1 and p['ident']==0x7301+index
            assert p['ip'][12:20]==bytes.fromhex('0a000001e0000001') and p['flags']==0x4000
            reassemble([request],requests[index],(49152,5000))
            reply=pair()
            for net,raw in enumerate(reply):
                p=decode(raw)
                assert p['vl']==0x101 and p['ident']==index+1 and p['sn']==index+1
                assert p['ip'][1]==0 and p['ip'][8]==255 and p['flags']==0
                assert p['ip'][12:20]==bytes.fromhex('0a0000020a000001')
                reassemble([raw],struct.pack('!HH',4,index),(5000,49152))
                golden[net][0x101].append(raw)
        captures,timings=[],[]
        for net,label in enumerate(('a','b')):
            name=f't83_case{case}_{label}.hex'
            actual=[bytes.fromhex(r) for r in (run/'metrics'/name).read_text(encoding='ascii').splitlines()]
            timing_name=f't83_case{case}_{label}_cycles.txt'
            cycles=[tuple(map(int,r.split())) for r in (run/'metrics'/timing_name).read_text(encoding='ascii').splitlines()]
            buckets=verify_stream(actual,golden[net],cycles)
            reassemble(buckets[0x100],tx,(0x1234,0x5678))
            for n in (name,timing_name):hashes[n]=sha(run/'metrics'/n)
            captures.append(actual);timings.append(cycles)
        assert [decode(f)['vl'] for f in captures[0]]==[decode(f)['vl'] for f in captures[1]], 'A/B order'
        host_name=f't83_case{case}_host.hex'
        actual_host=bytes.fromhex((run/'metrics'/host_name).read_text(encoding='ascii'))
        verify_host(actual_host,held,rx);hashes[host_name]=sha(run/'metrics'/host_name)
        row=list(map(int,rows[case]))
        assert row[:7]==[case,0,6,6,3,3,16448]
        assert row[9]>0 and row[11]>0 and row[12]>0 and row[13]>0, 'actual overlap/jobs'
        if case==0:assert row[7]>0 and row[8]>0 and row[10]>0, 'scatter/checker/host collisions'
        records.append({'case':case,'mode':['simultaneous_success','bad_udp_then_recovery','disable_incomplete_then_recovery'][case],
                        'frames_per_net':9,'tx_app_bytes':8192,'rx_app_bytes':8192,'host_readback_bytes':len(actual_host),
                        'contention':dict(zip(('tx_copy','tx_check','tx_host','rx_host','simultaneous_rx','copy_jobs','check_jobs'),row[7:])),
                        'first_to_last_tx_byte_ns':[(c[5][1]-c[0][0]+1)*8 for c in [[timings[n][i] for i,f in enumerate(captures[n]) if decode(f)['vl']==0x100] for n in range(2)]]})
        if case==0:
            good=captures[0];cycles=timings[0]
            corrupted=bytearray(good[0]);corrupted[50]^=1
            fixed_fcs=bytearray(corrupted);fixed_fcs[-4:]=struct.pack('<I',zlib.crc32(fixed_fcs[8:-4]))
            bads={'payload_corruption':[bytes(corrupted)]+good[1:],
                  'payload_corruption_valid_FCS':[bytes(fixed_fcs)]+good[1:],
                  'missing_frame':good[:-1],'extra_frame':good+[good[-1]],
                  'reordered_frames':[good[1],good[0]]+good[2:],
                  'truncated_frame':[good[0][:-1]]+good[1:]}
            for label,bad in bads.items():controls.append(rejected(label,lambda bad=bad:verify_stream(bad,golden[0],cycles)))
            broken=list(cycles);broken[1]=(broken[0][1]+1,broken[0][1]+len(good[1]))
            controls.append(rejected('timing_IFG_violation',lambda:verify_stream(good,golden[0],broken)))
            controls.append(rejected('host_payload_corruption',lambda:verify_host(bytes([actual_host[0]^1])+actual_host[1:],held,rx)))
    assert next(values,None) is None
    hashes['vectors']=sha(vector_path)
    frontend_evidence=None
    if frontend:
        fm=json.loads((frontend/'frontend_metadata.json').read_text(encoding='utf-8'))
        sources=(workspace/'elinx/AFDX_top_sources.f').read_text(encoding='utf-8').splitlines()
        assert len(sources)==len(set(sources)) and len(sources) in (49,50)
        assert ('rtl/mgmt/a615a_init_tx.v' in sources)==(len(sources)==50)
        assert fm['verdict']=='PASS' and set(fm['rtl_sha256'])==set(sources)
        for rel,digest in fm['rtl_sha256'].items():
            assert meta['source_sha256'][rel]==digest==sha(frontend/'input'/rel), rel
        for stage in fm['stages']:
            assert stage['verdict']=='PASS' and stage['exit_code']==0 and not stage['warnings'] and not stage['errors']
            assert sha(frontend/(stage['label']+'.log'))==stage['log_sha256']
        frontend_evidence={'path':str(frontend),'production_sources_matched':len(sources),
                           'metadata_sha256':sha(frontend/'frontend_metadata.json'),
                           'scope':fm['scope']}
    result={'verdict':'PASS','audit_script_sha256':sha(Path(__file__)),
            'frozen_input_count':len(meta['source_sha256']),'regression_tests':len(results),
            'checks':int(verdict[0]),'cases':records,'total_frames_per_net':27,'total_rx_app_bytes':24576,
            'total_host_readback_bytes':49344,'output_sha256':hashes,'negative_controls_rejected':controls,
            'same_rtl_frontend':frontend_evidence,
            'limitations':['opt-in one-top TX4/RX5; not the full manifest or complete synthesis',
                           'case0 requires scatter/checker/host contention; later recovery may finish after TX',
                           'TFTP 520B transport exchange; not full ARINC 615A workflow',
                           'legal 1ms BAG retained; complete-message 2ms requirement remains OPEN']}
    target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'TXRX COEXIST AUDIT PASS tests={len(results)} frames_per_net=27 host_bytes=49344 negative_controls={len(controls)}')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--frontend',type=Path)
    args=parser.parse_args()
    audit(args.run.resolve(),args.frontend.resolve() if args.frontend else None)
