"""Finish the existing full run, verify T15 capacity fix, then rerun full scope.

Never launches beside an existing heavy tool; unexpected failures stop for
diagnosis. Current full results remain failed evidence, not patched PASS rows.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--generated-input-review',required=True,type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    out=args.out.resolve()
    assert out.is_relative_to(root/'out') and not out.exists()
    out.mkdir()
    failed=root/'sim/out/gmii_guard_full137_20261013_r2'
    prerequisite=root/'out/gmii_guard_validation_pipeline_20261013_r2/pipeline_status.json'
    directed=root/'sim/out/t15_vector_capacity_20261013_r1'
    full=root/'sim/out/gmii_guard_full137_20261013_r3'
    next_pipe=root/'out/gmii_guard_validation_pipeline_20261013_r3'
    shell=shutil.which('pwsh')
    assert shell
    state={'schema':'t15-vector-capacity-recovery-v1','status':'WAITING_EXISTING_FULL_TERMINAL',
           'started_local':datetime.now().astimezone().isoformat(),'failed_run':str(failed),
           'scope':'Preserve failed full137; strict original-failure directed proof then new complete137; no synthesis claim',
           'runner_sha256':sha(Path(__file__)),'stages':[],
           'planned_t15_sha256':sha(root/'sim/tb/tb_t15_snmp.v'),
           'generated_input_review':str(args.generated_input_review.resolve()),
           'generated_input_review_sha256':sha(args.generated_input_review.resolve()),
           'planned_regression_runner_sha256':sha(root/'sim/run_regress.ps1')}

    def save():
        state['updated_local']=datetime.now().astimezone().isoformat()
        temp=out/'pipeline_status.json.tmp'
        temp.write_text(json.dumps(state,indent=2)+'\n',encoding='utf-8')
        temp.replace(out/'pipeline_status.json')

    def stage(name,command):
        item={'name':name,'command':list(map(str,command)),'status':'RUNNING'}
        state.update(status='RUNNING',current_stage=name)
        state['stages'].append(item)
        save()
        log=out/(name+'.log')
        started=time.monotonic()
        print('T15_RECOVERY START',name,flush=True)
        with log.open('wb') as stream:
            proc=subprocess.Popen(item['command'],cwd=root,stdout=stream,stderr=subprocess.STDOUT,
                                  creationflags=subprocess.CREATE_NO_WINDOW)
            item['owned_pid']=proc.pid
            save()
            item['exit_code']=proc.wait()
        item.update(status='PASS' if item['exit_code']==0 else 'FAIL',elapsed_seconds=round(time.monotonic()-started,3),
                    log_sha256=sha(log))
        save()
        print('T15_RECOVERY',item['status'],name,flush=True)
        assert item['exit_code']==0, f'{name} failed; no retry'

    try:
        save()
        while True:
            previous=json.loads(prerequisite.read_text())
            if previous['status']=='FAIL_STOP_NO_RETRY':
                break
            assert previous['status']=='RUNNING','Unexpected prerequisite state'
            running=previous['stages'][-1]
            pid=running.get('owned_pid')
            if pid and running['status']=='RUNNING':
                observation=subprocess.run([shell,'-NoProfile','-Command',f'if(Get-Process -Id {pid} -ErrorAction SilentlyContinue){{exit 0}}else{{exit 1}}'],
                                           capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
                if observation.returncode:
                    time.sleep(2)
                    assert json.loads(prerequisite.read_text())!=previous,'Prerequisite process absent with unchanged state'
                    continue
                state['last_verified_prerequisite_pid']=pid
                state['last_verified_prerequisite_local']=datetime.now().astimezone().isoformat()
                save()
            time.sleep(30)
        meta=json.loads((failed/'run_metadata.json').read_text(encoding='utf-8-sig'))
        assert meta['regression_result']=='FAIL' and meta['return_code']==1
        assert meta['tests_completed']==meta['test_count']==137
        failures={row['id'] for row in meta['test_results'] if row['result']!='PASS'}
        state['observed_failures']=sorted(failures)
        assert failures=={'T15','T15g'},'Unexpected full-run failure; diagnose before restarting anything'
        # The frozen TB contains UTF-8 comments. Windows' locale default can
        # be GBK, so comparing the reviewed edit must use an explicit codec.
        old=(failed/'workspace/sim/tb/tb_t15_snmp.v').read_text(encoding='utf-8-sig')
        new=(root/'sim/tb/tb_t15_snmp.v').read_text(encoding='utf-8-sig')
        expected=old.replace('  reg [31:0] vec [0:2047];',
            '  // All 54 current golden cases occupy 2101 words. Keep the complete vector,\n'
            "  // including cases beyond this TB's selected requests, without truncation.\n"
            '  reg [31:0] vec [0:2100];')
        assert new==expected,'More than the reviewed vector capacity fix changed'
        assert sha(root/'sim/tb/tb_t15_snmp.v')==state['planned_t15_sha256']
        assert sha(root/'sim/run_regress.ps1')==state['planned_regression_runner_sha256']
        proof_path=args.generated_input_review.resolve()
        assert sha(proof_path)==state['generated_input_review_sha256']
        proof=json.loads(proof_path.read_text(encoding='utf-8'))
        assert proof['status']=='PASS' and Path(proof['run'])==failed
        from verify_generated_runtime_inputs import GENERATED
        assert set(proof['generated_sha256'])==set(GENERATED), 'Only explicitly generated inputs may use generation evidence'
        for relative,expected in proof['generator_sha256'].items():
            assert sha(root/relative)==expected==meta['source_sha256'][relative]
        for relative,expected in proof['dependency_sha256'].items():
            assert sha(root/relative)==expected==meta['source_sha256'][relative]
        for relative,expected_hash in meta['source_sha256'].items():
            if relative.startswith(('rtl/','sim/tb/','sim/env/','sim/assert/','sim/vec/','sw/golden/')) and relative!='sim/tb/tb_t15_snmp.v':
                if relative in GENERATED:
                    assert proof['generated_sha256'][relative]==expected_hash
                    assert sha(proof_path.parent/'workspace'/relative)==expected_hash
                    assert sha(failed/'workspace'/relative)==expected_hash
                    continue
                assert sha(root/relative)==expected_hash,'Other functional input changed: '+relative
        assert not directed.exists() and not full.exists() and not next_pipe.exists()
        gate=subprocess.run([shell,'-NoProfile','-Command',
            'if(Get-Process -Name vsim,vsimk,eLinx_synthesis,iverilog,ivl,vvp,quartus_sh,quartus_map,quartus_fit -ErrorAction SilentlyContinue){exit 1}'],
            capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
        assert gate.returncode==0,'Other heavy tool active'
        stage('original_failure_path', [shell,'-NoProfile','-ExecutionPolicy','Bypass','-File',root/'sim/run_regress.ps1',
                                        '-Tests','T15,T15g','-OutDir','out/t15_vector_capacity_20261013_r1'])
        directed_meta=json.loads((directed/'run_metadata.json').read_text(encoding='utf-8-sig'))
        assert directed_meta['regression_result']=='PASS' and directed_meta['return_code']==0
        assert directed_meta['pass_count']==directed_meta['test_count']==2
        stage('new_full_and_audits', [sys.executable,root/'tools/run_current_validation_pipeline.py',
              '--directed',root/'sim/out/gmii_guard_production_scale_20261012_r3',
              '--out',next_pipe,'--frontend-out',root/'out/gmii_guard_frontend_20261012_r1','--full-out',full,
              '--reuse-directed-checks-from',root/'out/gmii_guard_validation_pipeline_20261012_r1'])
        state.update(status='RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING',current_stage=None,
                     full_metadata_sha256=sha(full/'run_metadata.json'))
    except BaseException as error:
        state.update(status='FAIL_STOP_NO_RETRY',exception=str(error))
        raise
    finally:
        save()


if __name__=='__main__':
    main()
