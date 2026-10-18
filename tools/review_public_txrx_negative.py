"""Review the exact single-byte T86 expected-value negative control.

Require a previously audited positive run of the identical frozen test and
identical actual PHY/host captures. This reports a control verdict only.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def review(positive, negative, out):
    assert __debug__ and not out.exists()
    audit_path = positive/'PUBLIC_TXRX_AUDIT.json'
    audit = json.loads(audit_path.read_text(encoding='utf-8'))
    assert audit['status']=='PASS'
    metas = [json.loads((r/'run_metadata.json').read_text(encoding='utf-8-sig'))
             for r in (positive, negative)]
    p,n = metas
    assert p['regression_result']=='PASS' and p['return_code']==0
    assert n['regression_result']=='FAIL' and n['return_code']==1
    assert n['compile_result']=='PASS' and n['compile_rc']==n['vlog_errors']==0
    assert n['current_test'] is None and n['tests_completed']==n['test_count']==1
    assert n['tests']==p['tests'] and n['tests'][0]['id']=='T86'
    assert p['plusargs']=='' and n['plusargs']=='+PUBLIC_CORRUPT_EXPECTED'
    assert n['invocation_parameters']['PlusArgs']==n['plusargs']
    assert n['source_sha256']==p['source_sha256']
    for run,meta in zip((positive,negative),metas):
        for relative,digest in meta['source_sha256'].items():
            path=run/'workspace'/relative
            assert path.resolve().is_relative_to((run/'workspace').resolve())
            assert sha(path)==digest,relative
    console=negative/'T86_console.txt'
    raw=console.read_text(encoding='utf-8-sig')
    lines=[re.sub(r'^#\s?', '', s).strip() for s in raw.splitlines()]
    assert not re.search(r'\*\*\s+(Error|Fatal|Warning)\b|\bTIMEOUT\b|\btimeout\b|\[chk\]',raw)
    assert 'Errors: 0, Warnings: 0' in lines
    verdicts=[s for s in lines if re.fullmatch(r'T86 PUBLIC TXRX (PASS|FAIL)\b.*',s)]
    assert len(verdicts)==1 and re.fullmatch(r'T86 PUBLIC TXRX FAIL errors=1 checks=\d+',verdicts[0])
    assert [s for s in lines if re.search(r'\bFAIL\b',s)]==verdicts
    diagnostics=[s for s in lines if s.startswith('T86 ERROR ')]
    assert len(diagnostics)==1 and re.fullmatch(
        r'T86 ERROR case=0 cycle=\d+ A complete data PHY differs from golden',diagnostics[0])
    rows=[m for s in lines if (m:=re.fullmatch(
        r'T86 CASE_DONE index=(\d+) errors=(\d+) data_frames_A=6 B=6 mgmt_frames_A=3 B=3 host_bytes=16448 tx_host_overlap=(\d+) rx_outstanding_bytes=(\d+) tftp_outstanding_bytes=(\d+)',s))]
    assert len(rows)==3 and [int(m[1]) for m in rows]==[0,1,2]
    assert all(int(m[2])==1 and all(int(m[i])>0 for i in (3,4,5)) for m in rows)
    with (negative/'regress.csv').open(encoding='utf-8-sig',newline='') as stream:
        table=list(csv.DictReader(stream))
    assert len(table)==1 and table[0]['test_id']=='T86' and table[0]['result']=='FAIL'
    # The mutation changes only the local expected byte. Every actual exported
    # capture and timing file must still equal its audited positive counterpart.
    captures={}
    for relative,digest in audit['output_sha256'].items():
        if relative.startswith('metrics/'):
            assert sha(positive/relative)==digest
            assert sha(negative/relative)==digest,relative
            assert sha(negative/'workspace/sim/out'/relative)==digest,relative
            captures[relative]=digest
    assert len(captures)==15, 'six PHY, six timing and three host captures required'
    out.mkdir(parents=True)
    report={'status':'EXACT_EXPECTED_BYTE_NEGATIVE_CONTROL_PASS',
            'business_verdict':'FAIL_EXPECTED_CONTROL_ONLY',
            'positive':str(positive),'negative':str(negative),
            'positive_audit_sha256':sha(audit_path),
            'metadata_sha256':[sha(r/'run_metadata.json') for r in (positive,negative)],
            'negative_console_sha256':sha(console),'negative_error':diagnostics[0],
            'error_count':1,'complete_cases':3,'unchanged_actual_captures_sha256':captures,
            'reviewer_sha256':sha(Path(__file__))}
    (out/'REVIEW.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(report['status'])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--positive',type=Path,required=True)
    parser.add_argument('--negative',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    review(args.positive.resolve(),args.negative.resolve(),args.out.resolve())
