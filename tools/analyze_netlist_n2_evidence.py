#!/usr/bin/env python3
"""Read-only parser for the saved NETLIST-N2 post-ABC IL and evidence logs."""

from __future__ import annotations

import collections
import hashlib
import json
import re
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "out/netlist_n2_instrumented_20261014_r1"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def parse_pe(path: Path) -> dict:
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe : pe + 4] != b"PE\0\0":
        raise ValueError(f"invalid PE signature: {path}")
    machine, _, _, _, _, opt_size, characteristics = struct.unpack_from(
        "<HHIIIHH", data, pe + 4
    )
    magic = struct.unpack_from("<H", data, pe + 24)[0]
    return {
        "path": str(path),
        "sha256": sha256(path),
        "bytes": len(data),
        "machine": f"0x{machine:04x}",
        "optional_header_magic": f"0x{magic:04x}",
        "characteristics": f"0x{characteristics:04x}",
        "large_address_aware": bool(characteristics & 0x20),
        "pe32": magic == 0x10B,
        "pe32_plus": magic == 0x20B,
        "optional_header_size": opt_size,
    }


def parse_il(path: Path, selected_modules: set[str]) -> dict:
    modules: dict[str, dict[str, list[dict]]] = {}
    module = None
    cell = None
    cell_text: list[str] = []

    def save_cell() -> None:
        nonlocal cell, cell_text
        if module is None or cell is None:
            cell = None
            cell_text = []
            return
        block = "\n".join(cell_text)
        y = re.search(r"^\s*connect \\Y (.+)$", block, re.M)
        a = re.search(r"^\s*connect \\A (.+)$", block, re.M)
        wire_re = r"\$abc:auto_generated\d+(?:\|[^\s{}]+)?"
        outputs = re.findall(wire_re, y.group(1)) if y else []
        inputs = re.findall(wire_re, a.group(1)) if a else []
        if outputs and module in selected_modules:
            for net in outputs:
                modules.setdefault(module, {}).setdefault(net, []).append(
                    {"cell": cell, "inputs": inputs, "y_expr": y.group(1).strip()}
                )
        cell = None
        cell_text = []

    with path.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith("module "):
                save_cell()
                module = line[len("module ") :].strip()
                continue
            if line.strip() == "end":
                if cell is not None:
                    save_cell()
                continue
            if module is None:
                continue
            m = re.match(r"\s*cell \$lut (\S+)", line)
            if m:
                save_cell()
                cell = m.group(1)
                cell_text = [line]
            elif cell is not None:
                cell_text.append(line)
        save_cell()

    duplicates = {}
    for mod, nets in modules.items():
        duplicates[mod] = {
            net: drivers for net, drivers in nets.items() if len(drivers) > 1
        }
    return {
        "file": str(path),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
        "module_duplicate_output_net_counts": {
            module_name.rsplit("\\", 1)[-1]: len(nets)
            for module_name, nets in duplicates.items()
        },
        "selected_duplicate_output_examples": {
            module_name.rsplit("\\", 1)[-1]: dict(list(nets.items())[:8])
            for module_name, nets in duplicates.items()
        },
        "_duplicate_outputs_full": duplicates,
    }


def parse_log(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    warnings = [line for line in lines if line.startswith("Warning:")]
    errors = [line for line in lines if line.startswith("ERROR:")]
    module_counts = collections.Counter()
    conflict_nets: dict[str, dict[str, list[str]]] = collections.defaultdict(dict)
    for i, line in enumerate(lines):
        m = re.match(r"Warning: multiple conflicting drivers for (.+)\s+:[^:]*:", line)
        if not m:
            continue
        target = m.group(1)
        module_match = re.match(r"(.*\\[^.]+)\.(\$abc:auto_generated\d+)$", target)
        if module_match:
            module_name, net = module_match.groups()
            module_counts[module_name.rsplit("\\", 1)[-1]] += 1
            drivers = []
            for following in lines[i + 1 : i + 4]:
                cm = re.search(r"port Y\[0\] of cell (\S+) \((\$lut)\)", following)
                if cm:
                    drivers.append(cm.group(1))
            conflict_nets[module_name][net] = drivers
    loops = [line for line in warnings if "found logic loop in module" in line]
    allocation = [line for line in errors if "bad allocation" in line.lower()]
    return {
        "file": str(path),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
        "diagnostic_lines": len(warnings) + len(errors),
        "warning_lines": len(warnings),
        "conflicting_driver_warning_count": sum(module_counts.values()),
        "conflicting_driver_modules": dict(module_counts),
        "logic_loop_warning_count": len(loops),
        "bad_allocation_error_count": len(allocation),
        "bad_allocation_line_number": next(
            (i + 1 for i, line in enumerate(lines) if "ERROR: bad allocation" in line), None
        ),
        "last_diagnostic_line_number": max(
            (i + 1 for i, line in enumerate(lines) if line.startswith(("Warning:", "ERROR:"))),
            default=None,
        ),
        "check_stage_markers": [
            {"line": i + 1, "text": line}
            for i, line in enumerate(lines)
            if "Executing CHECK pass" in line or "Re-integrating ABC results" in line
        ][-4:],
        "_conflict_nets_full": dict(conflict_nets),
    }


def parse_resource_samples(path: Path) -> dict:
    rows = []
    with path.open("r", encoding="utf-8-sig") as f:
        for line in f:
            if line.strip():
                rows.append(json.loads(line))
    run_rows = [r for r in rows if r.get("processes")]
    process_rows = [
        (r, p) for r in run_rows for p in r.get("processes", [])
        if p.get("ProcessName", "").lower() in {"elinx_synthesis", "abc"}
    ]
    max_virtual = max(process_rows, key=lambda x: x[1].get("VirtualMemorySize64", 0))
    max_private = max(process_rows, key=lambda x: x[1].get("PrivateMemorySize64", 0))
    min_physical = min(rows, key=lambda x: x.get("system", {}).get("physical_available_bytes", float("inf")))
    min_commit = min(rows, key=lambda x: x.get("system", {}).get("commit_available_estimate_bytes", float("inf")))
    def point(pair):
        row, proc = pair
        return {
            "observed_local": row.get("observed_local"),
            "process": proc.get("ProcessName"),
            "pid": proc.get("Id"),
            "virtual_bytes": proc.get("VirtualMemorySize64"),
            "private_bytes": proc.get("PrivateMemorySize64"),
            "working_set_bytes": proc.get("WorkingSet64"),
            "phase": row.get("phase"),
        }
    return {
        "file": str(path),
        "sha256": sha256(path),
        "sample_count": len(rows),
        "process_sample_count": len(process_rows),
        "first_observed_local": rows[0].get("observed_local") if rows else None,
        "last_observed_local": rows[-1].get("observed_local") if rows else None,
        "peak_virtual": point(max_virtual),
        "peak_private": point(max_private),
        "minimum_system_physical_available": {
            "observed_local": min_physical.get("observed_local"),
            "bytes": min_physical.get("system", {}).get("physical_available_bytes"),
        },
        "minimum_system_commit_available_estimate": {
            "observed_local": min_commit.get("observed_local"),
            "bytes": min_commit.get("system", {}).get("commit_available_estimate_bytes"),
        },
        "final_phase": rows[-1].get("phase") if rows else None,
    }


def main() -> None:
    il = OUT / "AFDX_top_postabc.il"
    log = OUT / "n2_synthesis.log"
    samples = OUT / "resource_samples.jsonl"
    candidate = ROOT / "out/production_repairs_native_hierarchy_default_20261013_r1/candidate.json"
    tools = [
        Path(r"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe"),
        ROOT / "out/native_elinx_cli_probe_20261009_r1/abc_source/_TEST/abc.exe",
    ]
    module_names = {
        r"$paramod$3eec85f513867eb67bf2c18df61a999b8a6e24d5\a615a_tftp",
        r"$paramod$4c222b690d4305e2e1151b8d76ce6d509e42661b\rx_reassembly",
    }
    il_result = parse_il(il, module_names)
    log_result = parse_log(log)
    il_drivers = il_result.pop("_duplicate_outputs_full")
    log_conflicts = log_result.pop("_conflict_nets_full")
    correspondence = {}
    for module_name, conflicts in log_conflicts.items():
        il_nets = il_drivers.get(module_name, {})
        matches = []
        mismatches = []
        absent = []
        for net, logged_cells in conflicts.items():
            il_cells = [d["cell"] for d in il_nets.get(net, [])]
            if not il_cells:
                absent.append(net)
            elif sorted(logged_cells) == sorted(il_cells):
                matches.append(net)
            else:
                mismatches.append({"net": net, "logged_cells": logged_cells, "il_cells": il_cells})
        correspondence[module_name.rsplit("\\", 1)[-1]] = {
            "log_conflict_nets": len(conflicts),
            "il_duplicate_y_nets": len(il_nets),
            "exact_log_cell_match_count": len(matches),
            "absent_from_il_count": len(absent),
            "different_driver_cell_count": len(mismatches),
            "absent_examples": absent[:5],
            "mismatch_examples": mismatches[:5],
        }
    candidate_json = json.loads(candidate.read_text(encoding="utf-8-sig"))
    result = {
        "candidate": {
            "path": str(candidate),
            "sha256": sha256(candidate),
            "top": candidate_json.get("top"),
            "rtl_source_count": len(candidate_json.get("rtl_sources", [])),
            "synthesis_executable_sha256": candidate_json.get("synthesis_executable_sha256"),
            "source_manifest": candidate_json.get("rtl_sources", []),
        },
        "il": il_result,
        "log": log_result,
        "log_to_il_driver_correspondence": correspondence,
        "resources": parse_resource_samples(samples),
        "binaries": [parse_pe(path) for path in tools],
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
