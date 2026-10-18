"""Verify isolated generated vectors without copying them into the source tree."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


GENERATED = {
    'sim/vec/t35_frames.hex':'sw/golden/gen_t35_vectors.py',
    'sim/vec/t35_frames.sha256':'sw/golden/gen_t35_vectors.py',
    'sim/vec/t35_mapping.csv':'sw/golden/gen_t35_vectors.py',
    'sim/vec/tx_fragment_builder/cases.hex':'sw/golden/gen_tx_fragment_builder.py',
    'sim/vec/tx_fragment_builder/manifest.json':'sw/golden/gen_tx_fragment_builder.py',
    'sim/vec/t36_mgmt.hex':'sw/golden/gen_t36_vectors.py',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(run, out, root):
    assert out.is_relative_to(root/'out') and not out.exists()
    meta=json.loads((run/'run_metadata.json').read_text(encoding='utf-8-sig'))
    out.mkdir()
    workspace=out/'workspace'
    sources={}
    dependencies={}
    for relative in ['sim/vec/t12_top.img.hex','sim/vec/t12_top.meta.hex']:
        expected=meta['source_sha256'][relative]
        source=run/'workspace'/relative
        assert sha(source)==sha(root/relative)==expected,'Generated vector dependency changed: '+relative
        destination=workspace/relative
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,destination)
        dependencies[relative]=expected
    for relative,expected in meta['source_sha256'].items():
        if not relative.startswith('sw/golden/') or not relative.endswith('.py'):
            continue
        source=run/'workspace'/relative
        assert sha(source)==sha(root/relative)==expected,'Generator source differs: '+relative
        destination=workspace/relative
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,destination)
        sources[relative]=expected
    steps=[]
    for generator in dict.fromkeys(GENERATED.values()):
        command=[sys.executable,str(workspace/generator)]
        if generator.endswith('gen_tx_fragment_builder.py'):
            command+=['--out',str(workspace/'sim/vec/tx_fragment_builder')]
        log=out/(Path(generator).stem+'.log')
        with log.open('wb') as stream:
            process=subprocess.run(command,cwd=root,stdout=stream,stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        steps.append({'generator':generator,'command':command,'exit_code':process.returncode,'log_sha256':sha(log)})
        assert process.returncode==0,'Generator failed: '+str(log)
    hashes={}
    for relative in GENERATED:
        expected=meta['source_sha256'][relative]
        assert sha(run/'workspace'/relative)==sha(workspace/relative)==expected,'Generated content differs: '+relative
        hashes[relative]=expected
    report={'status':'PASS','scope':'Six generated inputs reconstructed privately; no root vector overwrite and no simulator/synthesis',
            'run':str(run),'generator_sha256':sources,'dependency_sha256':dependencies,'generated_sha256':hashes,'steps':steps,
            'reviewer_sha256':sha(Path(__file__))}
    (out/'GENERATED_INPUT_REVIEW.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',required=True,type=Path)
    parser.add_argument('--out',required=True,type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    result=verify(args.run.resolve(),args.out.resolve(),root)
    print('PASS: six generated runtime inputs exactly reconstructed with unchanged frozen generators')
