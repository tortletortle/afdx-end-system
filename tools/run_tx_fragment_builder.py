"""Freeze and strictly verify the standalone TX fragment builder (not AFDX_top)."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
INPUTS = (
    "rtl/common/crc32.v", "rtl/tx/mac_tx_if.v", "rtl/tx/tx_pmem_window_reader.v",
    "rtl/tx/tx_fragment_frame_builder.v", "sim/tb/tb_tx_fragment_frame_builder.v",
    "sw/golden/gen_tx_fragment_builder.py", "tools/run_rx8k_acceptance.py",
    "tools/run_tx_fragment_builder.py",
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    directory = args.out.resolve()
    assert not directory.exists(), "Use a new result directory"
    assert directory.is_relative_to(ROOT / "out")
    directory.mkdir(parents=True)
    for rel in INPUTS:
        target = directory / "input" / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, target)
    hashes = {rel: sha(directory / "input" / rel) for rel in INPUTS}
    frozen = {"scope": "Standalone builder, 4-block TX PMEM; not integrated TX8KiB acceptance",
              "input_sha256": hashes}
    save(directory / "freeze_manifest.json", frozen)
    spec = importlib.util.spec_from_file_location("frozen_runner", directory / "input/tools/run_rx8k_acceptance.py")
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    env = shared.license_environment()
    exe = shared.VSIM_DEFAULT
    result = {"scope": frozen["scope"], "verdict": "FAIL", "status": "RUNNING", "stages": [],
              "freeze_manifest_sha256": sha(directory / "freeze_manifest.json"),
              "vsim_path": str(exe), "vsim_sha256": sha(exe), "started_local": shared.now()}
    save(directory / "run_metadata.json", result)
    try:
        command = [sys.executable, str(directory / "input/sw/golden/gen_tx_fragment_builder.py"),
                   "--out", str(directory / "vectors")]
        with (directory / "golden.stdout.txt").open("wb") as stdout, (directory / "golden.stderr.txt").open("wb") as stderr:
            proc = subprocess.run(command, cwd=directory, stdout=stdout, stderr=stderr, timeout=60,
                                  creationflags=subprocess.CREATE_NO_WINDOW)
        assert proc.returncode == 0 and not (directory / "golden.stderr.txt").read_bytes(), "Golden generation failed"
        vectors = json.loads((directory / "vectors/manifest.json").read_text(encoding="utf-8"))
        frozen["vector_sha256"] = {p.name: sha(p) for p in (directory / "vectors").iterdir()}
        save(directory / "freeze_manifest.json", frozen)
        result["freeze_manifest_sha256"] = sha(directory / "freeze_manifest.json")
        result["expected_fragments"] = vectors["case_count"]
        result["expected_cases"] = 2 * vectors["case_count"] + 6
        compile_file = directory / "compile.tcl"
        sources = [directory / "input" / rel for rel in INPUTS if rel.endswith(".v")]
        compile_file.write_text("onerror {quit -f -code 1}\nonbreak {quit -f -code 1}\nvlib work\nvmap work work\n"
                                + "vlog -sv " + " ".join("{" + p.as_posix() + "}" for p in sources)
                                + "\nquit -f -code 0\n", encoding="ascii")
        stage, _ = shared.stage(exe, compile_file, directory, "compile", 180, env)
        result["stages"].append(stage)
        assert stage["verdict"] == "PASS", "Compile failed strict acceptance"
        do_file = directory / "builder.tcl"
        do_file.write_text("onerror {quit -f -code 1}\nonbreak {quit -f -code 1}\nvsim work.tb_tx_fragment_frame_builder +TX_FRAGMENT_VECTORS=vectors/cases.hex\nrun -all\nquit -f -code 0\n", encoding="ascii")
        stage, log = shared.stage(exe, do_file, directory, "builder", 300, env)
        result["stages"].append(stage)
        markers = re.findall(r"^# T80 TX_FRAGMENT_FRAME_BUILDER PASS cases=(\d+) fragments=(\d+) checks=(\d+)$", log, re.M)
        assert stage["verdict"] == "PASS" and len(markers) == 1, "Builder failed strict acceptance"
        cases, fragments, checks = map(int, markers[0])
        assert cases == result["expected_cases"] and fragments == result["expected_fragments"]
        assert checks > 0 and not re.search(r"TX_FRAGMENT ERROR", log), "Incomplete or failed oracle checks"
        result.update({"verdict": "PASS", "status": "FINISHED", "cases": cases, "fragments": fragments, "checks": checks})
    except Exception as exc:
        result.update({"verdict": "FAIL", "status": "FAILED_STOP", "failure": str(exc)})
    finally:
        unchanged = all(sha(directory / "input" / rel) == value for rel, value in hashes.items())
        unchanged = unchanged and all(sha(directory / "vectors" / rel) == value for rel, value in frozen.get("vector_sha256", {}).items())
        result["inputs_unchanged_after"] = unchanged
        if not unchanged:
            result.update({"verdict": "FAIL", "status": "FAILED_STOP", "failure": "Frozen inputs changed"})
        result["finished_local"] = shared.now()
        result["output_sha256"] = {p.relative_to(directory).as_posix(): sha(p) for p in directory.rglob("*")
                                    if p.is_file() and "work" not in p.relative_to(directory).parts
                                    and "input" not in p.relative_to(directory).parts and p.name != "run_metadata.json"}
        save(directory / "run_metadata.json", result)
    print(f"TX FRAGMENT BUILDER {result['verdict']} directory={directory}", flush=True)
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
