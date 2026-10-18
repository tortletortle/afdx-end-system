#!/usr/bin/env python3
"""Normalize eLinx's N3 diagnostic IL/VQM identifiers without changing logic."""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
POSTMAP = ROOT / "out/netlist_n3_native_postmap_20261015_r1"
N3 = ROOT / "out/netlist_n3_fresh_process_mapping_20261014_r1"
CANDIDATE_DIR = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1"
CANDIDATE = CANDIDATE_DIR / "candidate.json"
TOOL_SHA256 = "b022eb9361b9847d0042b234fb6ee1b584836be4c0174e94addb6d2f1d236a23"


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, value: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def ys_path(path: Path) -> str:
    value = path.resolve().as_posix()
    if any(char in value for char in ('"', "\r", "\n")):
        raise ValueError(f"Unsafe path for eLinx: {path}")
    return f'"{value}"'


def inventory_il(path: Path) -> tuple[list[str], Counter, int, int]:
    modules: list[str] = []
    refs: Counter = Counter()
    cell_count = 0
    bare_names = 0
    module_re = re.compile(rb"^module (\S+)\s*$")
    cell_re = re.compile(rb"^\s*cell\s+(\S+)\s+(\S+)\s*$")
    for line in path.open("rb"):
        module = module_re.match(line)
        if module:
            modules.append(module[1].decode("ascii"))
        cell = cell_re.match(line)
        if cell:
            cell_count += 1
            refs[cell[1].decode("ascii").lstrip("\\")] += 1
            if not cell[2].startswith((b"\\", b"$")):
                bare_names += 1
    return modules, refs, cell_count, bare_names


def escaped_cell_ids(source: Path, output: Path) -> dict:
    cell_re = re.compile(rb"^(\s*cell\s+)(\S+)(\s+)(\S+)(\s*)$")
    module_re = re.compile(rb"^module (\S+)\s*$")
    edits = 0
    seen: set[tuple[str, bytes]] = set()
    module = ""
    with source.open("rb") as src, output.open("xb") as dst:
        for line_no, line in enumerate(src, 1):
            match_module = module_re.match(line)
            if match_module:
                module = match_module[1].decode("ascii")
                seen.clear()
            match = cell_re.match(line)
            if match:
                name = match[4]
                normalized = name if name.startswith((b"\\", b"$")) else b"\\" + name
                key = (module, normalized)
                if key in seen:
                    raise ValueError(f"Cell-ID collision after escaping at IL line {line_no}: {module} {normalized!r}")
                seen.add(key)
                if name != normalized:
                    edits += 1
                    line = match[1] + match[2] + match[3] + normalized + match[5]
            dst.write(line)
    if edits == 0:
        raise ValueError("No invalid unescaped IL cell IDs found; refusing an empty normalization")
    return {"source_sha256": sha(source), "escaped_il_sha256": sha(output),
            "source_bytes": source.stat().st_size, "escaped_il_bytes": output.stat().st_size,
            "cell_id_escape_count": edits, "cell_id_collisions": 0,
            "only_bare_cell_instance_tokens_prefixed": True}


def canonicalize_vqm(source: Path, output: Path, mapping: dict[str, str],
                     il_refs: Counter) -> dict:
    token_re = re.compile(rb"^(\s*)(module\s+)?(\\[^\s(]+)(?=[\s(])")
    definitions: Counter = Counter()
    instances: Counter = Counter()
    replacements = 0
    with source.open("rb") as src, output.open("xb") as dst:
        for line_no, line in enumerate(src, 1):
            match = token_re.match(line)
            if match:
                old = match[3][1:].decode("ascii")
                if old in mapping:
                    new = mapping[old].encode("ascii")
                    target = definitions if match[2] else instances
                    target[old] += 1
                    line = line[:match.start(3)] + new + line[match.end(3):]
                    replacements += 1
            dst.write(line)
    if set(definitions) != set(mapping) or any(count != 1 for count in definitions.values()):
        raise ValueError("VQM module declarations do not cover each renamed N3 parameterized module exactly once")
    for old in mapping:
        if instances[old] != il_refs[old]:
            raise ValueError(f"VQM/IL instance count differs for {old}: VQM={instances[old]} IL={il_refs[old]}")
    if replacements <= len(mapping):
        raise ValueError("VQM normalization found no parameterized submodule instances")
    return {"source_sha256": sha(source), "normalized_vqm_sha256": sha(output),
            "source_bytes": source.stat().st_size, "normalized_vqm_bytes": output.stat().st_size,
            "renamed_module_definitions": dict(definitions),
            "renamed_module_instances": dict(instances), "renamed_tokens": replacements,
            "non_module_type_and_instance_tokens_unchanged": True}


def run_stage(state: dict, out: Path, name: str, script: Path,
              tool: Path, timeout: int) -> dict:
    stage_dir = out / name
    stage_dir.mkdir()
    log, stdout, stderr = stage_dir / "synthesis.log", stage_dir / "stdout.log", stage_dir / "stderr.log"
    record = {"status": "RUNNING", "script": str(script), "script_sha256": sha(script),
              "tool_sha256": sha(tool), "timeout_seconds": timeout,
              "started_local": datetime.now().astimezone().isoformat()}
    state["stages"][name] = record
    write_json(out / "normalization_status.json", state)
    argv = [str(tool), "-Q", "-T", "-s", str(script), "-l", str(log)]
    record["argv"] = argv
    flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) if os.name == "nt" else 0
    start = time.monotonic()
    with stdout.open("xb") as out_stream, stderr.open("xb") as err_stream:
        proc = subprocess.Popen(argv, cwd=stage_dir, stdout=out_stream, stderr=err_stream,
                                creationflags=flags)
        record["owned_pid"] = proc.pid
        write_json(out / "normalization_status.json", state)
        try:
            record["exit_code"] = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            record["timed_out"] = True
            if os.name == "nt":
                killed = subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                                        capture_output=True, timeout=15, check=False)
                record["timeout_cleanup"] = {"exit_code": killed.returncode,
                    "output": killed.stdout.decode("utf-8", errors="replace") +
                              killed.stderr.decode("utf-8", errors="replace")}
            else:
                proc.kill()
            proc.wait(timeout=15)
            record["exit_code"] = proc.returncode
    record["wall_seconds"] = round(time.monotonic() - start, 3)
    record["ended_local"] = datetime.now().astimezone().isoformat()
    content = "\n".join(p.read_text(encoding="utf-8", errors="replace")
                       for p in (stdout, stderr, log) if p.is_file())
    warning_count = len(re.findall(r"(?i)\bwarning\b", content))
    error_count = len(re.findall(r"(?i)\berror\b", content))
    record.update({"log_sha256": sha(log) if log.exists() else None,
                   "stdout_sha256": sha(stdout), "stderr_sha256": sha(stderr),
                   "warning_count": warning_count, "error_count": error_count,
                   "success_marker": "Yosys execute success!" in content})
    record["status"] = ("PASS" if record["exit_code"] == 0 and not record.get("timed_out")
                        and warning_count == 0 and error_count == 0 and record["success_marker"] else "FAIL")
    write_json(out / "normalization_status.json", state)
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True,
                        help="new output directory under the repository out directory")
    args = parser.parse_args()
    out = (args.out if args.out.is_absolute() else ROOT / args.out).resolve()
    out_root = (ROOT / "out").resolve()
    if out == out_root or not out.is_relative_to(out_root) or out.exists():
        raise SystemExit("--out must be a new, non-existing child of the repository out directory")

    status = read_json(POSTMAP / "postmap_status.json")
    n3 = read_json(N3 / "run_status.json")
    candidate = read_json(CANDIDATE)
    if status.get("status") != "FAILED_STOP" or status.get("stages", {}).get("native_postmap", {}).get("status") != "PASS":
        raise SystemExit("Expected preserved N3 export with native postmap PASS and raw reload failure")
    for filename, key in (("AFDX_top_native.vqm", "AFDX_top_native.vqm"),
                          ("AFDX_top_mapped.il", "AFDX_top_mapped.il")):
        expected = status.get("artifacts", {}).get(filename, {}).get("sha256")
        if not expected or sha(POSTMAP / filename) != expected:
            raise SystemExit(f"Frozen N3 postmap artifact changed: {filename}")
    if sha(CANDIDATE) != n3.get("candidate_sha256") or sha(POSTMAP / "AFDX_top_mapped.il") != status.get("artifacts", {}).get("AFDX_top_mapped.il", {}).get("sha256"):
        raise SystemExit("N3/candidate source provenance mismatch")
    tool = Path(candidate["synthesis_executable"])
    if sha(tool) != TOOL_SHA256:
        raise SystemExit("eLinx executable hash mismatch")

    out.mkdir(parents=True)
    source_il = POSTMAP / "AFDX_top_mapped.il"
    source_vqm = POSTMAP / "AFDX_top_native.vqm"
    escaped_il = out / "cell_ids_escaped.il"
    cell_report = escaped_cell_ids(source_il, escaped_il)
    module_names, il_refs, cell_count, bare_count = inventory_il(escaped_il)
    if bare_count or len(module_names) != 61 or cell_count != 309528:
        raise SystemExit(f"Escaped IL inventory unexpected: modules={len(module_names)} cells={cell_count} bare_ids={bare_count}")
    mapping = {name: "n3_m_" + hashlib.sha1(name.encode("ascii")).hexdigest()[:20]
               for name in module_names if name.startswith("$paramod")}
    if len(mapping) != 40 or len(set(mapping.values())) != len(mapping):
        raise SystemExit(f"N3 parameterized module rename inventory mismatch: {len(mapping)}")
    normalized_vqm = out / "canonical_native.vqm"
    vqm_report = canonicalize_vqm(source_vqm, normalized_vqm, mapping, il_refs)
    canonical_il = out / "canonical_native.il"
    canonical_script = out / "canonicalize.ys"
    commands = [f"read_ilang {ys_path(escaped_il)}", "select *", "check -assert -noinit"]
    for old, new in mapping.items():
        commands.extend((f"rename {old} {new}", "select *", f"chtype -set {new} t:{old}"))
    commands.extend(("select *", "check -assert -noinit", f"write_ilang {ys_path(canonical_il)}"))
    canonical_script.write_text("\n".join(commands) + "\n", encoding="ascii")
    reload_script = out / "fresh_reload.ys"
    reload_script.write_text(f"read_ilang {ys_path(canonical_il)}\nselect *\ncheck -assert -noinit\n",
                             encoding="ascii")
    report = {
        "schema": "netlist-n3-identifier-normalization-v1", "status": "RUNNING",
        "started_local": datetime.now().astimezone().isoformat(),
        "scope": "Derived syntax-normalized exports only: prefixes 4997 unescaped IL cell IDs, maps 40 parameterized module/type identifiers to collision-checked plain names in IL/VQM. Raw N3 exports remain unchanged. This does not prove functional equivalence or business behavior.",
        "candidate_sha256": sha(CANDIDATE), "n3_whole_il_sha256": n3["whole_il_sha256"],
        "source_il_sha256": sha(source_il), "source_vqm_sha256": sha(source_vqm),
        "tool_path": str(tool), "tool_sha256": sha(tool),
        "runner_sha256": sha(Path(__file__)), "runner_snapshot_sha256": None,
        "cell_id_normalization": cell_report, "module_rename_map": mapping,
        "source_il_inventory": {"module_count": len(module_names), "cell_count": cell_count,
                                 "cell_type_counts": dict(il_refs)},
        "vqm_normalization": vqm_report,
        "canonicalize_script_sha256": sha(canonical_script), "fresh_reload_script_sha256": sha(reload_script),
        "stages": {}, "artifacts": {},
    }
    snapshot = out / "runner_snapshot.py"
    snapshot.write_bytes(Path(__file__).read_bytes())
    report["runner_snapshot_sha256"] = sha(snapshot)
    write_json(out / "normalization_status.json", report)
    try:
        first = run_stage(report, out, "canonical_il", canonical_script, tool, 300)
        if first["status"] != "PASS":
            raise RuntimeError("Native identifier canonicalization failed")
        if not canonical_il.is_file() or canonical_il.stat().st_size == 0:
            raise RuntimeError("Canonical IL output missing")
        report["artifacts"]["canonical_native.il"] = {"bytes": canonical_il.stat().st_size,
                                                        "sha256": sha(canonical_il)}
        second = run_stage(report, out, "fresh_il_reload", reload_script, tool, 180)
        if second["status"] != "PASS":
            raise RuntimeError("Fresh-process canonical IL reload CHECK failed")
        report.update({"status": "PASS_N3_CANONICAL_IL_RELOADED_VQM_PENDING_COMPILE",
                       "artifacts": {
                           "canonical_native.il": {"bytes": canonical_il.stat().st_size, "sha256": sha(canonical_il)},
                           "canonical_native.vqm": {"bytes": normalized_vqm.stat().st_size, "sha256": sha(normalized_vqm)},
                           "cell_ids_escaped.il": {"bytes": escaped_il.stat().st_size, "sha256": sha(escaped_il)}}})
    except Exception as exc:
        report.update({"status": "FAILED_STOP", "error": str(exc)})
    finally:
        report["ended_local"] = datetime.now().astimezone().isoformat()
        write_json(out / "normalization_status.json", report)
    print(json.dumps({"status": report["status"], "path": str(out),
                      "stages": {k: v.get("status") for k, v in report["stages"].items()},
                      "artifacts": report.get("artifacts")}, ensure_ascii=False))
    return 0 if report["status"] == "PASS_N3_CANONICAL_IL_RELOADED_VQM_PENDING_COMPILE" else 1


if __name__ == "__main__":
    raise SystemExit(main())
