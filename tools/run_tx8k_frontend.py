"""eLinx frontend for an audited frozen production run; not complete synthesis."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

EXE = Path('C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe')


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run(source, output, audit_name='TX_PRODUCTION_AUDIT.json'):
    assert not output.exists(), 'Use a new result directory'
    meta_file = source/'run_metadata.json'
    meta = json.loads(meta_file.read_text(encoding='utf-8-sig'))
    assert meta['regression_result'] == 'PASS' and meta['return_code'] == 0
    assert audit_name in ('TX_PRODUCTION_AUDIT.json','FILE_HOLD_AUDIT.json','PUBLIC_TXRX_AUDIT.json')
    audit_path=source/audit_name
    audit=json.loads(audit_path.read_text(encoding='utf-8'))
    assert audit.get('status',audit.get('verdict'))=='PASS'
    if audit_name=='PUBLIC_TXRX_AUDIT.json':
        assert audit['metadata_sha256']==sha(meta_file), 'Public repair audit belongs to another run'
    workspace = source/'workspace'
    source_list = workspace/'elinx/AFDX_top_sources.f'
    sources = source_list.read_text(encoding='utf-8').splitlines()
    assert len(sources) == len(set(sources)) and len(sources) in (49,50)
    assert ('rtl/mgmt/a615a_init_tx.v' in sources) == (len(sources)==50)
    output.mkdir(parents=True)
    hashes = {}
    for rel in sources:
        original = workspace/rel
        assert sha(original) == meta['source_sha256'][rel], rel
        dst = output/'input'/rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, dst)
        hashes[rel] = sha(dst)
    result = {'scope':'read_verilog/hierarchy/stat plus isolated integrated store/control proc/check; not complete synthesis',
              'runner_sha256':sha(Path(__file__)), 'regression_metadata_sha256':sha(meta_file),
              'audit_sha256':sha(audit_path), 'audit_name':audit_name, 'rtl_sha256':hashes,
              'source_list_sha256':sha(source_list), 'executable_sha256':sha(EXE), 'stages':[]}
    configurations = [('default',1,1),('tx4_rx5',4,5),('store_proc',None,None)]
    # Process-check each integrated control module even when the qualifying
    # functional run is audited for TX. File-hold proof remains a separate
    # audit; its name must not determine whether connected RTL gets checked.
    if 'rtl/mgmt/a615a_lur_orchestrator.v' in sources:
        configurations.append(('lur_orch_proc',None,None))
    if 'rtl/mgmt/a615a_init_tx.v' in sources:
        configurations.append(('init_proc',None,None))
    for label, tx, rx in configurations:
        isolated_top = {'lur_orch_proc':'a615a_lur_orchestrator',
                        'init_proc':'a615a_init_tx'}.get(label,'tx_message_store')
        selected = sources if tx else [('rtl/mgmt/' if label in ('lur_orch_proc','init_proc') else 'rtl/tx/')+isolated_top+'.v']
        lines = ['read_verilog '+('-mem2reg ' if rel=='rtl/tx/tx_vl_scheduler.v' else '')+
                 '"'+(output/'input'/rel).as_posix()+'"' for rel in selected]
        lines += ([f'hierarchy -check -top AFDX_top -chparam TX_MESSAGE_CHAIN_BLOCKS {tx} -chparam RX_REASM_CHAIN_BLOCKS {rx}', 'stat']
                  if tx else ['hierarchy -check -top '+isolated_top, 'proc', 'check', 'stat'])
        script = output/(label+'.ys')
        script.write_text('\n'.join(lines)+'\n', encoding='ascii')
        log = output/(label+'.log')
        command = [str(EXE),'-Q','-T','-s',str(script),'-l',str(log)]
        start = time.monotonic()
        rc = None
        timed_out = False
        with (output/(label+'.stdout.txt')).open('wb') as stdout, (output/(label+'.stderr.txt')).open('wb') as stderr:
            try:
                proc = subprocess.run(command, cwd=output, stdout=stdout, stderr=stderr,
                                      timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                timed_out = True
        text = log.read_text(encoding='utf-8',errors='replace') if log.exists() else ''
        warnings = re.findall(r'^Warning:.*', text, re.M)
        errors = re.findall(r'^ERROR:.*', text, re.M)
        verdict = 'PASS' if rc==0 and text and not warnings and not errors and not timed_out else 'FAIL'
        result['stages'].append({'label':label,'tx_chain':tx,'rx_chain':rx,'verdict':verdict,
                                 'command':command,'exit_code':rc,'timed_out':timed_out,
                                 'elapsed_seconds':round(time.monotonic()-start,3),
                                 'warnings':warnings,'errors':errors,'script_sha256':sha(script),
                                 'log_sha256':sha(log) if log.exists() else None})
        result['verdict'] = verdict
        (output/'frontend_metadata.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print(f'TX8K FRONTEND {verdict} stage={label} warnings={len(warnings)} errors={len(errors)}',flush=True)
        assert verdict=='PASS', label
    assert all(sha(output/'input'/rel)==digest for rel,digest in hashes.items())


if __name__=='__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--audit',choices=['TX_PRODUCTION_AUDIT.json','FILE_HOLD_AUDIT.json','PUBLIC_TXRX_AUDIT.json'],default='TX_PRODUCTION_AUDIT.json')
    args = parser.parse_args()
    run(args.run.resolve(),args.out.resolve(),args.audit)
