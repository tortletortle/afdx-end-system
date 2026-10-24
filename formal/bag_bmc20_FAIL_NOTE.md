# bag_bmc20 FAIL history — wrapper bugs so far (not RTL)

## Round 1 — wrong anchor + mid-run rst + cfg thrash

- FAIL step 12 (`bag_bmc20/` first CE).
- Property measured `start_vld`→`start_vld`; RTL rebases BAG on **pop**
  (`frame_start|builder_len_err`), not on grant.
- CE raised `rst_sync` mid-run; continuous `cfg_we` / `cfg_bag_only` thrashed ghost BAG.
- Fix attempt: pop-anchor, freeze cfg in run phase, forbid mid-run rst, `BAG_UPDATE_EN=0`.

**Do not patch `tx_vl_scheduler.v`.**

## Round 2 — delayed rst_sync reg → DUT boots unrested

- bmc40 FAIL step 30 with `rst_in` high but `rst_sync` reg still 0 at t0;
  CE init had garbage `ifq_rd/wr`, `cycle_count=0xFFFFFFFC`.
- Cover reached `pop_ok&&s_pop` at step 1 (vacuous).
- Fix: `rst_sync` is a top input (pool/rm style); fixed cfg on `tick` after reset.

## Round 3 — cover + bmc20 PASS; bmc40 still FAIL

- Cover: `run` @6; second-pop (`run&&pop_ok&&s_pop`) @27 (property can arm).
- bmc20 **PASS**; bmc40 **FAIL** step ~27 (`bag_bmc40/`).
- CE still shows free `frame_start` bursts / residual init noise on DUT arrays in smtc `initial`.
- Tried: top-input `rst_sync`, fixed cfg tick, `builder_len_err==0`, `frame_start==$past(start_vld)`.
- **Attribution (2026-10-24)**: treat as **wrapper modeling gap**, not RTL defect — do not patch `tx_vl_scheduler.v`. Grade **I**.
- If a later CE proves DUT grants before `next_tx` due: stop and ask user (plan C4 §3).
