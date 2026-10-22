"""Shared compile-file list for isolated mutant scripts.

Parses the same relative paths run_regress.ps1 feeds to vlog (rtl + chk + env),
so mutant TBs that instantiate afdx_cov_* / env BFMs can elaborate.
"""
from __future__ import annotations

import re
from pathlib import Path

_SIM = Path(__file__).resolve().parent


def regress_compile_files(sim: Path | None = None) -> list[Path]:
    sim = sim or _SIM
    runner = (sim / "run_regress.ps1").read_text(encoding="utf-8")
    names = re.findall(r"'((?:\.\./rtl|chk|env)/[^']+\.(?:v|sv))'", runner)
    if len(names) < 20 or names.count("../rtl/top/AFDX_top.v") != 1:
        raise RuntimeError("runner compile list parse incomplete")
    out: list[Path] = []
    seen: set[Path] = set()
    for name in names:
        if name.endswith("tb_afdx_top.sv"):
            continue
        p = (sim / name).resolve()
        if p in seen:
            continue
        seen.add(p)
        if not p.is_file():
            raise RuntimeError("missing compile file: " + name)
        out.append(p)
    return out
