#!/usr/bin/env python3
"""Bind a canonical N3 VQM to the frozen default simulation case inputs."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1"
NORMALIZED = ROOT / "out/netlist_n3_export_normalized_20261015_r1"
POSTMAP = ROOT / "out/netlist_n3_native_postmap_20261015_r1"
N3 = ROOT / "out/netlist_n3_fresh_process_mapping_20261014_r1"
TOOL_SHA256 = "b022eb9361b9847d0042b234fb6ee1b584836be4c0174e94addb6d2f1d236a23"


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True,
                        help="new output candidate under the repository out directory")
    args = parser.parse_args()
    out = (args.out if args.out.is_absolute() else ROOT / args.out).resolve()
    out_root = (ROOT / "out").resolve()
    if out == out_root or not out.is_relative_to(out_root) or out.exists():
        raise SystemExit("--out must be a new, non-existing child of the repository out directory")

    base_path = BASE / "candidate.json"
    base = read(base_path)
    n3_status = read(N3 / "run_status.json")
    postmap = read(POSTMAP / "postmap_status.json")
    normalized = read(NORMALIZED / "normalization_status.json")
    if base.get("schema") != "native-phy-candidate-v1" or base.get("configuration") != "Default":
        raise SystemExit("Frozen simulation source is not the required Default candidate")
    if normalized.get("status") != "PASS_N3_CANONICAL_IL_RELOADED_VQM_PENDING_COMPILE":
        raise SystemExit("N3 normalized VQM/IL did not pass the fresh IL reload gate")
    if (normalized.get("candidate_sha256") != n3_status.get("candidate_sha256") or
            normalized.get("n3_whole_il_sha256") != n3_status.get("whole_il_sha256")):
        raise SystemExit("Normalized N3 exports do not bind to the frozen N3 candidate")
    if postmap.get("stages", {}).get("native_postmap", {}).get("status") != "PASS":
        raise SystemExit("N3 native postmap/export stage did not pass")
    vqm = NORMALIZED / "canonical_native.vqm"
    mapped_il = NORMALIZED / "canonical_native.il"
    if sha(vqm) != normalized["artifacts"]["canonical_native.vqm"]["sha256"]:
        raise SystemExit("Normalized VQM hash drift")
    if sha(mapped_il) != normalized["artifacts"]["canonical_native.il"]["sha256"]:
        raise SystemExit("Normalized IL hash drift")
    tool = Path(base["synthesis_executable"])
    if sha(tool) != TOOL_SHA256:
        raise SystemExit("Pinned eLinx tool hash mismatch")
    sim_runner = BASE / "run_native_gmii_sim.ps1"
    if sha(sim_runner) != base.get("input_sha256", {}).get("run_native_gmii_sim.ps1"):
        raise SystemExit("Frozen mapped simulator runner hash mismatch")

    out.mkdir(parents=True)
    shutil.copy2(base_path, out / "candidate.json")
    copied = {}
    for relative, expected in base["input_sha256"].items():
        src, dst = BASE / relative, out / relative
        if not src.is_file() or sha(src) != expected:
            raise SystemExit(f"Frozen simulation input missing or changed: {relative}")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        actual = sha(dst)
        if actual != expected:
            raise SystemExit(f"Copied simulation input hash mismatch: {relative}")
        copied[relative] = actual
    shutil.copy2(vqm, out / "AFDX_top_native.vqm")
    shutil.copy2(mapped_il, out / "AFDX_top_mapped.il")
    vqm_sha, il_sha = sha(out / "AFDX_top_native.vqm"), sha(out / "AFDX_top_mapped.il")
    candidate_sha = sha(out / "candidate.json")
    if candidate_sha != sha(base_path):
        raise SystemExit("Derived candidate manifest was not copied byte-identically")
    synthesis_status = {
        "schema": "netlist-n3-derived-synthesis-export-v1",
        "status": "EXPORTED_PENDING_MAPPED_SIMULATION",
        "created_local": datetime.now().astimezone().isoformat(),
        "candidate_sha256": candidate_sha,
        "vqm_sha256": vqm_sha,
        "mapped_il_sha256": il_sha,
        "source_candidate_sha256": n3_status["candidate_sha256"],
        "n3_whole_il_sha256": n3_status["whole_il_sha256"],
        "n3_status_sha256": sha(N3 / "run_status.json"),
        "n3_integrity_audit_sha256": sha(N3 / "integrity_audit.json"),
        "n3_postmap_status_sha256": sha(POSTMAP / "postmap_status.json"),
        "identifier_normalization_status_sha256": sha(NORMALIZED / "normalization_status.json"),
        "identifier_normalization_scope": normalized["scope"],
        "tool_sha256": TOOL_SHA256,
        "scope": "N3 diagnostic COUT-closure VQM and canonicalized IL; based on an unchanged Default simulation input manifest. VQM export is verified; simulation has not run. No production-equivalence claim.",
        "input_count": len(copied),
    }
    write(out / "synthesis_status.json", synthesis_status)
    provenance = {
        "schema": "netlist-n3-simulation-candidate-provenance-v1",
        "status": "READY_FOR_T78_COMPILE_AND_SIMULATION",
        "candidate_sha256": candidate_sha,
        "source_candidate_sha256": sha(base_path),
        "copied_input_hashes_match_source_candidate": True,
        "copied_input_count": len(copied),
        "case": "T78",
        "case_contract": base["simulation_cases"]["T78"],
        "synthesis_status_sha256": sha(out / "synthesis_status.json"),
        "vqm_sha256": vqm_sha,
        "mapped_il_sha256": il_sha,
        "runner_sha256": sha(out / "run_native_gmii_sim.ps1"),
        "vqm_source": str(vqm.resolve()), "vqm_source_sha256": sha(vqm),
        "normalized_il_source": str(mapped_il.resolve()), "normalized_il_source_sha256": sha(mapped_il),
        "business_verdict": None,
    }
    write(out / "n3_sim_candidate_provenance.json", provenance)
    print(json.dumps({"status": provenance["status"], "candidate": str(out),
                      "candidate_sha256": candidate_sha, "vqm_sha256": vqm_sha,
                      "case": "T78", "copied_input_count": len(copied)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
