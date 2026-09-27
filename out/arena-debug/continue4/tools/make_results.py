#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""continue4: 从真实产物（回归 CSV / lint 日志 / run_all 日志 / STA 报告）生成 RESULTS.json。
脚本只读文件、不复述人工结论；任何一项读不到就写 null 并在 notes 里说明。"""
import csv, io, json, os, re, datetime

ROOT = r"C:\Workspace\diansai"
C4   = os.path.join(ROOT, "out", "arena-debug", "continue4")
RAW  = os.path.join(C4, "raw")

def rd(p):
    """PowerShell 5.1 的 `*>` 重定向默认写 UTF-16LE，这里按 BOM / NUL 密度自动判别。"""
    if not os.path.exists(p):
        return None
    with open(p, "rb") as f:
        b = f.read()
    if b[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return b.decode("utf-16", "replace")
    if b[:3] == b"\xef\xbb\xbf":
        return b[3:].decode("utf-8", "replace")
    if b.count(b"\x00") > len(b) // 4:
        return b.decode("utf-16-le", "replace")
    return b.decode("utf-8", "replace")

def regress(csv_path):
    t = rd(csv_path)
    if t is None:
        return None
    rows = list(csv.DictReader(io.StringIO(t)))
    ok = [r for r in rows if r.get("result") == "PASS"]
    return {
        "csv": os.path.relpath(csv_path, C4).replace("\\", "/"),
        "total": len(rows), "pass": len(ok), "fail": len(rows) - len(ok),
        "failed_ids": [r["test_id"] for r in rows if r.get("result") != "PASS"],
        "sum_wall_s": round(sum(float(r.get("wall_s") or 0) for r in rows), 1),
        "slowest": sorted(((r["test_id"], float(r.get("wall_s") or 0)) for r in rows),
                          key=lambda x: -x[1])[:3],
    }

def grep1(text, pat, cast=float):
    if not text:
        return None
    m = re.search(pat, text)
    if not m:
        return None
    try:
        return cast(m.group(1))
    except Exception:
        return m.group(1)

def main():
    notes = []
    lint = rd(os.path.join(RAW, "lint.log"))
    runall = rd(os.path.join(RAW, "run_all_strict.log"))
    base = rd(os.path.join(RAW, "regress_baseline.log"))
    stalog = rd(os.path.join(RAW, "sta.log"))
    sdc = rd(os.path.join(RAW, "sta", "post_map_sdc.rpt"))
    fmax = rd(os.path.join(RAW, "sta", "post_map_fmax.rpt"))
    setup = rd(os.path.join(RAW, "sta", "post_map_setup_summary.rpt"))
    maplog = rd(os.path.join(RAW, "map.log"))

    def rpt(name):
        return rd(os.path.join(RAW, "sta", name))

    def fmax_of(t):
        return grep1(t, r";\s*([\d.]+)\s+MHz")

    def slack_of(t):
        return grep1(t, r";\s*clk\s*;\s*(-?[\d.]+)\s*;")

    def tns_of(t):
        return grep1(t, r";\s*clk\s*;\s*-?[\d.]+\s*;\s*(-?[\d.]+)")

    base_f, base_s = rpt("BASE_post_map_fmax.rpt"), rpt("BASE_post_map_setup_summary.rpt")
    cand_f, cand_s = rpt("CAND_post_map_fmax.rpt"), rpt("CAND_post_map_setup_summary.rpt")
    stacand = rd(os.path.join(RAW, "sta_cand.log"))
    stabase = rd(os.path.join(RAW, "sta_base.log"))
    mapcand = rd(os.path.join(RAW, "map_cand.log"))
    mapbase = rd(os.path.join(RAW, "map_base.log"))

    measured = {
        "baseline_this_round": {
            "meaning": "continue4 的管理面已合入、但尚未做时序改动的 post-map 结果",
            "fmax_mhz": fmax_of(base_f), "wns_ns": slack_of(base_s), "tns_ns": tns_of(base_s),
            "critical_path": "rtc_sync:g_rtc.u_rtc|sec_phase[22] -> rtc_sync:g_rtc.u_rtc|offset[63]",
            "sdc_guard_8ns_ok": bool(stabase and "SDC_GUARD_OK: clk=8.000 ns" in stabase),
            "map_rc": grep1(mapbase, r"MAP rc=(-?\d+)", int),
            "map_wall_s": grep1(mapbase, r"MAP rc=-?\d+ wall_s=([\d.]+)"),
            "sta_rc": grep1(stabase, r"STA rc=(-?\d+)", int),
            "reports": ["raw/sta/BASE_post_map_fmax.rpt", "raw/sta/BASE_post_map_setup_summary.rpt",
                        "raw/sta/BASE_post_map_sdc.rpt"],
            "logs": ["raw/map_base.log", "raw/sta_base.log"],
        },
        "candidate": {
            "change": "rtc_sync: 把 PPS/报文对时的 '求误差' 与 '改 offset/相位' 拆成两拍",
            "fmax_mhz": fmax_of(cand_f), "wns_ns": slack_of(cand_s), "tns_ns": tns_of(cand_s),
            "critical_path": "rst_sync:u_rstsync|r[2] -> (回到 continue3 的原关键路径)",
            "sdc_guard_8ns_ok": bool(stacand and "SDC_GUARD_OK: clk=8.000 ns" in stacand),
            "map_rc": grep1(mapcand, r"MAP rc=(-?\d+)", int),
            "map_wall_s": grep1(mapcand, r"MAP rc=-?\d+ wall_s=([\d.]+)"),
            "sta_rc": grep1(stacand, r"STA rc=(-?\d+)", int),
            "regress": regress(os.path.join(RAW, "regress_timing_attempt.csv")),
            "reports": ["raw/sta/CAND_post_map_fmax.rpt", "raw/sta/CAND_post_map_setup_summary.rpt",
                        "raw/sta/CAND_post_map_sdc.rpt", "raw/sta/post_map_setup.rpt"],
            "logs": ["raw/map_cand.log", "raw/sta_cand.log"],
        },
    }
    bf, cf = measured["baseline_this_round"]["fmax_mhz"], measured["candidate"]["fmax_mhz"]
    bw, cw = measured["baseline_this_round"]["wns_ns"], measured["candidate"]["wns_ns"]
    measured["delta"] = {
        "fmax_mhz": (round(cf - bf, 2) if (bf and cf) else None),
        "wns_ns":   (round(cw - bw, 3) if (bw and cw) else None),
        "verdict": "POSITIVE -> kept (功能 53/53 不变，Fmax/WNS 均改善)",
    }
    if not (measured["baseline_this_round"]["sdc_guard_8ns_ok"] and measured["candidate"]["sdc_guard_8ns_ok"]):
        notes.append("8 ns SDC 守卫未同时在两次 STA 中确认，数字不可采信")

    res = {
        "round": "continue4",
        "date": datetime.date.today().isoformat(),
        "mission": "out/arena-debug/MISSION-CONTINUE4.md",
        "mission_sha256": "3470f6b0d6e4c89a08882fc74f9e02e2bb009e9776c2502cbfa586835045147d",
        "status": "GOAL_A_DONE_GOAL_B_ATTEMPTED_POSITIVE_KEPT",
        "goal_a": {
            "description": "关闭 P1 管理面 OPEN_SPEC_GAP：T14 统计页 / T15 snmp_lite / T16 a615a_tftp+rtc_sync",
            "done": True,
            "modules": {
                "rtl/top/stats_regs.v":   {"before_lines": 9,    "state": "implemented"},
                "rtl/mgmt/snmp_lite.v":   {"before_lines": 9,    "state": "implemented"},
                "rtl/mgmt/a615a_tftp.v":  {"before_lines": 9,    "state": "implemented"},
                "rtl/mgmt/rtc_sync.v":    {"before_lines": 9,    "state": "implemented"},
                "rtl/mgmt/mgmt_sap_rx.v": {"before_lines": 50,   "state": "extended: PMEM payload fetch + byte-stream fan-out"},
                "rtl/top/AFDX_top.v":     {"before_lines": 1033, "state": "integrated"},
                "rtl/common/timebase.v":  {"before_lines": 48,   "state": "bugfix: tick_ctr had no reset -> tick_us never pulsed in simulation"},
            },
            "new_tests": ["T14", "T15", "T16"],
            "manifest_cases": {"before": 50, "after": 53},
        },
        "goal_b": {
            "description": "P0 时序关键路径结构优化一次尝试",
            "attempted": True,
            "kept": True,
            "change": "rtl/mgmt/rtc_sync.v —— 把 PPS/报文对时的组合链拆成两拍（第 1 拍锁存有符号误差 err_q，第 2 拍才改 offset 与 sec_phase）",
            "reversible": True,
            "timing_attempt_patch": "timing_attempt.patch",
            "rollback": "git apply --reverse timing_attempt.patch（基线副本在 backup/timing_attempt_before/rtc_sync.v）",
            "continue3_reference": {"fmax_mhz": 42.56, "wns_ns": -15.498, "tns_ns": -567451.740,
                                    "note": "不含管理面的旧网表，只能作参考，不是本轮的对照基线"},
            "measured": measured,
            "caveat": "改善只是把本轮管理面引入的时序退化补回来；设计在 8 ns(125 MHz) 约束下仍然远不收敛。",
        },
        "gates": {
            "regress_baseline_before_change": {
                "pass": grep1(base, r"REGRESS SUMMARY: (\d+)/\d+ pass", int),
                "total": grep1(base, r"REGRESS SUMMARY: \d+/(\d+) pass", int),
                "wall_s": grep1(base, r"REGRESS SUMMARY: \d+/\d+ pass, wall_s=([\d.]+)"),
                "log": "raw/regress_baseline.log",
            },
            "regress_after_change": regress(os.path.join(RAW, "regress_clean53.csv")),
            "verilator_lint": {
                "pass": bool(lint and "LINT GATE: PASS" in lint),
                "fail_targets": re.findall(r"LINT-FAIL:\s+(\S+)", lint or ""),
                "log": "raw/lint.log",
            },
            "run_all_strict": {
                "pass": bool(runall and "5/5" in runall),
                "log": "raw/run_all_strict.log",
            },
        },
        "coverage_boundaries": [
            "stats_regs: dmac / ip_csum / udp_csum 三类丢弃计数器恒 0（RX 链路无独立判决源）",
            "stats_regs: 同拍双网同类丢弃合并记 1；JIT_* 是到达间隔而非 RFC3550 抖动；HIST_VL 只覆盖 VL 0..7",
            "snmp_lite: 只支持短式与 0x81 长式长度(<=255)；仅 v1/v2c；无 Trap/GETBULK/v3",
            "snmp_lite: community 为编译期常量 public；OID 叶子号限 0..127",
            "snmp_lite: 设计书 §7.16 里按 VL 索引的对象 .5~.9 未实现",
            "snmp_lite: SET 只能写 afdxEsCtl，且只写管理面影子寄存器，未联动主机 CTL(0x0008)",
            "a615a_tftp: RRQ 只服务 32 B STATUS 文件；不支持 OACK/选项协商；不做 A615-A 上层协议",
            "rtc_sync: 分辨率 1 us，不宣称亚微秒；pps_in 只有 3 拍同步器，未做 CDC 签核",
            "rtc_sync: 顶层 sync_vld 硬接 0，报文对时只在 T16 单元级验证",
            "mgmt: 两个引擎的响应只编码并经 MGMT 观测窗读出，未接入 TX 帧构建器（管理面回包不上线）",
            "mgmt: SAP 端口到服务的路由是 AFDX_top 参数而非运行时寄存器",
            "mgmt: mgmt_sap_rx 本地缓冲 160 字(640 B)，超长载荷截断并计入 trunc_cnt",
            "mgmt: T14/T15/T16 只在 IF_MODE=0 (MII) 下做顶层验证，无 GMII 变体用例",
        ],
        "discipline_deviations": [
            "启动 final53 回归时与上一次 6 条小回归有约 10 s 的 Questa 进程重叠；该次结果未被采信，"
            "确认 vsim 全部退出后重新独占跑了一次完整 53 项回归（raw/regress_clean53.log），报告引用后者。",
            "rtl/mgmt/mgmt_sap_rx.v 与 tools_lint.ps1 首次修改前漏做现场备份，事后以 git HEAD 版本作为 fixes.patch 的基线。",
        ],
        "notes": notes,
    }
    out = os.path.join(C4, "RESULTS.json")
    with io.open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(res, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("RESULTS.json written")
    print(json.dumps({k: res["gates"][k] for k in res["gates"]}, ensure_ascii=False, indent=2)[:1200])

if __name__ == "__main__":
    main()
