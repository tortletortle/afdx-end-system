#!/usr/bin/env python3
"""Read-only evidence checks; default writes audit/report, --verify-seal writes nothing."""
import csv, hashlib, importlib.util, io, json, os, re, subprocess, sys
from pathlib import Path
sys.dont_write_bytecode = True
ROOT = Path(r'C:\Workspace\diansai')
C4 = ROOT / 'out/arena-debug/continue4'

def digest(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''):
            h.update(b)
    return h.hexdigest()

def load(name):
    spec = importlib.util.spec_from_file_location(name, C4 / ('tools/' + name + '.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def retained():
    result = []
    for root, dirs, files in os.walk(C4):
        assert not set(dirs) & {'competition_case', 'data', 'logs'}, 'Forbidden directory in package'
        assert all(not (Path(root)/d).is_symlink() for d in dirs), 'No symlink traversal'
        for fn in files:
            p = Path(root)/fn
            assert not p.is_symlink()
            assert fn != '.env' and '.local.' not in fn, 'Sensitive file in package'
            if p != C4/'SHA256SUMS.txt':
                result.append(p)
    return sorted(result, key=lambda p:p.relative_to(C4).as_posix())

def replay(m):
    lines = (C4/'fixes.patch').read_text(encoding='utf-8').splitlines()
    paths = re.findall(r'^\+\+\+ b/(.+)$', '\n'.join(lines), re.M)
    assert paths == [rel for rel, _ in m.FILES]
    result = []
    for rel, bk in m.FILES:
        start = lines.index('--- a/'+rel)
        end = next((i for i in range(start+2,len(lines)) if lines[i].startswith('### ')),len(lines))
        seg = lines[start+2:end]
        if bk == 'NEW':
            base, baseline = '', 'new file'
        elif bk is None:
            base = m.head_of(rel)
            baseline = 'git HEAD' if base is not None else 'MISSING: full image only'
            base = base or ''
        else:
            base, baseline = m.rd(C4/'backup'/bk), 'backup/'+bk
        old = base.splitlines(); out=[]; pos=0; i=0
        while i < len(seg):
            line=seg[i]
            if not line.startswith('@@'):
                i+=1; continue
            h=re.match(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',line)
            assert h, (rel,line)
            old_count=int(h[2] or 1); new_count=int(h[4] or 1)
            index=int(h[1])-1 if old_count else int(h[1])
            assert index >= pos
            out+=old[pos:index]; pos=index; i+=1; consumed=added=0
            while i < len(seg) and not seg[i].startswith('@@'):
                line=seg[i]
                if line.startswith((' ','-')):
                    assert pos<len(old) and old[pos]==line[1:], (rel,pos,line)
                    pos+=1; consumed+=1
                if line.startswith((' ','+')):
                    out.append(line[1:]); added+=1
                i+=1
            assert (consumed,added)==(old_count,new_count), (rel,consumed,added)
        out+=old[pos:]
        assert out==(ROOT/rel).read_text(encoding='utf-8').splitlines(), 'Stale patch: '+rel
        result.append({'path':rel,'baseline':baseline,'baseline_text_sha256':hashlib.sha256(base.encode('utf-8')).hexdigest(),
                       'current_sha256':digest(ROOT/rel),'replay_matches_current_text':True})
    return result

def main():
    if '--verify-seal' in sys.argv:
        audit=json.loads((C4/'raw/finalize_audit.json').read_text(encoding='utf-8'))
        for entry in audit['patch_replay']:
            assert digest(ROOT/entry['path']) == entry['current_sha256'], 'Source changed after audit'
        rows={}
        for line in (C4/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('#'):continue
            h, rel=line.split('  ',1)
            assert rel not in rows
            rows[rel]=h
        paths=retained()
        assert set(rows)=={p.relative_to(C4).as_posix() for p in paths}, 'Manifest coverage mismatch'
        for p in paths:
            rel=p.relative_to(C4).as_posix()
            assert digest(p)==rows[rel], 'Hash mismatch: '+rel
        print(json.dumps({'seal_verified':True,'files':len(rows),'total_bytes':sum(p.stat().st_size for p in paths),
                          'sha256sums_sha256':digest(C4/'SHA256SUMS.txt'),'source_files_unchanged':len(audit['patch_replay'])},indent=2))
        return
    m=load('make_results'); mk=load('mkpatch')
    for fn in ['make_results.py','mkpatch.py','make_sha256.py','finalize_verify.py']:
        compile((C4/'tools'/fn).read_text(encoding='utf-8'), fn, 'exec')
    ids=[l.split()[0] for l in (ROOT/'sim/tests.manifest').read_text(encoding='utf-8').splitlines() if l.strip() and not l.lstrip().startswith('#')]
    assert len(ids)==len(set(ids))==53 and {'T14','T15','T16'}<=set(ids)
    gates={}
    for stem,wall in [('regress_clean53',542.0),('regress_timing_attempt',477.2)]:
        rows=list(csv.DictReader(io.StringIO(m.rd(str(C4/'raw'/(stem+'.csv'))))))
        text=m.rd(str(C4/'raw'/(stem+'.log')))
        assert len(rows)==53 and all(r['result']=='PASS' for r in rows)
        assert sorted(ids)==sorted(r['test_id'] for r in rows)
        assert 'REGRESS SUMMARY: 53/53 pass' in text
        runrows=re.findall(r'^\[\d+/53\]\s+(\S+)\s+\S+\s+->\s+(PASS|FAIL)',text,re.M)
        assert len(runrows)==53 and all(v=='PASS' for _,v in runrows) and sorted(x for x,_ in runrows)==sorted(ids)
        gates[stem]={'pass':53,'total':53,'wall_s':wall,'log_sha256':digest(C4/'raw'/(stem+'.log')),'csv_sha256':digest(C4/'raw'/(stem+'.csv'))}
    lint=m.rd(str(C4/'raw/lint.log'))
    assert 'LINT GATE: PASS (all gates 0 %Error)' in lint and not re.search(r'^\s*%Error',lint,re.M)
    strict=m.rd(str(C4/'raw/run_all_strict.log'))
    assert '5/5' in strict and '自查通过' in strict
    gates['lint']={'error_diagnostics':0,'gate_pass':True,'sha256':digest(C4/'raw/lint.log'),'scope':'historical, before retained RTC candidate'}
    gates['strict']={'pass':5,'total':5,'sha256':digest(C4/'raw/run_all_strict.log'),'scope':'historical document/model check, not RTL signoff'}
    results=json.loads((C4/'RESULTS.json').read_text(encoding='utf-8'))
    sta=results['goal_b']['sta_measurement_this_round']
    expected={'attempted':True,'map_rc':0,'map_wall_s':615.3,'sta_rc':0,'sta_wall_s':138.8,'sdc_guard_8ns_seen':True,
              'worst_setup_slack_ns':-15.723,'end_point_tns_ns':-665200.142,'fmax_mhz':42.15,'measurement_complete':True,'valid_for_current_rtl':True}
    assert all(sta[k]==v for k,v in expected.items()),sta
    baseline=results['goal_b']['baseline_measurement']
    assert baseline['map_rc']==baseline['sta_rc']==0 and baseline['sdc_guard_8ns_seen']
    assert (baseline['worst_setup_slack_ns'],baseline['end_point_tns_ns'],baseline['fmax_mhz'])==(-18.569,-661896.147,37.64)
    pairs={}
    for name in ['post_map_sdc.rpt','post_map_fmax.rpt','post_map_setup_summary.rpt']:
        a=C4/'raw/sta'/name; b=C4/'raw/sta'/('BASE_'+name)
        assert a.stat().st_mtime > (ROOT/'rtl/mgmt/rtc_sync.v').stat().st_mtime
        pairs[name]={'base_sha256':digest(b),'candidate_sha256':digest(a),'byte_identical':a.read_bytes()==b.read_bytes()}
    assert pairs['post_map_sdc.rpt']['byte_identical']
    assert not pairs['post_map_fmax.rpt']['byte_identical']
    stalog=m.rd(str(C4/'raw/sta_cand.log'))
    assert 'SDC_GUARD_OK: clk=8.000 ns' in stalog and 'WORST_SETUP_SLACK_NS=-15.723' in stalog
    assert 'POST_MAP_STA_DONE' in stalog and 'STA rc=0 wall_s=138.8' in stalog
    cand=m.rd(str(C4/'raw/map_cand.log'))
    assert 'Analysis & Synthesis was successful' in cand and 'MAP rc=0 wall_s=615.3' in cand
    rtl=[]
    initial={'rtl/top/stats_regs.v':'ca9ef2bdca68d5484964e822e9c33d91b0398ca62ac5594b6b5336a2a0467d59',
             'rtl/mgmt/snmp_lite.v':'4e25e970dbeb9620e6b0e2d40235925cfae8c89f0a8866531cced5b0b3ec3e14',
             'rtl/mgmt/a615a_tftp.v':'74d2117afb22676312c44cdbc1d3cf065de3dd0f8c72d68e34c5534ab7aa50f4',
             'rtl/mgmt/rtc_sync.v':'998bc5b20ff121f58def1d446b86c32a5f28177669254e009fd4c91a5be5d725'}
    for rel, h in initial.items():
        p=ROOT/rel;t=p.read_text(encoding='utf-8')
        assert digest(p)==h, 'RTL changed during finalize'
        assert len(t.splitlines())>100 and re.search(r'always\s*@',t) and '<=' in t
        rtl.append({'path':rel,'lines':len(t.splitlines()),'bytes':p.stat().st_size,'sha256':h,'non_stub':True})
    patch=replay(mk); assert len(patch)==15
    head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    audit={'date':'2026-09-26','status':'FINALIZED_TIMING_NOT_CLOSED','gate_logs_reexecuted':False,
           'rtl':rtl,'manifest_cases':len(ids),'gates':gates,'baseline_sta':baseline,'candidate_sta':sta,'sta_report_pairs':pairs,
           'candidate_post_map_measurement_verified':True,'timing_closed':False,'git_head_for_baseline_lookup':head,'patch_replay':patch,
           'patch_sha256':digest(C4/'fixes.patch'),'results_sha256':digest(C4/'RESULTS.json'),
           'checks_passed':True,'limitations':['Candidate post-map measured; WNS/Fmax improved but TNS worsened; 8 ns timing NOT closed.',
           'Missing pre-round mgmt_sap_rx baseline; patch includes full image only.',
           'Historical clean53/lint/strict predate candidate; no new RTL/synthesis run during finalize.']}
    (C4/'raw/finalize_audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    report='# Continue4 FINALIZE 报告\n\n**一句话结论：收尾打包完成；四个管理面 RTL 非空壳、历史回归 53/53、lint 0 %Error、strict 5/5 均有实证，BASE 与当前候选 post-map 已分离核对，但 8 ns 时序仍未收敛。**\n\n日期：2026-09-26。本次仅复核及生成交付物，未修改 RTL 功能，未启动新的回归/lint/strict/综合/STA。\n\n## 证据清单\n\n| 项目 | 复核结果 | 证据 |\n|---|---|---|\n| 四个管理面 RTL | stats_regs 308 行、snmp_lite 565 行、a615a_tftp 360 行、rtc_sync 149 行；实际事件计数、协议状态机和对时逻辑，非空壳；前后 SHA-256 不变 | 当前 RTL、raw/finalize_audit.json |\n| manifest | 53 个唯一 test-id，T14/T15/T16 已纳入；与两份回归 CSV 完全一致 | sim/tests.manifest |\n| 历史独占回归 | 日志 53 个 PASS 行、CSV 53/53，wall 542 s | raw/regress_clean53.log/.csv |\n| 既有 RTC 候选回归 | 日志及 CSV 53/53，wall 477.2 s | raw/regress_timing_attempt.log/.csv |\n| 历史 lint | 最终 gate PASS，无 %Error 诊断，不表示无 warnings | raw/lint.log |\n| 历史 strict | 5/5，仅文档/理论模型一致性，不代替 RTL/STA | raw/run_all_strict.log |\n| SDC | BASE 与候选均 create_clock clk 8.000 ns，STA 日志均有守卫 OK | raw/sta/*post_map_sdc.rpt、raw/sta_base.log、raw/sta_cand.log |\n| 补丁 | 15 个实现/测试/构建输入，按声明混合基线在内存逐段回放，与当前源码逐行相符 | fixes.patch、tools/mkpatch.py、raw/finalize_audit.json |\n| 完整性 | 排序逐文件 SHA-256，包含所有保留文件（含 Quartus db/output_files、缓存及本报告）；只排除清单自身 | SHA256SUMS.txt、tools/make_sha256.py |\n\n## 真实 STA 数字\n\n| 指标 | BASE：RTC 候选前 | 当前保留 RTC 候选 | 候选 − BASE |\n|---|---:|---:|---:|\n| Worst setup slack | -18.569 ns | **-15.723 ns** | +2.846 ns |\n| End Point TNS | -661896.147 ns | **-665200.142 ns** | -3303.995 ns（更差） |\n| Fmax / Restricted Fmax | 37.64 MHz | **42.15 MHz** | +4.51 MHz |\n| map rc / wall | 0 / 592 s | 0 / 615.3 s | — |\n| STA rc / wall | 0 / 116.3 s | 0 / 138.8 s | — |\n\nBASE 证据：`raw/map_base.log`、`raw/sta_base.log`、`raw/sta/BASE_post_map_*.rpt`。\n候选证据：`raw/map_cand.log`、`raw/sta_cand.log`、`raw/sta/post_map_*.rpt`。\n`RESULTS.json` 的 `goal_b.sta_measurement_this_round` 引用候选，`baseline_measurement` 保存 BASE。\n两者均通过返回码、完成标记、SDC 守卫及报告/日志 WNS 一致性核验。\n**这是 post-map 测量，不是布线后签核；WNS/Fmax 改善不抵消 TNS 恶化，8 ns 目标仍未达成。**\n\n## 修复的问题及边界\n\n1. 初读时候选日志未完整，现存无前缀 STA 报告还与 BASE 相同。封包前的独立断言检测到报告更新并阻止封包；随后既有候选 map/STA 输出完成，两次 rc=0，重新读取后采用上表数据。本次没有启动这些运行，不能把首次观察写成最终状态。\n2. 当前 `rtc_sync.v` 已保留 `err_q/disc_pend/disc_q_pps` 两拍候选，改前版本在 `backup/timing_attempt_before/rtc_sync.v`。旧报告“根本没做”已纠正：`goal_b.attempted=true`、`structural_attempt_measured=true`，但 `done=false` 表示时序目标尚未达成。本次未改 RTL。\n3. 旧补丁 RTC 段落过期，并漏了 `elinx/prj/AFDX_top_synth.ys`。现重建为 15 个输入并验证回放。`tools_lint.ps1` 用 HEAD；**mgmt_sap_rx.v 无现场备份且不在 HEAD 中**，只能交付完整文件镜像，不能声称恢复其改前 50 行基线。具体 HEAD commit、基线摘要与源码哈希见审计 JSON。\n4. 历史 clean53/lint/strict 都早于 RTC 候选；候选另有 53/53 回归和已完成 post-map，但本次未补跑候选后 lint，不宣称所有门禁均在最新 RTL 上重跑。\n5. 既有协议覆盖边界不变：管理面响应未进入线上 TX、统计/协议/对时仍有已登记限制；非空壳和用例通过不等于整机符合性通过。\n6. 返回码位于 UTF-16 日志末尾追加的 ASCII 段；已修复 `tools/make_results.py`，避免整文件单编码读取丢失 rc/wall。WNS/TNS 直接取自 .rpt，并与对应日志核对。\n7. 原 9 项 SHA 清单过期，现使用同样的排序逐文件 SHA-256 方法，扩展为所有保留文件，无生成目录遗漏。\n\n## 交付物与复核方法\n\n已更新 `RESULTS.json`、`REPORT.md`、`COMMANDS.md`、`fixes.patch`、三个生成脚本，新增 `tools/finalize_verify.py`、`raw/finalize_audit.json` 及本报告。\n实现补丁不混入收尾文档；这些收尾文件均由完整哈希清单覆盖。\n\n```powershell\nSet-Location C:\\Workspace\\diansai\npython -B out/arena-debug/continue4/tools/finalize_verify.py\npython -B out/arena-debug/continue4/tools/make_sha256.py\npython -B out/arena-debug/continue4/tools/finalize_verify.py --verify-seal\n```\n\n第二条是最后写文件步骤。第三条只读，逐文件校验摘要、清单覆盖及源码未变。\n补丁核验为混合基线内存回放，非当前工作区直接应用，也非单一 HEAD 的差分。\n\n纪律：未访问 competition_case/、data/、logs/ 或敏感配置/凭据；未执行 git commit/push/reset；本次未改写原始门禁或 STA 输出。后续应补候选后 lint，并继续优化/布线后验证，不能以 post-map 数字代替时序签核。\n'
    (C4/'FINALIZE-REPORT.md').write_text(report,encoding='utf-8')
    print(json.dumps({'audit_passed':True,'patch_files':len(patch),'rtl_unchanged':len(rtl),'candidate_post_map_measurement_verified':True,'timing_closed':False,
                      'outputs':['raw/finalize_audit.json','FINALIZE-REPORT.md']},indent=2))

if __name__ == '__main__':
    main()
