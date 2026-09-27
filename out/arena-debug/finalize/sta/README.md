# STA: SUPERSEDED — this round's real TimeQuest run replaces the BLOCKED verdict

> **STATUS 2026-09-25 (MISSION-CONTINUE2): the "BLOCKED" conclusion below is OBSOLETE.**
> Top-level eLinx synthesis now completes with rc=0, a Quartus revision was created,
> `quartus_map` ran clean and **post-map TimeQuest produced real numbers**:
> **Fmax 42.56 MHz** against the required 125 MHz, setup **WNS -15.498 ns**,
> **TNS -567,451.740 ns**, hold WNS -0.128 ns, 71 in / 120 out unconstrained IO ports.
> (Earlier drafts of this note quoted 43.39 / -22.048 / -1,103,482.274.  Those came from a
> run where elinx/sdc/AFDX_top.sdc was missing from disk, so Quartus silently fell back to a
> default 1 ns clock.  Those reports are kept as a counter-example in
> ../../continue2/sta/default_1ns_no_sdc/ and must not be quoted.)
> The design is therefore **timing-FAIL, not timing-unknown**.
> Authoritative write-up: `../../continue2/STA.md`;
> raw reports: `../../continue2/sta/`; commands and exit codes: `../../continue2/COMMANDS.md`.
>
> What was actually wrong before: the blocker was **not** a tool limitation. There simply was
> no Quartus project, so `create_timing_netlist` had no active revision to load. Creating
> `elinx/prj/quartus/AFDX_top.qpf` + `.qsf` (EP4SGX230HF35C2, 24 Verilog sources,
> `elinx/sdc/AFDX_top.sdc`) removed the blocker.
>
> Boundaries that still hold: `quartus_fit` was **not** run, so every number above is a
> **post-map optimistic upper bound**, not sign-off; hold slack is meaningless without routing;
> the SDC still has no `set_input_delay`/`set_output_delay`, so the results cover
> register-to-register internal paths only; EP4SGX230HF35C2 is a stand-in device, not a
> project-specified part.

## Historical record (state before 2026-09-25, kept for audit)

# STA prerequisite and negative probe: BLOCKED_NO_PROJECT_OR_NETLIST

- TimeQuest exists: `C:/Program Files (x86)/eHiWay/eLinx3.0/bin/Passkey/bin/quartus_sta.exe`, Quartus II 13.0.1. Therefore **not** `BLOCKED_NO_TOOL`.
- Executed `quartus_sta -t out/arena-debug/finalize/sta/sta_probe.tcl`: rc=3, `create_timing_netlist` reports **"Can't find active revision"**; see `sta_probe_console.log`. The earlier `read_netlist`-API experiment was invalid for this executable and is separately retained as `sta_probe_unsupported_command.log`; it is not used to justify the status.
- eLinx top-level original flow (`elinx/prj/AFDX_top_synth.ys`) fails `memory_map` (`invalid vector<T> subscript`); the explicit-BRAM continuation after fixing the `tx_rm` reset arrays maps some RAM but then fails at `OPT_MUXTREE` with `ERROR: bad allocation`, rc=1; see `../synth/`. Pre-optimization cell counts and partial `altsyncram` counts are not a completed, auditable netlist or placed device utilization.
- No target FPGA/P&R active revision, complete synthesized top netlist, board pin map or measured external timing budget is present in the current project. `elinx/sdc/AFDX_top.edc` only constrains the specification's 8 ns internal clock, uncertainty and transition, plus an asynchronous PPS path. It has **no invented IO delays**. It is preliminary and has NOT been applied to a successful placement/time-analysis run.
- **WNS/TNS/Fmax/critical path/device area: N/A, NOT PASS.** Next: make all large top-level memories synthesizable for the chosen eLinx/device flow, finish top synthesis without `ERROR`, define device/pins and measured IO budgets, create/place a project revision, then run and archive setup/hold STA reports.
