from pathlib import Path
import hashlib
P=Path('C:/Workspace/diansai');D=P/'out/arena-debug/continue/session_20260925_0432'
paths=[p for p in D.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name!='SHA256SUMS.txt']
paths += [P/'out/arena-debug/DIANSAI-REPORT.md',P/'out/arena-debug/fixes.patch',P/'out/arena-debug/finalize/CONTINUE-20260925.md',P/'doc/当前进度_20260923.md',P/'doc/后续计划.md']
lines=[hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(P).as_posix() for p in sorted(paths)]
s='\n'.join(lines)+'\n'
(D/'SHA256SUMS.txt').write_text(s,encoding='utf8')
(P/'out/arena-debug/finalize/CONTINUE-20260925-SHA256SUMS.txt').write_text(s,encoding='utf8')
print('SEALED',len(paths),'files')
