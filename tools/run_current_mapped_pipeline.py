"""Wait for strict full RTL evidence, synthesize once, then measure mapped cost.

Fail-stop pipeline; never reruns old netlists or infers business PASS from a
bounded feasibility observation. Uses frozen public T78 stimulus unchanged.
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


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-pipeline',required=True,type=Path)
    parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--probe-timeout-seconds',type=int,default=900)
    parser.add_argument('--keep-hierarchy',action='store_true',
                        help='Keep full hierarchy to reduce flattening memory demand; no RTL/configuration reduction')
    parser.add_argument('--wait-for-recovery',type=Path,
                        help='Live recovery pipeline to observe until it creates the requested RTL pipeline')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    out=args.out.resolve()
    candidate=args.candidate.resolve()
    rtl_pipeline=args.rtl_pipeline.resolve()
    for p in [out,candidate,rtl_pipeline]:
        assert p.is_relative_to(root/'out')
    assert not out.exists() and not candidate.exists()
    out.mkdir()
    shell=shutil.which('pwsh')
    assert shell
    state={'schema':'serial-current-mapped-pipeline-v1','status':'WAITING_FULL_RTL',
           'started_local':datetime.now().astimezone().isoformat(),
           'rtl_pipeline':str(rtl_pipeline),'candidate':str(candidate),
           'scope':'Default full synthesis then bounded original T78 mapped feasibility; no business/all-P11 closure',
           'runner_sha256':sha(Path(__file__)), 'powershell_sha256':sha(Path(shell)), 'stages':[]}
    scripts=['prepare_native_gmii.ps1','run_native_gmii.ps1','run_native_gmii_sim.ps1',
             'native_gmii_cases.json','native_gmii_contract.py']
    state['planned_input_sha256']={name:sha(root/'tools'/name) for name in scripts}

    def save():
        state['updated_local']=datetime.now().astimezone().isoformat()
        temp=out/'pipeline_status.json.tmp'
        temp.write_text(json.dumps(state,indent=2)+'\n',encoding='utf-8')
        temp.replace(out/'pipeline_status.json')

    def stage(name,command):
        entry={'name':name,'command':list(map(str,command)),'status':'RUNNING','started_local':datetime.now().astimezone().isoformat()}
        state.update(status='RUNNING',current_stage=name)
        state['stages'].append(entry)
        save()
        log=out/(name+'.log')
        started=time.monotonic()
        print('MAPPED_PIPELINE START',name,flush=True)
        with log.open('wb') as stream:
            process=subprocess.Popen(entry['command'],cwd=root,stdout=stream,stderr=subprocess.STDOUT,
                                     creationflags=subprocess.CREATE_NO_WINDOW)
            entry['owned_pid']=process.pid
            save()
            entry['exit_code']=process.wait()
        entry.update(status='PASS' if entry['exit_code']==0 else 'FAIL',
                     ended_local=datetime.now().astimezone().isoformat(),
                     wall_seconds=round(time.monotonic()-started,3), log_sha256=sha(log))
        save()
        print('MAPPED_PIPELINE',entry['status'],name,'rc='+str(entry['exit_code']),flush=True)
        assert entry['exit_code']==0, f'{name} failed; no retry; see {log}'

    try:
        save()
        while True:
            prerequisite_path=rtl_pipeline/'pipeline_status.json'
            if not prerequisite_path.exists():
                assert args.wait_for_recovery, 'RTL prerequisite has not been created'
                recovery_path=args.wait_for_recovery.resolve()/'pipeline_status.json'
                assert recovery_path.is_relative_to(root/'out')
                recovery=json.loads(recovery_path.read_text(encoding='utf-8'))
                assert recovery['status'] in ('WAITING_EXISTING_FULL_TERMINAL','RUNNING'), 'Recovery prerequisite terminal failed'
                pid=(recovery['stages'][-1].get('owned_pid') if recovery['stages'] else
                     recovery.get('last_verified_prerequisite_pid'))
                assert pid,'Recovery has no verifiable live prerequisite'
                live=subprocess.run([shell,'-NoProfile','-Command',f'if(Get-Process -Id {pid} -ErrorAction SilentlyContinue){{exit 0}}else{{exit 1}}'],
                                    capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
                if live.returncode:
                    time.sleep(2)
                    assert prerequisite_path.exists() or json.loads(recovery_path.read_text())!=recovery, 'Recovery process absent and unchanged; no launch'
                    continue
                state.update(last_verified_prerequisite_pid=pid,
                             last_verified_prerequisite_local=datetime.now().astimezone().isoformat(),
                             waiting_on_recovery=str(recovery_path))
                save()
                time.sleep(30)
                continue
            previous=json.loads(prerequisite_path.read_text())
            if previous['status']=='RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING':
                break
            assert previous['status'] in ('RUNNING','WAITING_DIRECTED'), 'RTL prerequisite terminal failed; no synthesis'
            current=previous['stages'][-1] if previous['stages'] else None
            if current and current['status']=='RUNNING' and current.get('owned_pid'):
                # Verify actual process liveness instead of relying on old RUNNING metadata.
                pid=current['owned_pid']
                live=subprocess.run([shell,'-NoProfile','-Command',f'if(Get-Process -Id {pid} -ErrorAction SilentlyContinue){{exit 0}}else{{exit 1}}'],
                                    capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
                if live.returncode:
                    time.sleep(2)
                    refreshed=json.loads((rtl_pipeline/'pipeline_status.json').read_text())
                    assert refreshed!=previous, 'Prerequisite process absent and state unchanged; inspect before any launch'
                    continue
                state['last_verified_prerequisite_pid']=pid
                state['last_verified_prerequisite_local']=datetime.now().astimezone().isoformat()
                save()
            time.sleep(30)
        state['completed_rtl_pipeline_sha256']=sha(rtl_pipeline/'pipeline_status.json')
        full=Path(previous['full'])
        frontend=Path(previous['frontend'])
        meta=json.loads((full/'run_metadata.json').read_text(encoding='utf-8-sig'))
        assert meta['regression_result']=='PASS' and meta['return_code']==0
        assert meta['pass_count']==meta['test_count']==len(meta['tests'])
        for name,expected in state['planned_input_sha256'].items():
            assert sha(root/'tools'/name)==expected,'Planned input changed; freeze a new pipeline'
        prefix=[shell,'-NoProfile','-ExecutionPolicy','Bypass','-File']
        prepare_command=prefix+[root/'tools/prepare_native_gmii.ps1','-RtlRunDir',full,
                                '-OutDir',candidate,'-Configuration','Default']
        if args.keep_hierarchy:
            prepare_command+=['-KeepHierarchy']
        state['hierarchy_policy']='keep' if args.keep_hierarchy else 'flatten'
        stage('prepare_default',prepare_command)
        stage('frontend_reuse',prefix+[candidate/'run_native_gmii.ps1','-CandidateDir',candidate,
                                      '-Stage','Frontend','-ReuseFrontendFrom',frontend])
        stage('full_synthesis_default',prefix+[candidate/'run_native_gmii.ps1','-CandidateDir',candidate,'-Stage','Synthesis'])
        stage('mapped_T78_feasibility',prefix+[candidate/'run_native_gmii_sim.ps1','-CandidateDir',candidate,
                                              '-Case','T78','-Stage','Feasibility','-ProbeMicroseconds','1',
                                              '-RunTag','cost_r1','-TimeoutSeconds',str(args.probe_timeout_seconds)])
        diagnostic=candidate/'sim_T78_Feasibility_cost_r1/simulation_status.json'
        report=json.loads(diagnostic.read_text(encoding='utf-8-sig'))
        assert report['status']=='DIAGNOSTIC_COMPLETED_NO_BUSINESS_VERDICT'
        state.update(status='SYNTHESIS_AND_COST_OBSERVATION_COMPLETE_BUSINESS_PENDING',current_stage=None,
                     diagnostic_sha256=sha(diagnostic), wall_seconds_per_sim_microsecond=report['wall_seconds_per_sim_microsecond'])
    except BaseException as error:
        state.update(status='FAIL_STOP_NO_RETRY',exception=str(error))
        raise
    finally:
        save()


if __name__=='__main__':
    main()
