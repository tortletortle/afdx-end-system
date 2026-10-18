#!/usr/bin/env python3
"""Fail-closed audit of regression top-module closures against bind profiles."""
from __future__ import annotations
import argparse, hashlib, pathlib, re, sys
TARGETS = {"AFDX_top", "rx_block_pool", "rx_ic", "rx_rm", "mac_tx_if"}

class AuditError(RuntimeError): pass

def clean_sv(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return re.sub(r'"(?:\\.|[^"\\])*"', ' ', text)

def sha(data: str) -> str: return hashlib.sha256(data.encode("utf-8")).hexdigest()

def index_modules(root: pathlib.Path) -> dict[str, tuple[str, str]]:
    files = sorted(list(root.rglob("*.v")) + list(root.rglob("*.sv")))
    result: dict[str, tuple[str, str]] = {}
    for path in files:
        src = clean_sv(path.read_text(encoding="utf-8", errors="strict"))
        for m in re.finditer(r"\bmodule\s+(\w+)\b(.*?)\bendmodule\b", src, re.S):
            name=m.group(1)
            if name in result: raise AuditError(f"duplicate module definition {name}: {path} and {result[name][0]}")
            result[name]=(path.relative_to(root).as_posix(),m.group(2))
    return result

def graph_for(modules: dict[str, tuple[str,str]]) -> dict[str,set[str]]:
    names=set(modules); graph={n:set() for n in names}
    for parent,(_,body) in modules.items():
        for child in names-{parent}:
            # A module type followed by optional parameter override and instance name.
            pat=rf"\b{re.escape(child)}\b\s*(?:#\s*\(.*?\)\s*)?[A-Za-z_]\w*\s*\("
            if re.search(pat,body,re.S): graph[parent].add(child)
            elif child in TARGETS and re.search(rf"\b{re.escape(child)}\b",body):
                # A type token the conservative instance recognizer cannot classify
                # is not silently ignored; the closure mapping must be reviewed.
                raise AuditError(f"unclassified possible module reference {parent} -> {child}")
    return graph

def closure(top: str, graph: dict[str,set[str]], modules: dict[str,tuple[str,str]]) -> tuple[set[str],dict[str,str]]:
    if top not in modules: raise AuditError(f"test top module missing: {top}")
    todo=[top]; seen=set(); path={top:top}
    while todo:
        n=todo.pop(0)
        if n in seen: continue
        seen.add(n)
        for child in sorted(graph[n]):
            if child not in path: path[child]=path[n]+" -> "+child
            todo.append(child)
    return seen,path

def read_tests(path: pathlib.Path) -> list[tuple[str,str,str]]:
    rows=[]
    for ln,line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(),1):
        s=line.strip()
        if not s or s.startswith("#"): continue
        p=s.split()
        if len(p)<2: raise AuditError(f"malformed test manifest line {ln}")
        rows.append((p[0],p[1],p[2] if len(p)>2 else "default"))
    ids=[r[0] for r in rows]
    if len(ids)!=len(set(ids)): raise AuditError("duplicate test IDs")
    return rows

def load_profiles(path: pathlib.Path, binddir: pathlib.Path) -> dict[str,tuple[tuple[str,...],str]]:
    out={}
    for ln,line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(),1):
        s=line.strip()
        if not s or s.startswith("#"):continue
        p=s.split("\t")
        if len(p)!=3: raise AuditError(f"malformed profile line {ln}")
        name,targets,binder=p
        ts=tuple(sorted(x for x in targets.split(",") if x))
        if name in out: raise AuditError(f"duplicate profile {name}")
        if name not in {"none","full","rx_ic","mac_tx_if"}: raise AuditError(f"unknown profile {name}")
        if binder!="-":
            bp=(binddir/binder).resolve()
            if not bp.is_file(): raise AuditError(f"missing binder source {bp}")
            actual=tuple(sorted(re.findall(r"(?m)^\s*bind\s+(\w+)\s+",clean_sv(bp.read_text(encoding="utf-8")))))
            actual=tuple(sorted(set(actual)))
            if actual!=ts: raise AuditError(f"profile {name} bind targets {actual} do not equal declared {ts}")
        elif ts: raise AuditError(f"profile {name} declares targets but no binder")
        out[name]=(ts,binder)
    if "none" not in out: raise AuditError("missing explicit none profile")
    return out

def rows_for(tests,modules,graph,profiles,scope_path=None):
    rows=[]
    for tid,tb,cfg in tests:
        nodes,paths=closure(tb,graph,modules)
        targets=tuple(sorted(nodes & TARGETS))
        matches=[n for n,(ts,_) in profiles.items() if ts==targets]
        if len(matches)!=1: raise AuditError(f"{tid}/{tb}: target closure {targets} maps to {len(matches)} profiles")
        profile=matches[0]
        # Signature binds the mapping to the reachable module graph, not behavior text.
        sig="\n".join(f"{n}:{modules[n][0]}:{','.join(sorted(graph[n]))}" for n in sorted(nodes))
        evidence=";".join(f"{t}={paths[t]}" for t in targets) if targets else "no-bound-target-in-reachable-module-closure"
        rows.append((tid,tb,cfg,modules[tb][0],profile,",".join(targets),sha(sig),evidence))
    return rows

def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--source-root",type=pathlib.Path,required=True)
    ap.add_argument("--sim-dir",type=pathlib.Path,required=True)
    ap.add_argument("--scope",type=pathlib.Path,required=True)
    ap.add_argument("--profiles",type=pathlib.Path,required=True)
    ap.add_argument("--emit",action="store_true")
    a=ap.parse_args(); root=a.source_root.resolve(); sim=a.sim_dir.resolve()
    try:
        modules=index_modules(root/"rtl")
        # Add TB modules; production module definitions remain rooted under rtl.
        tbmods=index_modules(root/"sim"/"tb")
        for n,v in tbmods.items():
            if n in modules: raise AuditError(f"duplicate module across RTL/TB: {n}")
            modules[n]=("sim/"+v[0],v[1])
        graph=graph_for(modules)
        profiles=load_profiles(a.profiles,sim/"chk"/"bind_profiles")
        tests=read_tests(sim/"tests.manifest")
        rows=rows_for(tests,modules,graph,profiles)
        header="test_id\ttb\tconfig\ttb_file\tprofile\ttargets\tclosure_sha256\tevidence"
        actual=[header]+["\t".join(r) for r in rows]
        if a.emit:
            a.scope.write_text("\n".join(actual)+"\n",encoding="utf-8")
        else:
            if not a.scope.is_file(): raise AuditError(f"scope manifest missing: {a.scope}")
            supplied=a.scope.read_text(encoding="utf-8-sig").splitlines()
            if supplied!=actual: raise AuditError("scope manifest is missing, extra, stale, or disagrees with DUT closure; update/review before compile")
        counts={p:sum(r[4]==p for r in rows) for p in profiles}
        print(f"BIND_SCOPE_AUDIT_PASS tests={len(rows)} profiles="+",".join(f"{p}:{counts[p]}" for p in sorted(counts)))
        return 0
    except (AuditError,OSError,UnicodeError) as e:
        print(f"BIND_SCOPE_AUDIT_FAIL {e}",file=sys.stderr); return 1
if __name__=="__main__": raise SystemExit(main())
