# Continue3 - command record (2026-09-25)

All PowerShell bridge calls explicitly changed to `C:/Workspace/diansai`; the bridge's default command cwd is elsewhere.
No git commit/push/reset was used. Full raw output and true child-process exit codes are in `raw/`.

## Preparation (actually executed)

1. MCP `initialize`, `notifications/initialized`, `tools/list`, then `read_files` for `out/arena-debug/MISSION-CONTINUE3.md` and the four required reports.
2. `run_command`: create `out/arena-debug/continue3/backup/rtl/{common,top}` and copy the two source files *before* editing; compare SHA-256. Exit code 0.
3. MCP `apply_patch` with both original SHA-256 version guards: `rtl/common/rst_sync.v` and `rtl/top/AFDX_top.v`.
4. `powershell -NoProfile -ExecutionPolicy Bypass -File out/arena-debug/continue3/prepare.ps1`: isolated 24-file source snapshot and copied Quartus/Questa inputs; exit code 0.
5. `python out/arena-debug/continue3/make_patch.py`: `git diff --no-index` (no repository mutation), `git apply --check` and isolated replay under `continue3/replay/`; check/apply rc=0, both replay files byte-identical. See `raw/patch_verify.log`.
6. `python out/arena-debug/continue3/verify_rollback.py`: isolated reverse apply of candidate patch, rc=0 and both recovered files byte-identical to backups; this did **not** yet modify live RTL. See `raw/patch_verify.log` lines 7–10 and `replay_undo/`.

**Recovered preparation events:** First MCP `apply_patch` for auxiliary test files failed preflight because `continue3/sim/tb/` did not exist; raw error is `raw/setup_patch_failure.log`, and no partial source changes resulted. After creating the parent, the same patch succeeded. During later backup of the **official STA Tcl** (bridge `cmd_1790331217754_37`), a PowerShell single-quoted `$o` inadvertently created a *temporary literal* `C:/Workspace/diansai/$o/backup/...` location. Bridge `cmd_1790331247774_38` checked it contained exactly the one intended file, copied it to `continue3/backup/elinx/prj/quartus/sta_post_map.tcl`, verified SHA-256 `a630b96074817e607b14fda0c678eea397d58c82b9567a83ec8f627903124a00` and removed the temporary directory. All retained outputs are under `continue3/`. The same first call archived the measured-worse experiment as `timing_attempt.patch` and `RESULTS-timing-attempt.json` before `fixes.patch` was replaced.

## Tool stages (from `COMMANDS.jsonl`)

| Stage | Child rc | Wall (s) | Raw stdout / stderr |
|---|---:|---:|---|
| `lint_top` | 0 | 0.9 | `raw/lint_top.stdout.log` / `raw/lint_top.stderr.log` |
| `lint_reset` | 0 | 0.1 | `raw/lint_reset.stdout.log` / `raw/lint_reset.stderr.log` |
| `compile` | 0 | 5.2 | `raw/compile.stdout.log` / `raw/compile.stderr.log` |
| `reset_tb` | 0 | 5 | `raw/reset_tb.stdout.log` / `raw/reset_tb.stderr.log` |
| `t01` | 0 | 74.6 | `raw/t01.stdout.log` / `raw/t01.stderr.log` |
| `t11` | 0 | 4.1 | `raw/t11.stdout.log` / `raw/t11.stderr.log` |
| `t11g` | 0 | 4.5 | `raw/t11g.stdout.log` / `raw/t11g.stderr.log` |
| `synth` | 0 | 250.3 | `raw/synth.stdout.log` / `raw/synth.stderr.log` |
| `map` | 0 | 964.2 | `raw/map.stdout.log` / `raw/map.stderr.log` |
| `sta` (candidate post-map) | 0 | 71.0 | `raw/sta.stdout.log` / `raw/sta.stderr.log` |
| `sta_guard` (official script, candidate netlist) | 0 | 58.2 | `raw/sta_guard.stdout.log` / `raw/sta_guard.stderr.log` |
| `guard_selftest` (8 ns / 1 ns report fixtures) | 0 | 0.6 | `raw/guard_selftest.stdout.log` / `raw/guard_selftest.stderr.log` |

Actual executable, argument string and cwd for each stage:

### lint_top

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3`
- command: `"C:/Program Files (x86)/eHiWay/eLinx3.0/verilator/verilator.exe" -f lint_top.f`
- process exit code: `0`; elapsed seconds: `0.9`

### lint_reset

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3`
- command: `"C:/Program Files (x86)/eHiWay/eLinx3.0/verilator/verilator.exe" -f lint_reset.f`
- process exit code: `0`; elapsed seconds: `0.1`

### compile

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3/sim`
- command: `"C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe" -c -do "source compile.tcl"`
- process exit code: `0`; elapsed seconds: `5.2`

### reset_tb

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3/sim`
- command: `"C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe" -c -do "source run_one.tcl"`
- process exit code: `0`; elapsed seconds: `5`

### t01

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3/sim`
- command: `"C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe" -c -do "source run_one.tcl"`
- process exit code: `0`; elapsed seconds: `74.6`

### t11

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3/sim`
- command: `"C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe" -c -do "source run_one.tcl"`
- process exit code: `0`; elapsed seconds: `4.1`

### t11g

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3/sim`
- command: `"C:/altera_pro/26.1.1/questa_fse/win64/vsim.exe" -c -do "source run_one.tcl"`
- process exit code: `0`; elapsed seconds: `4.5`

### synth

- cwd: `C:/Workspace/diansai/out/arena-debug/continue3`
- command: `"C:/Program Files (x86)/eHiWay/eLinx3.0/bin/shell/bin/eLinx_synthesis.exe" -s C:/Workspace/diansai/elinx/prj/AFDX_top_synth.ys -l C:/Workspace/diansai/out/arena-debug/continue3/raw/synth.elinx.log`
- process exit code: `0`; elapsed seconds: `250.3`

### map / sta / sta_guard / guard_selftest

- `map`: cwd `.../continue3/project`; `"C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_map.exe" AFDX_top -c AFDX_top`; child rc=0, 964.2 s. MCP `cmd_1790330024336_17` started it; full actual args/cwd/return code in `COMMANDS.jsonl`.
- `sta`: same cwd; `"C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_sta.exe" -t sta_continue3.tcl`; child rc=0, 71.0 s; raw `post_map_{sdc,fmax,setup,setup_summary}.rpt`. MCP `cmd_1790331005280_34`.
- `sta_guard`: same cwd; `DIANSAI_STA_OUT=C:/Workspace/diansai/out/arena-debug/continue3/raw/guarded`; `"C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_sta.exe" -t C:/Workspace/diansai/elinx/prj/quartus/sta_post_map.tcl`; child rc=0, 58.2 s. MCP `cmd_1790331299507_39`. `raw/guarded/` contains the actual official-script reports. **Only the rejected-candidate post-map netlist existed at that moment; this is not a post-rollback remeasurement.**
- `guard_selftest`: same cwd; `"C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_sh.exe" -t guard_selftest.tcl`; child rc=0, 0.6 s. MCP `cmd_1790331366645_40`. The Tcl fixture applies the **same helper** to `raw/guarded/post_map_sdc.rpt` (8 ns) and the historical `../continue2/sta/default_1ns_no_sdc/post_map_sdc.rpt` (1 ns), requiring rejection of the latter. This is **not** a new missing-SDC TimeQuest run.

## Result, rollback, and final audit (all actually executed)

1. `python out/arena-debug/continue3/audit_results.py` (MCP `cmd_1790331083626_35` and again `cmd_1790331544500_45`): read real baseline/candidate reports and logs; all 13 **candidate evidence** checks true, but Fmax/WNS **worse**. Output is `RESULTS-timing-attempt.json`, not a whole-system PASS. `python .../check_inputs.py` (`cmd_1790331084439_36`) confirmed the measured 24/24 candidate snapshots plus SDC hashes; see `raw/input_binding.log`.
2. `python out/arena-debug/continue3/rollback_candidate.py` (MCP `cmd_1790331392637_41`): byte-check live source against tested candidate, `git apply --check --reverse timing_attempt.patch`, then `git apply --reverse timing_attempt.patch`, all rc=0; both **live** RTL files equal original backups byte-for-byte. See `raw/live_rollback.log`.
3. `python out/arena-debug/continue3/make_final_patch.py` (`cmd_1790331426859_42`): produce **final STA-only** `fixes.patch`; forward and reverse `git apply --check` and replay in `replay_final/`, `replay_final_undo/` each rc=0, byte comparisons pass. See `raw/final_patch_verify.log`.
4. `python out/arena-debug/continue3/cleanup_generated.py` (`cmd_1790331447978_43`): first copy Quartus `.map.rpt`/`.map.summary` to `raw/`, then remove **only** isolated `continue3/project/{db,incremental_db,output_files}` and `continue3/{sim/work,work}`. See `raw/cleanup.log`.
5. `python out/arena-debug/continue3/audit_final.py` (`cmd_1790331544500_45`): all 13 **final artifact/guard** checks true; `RESULTS.json`, `raw/audit_final.log`. This does not mean the design meets 125 MHz.
6. Update `REPORT.md` and this command record; `python out/arena-debug/continue3/make_sha256.py` is the **last file-producing audit step**, generating `SHA256SUMS.txt` for all retained files except the manifest itself.

An exit code of zero alone is not a simulation PASS: audit test verdict lines in the raw Questa console separately. STA numbers must be rejected if `raw/post_map_sdc.rpt` does not show an 8.000 ns clock.
