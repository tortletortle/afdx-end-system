#!/usr/bin/env python3
"""Freeze inputs and check syntax/hierarchy/process lowering. Never simulate or map.

No functional test, technology mapping, full synthesis, P&R, or simulator is run.
The default top is only parsed/elaborated; bounded management blocks also pass
through proc/opt_clean/check. Outputs must be a new directory under project/out.
"""
from __future__ import annotations

import argparse
import ast
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ENGINE = Path("C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe")
PYTHON_INPUTS = ("sw/golden/a615a_files.py", "tools/a615a_control.py",
                 "tools/pack_source_snapshot.py", "tools/check_non_sim_preparation.py")


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def source_list(name: str) -> list[str]:
    lines = [line.strip() for line in (ROOT / name).read_text(encoding="utf-8-sig").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if len(lines) != len(set(lines)):
        raise ValueError(f"duplicate input in {name}")
    for line in lines:
        path = ROOT / line
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError(f"source path escapes project: {line}")
        if not path.is_file():
            raise FileNotFoundError(line)
    return lines


def check(destination: Path, engine: Path) -> dict:
    destination, engine = destination.resolve(), engine.resolve()
    if not destination.is_relative_to((ROOT / "out").resolve()) or destination.exists():
        raise ValueError("output must be a fresh directory below project/out")
    if not engine.is_file():
        raise FileNotFoundError(engine)
    production = source_list("elinx/AFDX_top_sources.f")
    preparation = source_list("elinx/AFDX_615A_prepare_sources.f")
    fragment_preparation = source_list("elinx/AFDX_fragment_prepare_sources.f")
    names = sorted(set(production + preparation + list(PYTHON_INPUTS) +
                       fragment_preparation + ["elinx/AFDX_top_sources.f",
                       "elinx/AFDX_615A_prepare_sources.f", "elinx/AFDX_fragment_prepare_sources.f"]))
    payloads = {name: (ROOT / name).read_bytes() for name in names}
    for name in PYTHON_INPUTS:
        ast.parse(payloads[name].decode("utf-8-sig"), filename=name)
    destination.mkdir(parents=True)
    workspace = destination / "workspace"
    for name, data in payloads.items():
        target = workspace / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    manifest = {"schema": "afdx-static-input-v1", "created_local": datetime.now().astimezone().isoformat(),
                "production_rtl_count": len(production),
                "additional_preparation_rtl_count": len(set(preparation + fragment_preparation) - set(production)),
                "python_ast_syntax": "PASS", "files": [
                    {"path": name, "bytes": len(raw), "sha256": sha(raw)}
                    for name, raw in payloads.items()]}
    manifest_raw = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    (destination / "static_input_manifest.json").write_bytes(manifest_raw)
    definitions = [("AFDX_top", production, False, None),
                   ("a615a_tftp", ["rtl/common/bram_sdp.v", "rtl/mgmt/a615a_tftp.v"], True, None),
                   ("a615a_tftp_bind_peer_ip", ["rtl/common/bram_sdp.v", "rtl/mgmt/a615a_tftp.v"], True,
                    ("a615a_tftp", "BIND_PEER_IP", 1)),
                   ("a615a_init_tx", preparation, True, None),
                   ("a615a_lur_rx", preparation, True, None),
                   ("a615a_file_rx", ["rtl/mgmt/a615a_file_rx.v"], True, None),
                   ("a615a_tftp_client_1350", ["rtl/mgmt/a615a_tftp_client_1350.v"], True, None),
                   ("a615a_tftp_file_rx_adapter", ["rtl/mgmt/a615a_file_rx.v", "rtl/mgmt/a615a_tftp_file_rx_adapter.v"], True, None),
                   ("ipv4_fragment_plan", fragment_preparation, True, None),
                   ("ipv4_fragment_header", ["rtl/tx/ipv4_fragment_header.v"], True, None),
                   ("tx_pmem_byte_reader", ["rtl/tx/tx_pmem_byte_reader.v"], True, None)]
    records = []
    for top, sources, lower, parameter_override in definitions:
        commands = []
        for name in sources:
            path = (workspace / name).as_posix()
            if '"' in path:
                raise ValueError("unsupported quote in source path")
            option = " -mem2reg" if name == "rtl/tx/tx_vl_scheduler.v" else ""
            commands.append(f'read_verilog{option} "{path}"')
        if parameter_override is not None:
            module, parameter, value = parameter_override
            commands.append(f"chparam -set {parameter} {value} {module}")
            commands.append(f"hierarchy -check -top {module}")
        else:
            commands.append(f"hierarchy -check -top {top}")
        if lower:
            commands += ["proc", "opt_clean", "check -noinit"]
        commands.append("stat")
        script, log = destination / f"{top}_static.ys", destination / f"{top}_static.log"
        script.write_text("\n".join(commands) + "\n", encoding="utf-8")
        arguments = [str(engine), "-Q", "-T", "-s", str(script), "-l", str(log)]
        start = time.perf_counter()
        try:
            result = subprocess.run(arguments, cwd=destination, capture_output=True, timeout=60)
            code, console = result.returncode, result.stdout + result.stderr
        except subprocess.TimeoutExpired as exc:
            code, console = 124, (exc.stdout or b"") + (exc.stderr or b"")
        (destination / f"{top}_console.txt").write_bytes(console)
        raw = log.read_bytes() if log.exists() else console
        decoded = raw.decode("utf-8", errors="replace")
        errors = bool(re.search(r"(?m)^ERROR:", decoded))
        warnings = len(re.findall(r"(?m)^Warning:", decoded))
        records.append({"top": top,
                        "parameters": ({parameter_override[1]: parameter_override[2]}
                                       if parameter_override else "module_defaults"),
                        "scope": "parse_hierarchy_proc_check" if lower else "parse_hierarchy_only",
                        "script": script.name, "script_sha256": sha(script.read_bytes()),
                        "arguments": arguments, "exit_code": code, "warning_count": warnings,
                        "latch_cell_reported": bool(re.search(r"\$(?:a?dlatch)\b", decoded)),
                        "status": "STATIC_ONLY_PASS" if code == 0 and not errors else "FAIL",
                        "log_sha256": sha(raw), "wall_seconds": round(time.perf_counter() - start, 2)})
    report = {"status": "STATIC_ONLY_PASS_FUNCTIONAL_VALIDATION_PENDING"
              if all(record["status"] == "STATIC_ONLY_PASS" for record in records) else "FAIL",
              "scope": "syntax/hierarchy/proc only; no functional execution or technology mapping",
              "engine_sha256": sha(engine.read_bytes()), "simulation_started": False,
              "full_synthesis_started": False, "python_ast_syntax": "PASS",
              "input_manifest_sha256": sha(manifest_raw), "checks": records,
              "completed_local": datetime.now().astimezone().isoformat()}
    (destination / "static_status.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--synthesis-exe", type=Path, default=DEFAULT_ENGINE)
    args = parser.parse_args()
    try:
        destination = args.out_dir if args.out_dir.is_absolute() else ROOT / args.out_dir
        report = check(destination, args.synthesis_exe)
    except (OSError, ValueError, SyntaxError) as exc:
        parser.exit(2, f"Static preparation failed: {exc}\n")
    print(json.dumps(report, indent=2))
    return 0 if report["status"].startswith("STATIC_ONLY_PASS") else 1


if __name__ == "__main__":
    raise SystemExit(main())
