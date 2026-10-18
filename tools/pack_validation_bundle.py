"""Package a complete frozen RTL validation run with reproducible inputs.

This evidence bundle deliberately retains open protocol/netlist requirements.
It is not the final P00-P12 acceptance package. Runtime inputs always come
from the passed run; current progress documents are separate supplements.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile


def sha(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):
            digest.update(block)
    return digest.hexdigest()


def safe(root,relative):
    name=PurePosixPath(relative)
    assert not name.is_absolute() and '..' not in name.parts and '\\' not in relative
    path=(root/relative).resolve()
    assert path.is_relative_to(root.resolve()) and path.is_file() and not (root/relative).is_symlink()
    return path


def collect(pipeline):
    status_path=pipeline/'pipeline_status.json'
    state=json.loads(status_path.read_text(encoding='utf-8'))
    assert state['status']=='RTL_AND_FRONTEND_PASS_SYNTHESIS_PENDING', 'Completed full RTL/audit pipeline required'
    run=Path(state['full'])
    frontend=Path(state['frontend'])
    freeze=json.loads((pipeline/'full_evidence.json').read_text(encoding='utf-8'))
    meta=json.loads((run/'run_metadata.json').read_text(encoding='utf-8-sig'))
    assert freeze['scope']=='complete manifest'
    assert meta['return_code']==0 and meta['regression_result']=='PASS'
    assert freeze['passing']==freeze['test_count']==meta['pass_count']==meta['test_count']==len(meta['tests'])
    assert state['full_metadata_sha256']==sha(run/'run_metadata.json')==freeze['evidence_sha256']['run_metadata.json']
    files={}

    def add(name,path,expected=None):
        digest=sha(path)
        if expected is not None:
            assert digest==expected, 'Evidence hash changed: '+name
        if name in files:
            assert files[name]['sha256']==digest
        files[name]={'path':path,'sha256':digest,'bytes':path.stat().st_size}

    for relative,digest in freeze['source_sha256'].items():
        add('source/'+relative,safe(run/'workspace',relative),digest)
    # Mutable transcripts are outputs, never recreated as source inputs.
    for relative,digest in freeze['evidence_sha256'].items():
        add('evidence/rtl/'+relative,safe(run,relative),digest)
    audit_names = ['TX_PRODUCTION_AUDIT.json','INIT_SOURCE_AUDIT.json','TXRX_COEXIST_AUDIT.json',
                   'FILE_HOLD_AUDIT.json','GMII_SCALE_AUDIT.json']
    if any(row['id']=='T86' for row in meta['tests']):
        audit_names.append('PUBLIC_TXRX_AUDIT.json')
    for audit_name in audit_names:
        path=run/audit_name
        audit=json.loads(path.read_text(encoding='utf-8'))
        assert audit.get('status',audit.get('verdict'))=='PASS'
        aliases = {
            'TX_PRODUCTION_AUDIT.json': {
                'metadata': 'run_metadata.json',
                'vectors': 'workspace/sim/vec/t82_tx8k/cases.hex',
                'recovery_vectors': 'workspace/sim/vec/t82_recovery/cases.hex',
            },
            'INIT_SOURCE_AUDIT.json': {'ACK_vectors': 'workspace/sim/vec/t84_init_source/acks.hex'},
            'TXRX_COEXIST_AUDIT.json': {'vectors': 'workspace/sim/vec/t83_coexist/cases.hex'},
        }
        for field in ['output_sha256','logs_sha256']:
            for relative,digest in audit.get(field,{}).items():
                resolved = aliases.get(audit_name, {}).get(relative, relative)
                if relative.startswith(('t82_tx_', 't84_init_', 't83_case')):
                    resolved = 'metrics/' + relative
                add('evidence/rtl/'+resolved,safe(run,resolved),digest)
        if 'metadata_sha256' in audit:
            assert audit['metadata_sha256']==sha(run/'run_metadata.json')
        add('evidence/rtl/'+audit_name,path)
        # Evidence-only parser repairs may postdate the frozen simulation.
        # Preserve the exact executed auditor separately from source/.
        auditor_names = {
            'TX_PRODUCTION_AUDIT.json': 'audit_tx8k_production.py',
            'INIT_SOURCE_AUDIT.json': 'audit_a615a_init_source.py',
            'TXRX_COEXIST_AUDIT.json': 'audit_txrx_coexist.py',
            'FILE_HOLD_AUDIT.json': 'audit_a615a_file_hold.py',
            'GMII_SCALE_AUDIT.json': 'audit_gmii_scale.py',
            'PUBLIC_TXRX_AUDIT.json': 'audit_public_txrx.py',
        }
        auditor = pipeline.parents[1]/'tools'/auditor_names[audit_name]
        recorded = audit.get('auditor_sha256', audit.get('audit_script_sha256'))
        if audit_name == 'INIT_SOURCE_AUDIT.json':
            recorded = audit['source_sha256']
        assert recorded, 'Auditor provenance missing: '+audit_name
        add('evidence/audit_tools/'+auditor.name, auditor, recorded)
    front_meta_path=frontend/'frontend_metadata.json'
    front=json.loads(front_meta_path.read_text(encoding='utf-8'))
    assert front['verdict']=='PASS' and len(front['stages'])==5
    for rel,digest in front['rtl_sha256'].items():
        assert meta['source_sha256'][rel]==digest
        add('evidence/frontend/input/'+rel,safe(frontend/'input',rel),digest)
    for stage in front['stages']:
        assert stage['verdict']=='PASS' and stage['exit_code']==0
        label=stage['label']
        add('evidence/frontend/'+label+'.log',frontend/(label+'.log'),stage['log_sha256'])
        add('evidence/frontend/'+label+'.ys',frontend/(label+'.ys'),stage['script_sha256'])
    add('evidence/frontend/frontend_metadata.json',front_meta_path)
    add('evidence/full_evidence.json',pipeline/'full_evidence.json')
    add('evidence/rtl_pipeline_status.json',status_path)
    for stage in state['stages']:
        assert stage['status']=='PASS' and stage['exit_code']==0
        add('evidence/pipeline/'+stage['name']+'.log',pipeline/(stage['name']+'.log'),stage['log_sha256'])
    return files,meta,freeze


def package(pipeline,out,root):
    assert out.is_relative_to(root/'out') and not out.exists(), 'Use a new workspace output directory'
    files,meta,freeze=collect(pipeline)
    # Current narrative/decisions are versioned supplements, never silently
    # substituted for the exact tested documentation/runtime snapshot.
    documents=['当前执行表_20261012.md','AFDX项目应用追踪.md','新对话交接_20261012.md',
               '赛题最终验收矩阵.md','协议差距清单_20261009.json','2ms指标负载与计时核实_20261012.md',
               '615A_交付范围与字段依据_20261012.json','615A_规范依据研究_20261013.md',
               '615A_665_官方依据补充_20261013.md','需向赛方确认的问题_20261013.md']
    for name in documents:
        p=root/'doc'/name
        files['supplemental/doc/'+name]={'path':p,'sha256':sha(p),'bytes':p.stat().st_size}
    # The precise frozen source must remain intact. Reproduction uses a new
    # root that omits only derived vector outputs, then regenerates them.
    bootstrap=root/'tools/prepare_validation_reproduction.py'
    files['reproduce/prepare_validation_reproduction.py']={'path':bootstrap,'sha256':sha(bootstrap),'bytes':bootstrap.stat().st_size}
    out.mkdir()
    archive=out/'AFDX_RTL_VALIDATION_BUNDLE.zip'
    manifest={'schema':'afdx-rtl-validation-bundle-v1','status':'FULL_RTL_AND_FRONTEND_EVIDENCE_NOT_FINAL_ACCEPTANCE',
              'created_local':datetime.now().astimezone().isoformat(),'run_id':meta['run_id'],
              'tests':freeze['test_count'],'ordered_test_ids':freeze['ordered_test_ids'],
              'defaults':'IF_MODE2/125MHz/128TX/4096RX/TX1RX1; explicit TX4RX5 only in configured tests',
              'open_requirements':['Official2ms applicability/start/end','Complete selected normative615A load/unload and665',
                                   'Remaining P09 combinations','Current complete synthesis/mapped business','P12 final same-version reproduction'],
              'packager_sha256':sha(Path(__file__)),
              'members':{name:{k:v for k,v in record.items() if k!='path'} for name,record in files.items()}}
    readme=f'''# AFDX完整RTL验证证据包

状态：FULL_RTL_AND_FRONTEND_EVIDENCE_NOT_FINAL_ACCEPTANCE。
冻结运行：{meta['run_id']}，实际manifest {freeze['test_count']}/{freeze['test_count']}。

source/为该运行的确切冻结输入；evidence/为对应原始日志、度量、独立审计和前端证据。
evidence/audit_tools/为实际生成独立审计的工具；审计标题/自测诊断解析修复未修改原仿真输入，不能用source/中的历史审计器代替这些已绑定版本。
supplemental/doc/为打包时的进度与语义决策，和source/doc/的历史冻结内容分别标识。
不以RTL/前端通过声称完整综合、网表业务或完整615A通过；全部开放项见BUNDLE_MANIFEST.json。

复现：保留source/冻结原件。解包后在当前项目目录执行
`python <解包路径>/reproduce/prepare_validation_reproduction.py --bundle <本ZIP绝对路径> --out out/reproduction_inputs_<唯一tag>`。
准备入口逐件核验source/，仅在新工作区省略六份可重建向量，避免一次性生成目录已存在。
然后进入新工作区，使用PowerShell7及Python3，配置Questa路径/本地许可，执行
`pwsh -NoProfile -File sim/run_regress.ps1 -OutDir out/reproduction_full_<唯一tag>`。
运行后将新隔离workspace中的六份生成向量与SOURCE_PREPARATION_REVIEW.json所列哈希核对。
每次使用新目录，保留全部载荷/BAG/断言。运行工具环境及原始命令见evidence/rtl/run_metadata.json。
厂商工具、许可和原语库不随包分发；机器绝对路径须按本地环境配置。
ZIP成员已逐件哈希核验；ZIP完整性核验本身不是实际功能复现。
'''
    with zipfile.ZipFile(archive,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as zipout:
        for name,record in files.items():
            assert sha(record['path'])==record['sha256'], 'Input changed during packaging: '+name
            zipout.write(record['path'],name)
        zipout.writestr('BUNDLE_MANIFEST.json',json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        zipout.writestr('START_HERE.md',readme)
    with zipfile.ZipFile(archive) as zipin:
        assert len(zipin.namelist())==len(files)+2 and len(zipin.namelist())==len(set(zipin.namelist()))
        for name,record in files.items():
            digest=hashlib.sha256()
            with zipin.open(name) as stream:
                for block in iter(lambda:stream.read(1024*1024),b''):
                    digest.update(block)
            assert digest.hexdigest()==record['sha256'], 'ZIP mismatch: '+name
    report={'status':'ZIP_MEMBERS_HASH_VERIFIED_NOT_FUNCTIONAL_REPRODUCTION','archive':str(archive),
            'archive_sha256':sha(archive),'archive_bytes':archive.stat().st_size,'members':len(files)+2,
            'run_id':meta['run_id'],'tests':freeze['test_count'],'final_acceptance':False}
    (out/'BUNDLE_MANIFEST.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (out/'PACKAGE_REVIEW.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-pipeline',required=True,type=Path)
    parser.add_argument('--out',required=True,type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    package(args.rtl_pipeline.resolve(),args.out.resolve(),root)
