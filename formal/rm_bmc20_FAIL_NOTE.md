# rm_bmc20 FAIL history — wrapper bugs, not RTL

## Round 1 — mid-run reset / unstable inputs

- FAIL step 16; CE drove `rst_sync` mid-run; no `$stable` while `!in_ready`.
- Fix: no mid-run rst; `$stable` payload; `out_ready=1`.

## Round 2/3 — unpacked ghost → anyseq

- `g_have[]` / arrays became `$mem` + `anyseq`; assert vs unconstrained ghost.
- Fix: scalar regs, `in_vl==0` only. Traces: `rm_bmc20_first_fail/`, `rm_bmc20_fail_v2/`, `rm_bmc20_fail_v3/`.

## Round 4 — wrong skew in property (this CE)

- FAIL step 12 after scalar rewrite. CE decode (`trace.smtc`):
  - accept1: sn=224, ts=`0xa6b020`, skew_exp=4 → skew=64
  - accept2: sn=224, ts=`0xa6afe0`, skew_exp=1 → skew=8
  - `|Δts|=64`
- DUT: `in_win = (dts_ab <= skew_q)` with **current** skew_q=8 → 64>8 → forward (same-SN beyond SkewMax). Correct per `rx_rm.v`.
- Property used **prior** forward's skew (64) → claimed drop → false FAIL.
- Fix: `in_win` uses `sk3` (skew latched for the exiting frame), matching DUT.

**Do not patch `rx_rm.v`.**

## Round 5 — ghost latched behind-only hist fill

- FAIL step 16 after skew fix. CE: primary sn=252 ts=`0x800000`, then behind sn=248
  (hist fill, table last_* unchanged), then sn=248 ts=0 again with tiny skew.
- DUT forwards the third (late_dup needs `|ts-last_ts|<=skew` vs table last_ts of 252).
- Ghost had wrongly stored (248,0) from the behind forward → false FAIL.
- Fix attempt via `dut.wr_ent_q` **failed**: Yosys made hierarchical ref implicit/anyseq.
- Final fix: SN-ring `behind` vs ghost (same rule as RTL); latch ghost only if `out_fwd && !behind`.
- After that: **bmc20 PASS**, **bmc40 PASS** (boolector). No RTL change.
