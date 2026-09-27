import subprocess,pathlib,json,time,hashlib,os,sys
P=pathlib.Path('C:/Workspace/diansai');os.chdir(P)
D=P/'out/arena-debug/continue/session_20260925_0432'
J=D/'commands.jsonl'
def run(name,args,cwd=P,timeout=1200):
 log=D/(name+'.log');start=time.time()
 if log.exists():raise RuntimeError('Refusing overwrite: '+str(log))
 with log.open('wb') as f:
  try:r=subprocess.run(args,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,timeout=timeout);rc=r.returncode
  except subprocess.TimeoutExpired:rc=124
 data=dict(name=name,argv=[str(a) for a in args],cwd=str(cwd),rc=rc,wall_s=round(time.time()-start,2),sha256=hashlib.sha256(log.read_bytes()).hexdigest())
 with J.open('a',encoding='utf8') as f:f.write(json.dumps(data)+'\n')
 (D/(name+'_rc.txt')).write_text(str(rc))
 print(json.dumps(data),flush=True);return rc
if __name__=='__main__':
 if sys.argv[1]=='coverage':
  rc=run('coverage_full50',['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',str(D/'run_full_cov.ps1')],timeout=3600)
  cov=D/'coverage';dbs=sorted(cov.glob('T*.ucdb'))
  (D/'coverage_db_inventory.json').write_text(json.dumps([dict(path=x.name,bytes=x.stat().st_size,sha256=hashlib.sha256(x.read_bytes()).hexdigest()) for x in dbs],indent=2))
  vc='C:/altera_pro/26.1.1/questa_fse/win64/vcover.exe'
  if dbs:
   mr=run('coverage_merge',[vc,'merge',str(cov/'full50.ucdb')]+list(map(str,dbs)))
   if mr==0:run('coverage_report',[vc,'report','-code','sb','-summary','-output',str(cov/'merged_summary.txt'),str(cov/'full50.ucdb')])
  sys.exit(rc)
