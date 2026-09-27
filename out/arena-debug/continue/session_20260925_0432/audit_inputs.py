from execute import *
import re
rows=[]
for p in sorted((P/'out/arena-debug/finalize/synth').glob('*')):
 if p.suffix not in ('.log','.txt','.ys','.md'):continue
 b=p.read_bytes();enc='utf-16' if b.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig'
 t=b.decode(enc,errors='replace');ls=t.splitlines()
 rows.append(dict(path=str(p.relative_to(P)),bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),lines=len(ls),errors=[x for x in ls if re.search(r'ERROR|invalid vector|bad allocation|dict::at',x)],tail=ls[-8:]))
(D/'prior_synth_full_log_audit.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf8')
book=P/('AFDX'+chr(0x7aef)+chr(0x7cfb)+chr(0x7edf)+'_'+chr(0x603b)+chr(0x4f53)+chr(0x8bbe)+chr(0x8ba1)+chr(0x4e66)+'.md')
ls=book.read_text(encoding='utf-8-sig').splitlines()
text='\n'.join(f'{i+1}: {ls[i]}' for a,b in [(786,860),(1076,1104),(1157,1160)] for i in range(a,b))
(D/'spec_excerpts.txt').write_text(text,encoding='utf8')
manifest=(P/'sim/tests.manifest').read_text(encoding='utf-8-sig')
rtl=list((P/'rtl').rglob('*.v'))
mg={}
for mod in ['snmp_lite','a615a_tftp','rtc_sync','stats_regs']:
 files=[x for x in rtl if x.stem==mod]
 refs=[]
 for x in rtl:
  for i,l in enumerate(x.read_text(encoding='utf8',errors='replace').splitlines(),1):
   if re.search(r'\b'+mod+r'\b',l) and not l.lstrip().startswith('//'):refs.append([str(x.relative_to(P)),i,l])
 mg[mod]=dict(files=[str(x.relative_to(P)) for x in files],noncomment_references=refs)
mg['T14_T16_manifest']=[l for l in manifest.splitlines() if re.match(r'T1[456]\s',l)]
mg['status']='OUT_OF_SCOPE_FINALIZE / OPEN_SPEC_GAP; no requirements waiver; overall design incomplete'
(D/'management_audit.json').write_text(json.dumps(mg,ensure_ascii=False,indent=2),encoding='utf8')
projects=[]
for scope in ['elinx','sim']:
 for ext in ['*.qpf','*.qsf','*.sdc','*.edc']:
  projects.extend(str(x.relative_to(P)) for x in (P/scope).rglob(ext))
(D/'sta_inventory.json').write_text(json.dumps(dict(search_scope=['elinx','sim'],files=projects,constraints=(P/'elinx/sdc/AFDX_top.edc').read_text(),note='Internal-clock preliminary only; no invented board IO delays'),indent=2))
print('Read all prior synth logs; management and scoped STA inventory written')
