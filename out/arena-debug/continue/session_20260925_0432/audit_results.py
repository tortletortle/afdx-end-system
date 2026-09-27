from execute import *
import csv,re
m=[l.split()[:2] for l in (P/'sim/tests.manifest').read_text(encoding='utf-8-sig').splitlines() if l.strip() and not l.lstrip().startswith('#')]
a={}
for label,folder in [('coverage',D/'coverage'),('final',D/'final_tests')]:
 rows=list(csv.DictReader((folder/'regress.csv').open(encoding='utf-8-sig')))
 errs={}
 for ident,tb in m:
  t=(folder/(ident+'_console.txt')).read_text(encoding='utf8',errors='replace')
  bad=[l for l in t.splitlines() if re.search(r'\bFAIL\b|^#\s*\*\*\s*(Error|Fatal)',l)]
  if bad:errs[ident]=bad
 a[label]=dict(manifest_count=len(m),csv_count=len(rows),same_order=[[r['test_id'],r['tb']] for r in rows]==m,passed=sum(r['result']=='PASS' for r in rows),raw_failure_lines=errs)
 if label=='coverage':
  dbs=[x.stem for x in folder.glob('T*.ucdb') if x.stat().st_size>0]
  a[label]['ucdb_count']=len(dbs);a[label]['ucdb_ids_exact']=set(dbs)==set(x[0] for x in m)
backup=P/'out/arena-debug/backup/continue_20250925/session_20260925_0432'
source=[];mismatches=[]
for scope in ['rtl','sim/tb']:
 for f in sorted((P/scope).rglob('*.v')):
  rel=f.relative_to(P);b=backup/rel
  same=b.exists() and f.read_bytes()==b.read_bytes()
  source.append(dict(path=rel.as_posix(),sha256=hashlib.sha256(f.read_bytes()).hexdigest(),unchanged=same))
  if not same:mismatches.append(rel.as_posix())
a['rtl_tb_changed_since_backup']=mismatches
(D/'source_binding.json').write_text(json.dumps(source,indent=2))
a['lint_errors']=len(re.findall(r'%Error', (D/'final_lint.log').read_text(encoding='utf8',errors='replace').replace('0 %Error','0 errors')))
a['commands']=[json.loads(l) for l in (D/'commands.jsonl').read_text().splitlines() if l.strip()]
(D/'acceptance_audit.json').write_text(json.dumps(a,indent=2))
print(json.dumps({k:v for k,v in a.items() if k!='commands'},indent=2))
