"""Restore the missing escaped-module identifier terminator in eLinx VQM.

Only a single ASCII space before '(' on exact known escaped module declaration
lines is inserted. All other bytes remain unchanged; original artifacts are
never overwritten. This is export syntax normalization, not resynthesis.
"""
from pathlib import Path
import argparse,hashlib,json,re

def sha(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def normalize(source, module_il, destination, review):
    assert source.is_file() and module_il.is_file()
    assert not destination.exists() and not review.exists()
    names=set()
    with module_il.open('rb') as f:
        for line in f:
            if line.startswith(b'module '):names.add(line.strip().split(b' ',1)[1])
    pattern=re.compile(rb'^(module )(\\[^\s(]+)(\(\r?\n)$')
    changes=[];original_digest=hashlib.sha256();reversed_digest=hashlib.sha256()
    destination.parent.mkdir(parents=True,exist_ok=True)
    with source.open('rb') as src,destination.open('xb') as dst:
        for number,line in enumerate(src,1):
            original_digest.update(line)
            match=pattern.fullmatch(line)
            if match:
                actual=match.group(2)[1:]
                assert actual in names,(number,actual)
                revised=match.group(1)+match.group(2)+b' '+match.group(3)
                assert revised.replace(match.group(2)+b' (',match.group(2)+b'(',1)==line
                changes.append({'line':number,'actual_module_name':actual.decode('utf-8')})
                dst.write(revised);reversed_digest.update(line)
            else:dst.write(line);reversed_digest.update(line)
    assert changes and original_digest.hexdigest()==sha(source)==reversed_digest.hexdigest()
    result={'status':'EXACT_ESCAPED_MODULE_TERMINATOR_SPACES_INSERTED_NOT_COMPILED',
            'source_sha256':sha(source),'module_il_sha256':sha(module_il),'normalized_sha256':sha(destination),
            'changed_declarations':changes,'inserted_ascii_spaces':len(changes),
            'source_bytes':source.stat().st_size,'normalized_bytes':destination.stat().st_size,
            'noninsertion_bytes_unchanged':True,
            'scope':'Only missing lexical whitespace at known escaped module declarations; no cell, net, parameter, port, model or test changes. Original export retained.'}
    assert result['normalized_bytes']==result['source_bytes']+len(changes)
    review.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source',type=Path,required=True);p.add_argument('--module-il',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--review',type=Path,required=True)
    a=p.parse_args();r=normalize(a.source.resolve(),a.module_il.resolve(),a.out.resolve(),a.review.resolve())
    print(json.dumps({k:v for k,v in r.items() if k!='changed_declarations'}))
