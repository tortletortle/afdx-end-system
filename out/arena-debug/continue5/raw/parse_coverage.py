import re,json,os
p=r'C:\Workspace\diansai\out\arena-debug\continue5\raw\vcover_details_completed53.txt'
lines=open(p,encoding='utf-8',errors='replace').read().splitlines()
cur_src=''; cur_inst=''; mode=''; all_b=[0,0,0]; rtl_b=[0,0,0]; all_s=[0,0,0]; rtl_s=[0,0,0]; mods={}
def isrtl(s):
    q=s.replace('\\','/').lower()
    return '/rtl/' in q
for line in lines:
    m=re.match(r'^=== Instance: (.+)$',line)
    if m: cur_inst=m.group(1); continue
    m=re.match(r'^\s*File (.+)$',line)
    if m: cur_src=m.group(1).strip(); continue
    m=re.search(r'Branch totals:\s*(\d+) hits of (\d+) branches',line)
    if m:
        h,n=map(int,m.groups()); miss=n-h; all_b[0]+=n;all_b[1]+=h;all_b[2]+=miss
        if isrtl(cur_src):
            rtl_b[0]+=n;rtl_b[1]+=h;rtl_b[2]+=miss
            k=os.path.basename(cur_src.replace('\\','/')); x=mods.setdefault(k,{'source':cur_src,'branch':[0,0,0],'statement':[0,0,0]}); x['branch'][0]+=n;x['branch'][1]+=h;x['branch'][2]+=miss
        continue
    m=re.match(r'^\s*Statements\s+(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)%',line)
    if m:
        n,h,miss=int(m.group(1)),int(m.group(2)),int(m.group(3)); all_s[0]+=n;all_s[1]+=h;all_s[2]+=miss
        if isrtl(cur_src):
            rtl_s[0]+=n;rtl_s[1]+=h;rtl_s[2]+=miss
            k=os.path.basename(cur_src.replace('\\','/')); x=mods.setdefault(k,{'source':cur_src,'branch':[0,0,0],'statement':[0,0,0]}); x['statement'][0]+=n;x['statement'][1]+=h;x['statement'][2]+=miss
res={'inputs_completed_ucdb':53,'all_details':{'branch':all_b,'statement':all_s},'rtl_only_details':{'branch':rtl_b,'statement':rtl_s},'top_uncovered_rtl':sorted(mods.values(),key=lambda x:x['branch'][2]+x['statement'][2],reverse=True)[:15]}
out=r'C:\Workspace\diansai\out\arena-debug\continue5\coverage_metrics.json'; json.dump(res,open(out,'w',encoding='utf-8'),indent=2)
print(json.dumps(res,indent=2))
print('DETAIL_LINE_COUNT='+str(len(lines)))