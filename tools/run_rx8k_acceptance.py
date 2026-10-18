#!/usr/bin/env python3
"""Freeze and run the RX8KiB acceptance inputs without overwriting evidence.

freeze snapshots production RTL plus the complete regression inputs, runner,
GMII vectors, and SAP legacy reference. run uses only that verified snapshot.
A fresh result directory is mandatory for every invocation, including failures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
VSIM_DEFAULT = Path(r"C:\altera_pro\26.1.1\questa_fse\win64\vsim.exe")
BASELINE = "out/rx8k_production_integration_20261012_r1/baseline.json"
REFERENCE = "out/rx8k_sap_chain_20261012_r1/mgmt_sap_rx_legacy_baseline.v"
INPUT_DIRS = ("rtl", "sim/tb", "sim/bfm", "sim/chk", "sim/env", "sim/vec", "sw/golden", "sw/report", "doc", "elinx/sdc")
SOURCE_SUFFIXES = {".v", ".sv", ".vh", ".hex", ".json", ".py", ".ps1", ".tcl", ".manifest", ".tsv", ".yaml", ".yml", ".csv", ".md", ".txt", ".sdc", ".ys", ".qsf", ".qpf", ".names", ".sha256", ".f"}
UNITS = [
    ("tb_rx_block_pool_chain", "RX_BLOCK_POOL_CHAIN", 16),
    ("tb_rx_udp_checksum_chain", "RX8K_CHECKSUM_CHAIN", 45),
    ("tb_rx_udp_checksum_legacy", "RX8K_CHECKSUM_CHAIN", 16),
    ("tb_rx_udp_checksum_legacy_poison", "RX8K_CHECKSUM_CHAIN", 16),
    ("tb_rx_reassembly_chain", "RX_REASSEMBLY_CHAIN", 37),
    ("tb_rx_chain_metadata", "RX_CHAIN_METADATA", 25),
    ("tb_mgmt_sap_rx_chain", "RX8K_SAP_CHAIN", 47),
    ("tb_mgmt_sap_rx_legacy_open", "RX8K_SAP_CHAIN", 15),
    ("tb_mgmt_sap_rx_legacy_poison", "RX8K_SAP_CHAIN", 15),
]

def now():
    return datetime.now().astimezone().isoformat()

def sha(file):
    return hashlib.sha256(Path(file).read_bytes()).hexdigest()

def save(file, value):
    Path(file).write_text(json.dumps(value, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")

def child(path, parent):
    path = Path(path).resolve()
    if not path.is_relative_to(parent.resolve()) or path == parent.resolve():
        raise ValueError(f"path must be a child of {parent}: {path}")
    return path

def snapshot_inputs():
    result = set()
    for rel in INPUT_DIRS:
        folder = ROOT / rel
        if folder.exists():
            result.update(p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() in SOURCE_SUFFIXES and "__pycache__" not in p.parts)
    for rel in ("sim", "tools", "elinx", "elinx/prj"):
        folder = ROOT / rel
        result.update(p for p in folder.glob("*") if p.is_file() and p.suffix.lower() in SOURCE_SUFFIXES)
    for rel in ("README.md", "_project.md", "AFDX端系统_总体设计书.md", "elinx/README.txt", BASELINE, REFERENCE, "out/rx8k_production_integration_20261012_r1/CONTRACT.md", "out/rx8k_sap_chain_20261012_r1/cases.json"):
        p = ROOT / rel
        if p.exists():
            result.add(p)
    return sorted(result)

def freeze(args):
    bundle = child(args.bundle, ROOT / "out")
    if bundle.exists():
        raise ValueError(f"refusing to overwrite bundle: {bundle}")
    bundle.mkdir()
    workspace = bundle / "workspace"
    hashes = {}
    for source in snapshot_inputs():
        rel = source.relative_to(ROOT).as_posix()
        target = workspace / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        before = sha(source)
        shutil.copyfile(source, target)
        if sha(target) != before or sha(source) != before:
            raise RuntimeError(f"input changed during snapshot: {rel}")
        hashes["workspace/"+rel] = before
    baseline = json.loads((workspace / BASELINE).read_text(encoding="utf-8-sig"))
    deltas = []
    for rel, old in baseline["sha256"].items():
        current = hashes.get("workspace/"+rel)
        deltas.append({"path": rel, "baseline_sha256": old, "frozen_sha256": current, "changed": current != old})
    for suite in ("minimal", "full"):
        target = bundle / "vectors" / suite
        command = [sys.executable, str(workspace / "sw/golden/gen_rx8k_gmii.py"), "--suite", suite, "--out-dir", str(target)]
        # The frozen generator locates its project root from its snapshot path.
        # Generate under snapshot/out, then copy that immutable result here.
        generated = workspace / "out" / "rx8k_acceptance_vectors" / suite
        command[-1] = str(generated)
        proc = subprocess.run(command, text=True, capture_output=True)
        (bundle / f"golden_{suite}.stdout.txt").write_text(proc.stdout, encoding="utf-8")
        (bundle / f"golden_{suite}.stderr.txt").write_text(proc.stderr, encoding="utf-8")
        if proc.returncode or f"RX8K GOLDEN PASS suite={suite}" not in proc.stdout:
            raise RuntimeError(f"golden {suite} failed rc={proc.returncode}")
        shutil.copytree(generated, target)
        for p in target.iterdir():
            hashes[p.relative_to(bundle).as_posix()] = sha(p)
    # Include every source copied above and all generated vectors. No old PASS
    # is inherited by the package and no historical evidence is rewritten.
    state = {"schema": 1, "created_local": now(), "status": "FROZEN_NOT_EXECUTED", "scope": "RX8KiB opt-in production GMII acceptance; common revision for unit and regression inputs", "source_root": str(ROOT), "source_sha256": hashes, "regression_test_count": len([x for x in (workspace/"sim/tests.manifest").read_text().splitlines() if x.strip() and not x.lstrip().startswith("#")]), "production_rtl": sorted(k for k in hashes if k.startswith("workspace/rtl/") and k.endswith(".v")), "baseline_differences": deltas, "configuration": {"IF_MODE": 2, "FCS_MODE": 2, "RX_REASM_CHAIN_BLOCKS": 5, "other_top_parameters": "production defaults"}, "limitations": ["Historical isolated PASS results do not establish this revision", "Final full regression and netlist validation remain required", "GMII host acceptance does not establish the entire 615A/TFTP protocol scope"]}
    save(bundle / "freeze_manifest.json", state)
    print(f"RX8K FREEZE PASS inputs={len(hashes)} full_cases={json.loads((bundle/'vectors/full/manifest.json').read_text())['case_count']} bundle={bundle}")

def verify(bundle):
    file = bundle / "freeze_manifest.json"
    state = json.loads(file.read_text(encoding="utf-8"))
    for rel, expected in state["source_sha256"].items():
        p = child(bundle / rel, bundle)
        if not p.is_file() or sha(p) != expected:
            raise RuntimeError(f"frozen input hash mismatch: {rel}")
    # Bind the runner that is actually executing, as well as its frozen copy.
    expected_runner = state["source_sha256"]["workspace/tools/run_rx8k_acceptance.py"]
    if sha(__file__) != expected_runner:
        raise RuntimeError("executing runner differs from the frozen runner")
    return state

def license_environment():
    env = os.environ.copy()
    if not env.get("SALT_LICENSE_SERVER") and os.name == "nt":
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
                env["SALT_LICENSE_SERVER"] = winreg.QueryValueEx(key, "SALT_LICENSE_SERVER")[0]
        except FileNotFoundError:
            pass
    return env

def stage(exe, do_file, directory, label, timeout, env):
    start = time.monotonic()
    result = {"stage": label, "started_local": now(), "timeout_seconds": timeout, "command": [str(exe), "-c", "-quiet", "-l", label+".log", "-do", str(do_file)]}
    save(directory / (label+".metadata.json"), result)
    with (directory / (label+".stdout.txt")).open("wb") as stdout, (directory / (label+".stderr.txt")).open("wb") as stderr:
        proc = subprocess.Popen(result["command"], cwd=directory, stdout=stdout, stderr=stderr, env=env, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        result["pid"] = proc.pid
        save(directory / (label+".metadata.json"), result)
        next_progress = start+30
        timed_out = False
        try:
            while proc.poll() is None:
                elapsed = time.monotonic()-start
                if elapsed >= timeout:
                    timed_out = True
                    if os.name == "nt":
                        kill = subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, text=True)
                        result["termination_exit_code"] = kill.returncode
                        (directory/(label+".termination.txt")).write_text(kill.stdout+kill.stderr, encoding="utf-8")
                    else:
                        proc.kill()
                    proc.wait(timeout=15)
                    break
                if time.monotonic() >= next_progress:
                    log = directory / (label+".log")
                    tail = log.read_text(errors="replace").splitlines()[-1:] if log.exists() else []
                    print(f"RX8K_PROGRESS stage={label} elapsed={elapsed:.1f}s last={tail}", flush=True)
                    next_progress += 30
                time.sleep(0.5)
        finally:
            if proc.poll() is None:
                if os.name == "nt":
                    subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
                else:
                    proc.kill()
                proc.wait(timeout=15)
        result.update({"exit_code": proc.returncode, "timed_out": timed_out, "elapsed_seconds": round(time.monotonic()-start, 3), "finished_local": now()})
    text = (directory / (label+".log")).read_text(errors="replace") if (directory / (label+".log")).exists() else ""
    stderr_text = (directory / (label+".stderr.txt")).read_text(errors="replace")
    errors = re.findall(r"^#?\s*\*\*\s*(?:Error|Fatal)\b.*", text, re.M)
    warnings = re.findall(r"^#?\s*\*\*\s*Warning\b.*", text, re.M)
    summaries = re.findall(r"^#?\s*Errors:\s*(\d+),\s*Warnings:\s*(\d+)(?:,\s*Suppressed Warnings:\s*(\d+))?", text, re.M)
    summary_good = bool(summaries) and all(int(a)==0 and int(b)==0 and (not c or int(c)==0) for a,b,c in summaries)
    result.update({"diagnostic_errors": errors, "unreviewed_warnings": warnings, "native_summaries": summaries, "summary_good": summary_good, "stderr_empty": not stderr_text.strip()})
    result["verdict"] = "PASS" if proc.returncode == 0 and not timed_out and not errors and not warnings and summary_good and not stderr_text.strip() and not re.search(r"\bFAIL\b", text) else "FAIL"
    save(directory / (label+".metadata.json"), result)
    return result, text

def run(args):
    bundle = Path(args.bundle).resolve()
    state = verify(bundle)
    directory = child(bundle / "runs" / args.name, bundle / "runs")
    if directory.exists():
        raise ValueError(f"refusing to overwrite run: {directory}")
    directory.mkdir(parents=True)
    metadata = {"started_local": now(), "status": "RUNNING", "mode": args.mode, "freeze_manifest_sha256": sha(bundle/"freeze_manifest.json"), "runner_sha256": sha(__file__), "vsim_path": str(args.vsim.resolve()), "vsim_sha256": sha(args.vsim), "source_input_count": len(state["source_sha256"]), "stages": [], "verdict": "NOT_EXECUTED"}
    save(directory / "run_metadata.json", metadata)
    try:
        env = license_environment()
        workspace = bundle / "workspace"
        rtl = sorted((workspace/"rtl").rglob("*.v"))
        if args.mode == "units":
            tbs = [workspace/"sim/tb"/x for x in ("tb_rx_block_pool_chain.v", "tb_rx_udp_checksum_chain.v", "tb_rx_reassembly_chain.v", "tb_rx_chain_metadata.v", "tb_mgmt_sap_rx_chain.v")]
            tbs.append(workspace / REFERENCE)
            jobs = UNITS
            plusargs = []
        else:
            tbs = [workspace / "sim/tb/tb_rx8k_gmii.v"]
            suite = "minimal" if args.mode == "smoke" else "full"
            shutil.copytree(bundle / "vectors" / suite, directory / "vectors")
            vector_meta = json.loads((directory/"vectors/manifest.json").read_text())
            total = vector_meta["case_count"]
            count = args.case_count or (total-args.case_start)
            if args.case_start < 0 or count < 1 or args.case_start+count > total:
                raise ValueError("invalid selected case range")
            metadata["vector_suite"] = suite
            metadata["selected_cases"] = vector_meta["cases"][args.case_start:args.case_start+count]
            jobs = [("tb_rx8k_gmii", "RX8K GMII", count)]
            plusargs = [f"+RX8K_CASE_START={args.case_start}", f"+RX8K_CASE_LIMIT={args.case_start+count}"]
        def tcl(p):
            return "{"+p.as_posix()+"}"
        compile_text = "onerror {quit -f -code 1}\nonbreak {quit -f -code 1}\nvlib work\nvmap work work\nvlog -sv -mfcu -cuname rx8k_acceptance "+" ".join(tcl(p) for p in rtl+tbs)+"\nquit -f -code 0\n"
        compile_file = directory / "compile.tcl"
        compile_file.write_text(compile_text, encoding="ascii")
        metadata["compile_script_sha256"] = sha(compile_file)
        result, text = stage(args.vsim, compile_file, directory, "compile", min(args.timeout, 180), env)
        metadata["stages"].append(result)
        if result["verdict"] != "PASS":
            raise RuntimeError("compile did not meet strict acceptance")
        for top, prefix, expected_cases in jobs:
            do_file = directory / (top+".tcl")
            # HDL hierarchical checks are compiled dependencies. These tests
            # do not examine/force signals through Tcl, so full +acc is unused.
            do_file.write_text("onerror {quit -f -code 1}\nonbreak {quit -f -code 1}\nvsim work."+top+" "+" ".join(plusargs)+"\nrun -all\nquit -f -code 0\n", encoding="ascii")
            result, text = stage(args.vsim, do_file, directory, top, args.timeout, env)
            verdicts = re.findall(r"^#?\s*"+re.escape(prefix)+r" PASS\b.*", text, re.M)
            result["pass_lines"] = verdicts
            if len(verdicts) != 1 or (expected_cases and not re.search(r"\bcases="+str(expected_cases)+r"\b", verdicts[0])):
                result["verdict"] = "FAIL"
                result["reason"] = "missing unique PASS or exact case coverage"
            result["do_script_sha256"] = sha(do_file)
            save(directory / (top+".metadata.json"), result)
            metadata["stages"].append(result)
            save(directory / "run_metadata.json", metadata)
            if result["verdict"] != "PASS":
                raise RuntimeError(f"{top} did not meet strict acceptance")
        verify(bundle)
        metadata["verdict"] = "PASS"
        metadata["status"] = "FINISHED"
    except Exception as exc:
        metadata["status"] = "FAILED_STOP"
        metadata["verdict"] = "FAIL"
        metadata["failure"] = str(exc)
        print(f"RX8K RUN FAIL: {exc}", flush=True)
    finally:
        try:
            verify(bundle)
            metadata["inputs_unchanged_after"] = True
        except Exception as exc:
            metadata["inputs_unchanged_after"] = False
            metadata["input_integrity_error"] = str(exc)
            metadata["verdict"] = "FAIL"
            metadata["status"] = "FAILED_STOP"
        metadata["finished_local"] = now()
        metadata["output_sha256"] = {p.relative_to(directory).as_posix(): sha(p) for p in directory.rglob("*") if p.is_file() and "work" not in p.relative_to(directory).parts and p.name != "run_metadata.json"}
        save(directory / "run_metadata.json", metadata)
    print(f"RX8K RUN {metadata['verdict']} mode={args.mode} directory={directory}", flush=True)
    return 0 if metadata["verdict"] == "PASS" else 1

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    commands = ap.add_subparsers(dest="action", required=True)
    fp = commands.add_parser("freeze")
    fp.add_argument("--bundle", type=Path, required=True)
    vp = commands.add_parser("verify")
    vp.add_argument("--bundle", type=Path, required=True)
    rp = commands.add_parser("run")
    rp.add_argument("--bundle", type=Path, required=True)
    rp.add_argument("--name", required=True)
    rp.add_argument("--mode", choices=("smoke", "gmii", "units"), default="smoke")
    rp.add_argument("--case-start", type=int, default=0)
    rp.add_argument("--case-count", type=int)
    rp.add_argument("--timeout", type=int, default=300)
    rp.add_argument("--vsim", type=Path, default=VSIM_DEFAULT)
    args = ap.parse_args()
    if args.action == "freeze":
        freeze(args)
        return 0
    if args.action == "verify":
        state = verify(args.bundle.resolve())
        print(f"RX8K VERIFY PASS inputs={len(state['source_sha256'])}")
        return 0
    if not 30 <= args.timeout <= 1800:
        ap.error("timeout must be between 30 and 1800 seconds")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", args.name):
        ap.error("run name must be a simple fresh directory name")
    return run(args)

if __name__ == "__main__":
    sys.exit(main())
