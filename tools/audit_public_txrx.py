"""Audit one frozen public T86 run; never combine evidence from separate runs.

Usage: python -B tools/audit_public_txrx.py --run <run-directory>
No HDL tools are invoked. Only a successful audit creates PUBLIC_TXRX_AUDIT.json.
"""
import argparse
import ast
import csv
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import sys
from types import SimpleNamespace
import zlib


TB = 'sim/tb/tb_t86_public_txrx.v'
DECODER = 'tools/audit_txrx_coexist.py'
GENERATOR = 'sw/golden/gen_t83_coexist.py'
RX_GENERATOR = 'sw/golden/gen_rx8k_gmii.py'
VECTORS = 'sim/vec/t83_coexist/cases.hex'
IMAGE = 'sim/vec/t83_coexist/hash_img.hex'
TB_CONTRACT = 'edfe9a5c3de8e3725e0a79495db0cc03cdf82cb76c550181a5f2eb93ce5632a9'
# Reviewed independent oracle revisions, not RTL-derived expectations.
ORACLE_HASHES = {
    DECODER: {'6e0572376eae7cc5325e007ecb66215558d28cbbd4c128fbc912576ea1751c6a',
              '8764f250562bea75ba5b5988dd3175fa873d1aff0d6709ea7b1d6045432b6da2'},
    GENERATOR: {'82f730ec84fff7cf40f55d9968ba1d080437e67c7775e9a64ebef8915cd1b1d4'},
    RX_GENERATOR: {'ea3fab5ede9bf689ff3ec91fed228518fb2596fbfe932d4782acc7bdb6fd9986'},
}
KINDS = ['simultaneous_success', 'bad_udp_then_recovery', 'disable_incomplete_then_recovery']


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key: '+key)
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'), object_pairs_hook=unique_object)


def local_file(base, relative):
    """Reject absolute paths, aliases, traversal, symlinks and Windows junctions."""
    require(isinstance(relative, str) and '\\' not in relative and ':' not in relative,
            'noncanonical relative path: '+str(relative))
    parts = relative.split('/')
    require(parts and all(p not in ('', '.', '..') for p in parts)
            and not PurePosixPath(relative).is_absolute(), 'unsafe relative path: '+relative)
    path = base
    for part in parts:
        path = path/part
        require(not path.is_symlink() and not (hasattr(path, 'is_junction') and path.is_junction()),
                'linked evidence: '+relative)
    require(path.resolve().is_relative_to(base.resolve()) and path.is_file(),
            'missing/nonlocal evidence: '+relative)
    return path


def parse_manifest(text):
    rows = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        words = line.split()
        require(2 <= len(words) <= 3, 'malformed manifest row')
        require(re.fullmatch(r'T\d{2}[A-Za-z]*', words[0]) is not None, 'invalid manifest ID')
        rows.append(dict(zip(('id', 'tb', 'config'), words[:2]+[words[2] if len(words)==3 else 'default'])))
    require(rows and len({r['id'] for r in rows}) == len(rows), 'empty/duplicate manifest')
    return rows


def validate_manifest(meta, manifest):
    require(meta['compile_result'] == meta['regression_result'] == 'PASS', 'run is not terminal PASS')
    require(meta['return_code'] == meta['compile_rc'] == meta['vlog_errors'] == 0, 'run exit/compile errors')
    require(meta.get('completed_local') and meta.get('current_test') is None, 'incomplete run')
    parameters = meta['invocation_parameters']
    require(meta['plusargs'] == parameters['PlusArgs'] == '', 'plusargs/negative-control run rejected')
    requested = parameters['Tests']
    require(isinstance(requested, list) and all(isinstance(x, str) for x in requested), 'invalid Tests')
    selected = [part.strip() for item in requested for part in item.split(',') if part.strip()]
    require(len(set(selected)) == len(selected), 'duplicate selected test')
    require(set(selected) <= {r['id'] for r in manifest}, 'unknown selected test')
    expected = [r for r in manifest if not selected or r['id'] in selected]
    require(meta['tests'] == expected, 'metadata does not match frozen manifest/selection/order')
    results = meta['test_results']
    require([r['id'] for r in results] == [r['id'] for r in expected], 'missing/duplicate/reordered results')
    n = len(expected)
    require(n and all(meta[k] == n for k in ('test_count', 'pass_count', 'tests_completed')), 'run counts')
    require(all(r['result']=='PASS' and r['simulator_exit_code']==0 for r in results), 'failed test result')
    t86 = [r for r in expected if r['id']=='T86']
    require(len(t86)==1 and t86[0]['tb']=='tb_t86_public_txrx', 'exactly one public T86 required')
    require(t86[0]['config'] in ('public-tx4-rx5-gmii-host-tftp-business',
                               'public-tx4-rx5-phy-host-coactivity'), 'incorrect T86 configuration')
    # A subset never receives a full-manifest scope label.
    return ('isolated_directed' if n==1 else 'full_manifest' if expected==manifest else 'selected_manifest')


def validate_log(raw, test_id=None):
    summaries = re.findall(r'(?m)^\s*(?:#\s*)?Errors:\s*(\d+),\s*Warnings:\s*(\d+)\s*$', raw)
    require(summaries and all(e=='0' and w=='0' for e,w in summaries), 'missing/nonzero simulator summary')
    require(not re.search(r'(?im)^\s*(?:#\s*)?(?:\*\*\s*)?(?:Warning|Error|Fatal)\b|VSIM-ERROR|VLOG-ERROR|\[chk\]\s+A(?:2|6|7|8|9|10|11)\b', raw),
            'raw simulator/assertion diagnostic')
    if test_id:
        verdicts = re.findall(r'(?m)^#?\s*(T\d\d)[A-Za-z]*\s[^\n]*\b(PASS|FAIL)\b[^\n]*$', raw)
        require(len(verdicts)==1 and verdicts[0]==(test_id[:3], 'PASS'), 'nonunique/wrong raw verdict')
    scrubbed = raw
    if test_id=='T45':
        scrubbed, count = re.subn(r'(?m)^#?\s*T45 TFTP TIMEOUT CONTRACT PASS checks=\d+ events=\d+ images_ok=\d+\s*$', '', raw)
        require(count==1, 'missing/duplicate T45 timeout-contract PASS')
    require(not re.search(r'\bFAIL|\bTIMEOUT\b', scrubbed), 'failure/timeout text')


def validate_tb(text):
    # Hash all executable contract text after removing comments and ONLY
    # informational host-window displays. This preserves every original check,
    # reset, counter update, 128-read loop, configuration and negative control.
    code = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    require(not re.search(r'\bdut\s*\.|\bforce\b|\brelease\b', code), 'nonpublic TB access/force')
    diagnostic = r'\$display\("T86 (?:HOST_PHY_SYNC|HOST_HELD_WINDOW|HELD_READ_WINDOW_BEGIN|HELD_READ_WINDOW_END)[^;]*;'
    for statement in re.findall(diagnostic,code):
        require(re.fullmatch(r'\$display\("[^"\n]*"\s*(?:,\s*[A-Za-z_]\w*\s*)*\);',statement),
                'host diagnostic has executable side effects/nonvariable arguments')
    stripped = re.sub(diagnostic, '', code)
    contract = hashlib.sha256(re.sub(r'\s+', '', stripped).encode()).hexdigest()
    require(contract==TB_CONTRACT, 'unreviewed T86 executable contract: '+contract)
    require('T86 HOST_PHY_SYNC ' in code, 'missing bounded PHY synchronization record')
    require(('T86 HELD_READ_WINDOW_BEGIN ' in code and 'T86 HELD_READ_WINDOW_END ' in code)
            or 'T86 HOST_HELD_WINDOW ' in code, 'missing held-read window records')
    return contract


def load_definitions(path, names, namespace=None):
    """Load only reviewed pure definitions; no module top-level I/O or CLI."""
    tree = ast.parse(path.read_text(encoding='utf-8-sig'))
    nodes = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names]
    require({n.name for n in nodes}==set(names), 'missing pure oracle definitions')
    env = dict(struct=struct, zlib=zlib, hashlib=hashlib)
    env.update(namespace or {})
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), 'exec'), env)
    return SimpleNamespace(**env)


def load_oracles(workspace):
    for relative, approved in ORACLE_HASHES.items():
        require(sha(local_file(workspace, relative)) in approved, 'unreviewed oracle revision: '+relative)
    decoder = load_definitions(local_file(workspace, DECODER),
                               ['checksum','patterned','decode','reassemble','verify_stream','verify_host'])
    rx = load_definitions(local_file(workspace, RX_GENERATOR),
                          ['payload','checksum','udp','Frames','hash_bucket'],
                          dict(SRC=bytes.fromhex('0a000099'), DST=bytes.fromhex('0a000002'), CHUNK=1400))
    tx = load_definitions(local_file(workspace, GENERATOR), ['checksum','outgoing','request'])
    return decoder, rx, tx


def check_sync(log, case, timings, overlap):
    sync = re.findall(r'T86 HOST_PHY_SYNC case=(\d+) cycle=(\d+) waited_cycles=(\d+) A=([01]) B=([01])', log)
    require(len(sync)==3 and [int(s[0]) for s in sync]==[0,1,2], 'missing/duplicate/invalid HOST_PHY_SYNC')
    _, cycle, waited, a, b = map(int, sync[case])
    require(0<=waited<=250000 and (a or b), 'PHY synchronization timeout/no PHY')
    # A negedge observes the same cycle just captured at the preceding posedge.
    for net, active in enumerate((a,b)):
        if active:
            require(any(start<=cycle<=end for start,end in timings[net]), 'sync outside actual PHY capture')
    begins = re.findall(r'T86 HELD_READ_WINDOW_BEGIN case=(\d+) cycle=(\d+) held_id=(\d+)', log)
    ends = re.findall(r'T86 HELD_READ_WINDOW_END case=(\d+) cycle=(\d+) host_bytes=(\d+)', log)
    summaries = re.findall(r'T86 HOST_HELD_WINDOW ([^\r\n]+)', log)
    window = None
    if begins or ends:
        require(len(begins)==len(ends)==3 and [int(x[0]) for x in begins]==[0,1,2]
                and [int(x[0]) for x in ends]==[0,1,2], 'held window BEGIN/END count/order')
        _, start, held_id = map(int, begins[case])
        _, end, host_bytes = map(int, ends[case])
        require(6<=held_id<=15 and host_bytes==64*129, 'held RX ID/128-read host bytes')
        window = (start,end)
    if summaries:
        require(len(summaries)==3, 'HOST_HELD_WINDOW count')
        parsed = []
        for line in summaries:
            fields = line.split()
            require(all(re.fullmatch(r'[a-z_]+=\d+', f) for f in fields), 'HOST_HELD_WINDOW format')
            pairs = [f.split('=') for f in fields]
            item = unique_object([(k,int(v)) for k,v in pairs])
            # Explicit schema; unknown fields are not silently ignored.
            require(set(item)=={'case','start_cycle','end_cycle','held_reads','host_bytes','tx_host_overlap'},
                    'HOST_HELD_WINDOW schema (case,start_cycle,end_cycle,held_reads,host_bytes,tx_host_overlap)')
            parsed.append(item)
        require([p['case'] for p in parsed]==[0,1,2], 'HOST_HELD_WINDOW case order')
        item = parsed[case]
        require(item['held_reads']==128 and item['host_bytes']==8256 and item['tx_host_overlap']==overlap,
                'HOST_HELD_WINDOW reads/bytes/overlap disagreement')
        require(window is None or window==(item['start_cycle'],item['end_cycle']), 'inconsistent window records')
        window = (item['start_cycle'],item['end_cycle'])
    require(window is not None, 'no held window evidence')
    start,end = window
    require(start==cycle and end>start, 'held read starts without PHY synchronization')
    capacity = sum(max(0,min(end,finish)-max(start,begin)+1) for begin,finish in
                   merge_intervals(timings[0]+timings[1]))
    require(0<overlap<=capacity, 'no real PHY/held window overlap or impossible overlap count')
    # Original 64B payload requires 17 word accesses; each takes >=2 cycles.
    require(end-start>=128*17*2, 'held window too short for original 128 reads')
    return dict(sync_cycle=cycle, waited_cycles=waited, start_cycle=start, end_cycle=end,
                held_reads=128, host_bytes_before_rx=8256, phy_cycles_in_window=capacity,
                public_request_overlap_cycles=overlap)


def merge_intervals(intervals):
    merged = []
    for start,end in sorted(intervals):
        require(0<=start<=end, 'invalid PHY cycles')
        if merged and start<=merged[-1][1]+1:
            merged[-1] = (merged[-1][0],max(end,merged[-1][1]))
        else:
            merged.append((start,end))
    return merged


def audit_captures(run, workspace, log, rows, decoder, rx_generator, tx_generator, hashes):
    words = [int(w,16) for w in local_file(workspace,VECTORS).read_text(encoding='ascii').split()]
    values = iter(words)
    vector_manifest = read_json(local_file(workspace,'sim/vec/t83_coexist/manifest.json'))
    require(vector_manifest['words']==len(words) and len(vector_manifest['cases'])==3, 'golden manifest dimensions')
    # Independently reconstruct the public lookup image with the frozen software
    # generator; never read any RTL signal to obtain expected packet data.
    expected_image = [0]*8192
    for vl,index in ((5,5),(6,6),(0x100,0x100)):
        slot = 2*rx_generator.hash_bucket(vl,0x172d,0)
        require(expected_image[slot]==0, 'golden hash collision')
        expected_image[slot] = (1<<28)|(index<<12)|vl
    image = [int(w,16) for w in local_file(workspace,IMAGE).read_text(encoding='ascii').split()]
    require(image==expected_image, 'golden public hash image')
    def take(n):
        require(0<=n<=8192, 'golden length bounds')
        return bytes(next(values) for _ in range(n))
    def pair():
        n = next(values)
        require(72<=n<=1531, 'golden PHY frame bounds')
        a,b = take(n),take(n)
        require(a[8:19]+a[20:-4]==b[8:19]+b[20:-4] and a[19]==0x20 and b[19]==0x40,
                'golden redundant A/B frame content')
        decoder.decode(a); decoder.decode(b)
        return a,b
    def metric(relative):
        path = local_file(run,relative)
        hashes[relative] = sha(path)
        raw_relative = 'workspace/sim/out/'+relative
        raw_path = local_file(run,raw_relative)
        require(sha(raw_path)==hashes[relative], 'export differs from same-run raw capture: '+relative)
        hashes[raw_relative] = hashes[relative]
        return path.read_text(encoding='ascii')
    require(next(values)==3, 'golden three cases')
    records = []
    for case in range(3):
        mode,count,prefix,recovery = [next(values) for _ in range(4)]
        require((mode,count,prefix,recovery)==[(0,7,6,0),(1,13,6,6),(2,12,5,6)][case], 'original three-case contract')
        tx,rx,held = take(8192),take(8192),take(64)
        require(tx==bytes((i*37+case*19+3)&255 for i in range(8192)), 'independent TX payload')
        require(rx==decoder.patterned(8192,100+case)==rx_generator.payload(8192,100+case)
                and held==decoder.patterned(64,200+case)==rx_generator.payload(64,200+case), 'independent RX/held payload')
        vm = vector_manifest['cases'][case]
        expected_vm = dict(case=case,kind=KINDS[case],tx_app_bytes=8192,rx_app_bytes=8192,held_app_bytes=64,
                           rx_frames_per_net=count,prefix_frames=prefix,recovery_frames=recovery,
                           tx_data_frames_per_net=6,management_frames_per_net=3,tftp_file_bytes=520,
                           tx_app_sha256=hashlib.sha256(tx).hexdigest(),rx_app_sha256=hashlib.sha256(rx).hexdigest())
        require(vm==expected_vm, 'golden case manifest contract')
        received = [pair() for _ in range(count)]
        # Exact RX vectors from frozen generator, including intentionally bad
        # checksum, missing tail-first fragment and shuffled complete recovery.
        frames = rx_generator.Frames()
        expected_rx = frames.pieces(rx_generator.udp(held,5001),0x7000,vl=6)
        datagram = bytearray(rx_generator.udp(rx))
        if case==1:
            datagram[6] ^= 1
        bad_prefix = frames.pieces(bytes(datagram),0x7100,order='tail_first')
        if case==2:
            bad_prefix = bad_prefix[:5]; frames.sn[5] = 5
        expected_rx += bad_prefix
        if case:
            expected_rx += frames.pieces(rx_generator.udp(rx),0x7200,order='shuffled')
        for index,raw in enumerate(expected_rx):
            a = b'\x55'*7+b'\xd5'+raw
            body = raw[:-4]; body = body[:11]+b'\x40'+body[12:]
            b = b'\x55'*7+b'\xd5'+body+struct.pack('<I',zlib.crc32(body))
            require(received[index]==(a,b), 'frozen RX vectors differ from software oracle')
        for net in range(2):
            stream = [p[net] for p in received]
            decoder.reassemble(stream[:1],held,(12345,5001))
            require([decoder.decode(f)['sn'] for f in stream[1:]]==list(range(1,count)), 'RX sequence numbers')
            require(all(decoder.decode(f)['vl']==5 and decoder.decode(f)['ip'][12:20]==bytes.fromhex('0a0000990a000002')
                        for f in stream[1:]), 'RX VL/IP')
            require(all(decoder.decode(f)['ident']==0x7100 for f in stream[1:1+prefix]), 'RX prefix identity')
            if case<2:
                decoder.reassemble(stream[1:1+prefix],rx,(12345,5000),good=case==0)
            else:
                require({decoder.decode(f)['offset'] for f in stream[1:1+prefix]}=={0,1400,2800,4200,7000}, 'missing RX fragment')
            if recovery:
                decoder.reassemble(stream[1+prefix:],rx,(12345,5000))
                require(all(decoder.decode(f)['ident']==0x7200 for f in stream[1+prefix:]), 'RX recovery identity')
        tx_pairs = [pair() for _ in range(6)]
        for index,p in enumerate(tx_pairs):
            require(p==tx_generator.outgoing(tx,0x100,0,index+1,index*1472), 'TX golden/software oracle')
        golden = [{0x100:[p[net] for p in tx_pairs],0x101:[]} for net in range(2)]
        for net in range(2):
            decoder.reassemble(golden[net][0x100],tx,(0x1234,0x5678))
            for index,raw in enumerate(golden[net][0x100]):
                p = decoder.decode(raw)
                require(p['ident']==0 and p['sn']==index+1 and p['offset']==index*1472, 'TX SN/fragment ID/offset')
                require(p['ip'][1]==12 and p['ip'][8]==255 and p['ip'][12:20]==bytes.fromhex('0a000002c0a80102'), 'TX TOS/TTL/IP')
                require(raw[8:14]==bytes.fromhex('030000000100') and raw[14:20]==bytes.fromhex('020000172d20' if net==0 else '020000172d40'), 'TX MAC')
        file_app = bytes((i*11+7)&255 for i in range(520))
        requests = [b'\x00\x02UPLOAD\0octet\0',b'\x00\x03\x00\x01'+file_app[:512],b'\x00\x03\x00\x02'+file_app[512:]]
        for index in range(3):
            request = take(next(values))
            require(request==tx_generator.request(requests[index],index+1,0x7301+index), 'TFTP request/software oracle')
            decoder.reassemble([request],requests[index],(49152,5000))
            p = decoder.decode(request)
            require(p['vl']==0x100 and p['sn']==index+1 and p['ident']==0x7301+index
                    and p['ip'][12:20]==bytes.fromhex('0a000001e0000001') and p['flags']==0x4000, 'TFTP request headers')
            reply = pair()
            ack = struct.pack('!HH',4,index)
            require(reply==tx_generator.outgoing(ack,0x101,index+1,index+1,management=True), 'TFTP reply/software oracle')
            for net,raw in enumerate(reply):
                decoder.reassemble([raw],ack,(5000,49152))
                p = decoder.decode(raw)
                require(p['vl']==0x101 and p['ident']==index+1 and p['sn']==index+1 and p['ip'][1]==0
                        and p['ip'][8]==255 and p['flags']==0 and p['ip'][12:20]==bytes.fromhex('0a0000020a000001'), 'TFTP reply headers')
                golden[net][0x101].append(raw)
        captures,timings = [],[]
        for net,label in enumerate(('a','b')):
            actual = [bytes.fromhex(line) for line in metric(f'metrics/t86_case{case}_{label}.hex').splitlines()]
            cycles = [tuple(map(int,line.split())) for line in metric(f'metrics/t86_case{case}_{label}_cycles.txt').splitlines()]
            require(all(len(c)==2 and 0<=c[0]<=c[1] for c in cycles), 'invalid PHY timing rows')
            buckets = decoder.verify_stream(actual,golden[net],cycles)
            decoder.reassemble(buckets[0x100],tx,(0x1234,0x5678))
            captures.append(actual); timings.append(cycles)
        require([decoder.decode(f)['vl'] for f in captures[0]]==[decoder.decode(f)['vl'] for f in captures[1]], 'A/B order')
        host = bytes.fromhex(metric(f'metrics/t86_case{case}_host.hex'))
        decoder.verify_host(host,held,rx)
        row = list(map(int,rows[case]))
        require(row[:7]==[case,0,6,6,3,3,16448] and all(v>0 for v in row[7:]), 'T86 case counts/errors/coactivity')
        window = check_sync(log,case,timings,row[7])
        records.append(dict(case=case,mode=KINDS[case],frames_per_net=9,tx_bytes=8192,rx_bytes=8192,
                            host_bytes=len(host),held_window=window,
                            public_coactivity=dict(zip(('tx_phy_host_pmem_request_cycles','rx_bytes_while_tx_message_outstanding',
                                                        'tftp_bytes_while_tx_message_outstanding'),row[7:]))))
    require(next(values,None) is None, 'unconsumed golden vector words')
    return records


def audit(run):
    require(__debug__, 'Python -O is unsupported: independent decoder assertions must remain active')
    run = run.resolve()
    target = run/'PUBLIC_TXRX_AUDIT.json'
    require(not target.exists() and not target.is_symlink(), 'refusing to overwrite audit')
    metadata_path = local_file(run, 'run_metadata.json')
    metadata_hash = sha(metadata_path)
    meta = read_json(metadata_path)
    require(meta['run_id']==run.name, 'run_id/directory mismatch')
    workspace = run/'workspace'
    require(workspace.is_dir() and not workspace.is_symlink()
            and not (hasattr(workspace,'is_junction') and workspace.is_junction()), 'missing/linked frozen workspace')
    sources = meta['source_sha256']
    require(isinstance(sources,dict) and sources, 'missing frozen source hashes')
    required = [TB,DECODER,GENERATOR,RX_GENERATOR,VECTORS,IMAGE,'sim/vec/t83_coexist/manifest.json',
                'sim/tests.manifest','sim/run_regress.ps1','sim/run_one.tcl','sim/compile.tcl',
                'sim/bind_scope.tsv','elinx/AFDX_top_sources.f']
    require(all(r in sources for r in required), 'unbound TB/oracle/runner/configuration input')
    seen = set()
    for relative,digest in sources.items():
        require(relative.casefold() not in seen, 'case-aliased frozen input')
        seen.add(relative.casefold())
        require(isinstance(digest,str) and re.fullmatch('[0-9a-f]{64}',digest), 'invalid source hash')
        require(sha(local_file(workspace,relative))==digest, 'source hash mismatch: '+relative)
    # Match the runner's complete frozen-input census, restricted to this run's
    # workspace. Do not descend into simulator output/work or nested runs.
    census = set()
    for directory,subdirs,files in os.walk(workspace,followlinks=False):
        relative_dir = Path(directory).relative_to(workspace).as_posix()
        if relative_dir=='sim':
            subdirs[:] = [d for d in subdirs if d not in ('out','work')]
        for subdir in subdirs:
            child = Path(directory)/subdir
            require(not child.is_symlink() and not (hasattr(child,'is_junction') and child.is_junction()),
                    'linked frozen source directory')
        for name in files:
            rel = (Path(directory)/name).relative_to(workspace).as_posix()
            if Path(name).suffix=='.pyc' or rel in ('sim/transcript','sim/vsim_stacktrace.vstf',
                                                   'sim/vish_stacktrace.vstf','sim/vsim.wlf'):
                continue
            census.add(rel)
    require(census==set(sources), 'frozen input census differs from metadata: missing='+
            str(sorted(census-set(sources)))+' stale='+str(sorted(set(sources)-census)))
    manifest = parse_manifest(local_file(workspace,'sim/tests.manifest').read_text(encoding='utf-8-sig'))
    scope = validate_manifest(meta,manifest)
    tb_contract = validate_tb(local_file(workspace,TB).read_text(encoding='utf-8-sig'))
    production = local_file(workspace,'elinx/AFDX_top_sources.f').read_text(encoding='utf-8-sig').splitlines()
    require(len(production)==len(set(production))==50 and all(p in sources for p in production),
            'incomplete production RTL source closure')
    scopes = list(csv.DictReader(io.StringIO(local_file(workspace,'sim/bind_scope.tsv').read_text(encoding='utf-8-sig')),delimiter='\t'))
    require([r['test_id'] for r in scopes]==[r['id'] for r in manifest], 'bind scope manifest mismatch')
    require(all(r['tb']==m['tb'] and r['config']==m['config'] for r,m in zip(scopes,manifest)), 'bind scope TB/config mismatch')
    require(next(r for r in scopes if r['test_id']=='T86')['profile']=='full', 'T86 full bind missing')
    hashes = {}
    def output(relative):
        path = local_file(run,relative)
        hashes[relative] = sha(path)
        return path.read_text(encoding='utf-8-sig')
    validate_log(output('compile_console.txt'))
    for result in meta['test_results']:
        relative = result['id']+'_console.txt'
        require(result['console_log']==relative, 'foreign/mixed-run console path')
        validate_log(output(relative),result['id'])
    log = output('T86_console.txt')
    require(re.search(r'Loading work\.tb_t86_public_txrx\b',log) and
            re.search(r'Loading work\.afdx_bind_full\b',log), 'T86 public top/full binding not loaded')
    verdict = re.findall(r'T86 PUBLIC TXRX PASS cases=3 data_frames_per_net=18 mgmt_frames_per_net=9 rx_app_bytes=24576 checks=(\d+)',log)
    require(len(verdict)==1 and int(verdict[0])>200000, 'incomplete T86 terminal verdict')
    rows = re.findall(r'T86 CASE_DONE index=(\d+) errors=(\d+) data_frames_A=(\d+) B=(\d+) mgmt_frames_A=(\d+) B=(\d+) host_bytes=(\d+) tx_host_overlap=(\d+) rx_outstanding_bytes=(\d+) tftp_outstanding_bytes=(\d+)',log)
    require(len(rows)==3 and [int(r[0]) for r in rows]==[0,1,2], 'T86 three-case result records')
    decoder,rx_generator,tx_generator = load_oracles(workspace)
    cases = audit_captures(run,workspace,log,rows,decoder,rx_generator,tx_generator,hashes)
    # Detect evidence edits while auditing; the exclusive output also handles races.
    require(sha(metadata_path)==metadata_hash, 'metadata changed during audit')
    for relative,digest in sources.items():
        require(sha(local_file(workspace,relative))==digest, 'source changed during audit: '+relative)
    for relative,digest in hashes.items():
        require(sha(local_file(run,relative))==digest, 'output changed during audit: '+relative)
    report = dict(status='PASS',run=str(run),run_id=meta['run_id'],scope=scope,
                  regression_tests=len(meta['tests']),frozen_manifest_tests=len(manifest),
                  manifest_complete=meta['tests']==manifest,metadata_sha256=metadata_hash,
                  source_sha256=sources,auditor_sha256=sha(Path(__file__)),
                  output_sha256=hashes,tb_contract_sha256=tb_contract,
                  decoder_sha256=sources[DECODER],golden_generator_sha256={p:sources[p] for p in (GENERATOR,RX_GENERATOR)},
                  checks=int(verdict[0]),cases=cases,frames_per_net=27,host_readback_bytes=49344,
                  limitations=['Public PHY/host request coactivity does not prove internal grant collisions.',
                               'Frozen HDL run evidence; no synthesis, mapped timing, or complete-message 2ms claim.',
                               'TFTP 520-byte transport exchange; no complete ARINC 615A conformance claim.',
                               'Hashes bind recorded evidence; they are not signed simulator provenance.'])
    with target.open('x',encoding='utf-8',newline='\n') as stream:
        stream.write(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    args = parser.parse_args()
    try:
        result = audit(args.run)
    except (ValueError,AssertionError,OSError,KeyError,IndexError,TypeError,StopIteration,struct.error) as error:
        print('PUBLIC TXRX AUDIT REJECTED: '+str(error),file=sys.stderr)
        return 1
    print(f"PUBLIC TXRX AUDIT PASS scope={result['scope']} tests={result['regression_tests']} frames_per_net=27 host_bytes=49344")
    return 0


if __name__=='__main__':
    sys.exit(main())
