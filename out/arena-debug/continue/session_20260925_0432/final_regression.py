from execute import *
import shutil,csv,re
# Explicit dependency: final normal Questa starts only after coverage and vcover end.
start=time.time()
while not (D/'coverage_report_rc.txt').exists():
 if time.time()-start>1800: raise RuntimeError('Coverage dependency not complete; final regression NOT started')
 time.sleep(2)
# Preserve every coverage output in its own directory; normal regression uses sim/out.
rc=run('final_full50',['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(P/'sim/run_regress.ps1')],timeout=3600)
f=D/'final_tests';f.mkdir(exist_ok=False)
for x in (P/'sim/out').glob('*_console.txt'):shutil.copy2(x,f/x.name)
shutil.copy2(P/'sim/out/regress.csv',f/'regress.csv')
shutil.copy2(P/'sim/tests.manifest',f/'tests.manifest')
manifest=[l.split()[:2] for l in (P/'sim/tests.manifest').read_text(encoding='utf-8-sig').splitlines() if l.strip() and not l.lstrip().startswith('#')]
rows=list(csv.DictReader((f/'regress.csv').open(encoding='utf-8-sig')))
audit={'manifest_count':len(manifest),'rows':len(rows),'same_order':[[r['test_id'],r['tb']] for r in rows]==manifest,'pass':sum(r['result']=='PASS' for r in rows),'fail':sum(r['result']!='PASS' for r in rows),'rc':rc}
audit['console_count']=sum((f/(m[0]+'_console.txt')).is_file() for m in manifest)
audit['compile_errors']=re.findall(r'Errors:\s*(\d+)',(f/'compile_console.txt').read_text(encoding='utf8',errors='replace'))
(D/'final_audit.json').write_text(json.dumps(audit,indent=2))
run('final_lint',['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(P/'tools_lint.ps1')])
run('final_docgate',['python',str(P/'tools/run_all.py'),'--strict'])
print(json.dumps(audit),flush=True)
