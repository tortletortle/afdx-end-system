"""Render the exact staged command/rc log without inventing PASS verdicts."""
from pathlib import Path
import json

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
source = out / "COMMANDS.jsonl"
records = []
for line in source.read_text(encoding="utf-8-sig").splitlines():
    if line.strip():
        records.append(json.loads(line.lstrip("\ufeff")))
lines = [
    "# Continue3 - command record (2026-09-25)",
    "",
    "All PowerShell bridge calls explicitly changed to `C:/Workspace/diansai`; the bridge's default command cwd is elsewhere.",
    "No git commit/push/reset was used. Full raw output and true child-process exit codes are in `raw/`.",
    "",
    "## Preparation (actually executed)",
    "",
    "1. MCP `initialize`, `notifications/initialized`, `tools/list`, then `read_files` for `out/arena-debug/MISSION-CONTINUE3.md` and the four required reports.",
    "2. `run_command`: create `out/arena-debug/continue3/backup/rtl/{common,top}` and copy the two source files *before* editing; compare SHA-256. Exit code 0.",
    "3. MCP `apply_patch` with both original SHA-256 version guards: `rtl/common/rst_sync.v` and `rtl/top/AFDX_top.v`.",
    "   - First attempt to add helper files failed preflight (`PATH_OUTSIDE_WORKSPACE`: missing `continue3/sim/tb/` parent). No partial change; created the missing directory and retried successfully. Original diagnostic: `raw/setup_patch_failure.log`.",
    "4. `powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue3/prepare.ps1`: isolated 24-file source snapshot and copied Quartus/Questa inputs; exit code 0.",
    "5. `python out/arena-debug/continue3/make_patch.py`: `git diff --no-index` (no repository mutation), `git apply --check` and isolated replay under `continue3/replay/`; check/apply rc=0, both replay files byte-identical. See `raw/patch_verify.log`.",
    "6. `python out/arena-debug/continue3/verify_rollback.py`: reverse `git apply --check` and `git apply --reverse` ONLY on `continue3/replay_undo/`; both rc=0 and 2/2 files byte-identical to backups. Live RTL was not rolled back.",
    "",
    "## Tool stages (from `COMMANDS.jsonl`)",
    "",
    "| Stage | Child rc | Wall (s) | Raw stdout / stderr |",
    "|---|---:|---:|---|",
]
for record in records:
    stage = record["stage"]
    lines.append(f"| `{stage}` | {record['process_exit_code']} | {record['wall_seconds']} | `raw/{stage}.stdout.log` / `raw/{stage}.stderr.log` |")
lines += ["", "Actual executable, argument string and cwd for each stage:", ""]
for record in records:
    lines += [
        f"### {record['stage']}",
        "",
        f"- cwd: `{record['cwd']}`",
        f"- command: `\"{record['executable']}\" {record['arguments']}`",
        f"- process exit code: `{record['process_exit_code']}`; elapsed seconds: `{record['wall_seconds']}`",
        "",
    ]
lines += [
    "## Final audit",
    "",
    "After all stages: `python out/arena-debug/continue3/audit_results.py`; run `python out/arena-debug/continue3/cleanup_generated.py` to copy Quartus `.map.rpt/.map.summary` to `raw/` before deleting disposable DB/work directories; write `REPORT.md`; run `python out/arena-debug/continue3/make_sha256.py` last.",
    "",
    "An exit code of zero alone is not a simulation PASS: audit test verdict lines in the raw Questa console separately. STA numbers must be rejected if `raw/post_map_sdc.rpt` does not show an 8.000 ns clock.",
]
(out / "COMMANDS.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"COMMANDS.md: {len(records)} verified stage command records")
