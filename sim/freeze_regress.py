#!/usr/bin/env python3
"""Freeze one isolated run's source and evidence hashes.

The CSV, run metadata, copied source tree, compile log and test consoles must
come from the same run directory. A stitched set of local CSVs is rejected.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
from typing import Any


# Questa opens the copied simulator transcript for writing during the run.
# Its pre-run content is still recorded in run_metadata.json, while the final
# workspace copy is a run artifact rather than an immutable source input.
MUTABLE_RUNTIME_OUTPUTS = {"sim/transcript"}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inside(root: Path, candidate: Path) -> Path:
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as exc:
        raise RuntimeError(f"path escapes run workspace: {candidate}") from exc
    return resolved


def read_manifest(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2:
            raise RuntimeError(f"malformed manifest row: {raw!r}")
        test_id, tb = fields[:2]
        config = fields[2] if len(fields) > 2 else "default"
        if test_id in seen:
            raise RuntimeError(f"duplicate manifest test id: {test_id}")
        seen.add(test_id)
        rows.append({"id": test_id, "tb": tb, "config": config})
    return rows


def freeze(csv_path: Path, out_path: Path, require_full: bool) -> None:
    csv_path = csv_path.resolve()
    run_dir = csv_path.parent
    metadata_path = run_dir / "run_metadata.json"
    workspace = run_dir / "workspace"
    compile_log = run_dir / "compile_console.txt"
    for path in (metadata_path, workspace, compile_log):
        if not path.exists():
            raise RuntimeError(f"missing run artifact: {path}")

    metadata: dict[str, Any] = json.loads(metadata_path.read_text(encoding="utf-8-sig"))
    if metadata.get("compile_result") != "PASS":
        raise RuntimeError("run metadata does not record a successful compile")
    if metadata.get("regression_result") != "PASS":
        raise RuntimeError("run metadata does not record an all-PASS regression")

    with csv_path.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise RuntimeError("regression CSV has no result rows")
    actual = [
        {"id": row.get("test_id", ""), "tb": row.get("tb", ""), "config": row.get("config", "")}
        for row in rows
    ]
    recorded = metadata.get("tests", [])
    normalized_recorded = [
        {"id": row.get("id", ""), "tb": row.get("tb", ""), "config": row.get("config", "")}
        for row in recorded
    ]
    if actual != normalized_recorded:
        raise RuntimeError("CSV rows do not exactly match this run's ordered test metadata")
    ids = [row["id"] for row in actual]
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", test_id) for test_id in ids):
        raise RuntimeError("regression CSV contains an unsafe test id")
    if len(ids) != len(set(ids)):
        raise RuntimeError("regression CSV contains duplicate test ids")
    if any(row.get("result") != "PASS" for row in rows):
        raise RuntimeError("regression CSV is not all PASS")
    if metadata.get("pass_count") != len(rows) or metadata.get("test_count") != len(rows):
        raise RuntimeError("run metadata counts do not match the CSV")

    snapshot_manifest = workspace / "sim" / "tests.manifest"
    full_manifest = read_manifest(snapshot_manifest)
    is_full = actual == full_manifest
    if require_full and not is_full:
        raise RuntimeError("run is a subset; --require-full needs exact ordered manifest coverage")

    input_hashes = metadata.get("source_sha256")
    if not isinstance(input_hashes, dict) or not input_hashes:
        raise RuntimeError("run metadata has no source hash map")
    verified_inputs: dict[str, str] = {}
    mutable_runtime_outputs: dict[str, dict[str, str]] = {}
    for relative, expected in sorted(input_hashes.items()):
        source = inside(workspace, workspace / relative)
        if not source.is_file():
            raise RuntimeError(f"missing hashed source input: {relative}")
        actual_hash = sha(source)
        if actual_hash.lower() != str(expected).lower():
            normalized = relative.replace("\\", "/")
            if normalized in MUTABLE_RUNTIME_OUTPUTS:
                original_workspace = Path(str(metadata.get("original_workspace", ""))).resolve()
                original_source = inside(original_workspace, original_workspace / relative)
                if not original_source.is_file() or sha(original_source).lower() != str(expected).lower():
                    raise RuntimeError(
                        f"mutable runtime output changed and original input no longer matches: {relative}"
                    )
                mutable_runtime_outputs[normalized] = {
                    "run_start_sha256": str(expected).lower(),
                    "post_run_workspace_sha256": actual_hash,
                    "original_workspace_sha256": sha(original_source),
                }
                continue
            raise RuntimeError(f"source hash changed after the run: {relative}")
        verified_inputs[relative.replace("\\", "/")] = actual_hash

    evidence_paths = [csv_path, metadata_path, compile_log]
    evidence_paths.extend(run_dir / f"{test_id}_console.txt" for test_id in ids)
    metrics = run_dir / "metrics"
    if metrics.is_dir():
        evidence_paths.extend(path for path in metrics.rglob("*") if path.is_file())
    coverage = run_dir / "coverage"
    if coverage.is_dir():
        evidence_paths.extend(path for path in coverage.rglob("*") if path.is_file())
    missing = [str(path) for path in evidence_paths if not path.is_file()]
    if missing:
        raise RuntimeError("missing run evidence: " + ", ".join(missing))
    evidence_hashes = {
        path.relative_to(run_dir).as_posix(): sha(path)
        for path in sorted(set(evidence_paths), key=lambda p: p.as_posix())
    }

    data = {
        "scope": "complete manifest" if is_full else "selected test subset",
        "run_id": metadata.get("run_id"),
        "original_git_head": metadata.get("original_git_head"),
        "vsim_path": metadata.get("vsim_path"),
        "vsim_file_version": metadata.get("vsim_file_version"),
        "vsim_executable_sha256": metadata.get("vsim_executable_sha256"),
        "test_count": len(rows),
        "passing": sum(1 for row in rows if row.get("result") == "PASS"),
        "ordered_test_ids": ids,
        "source_sha256": verified_inputs,
        "mutable_runtime_outputs": mutable_runtime_outputs,
        "evidence_sha256": evidence_hashes,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"REGRESS EVIDENCE: {len(rows)}/{len(rows)} PASS; "
        f"{len(verified_inputs)} input hashes; {len(evidence_hashes)} evidence hashes; "
        f"scope={data['scope']} -> {out_path}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", type=Path, required=True, help="CSV from one isolated run directory")
    parser.add_argument("--out", type=Path, help="evidence JSON (defaults beside the CSV)")
    parser.add_argument("--require-full", action="store_true", help="require exact ordered coverage of the copied manifest")
    args = parser.parse_args()
    csv_path = args.csv.resolve()
    out_path = (args.out or (csv_path.parent / "regress_evidence.json")).resolve()
    if out_path.exists():
        raise RuntimeError(f"refusing to overwrite existing evidence file: {out_path}")
    freeze(csv_path, out_path, args.require_full)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
