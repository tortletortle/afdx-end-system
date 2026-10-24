# bag_bmc40 CE analysis (step-27 FAIL)

Source: `formal/bag_bmc40/engine_0/trace_tb.v` + `trace.smtc` / `trace.vcd`
Wrapper: `formal/tx_vl_scheduler_bag.sv` (`bag_formal_top`, BAG_US=4, CYCLES_PER_US=1, NUM_TX_VL=4)
Fail: assert `(cyc - l_pop) >= BAG` at step **27**

## 0. Init snapshot (smtc/tb `initial`, before/at first edge)

| field | value | note |
|---|---|---|
| PI_rst_sync | 1 | $initstate assume rst=1 |
| dut.cycle_count | 4294967292 (`11111111111111111111111111111100`) | **not** meaningful until rst NBA; RTL resets on rst |
| dut.ifq_rd / ifq_wr | 1111 / 0111 | RTL **does** reset ifq ptrs on rst |
| dut.next_tx[0] | 4 | RTL **does not** reset `next_tx[]` |
| dut.next_tx[1] | 3 | RTL **does not** reset `next_tx[]` |
| dut.next_tx[2] | 3 | RTL **does not** reset `next_tx[]` |
| dut.next_tx[3] | 0 | RTL **does not** reset `next_tx[]` |
| dut.bag_arr[0] | 4 | RTL **does not** reset `bag_arr[]` |
| dut.bag_arr[1] | 4 | RTL **does not** reset `bag_arr[]` |
| dut.bag_arr[2] | 4 | RTL **does not** reset `bag_arr[]` |
| dut.bag_arr[3] | 4 | RTL **does not** reset `bag_arr[]` |

## 1. Input timeline (PI_* after each `cycle==N` NBA)

Convention: row `cycle=N` is the stimulus scheduled when the TB's `cycle` counter equals N (sby `trace_tb` style). `rst`/`fs` are values driven for the **next** sampling edge.

| cycle | rst | frame_start | builder_busy | sch_ack | len_err | port_ready | wrapper phase (model) |
|---|---|---|---|---|---|---|---|
| 0 | 0 | 0 | 0 | 0 | 0 | 0 | rst→0 (release) |
| 1 | 0 | 0 | 1 | 1 | 0 | 255 | cfg tick≈0 (VL0) |
| 2 | 0 | 0 | 1 | 1 | 0 | 255 | cfg tick≈1 (VL1) |
| 3 | 0 | 0 | 1 | 1 | 0 | 255 | cfg tick≈2 (VL2) |
| 4 | 0 | 0 | 0 | 1 | 0 | 255 | cfg tick≈3 (VL3) |
| 5 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈4 |
| 6 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈5 |
| 7 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈6 |
| 8 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈7 |
| 9 | 0 | 1 | 0 | 1 | 0 | 255 | run tick≈8 |
| 10 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈9 |
| 11 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈10 |
| 12 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈11 |
| 13 | 0 | 1 | 0 | 1 | 0 | 255 | run tick≈12 |
| 14 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈13 |
| 15 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈14 |
| 16 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈15 |
| 17 | 0 | 1 | 0 | 1 | 0 | 255 | run tick≈16 |
| 18 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈17 |
| 19 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈18 |
| 20 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈19 |
| 21 | 0 | 1 | 0 | 1 | 0 | 255 | run tick≈20 |
| 22 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈21 |
| 23 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈22 |
| 24 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈23 |
| 25 | 0 | 1 | 0 | 1 | 0 | 255 | run tick≈24 |
| 26 | 0 | 0 | 0 | 1 | 0 | 255 | run tick≈25 |

frame_start pulses at TB cycle indices: **[9, 13, 17, 21, 25]**

## 2. Wrapper phase model vs depth

| event | earliest step (cover evidence) |
|---|---|
| `run` (tick≥4) | cover @ **6** |
| first pop | after first grant+frame_start |
| second pop (`run && pop_ok && s_pop`) | cover @ **27** |
| bmc20 depth | **20** < 27 → assert **never arms** → **vacuous PASS** |

## 3. RTL reset facts (code read, no patch)

| state | reset on `rst_sync`? |
|---|---|
| `cycle_count` | yes → 0 |
| `ifq_rd/wr`, `ifq[]` | yes |
| `valid_map`, `inflight` | yes |
| `next_tx[]` | **no** — only `cfg_we` / `pop` writes |
| `bag_arr[]` | **no** — only `cfg_we` writes |

Simulation X risk: after rst, unread `next_tx`/`bag_arr` are X until cfg; wrapper programs VL0..3 on ticks 0..3 (`next_tx<=cycle_count`, `bag_arr<=4`), so **post-cfg** intervals should not depend on pre-rst garbage **if** cfg completes.

## 4. Classification

### Observed in this CE

1. **bmc20 vacuous**: second-pop cover at step 27 > depth 20. Not BAG evidence.
2. **frame_start coupling** (`assume frame_start == $past(start_vld && run)`): CE still has FS at [9, 13, 17, 21, 25]. Gaps between consecutive FS: 4, 4, 4, 4.
3. **Init anyseq** on `next_tx`/`bag_arr`/`ifq_*` visible in tb `initial`; ifq is cleared by rst, but next_tx/bag_arr rely on cfg. This matches category **(b)** residual risk for any path that grants before cfg or reads unprogrammed VL — wrapper should `assume (!enable)` until cfg done (already `enable=run` with tick≥4) and/or force multi-cycle rst.
4. Assert fails at step 27 on ghost-pop spacing `< BAG`. With FS gaps mostly 4, a `<4` failure implies either (i) ghost IFQ pop/push desync vs DUT (wrapper bug / category **a**), or (ii) two pops of same VL closer than BAG under legal due checks (category **c**).

### Verdict (time-box)

**Primary: (a) wrapper modeling** — ghost IFQ + `$past(start_vld)` coupling still allows CE where the **property state** (ghost last-pop) fires with Δcyc < BAG while DUT BAG rebase is on real `pop`/`next_tx`. Not proven as DUT early-grant.

**Secondary: (b) documented** — RTL does not reset `next_tx`/`bag_arr`; formal init shows arbitrary values. Post-cfg should overwrite all 4 VLs; no evidence yet that X/anyseq after cfg causes the step-27 fire. **Do not stop for RTL fix** on (b) alone (cfg path present).

**(c) 未排除（VCD 未能解码 start_vld/next_tx）**: no decoded proof that `start_vld` occurred with `cycle_count < next_tx[vl]` (due). Would need reliable VCD of `start_vld`/`start_vl`/`next_tx[vl]`; VCD scalar extract incomplete in this harness.

## 5. VCD scalar scrap (best-effort)

Matched ids: `{'n12': 'cfg_we', 'n63': 'cfg_we', 'n66': 'enable', 'n68': 'frame_start', 'n89': 'rst_sync', 'n101': 'sch_take', 'n107': 'start_vld', 'n112': 'enable', 'n114': 'frame_start', 'n124': 'rst_sync', 'n125': 'run', 'n135': 'sch_take', 'n141': 'start_vld'}`

- t=280: {'start_vld': None, 'enable': None, 'cfg_we': None, 'run': None, 'sch_take': None, 'frame_start': None, 'rst_sync': None}
- … (1 time points)

## 6. Follow-ups (if continuing C4)

1. Drop ghost IFQ; assert on `start_vld` spacing with bag from cfg only, or
2. Add `cover`/`assume` that first pop occurs by step ≤15 so bmc20 is non-vacuous, or
3. Export hierarchical VCD for `start_vld`/`next_tx` and re-classify (c) if due violated.

## 7. Claiming grade（时间盒到期）

**F — 不宣称任何 BAG 形式结论。**

| 项 | 结论 |
|---|---|
| cover | 可达（第二 grant ~26–27） |
| bmc20 | **vacuous（空真）** — 不得引用 |
| bmc40 | FAIL；主因 **(a) wrapper**；**(b)** 数组不复位已记录；**(c) 未排除（VCD 未能解码 start_vld/next_tx）** |
| RTL | **未改**；未以 early-grant 停问 |

重试（grant 锚点 + `frame_start==$past(start_vld)`）后 bmc40 仍 FAIL（2026-10-24 23:57）→ 时间盒内未收绿。

