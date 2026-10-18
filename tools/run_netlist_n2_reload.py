"""Reload a saved IL artifact, with optional isolated dangling-COUT declarations.

Never edits the source IL. The optional derivative only adds scalar declarations
for undeclared LCELL COUT identifiers that have exactly one reference, at that
output port. This is a diagnostic artifact, not a production netlist repair.
"""

from __future__ import annotations

import argparse
import collections
import ctypes as ct
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(r"C:\Program Files (x86)\eHiWay\eLinx3.0\bin\shell\bin\eLinx_synthesis.exe")
TOOL_SHA = "b022eb9361b9847d0042b234fb6ee1b584836be4c0174e94addb6d2f1d236a23"
ABC = ROOT / "out/native_elinx_cli_probe_20261009_r1/abc_source/_TEST/abc.exe"
ABC_SHA = "96fdf5d4bfd70ddd4605e22b33b2396df1fc6bae67e9288b2f30a32af1adc22d"
TOKEN = re.compile(r"\S+")
NATIVE = {"$_LCELL_COMB_", "$_LCELL_COMB_INVA_"}


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def now():
    return dt.datetime.now().astimezone().isoformat()


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def audit_cout(source):
    """Two streaming passes; include every reference, not only COUT ports."""
    modules = {}
    module = None
    for n, line in enumerate(source.open(encoding="utf-8"), 1):
        if line.startswith("module "):
            module = line[7:].strip()
            modules[module] = {"declarations": set(), "candidates": {}}
        elif line.startswith("end"):
            module = None
        elif module and line.startswith("  wire "):
            modules[module]["declarations"].add(line.split()[-1])
    module = cell_type = cell_name = None
    refs = collections.Counter()
    for n, line in enumerate(source.open(encoding="utf-8"), 1):
        if line.startswith("module "):
            module = line[7:].strip()
        elif line.startswith("end"):
            module = None
        elif line.startswith("  cell "):
            _, cell_type, cell_name = line.split(maxsplit=2)
            cell_name = cell_name.strip()
        elif line.startswith("  end"):
            cell_type = cell_name = None
        elif module and line.lstrip().startswith("connect "):
            tokens = TOKEN.findall(line)
            for token in tokens[2:] if cell_type else tokens[1:]:
                if token.startswith(("$", "\\")):
                    refs[(module, token)] += 1
            if cell_type in NATIVE and tokens[1] == "\\COUT":
                if len(tokens) != 3:
                    raise ValueError(f"Non-scalar COUT at {n}")
                net = tokens[2]
                if net not in modules[module]["declarations"]:
                    modules[module]["candidates"][net] = {
                        "line": n, "cell": cell_name, "cell_type": cell_type,
                        "port": "COUT", "net": net,
                    }
    result = {}
    for module, data in modules.items():
        if data["candidates"]:
            result[module] = []
            for net, item in data["candidates"].items():
                result[module].append({**item, "total_signal_references": refs[(module, net)]})
    return result


class ProcessMemory(ct.Structure):
    _fields_ = [("cb", ct.c_ulong), ("PageFaultCount", ct.c_ulong)] + [
        (name, ct.c_size_t) for name in (
            "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
            "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage",
            "PagefileUsage", "PeakPagefileUsage", "PrivateUsage",
        )
    ]


def sample(proc):
    memory = ProcessMemory()
    memory.cb = ct.sizeof(memory)
    psapi = ct.WinDLL("psapi", use_last_error=True)
    call = psapi.GetProcessMemoryInfo
    call.argtypes = [ct.c_void_p, ct.POINTER(ProcessMemory), ct.c_ulong]
    call.restype = ct.c_int
    ok = call(ct.c_void_p(int(proc._handle)), ct.byref(memory), memory.cb)
    return {"observed_local": now(), "pid": proc.pid, "sample_ok": bool(ok),
            "working_set_bytes": memory.WorkingSetSize if ok else None,
            "private_bytes": memory.PrivateUsage if ok else None,
            "peak_working_set_bytes": memory.PeakWorkingSetSize if ok else None,
            "peak_private_bytes": memory.PeakPagefileUsage if ok else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--declare-unused-cout", action="store_true")
    parser.add_argument("--module-pattern")
    parser.add_argument("--run-abc", action="store_true")
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    source = args.input.resolve()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT / "out"):
        raise ValueError("Output must be in workspace/out")
    if out.exists():
        raise FileExistsError(out)
    if sha(TOOL) != TOOL_SHA:
        raise ValueError("Frozen synthesis executable hash mismatch")
    active = subprocess.run(
        ["tasklist", "/FI", "IMAGENAME eq eLinx_synthesis.exe", "/FO", "CSV", "/NH"],
        capture_output=True, check=False, creationflags=subprocess.CREATE_NO_WINDOW,
    )
    if b'"eLinx_synthesis.exe"' in active.stdout:
        raise RuntimeError("Another synthesis process is active")
    out.mkdir(parents=True)
    source_hash = sha(source)
    if args.run_abc and (not args.module_pattern or sha(ABC) != ABC_SHA):
        raise ValueError("ABC isolation requires a module pattern and the frozen ABC executable")
    audit = audit_cout(source)
    write_json(out / "cout_audit.json", audit)
    missing = [row for rows in audit.values() for row in rows]
    load_input = source
    if args.declare_unused_cout:
        if not missing or any(row["total_signal_references"] != 1 for row in missing):
            raise ValueError("Every added declaration must have exactly one COUT reference")
        load_input = out / "diagnostic_declared_cout.il"
        inserted = 0
        # Copy bytes exactly, inserting only declarations immediately after module headers.
        with source.open("rb") as fin, load_input.open("wb") as fout:
            for raw in fin:
                fout.write(raw)
                if raw.startswith(b"module "):
                    module = raw.decode("utf-8")[7:].strip()
                    for row in audit.get(module, []):
                        fout.write(("  wire " + row["net"] + "\n").encode("utf-8"))
                        inserted += 1
        if inserted != len(missing):
            raise AssertionError("Declaration count mismatch")
        # Verify the derivative reproduces every original byte after removing insertions.
        with source.open("rb") as original, load_input.open("rb") as derivative:
            for raw in original:
                if derivative.readline() != raw:
                    raise AssertionError("Derivative differs beyond inserted declarations")
                if raw.startswith(b"module "):
                    module = raw.decode("utf-8")[7:].strip()
                    for row in audit.get(module, []):
                        expected = ("  wire " + row["net"] + "\n").encode("utf-8")
                        if derivative.readline() != expected:
                            raise AssertionError("Unexpected inserted text")
            if derivative.read(1):
                raise AssertionError("Unexpected trailing derivative bytes")
    script = out / "reload_check.ys"
    commands = [f'read_ilang "{load_input.as_posix()}"']
    check = "check -assert -noinit"
    if args.module_pattern:
        if not re.fullmatch(r"[A-Za-z0-9_$=\\?*]+", args.module_pattern):
            raise ValueError("Module selection accepts only a simple Yosys wildcard pattern")
        if args.run_abc:
            commands.append("select -module " + args.module_pattern)
            commands.append(f'abc -exe "{ABC.as_posix()}" -fast -lut 4 -nocleanup -showtmp')
            commands.append(f'write_ilang "{(out / "postabc_isolated.il").as_posix()}"')
        else:
            commands.append("select *")
        check += " " + args.module_pattern
    else:
        commands.append("select *")
    commands.append(check)
    script.write_text("\n".join(commands) + "\n", encoding="ascii")
    metadata = {
        "schema": "netlist-n2-python-reload-v1", "started_local": now(),
        "runner": str(Path(__file__).resolve()), "runner_sha256": sha(Path(__file__)),
        "source": str(source), "source_sha256": source_hash,
        "load_input": str(load_input), "load_input_sha256": sha(load_input),
        "tool": str(TOOL), "tool_sha256": sha(TOOL),
        "script_sha256": sha(script), "added_unused_cout_declarations": len(missing) if args.declare_unused_cout else 0,
        "module_pattern": args.module_pattern,
        "abc_requested": args.run_abc,
        "abc": str(ABC) if args.run_abc else None,
        "abc_sha256": sha(ABC) if args.run_abc else None,
        "missing_cout_declarations": len(missing), "derivative_verified_insertions_only": args.declare_unused_cout,
        "diagnostic_only": True, "timeout_seconds": args.timeout,
    }
    write_json(out / "metadata.json", metadata)
    started = time.monotonic()
    samples = []
    timed_out = False
    with (out / "stdout.txt").open("wb") as stdout, (out / "stderr.txt").open("wb") as stderr:
        proc = subprocess.Popen([str(TOOL), "-Q", "-T", "-s", str(script), "-l", str(out / "reload_check.log")],
                                cwd=out, stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        write_json(out / "process.json", {"pid": proc.pid, "started_local": now()})
        with (out / "resource_samples.jsonl").open("w", encoding="utf-8") as sf:
            while True:
                row = sample(proc)
                row["elapsed_seconds"] = round(time.monotonic() - started, 3)
                samples.append(row)
                sf.write(json.dumps(row) + "\n")
                sf.flush()
                try:
                    proc.wait(timeout=1)
                    break
                except subprocess.TimeoutExpired:
                    if time.monotonic() - started >= args.timeout:
                        timed_out = True
                        proc.terminate()
                        proc.wait()
                        break
            # The Popen handle remains owned until return-code collection and final sample.
            row = sample(proc)
            row["elapsed_seconds"] = round(time.monotonic() - started, 3)
            samples.append(row)
            sf.write(json.dumps(row) + "\n")
    log_path = out / "reload_check.log"
    log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    warnings = [line for line in log.splitlines() if line.startswith("Warning:")]
    errors = [line for line in log.splitlines() if line.startswith("ERROR:")]
    success = "Yosys execute success!" in log
    check_started = "Executing CHECK pass" in log
    result = {"schema": "netlist-n2-python-reload-result-v1", "ended_local": now(),
              "exit_code": proc.returncode, "pid": proc.pid, "timed_out": timed_out,
              "wall_seconds": round(time.monotonic() - started, 3),
              "status": "PASS_CHECK" if proc.returncode == 0 and success and not warnings and not errors and check_started and not timed_out else "FAIL_RELOAD_OR_CHECK",
              "check_started": check_started, "success_marker": success,
              "module_pattern": args.module_pattern,
              "postabc_il_exists": (out / "postabc_isolated.il").exists(),
              "postabc_il_sha256": sha(out / "postabc_isolated.il") if (out / "postabc_isolated.il").exists() else None,
              "warning_count": len(warnings), "error_count": len(errors), "errors": errors,
              "warning_examples": warnings[:5], "logic_loop_count": sum("found logic loop" in line for line in warnings),
              "conflicting_driver_count": sum("multiple conflicting drivers" in line for line in warnings),
              "log_sha256": sha(log_path) if log_path.exists() else None,
              "source_unchanged": source_hash == sha(source),
              "peak_private_bytes": max((row.get("peak_private_bytes") or 0 for row in samples), default=0),
              "resource_sample_count": len(samples)}
    write_json(out / "result.json", result)
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
