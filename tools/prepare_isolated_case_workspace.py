"""Prepare one new test in a fresh workspace from exact frozen run inputs.

Copy only recorded files, never recursive output trees. Omit deterministic
runtime vector outputs in the new copy so one-shot generators can run. Keep
the original full snapshot, production RTL, stimulus and failed evidence.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from prepare_validation_reproduction import GENERATED


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(root, run, draft, case, module, configuration, out):
    assert out.is_relative_to(root/'out') and not out.exists()
    assert draft.is_relative_to(root) and draft.is_file()
    meta = json.loads((run/'run_metadata.json').read_text(encoding='utf-8-sig'))
    assert meta['regression_result']=='PASS' and meta['return_code']==meta['compile_rc']==0
    workspace = out/'workspace'
    out.mkdir()
    workspace.mkdir()
    copied = {}
    for relative, expected in meta['source_sha256'].items():
        path = run/'workspace'/relative
        assert sha(path)==expected, relative
        if relative in GENERATED:
            continue
        destination = workspace/relative
        assert destination.resolve().is_relative_to(workspace)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        copied[relative] = expected
    target = workspace/'sim/tb'/f'{module}.v'
    assert not target.exists()
    shutil.copy2(draft, target)
    # This is a directed workspace; root/full-run manifest is never changed.
    (workspace/'sim/tests.manifest').write_text(f'{case} {module} {configuration}\n',encoding='utf-8')
    command=[sys.executable,workspace/'sim/check_bind_scope.py',
             '--source-root',workspace,'--sim-dir',workspace/'sim',
             '--scope',workspace/'sim/bind_scope.tsv',
             '--profiles',workspace/'sim/bind_scope_profiles.tsv','--emit']
    result=subprocess.run(list(map(str,command)),capture_output=True,text=True,encoding='utf-8',
                          creationflags=subprocess.CREATE_NO_WINDOW)
    (out/'bind_scope_preparation.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    assert result.returncode==0,result.stdout+result.stderr
    sources=(workspace/'elinx/AFDX_top_sources.f').read_text(encoding='utf-8').splitlines()
    assert all(sha(workspace/relative)==meta['source_sha256'][relative] for relative in sources)
    report={'status':'FROZEN_PRODUCTION_DIRECTED_WORKSPACE_PREPARED_NOT_RUN',
            'prepared_local':datetime.now().astimezone().isoformat(),'base_run':str(run),
            'base_metadata_sha256':sha(run/'run_metadata.json'),'workspace':str(workspace),
            'draft':str(draft),'draft_sha256':sha(draft),'case':case,'module':module,
            'production_sources':len(sources),'copied_source_sha256':copied,
            'omitted_generated':sorted(GENERATED),'bind_scope_sha256':sha(workspace/'sim/bind_scope.tsv'),
            'tool_sha256':sha(Path(__file__)),'scope':'New directed test only; no root integration, no simulation or synthesis acceptance'}
    (out/'WORKSPACE_REVIEW.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='copied_source_sha256'}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--draft',type=Path,required=True)
    parser.add_argument('--case',required=True)
    parser.add_argument('--module',required=True)
    parser.add_argument('--configuration',required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    prepare(root,args.run.resolve(),args.draft.resolve(),args.case,args.module,args.configuration,args.out.resolve())
