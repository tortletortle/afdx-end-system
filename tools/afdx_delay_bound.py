#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AFDX ES 离线时延上界计算器（方向 A，任务 1）。

对照：
  L158 / ARINC 664 P7 §3.2.4.3 第一式与封顶：
      J = min(40 + Σ_j (20 + Lmax_j)·8 / Nbw, 500)  [μs]
  Nbw 规范原文为介质带宽（bit/s），不是有效载荷吞吐。
  本工具对 100 Mbps 与约 1 Gbps 两种 Nbw 都算；IF_MODE 只选主口径标签。

模型假设（与本仓库 RTL/TB 对齐，见脚本 --self-check 与对照文档）：
  * Lmax：DA 起算含 FCS 的 MAC 帧长（字节），与配置表一致。
  * BAG：配置表 BAG（μs）；调度器以线上 MAC 帧起始周期计（tx_vl_scheduler）。
  * 单输出口忙期最坏排队：该端口上全部 VL 的 Lmax 在选定 Nbw 下串行化时间。
  * 多片消息：应用载荷 8192 B 按 1472 B/片切，
      (片数−1)·BAG + 首片等待 + J + 末片串行化时间。
    首片等待默认 = max(该 VL 的 BAG, 同网口忙期 Lmax 串行化)：
      BAG 相位对齐是 commit→首片上线的主项（T82 单帧可见 ~1 ms 档）；
      争用口上串行化更大时取串行化。不得把该界写成「满足 2 ms」。

不读 RTL、不改 TB、不跑仿真。自检目标：T13w 注释 J=499.36 μs；
T82 8192 B 多片界 ≥ 日志 max commit_call_to_last_A。
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import defaultdict
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

NBW_100M = 100e6
NBW_1G = 1e9
JITTER_FIXED_US = 40.0
JITTER_CAP_US = 500.0
WIRE_OH_BYTES = 20  # §3.2.4.3 式内 (20 + Lmax)
FRAG_PAYLOAD_B = 1472
MSG_8192_B = 8192


@dataclass(frozen=True)
class VL:
    name: str
    lmax_b: int
    bag_us: float
    net: str  # "A" / "B" / "AB"（忙期按输出口拆，AB 计入两侧）
    port: int


def nbw_for_if_mode(if_mode: int) -> Tuple[float, str]:
    """主口径标签。两种 Nbw 始终都算；此处只标项目约定的主分母。

    IF_MODE=0：旧 100 Mbps 节拍模型 → 主用 100 Mbps
    IF_MODE=1：连续字节仿真约 1 Gbps → 主用 1 Gbps
    IF_MODE=2：PHY GMII；规范/配置抖动式仍按项目 100 Mbps 有效口径（介质/预算）
    """
    if if_mode == 1:
        return NBW_1G, "1Gbps(IF_MODE=1 wire-rate sim)"
    if if_mode in (0, 2):
        return NBW_100M, "100Mbps(IF_MODE=%d project/regulatory)" % if_mode
    raise ValueError("unsupported IF_MODE=%r (expect 0/1/2)" % if_mode)


def serialize_us(bytes_: float, nbw_bps: float) -> float:
    return bytes_ * 8.0 / nbw_bps * 1e6


def jitter_first_us(lmax_list: Sequence[int], nbw_bps: float) -> float:
    """§3.2.4.3 第一式（未封顶）。"""
    sigma = sum((WIRE_OH_BYTES + int(l)) for l in lmax_list)
    return JITTER_FIXED_US + serialize_us(sigma, nbw_bps)


def jitter_bound_us(lmax_list: Sequence[int], nbw_bps: float) -> float:
    return min(jitter_first_us(lmax_list, nbw_bps), JITTER_CAP_US)


def net_keys(v: VL) -> List[str]:
    """物理输出口（网 A/B）。抖动式与忙期按同网口 VL 集合求和，不是主机 port。"""
    return ["A", "B"] if v.net.upper() == "AB" else [v.net.upper()]


def group_by_net(vls: Sequence[VL]) -> Dict[str, List[VL]]:
    g: Dict[str, List[VL]] = defaultdict(list)
    for v in vls:
        for n in net_keys(v):
            g[n].append(v)
    return g


def n_frags(msg_b: int = MSG_8192_B, frag_b: int = FRAG_PAYLOAD_B) -> int:
    if msg_b <= 0:
        raise ValueError("msg_b must be positive")
    return int(math.ceil(msg_b / float(frag_b)))


def multi_fragment_bound_us(
    bag_us: float,
    j_us: float,
    last_lmax_b: int,
    nbw_bps: float,
    first_wait_us: float = 0.0,
    msg_b: int = MSG_8192_B,
    frag_b: int = FRAG_PAYLOAD_B,
) -> dict:
    """多片消息上界（工程分解，不是形式化 WCTT）。

    (片数−1)·BAG + 首片等待 + J + 末片串行化时间
    末片串行化按 last_lmax_b（默认末片应用载荷对应的 MAC Lmax，调用方给定）。
    """
    nf = n_frags(msg_b, frag_b)
    last_ser = serialize_us(last_lmax_b, nbw_bps)
    total = (nf - 1) * bag_us + first_wait_us + j_us + last_ser
    return {
        "n_frags": nf,
        "bag_us": bag_us,
        "first_wait_us": first_wait_us,
        "j_us": j_us,
        "last_lmax_b": last_lmax_b,
        "last_serialize_us": last_ser,
        "bound_us": total,
    }


def compute(vls: Sequence[VL], if_mode: int = 0) -> dict:
    if not vls:
        raise ValueError("empty VL table")
    primary_nbw, primary_label = nbw_for_if_mode(if_mode)
    lmax_all = [v.lmax_b for v in vls]

    nbws = [
        ("100Mbps", NBW_100M),
        ("1Gbps", NBW_1G),
    ]
    jitter = {}
    for name, nbw in nbws:
        first = jitter_first_us(lmax_all, nbw)
        bound = min(first, JITTER_CAP_US)
        jitter[name] = {
            "nbw_bps": nbw,
            "first_us": first,
            "bound_us": bound,
            "capped": first > JITTER_CAP_US,
        }

    # 每 VL：所属物理网口上的抖动界（同网口集合；主机 port 只作元数据）
    per_vl = []
    by_net = group_by_net(vls)
    for v in vls:
        row = {
            "name": v.name,
            "lmax_b": v.lmax_b,
            "bag_us": v.bag_us,
            "net": v.net,
            "port": v.port,
            "j_100Mbps_us": None,
            "j_1Gbps_us": None,
        }
        j100 = 0.0
        j1g = 0.0
        for n in net_keys(v):
            lmaxs = [p.lmax_b for p in by_net[n]]
            j100 = max(j100, jitter_bound_us(lmaxs, NBW_100M))
            j1g = max(j1g, jitter_bound_us(lmaxs, NBW_1G))
        row["j_100Mbps_us"] = j100
        row["j_1Gbps_us"] = j1g
        per_vl.append(row)

    busy = []
    for net, peers in sorted(by_net.items()):
        lmax_sum = sum(p.lmax_b for p in peers)
        entry = {
            "net": net,
            "n_vl": len(peers),
            "lmax_sum_b": lmax_sum,
            "serialize_100Mbps_us": serialize_us(lmax_sum, NBW_100M),
            "serialize_1Gbps_us": serialize_us(lmax_sum, NBW_1G),
            "j_100Mbps_us": jitter_bound_us([p.lmax_b for p in peers], NBW_100M),
            "j_1Gbps_us": jitter_bound_us([p.lmax_b for p in peers], NBW_1G),
            "host_ports": sorted({p.port for p in peers}),
        }
        busy.append(entry)

    # 多片：对每个 VL 用其 BAG 与所属网口 J；末片 Lmax = 末片载荷+47。
    multi = []
    for v in vls:
        rem = MSG_8192_B % FRAG_PAYLOAD_B
        last_pay = rem if rem != 0 else FRAG_PAYLOAD_B
        last_lmax = last_pay + 47
        n0 = net_keys(v)[0]
        peers = by_net[n0]
        j_pri = jitter_bound_us([p.lmax_b for p in peers], primary_nbw)
        busy_ser = serialize_us(sum(p.lmax_b for p in peers), primary_nbw)
        # 首片等待：BAG 相位上界与忙期串行化取大（见模块头注释 / T82 对照）
        first_wait = max(float(v.bag_us), busy_ser)
        mf = multi_fragment_bound_us(
            bag_us=v.bag_us,
            j_us=j_pri,
            last_lmax_b=last_lmax,
            nbw_bps=primary_nbw,
            first_wait_us=first_wait,
        )
        mf["vl"] = v.name
        mf["primary_nbw_label"] = primary_label
        mf["first_wait_rule"] = "max(BAG, busy_serialize)"
        mf["busy_serialize_us"] = busy_ser
        multi.append(mf)

    return {
        "if_mode": if_mode,
        "primary_nbw_bps": primary_nbw,
        "primary_nbw_label": primary_label,
        "n_vl": len(vls),
        "jitter_global": jitter,
        "per_vl": per_vl,
        "busy_period": busy,
        "multi_fragment_8192": multi,
        "notes": [
            "Nbw 规范义为介质带宽；TB T13w 第一式写死 /100 Mbps。",
            "IF_MODE=1 仿真约 1 Gbps 字节节拍，不等于把规范 Nbw 改成 1 Gbps。",
            "多片界为工程分解；T82 有日志对照时可升 P；禁止写成满足 2 ms（官方口径 OPEN）。",
        ],
    }


# ---- presets / I/O ---------------------------------------------------------

def preset_t13w() -> List[VL]:
    """tb_t13w_worst.v：6 VL，3×1518 + 3×356，BAG=4 ms，单口争用。"""
    out = []
    for i in range(3):
        out.append(VL("VL%d" % i, 1518, 4000.0, "A", 0))
    for i in range(3, 6):
        out.append(VL("VL%d" % i, 356, 4000.0, "A", 0))
    return out


def preset_t13() -> List[VL]:
    """T13 最大帧场景：单 VL Lmax=1518（BAG 取 TB 写入 256 μs，仅作表项）。"""
    return [VL("VL0", 1518, 256.0, "A", 0)]


def preset_t05b() -> List[VL]:
    """T05b：32 VL，Lmax=303，BAG=828 μs。"""
    return [VL("VL%d" % i, 303, 828.0, "A", i) for i in range(32)]


def preset_t42() -> List[VL]:
    """T42：16 VL，Lmax=1024+47=1071，BAG=1 ms，IF_MODE=2。"""
    return [VL("VL%d" % i, 1071, 1000.0, "AB", i) for i in range(16)]


def preset_t82() -> List[VL]:
    """T82：单 VL，Lmax=1518，合法 BAG=1 ms，IF_MODE=2（tb_t82_tx8k_gmii.v）。"""
    return [VL("VL0", 1518, 1000.0, "AB", 0)]


PRESETS = {
    "t13w": preset_t13w,
    "t13": preset_t13,
    "t05b": preset_t05b,
    "t42": preset_t42,
    "t82": preset_t82,
}


def load_csv(path: str) -> List[VL]:
    """CSV 列：name,lmax_b,bag_us,net,port"""
    vls: List[VL] = []
    with open(path, newline="", encoding="utf-8") as f:
        r = csv.DictReader(f)
        for row in r:
            vls.append(
                VL(
                    name=row["name"].strip(),
                    lmax_b=int(row["lmax_b"]),
                    bag_us=float(row["bag_us"]),
                    net=row["net"].strip(),
                    port=int(row["port"]),
                )
            )
    return vls


def self_check() -> int:
    """复现 T13w 注释：J = 40 + (3*1538 + 3*376)*0.08 = 499.36 μs。
    并核对 T82 多片界 ≥ 日志 max commit_call_to_last_A（6161736 ns）。
    """
    vls = preset_t13w()
    r = compute(vls, if_mode=0)
    j = r["jitter_global"]["100Mbps"]["bound_us"]
    expect = 499.36
    ok_j = abs(j - expect) < 1e-9
    ser = r["busy_period"][0]["serialize_100Mbps_us"]
    print("SELF-CHECK T13w")
    print("  J_100Mbps_us = %.6f  (expect %.2f)  %s" % (j, expect, "PASS" if ok_j else "FAIL"))
    print("  busy_serialize_100Mbps_us = %.6f" % ser)
    print("  J_1Gbps_us = %.6f" % r["jitter_global"]["1Gbps"]["bound_us"])
    manual = 40.0 + (3 * 1538 + 3 * 376) * 0.08
    print("  manual_first = %.6f" % manual)

    r82 = compute(preset_t82(), if_mode=2)
    m = r82["multi_fragment_8192"][0]
    # post_fix4_full140_20261018_011708/T82_console.txt index=15
    t82_max_us = 6161736 / 1000.0
    ok_m = m["bound_us"] + 1e-9 >= t82_max_us
    print("SELF-CHECK T82 multi-frag 8192B")
    print(
        "  bound_us = %.6f  measured_max_us = %.6f  (bound>=meas) %s"
        % (m["bound_us"], t82_max_us, "PASS" if ok_m else "FAIL")
    )
    print(
        "  n_frags=%d first_wait=%.4f J=%.4f last_ser=%.4f"
        % (m["n_frags"], m["first_wait_us"], m["j_us"], m["last_serialize_us"])
    )
    return 0 if (ok_j and ok_m) else 1


def fmt_report(r: dict) -> str:
    lines = []
    lines.append("IF_MODE=%d  primary=%s" % (r["if_mode"], r["primary_nbw_label"]))
    lines.append("VLs=%d" % r["n_vl"])
    for name, g in r["jitter_global"].items():
        lines.append(
            "J[%s]: first=%.4f us  bound=%.4f us  capped=%s"
            % (name, g["first_us"], g["bound_us"], g["capped"])
        )
    lines.append("per-VL jitter bounds:")
    for row in r["per_vl"]:
        lines.append(
            "  %s Lmax=%d BAG=%.0fus net=%s port=%d  J100=%.4f  J1G=%.4f"
            % (
                row["name"],
                row["lmax_b"],
                row["bag_us"],
                row["net"],
                row["port"],
                row["j_100Mbps_us"],
                row["j_1Gbps_us"],
            )
        )
    lines.append("busy-period (serialize all Lmax on physical net):")
    for b in r["busy_period"]:
        lines.append(
            "  net=%s n=%d Lmax_sum=%d  ser100=%.4fus ser1G=%.4fus  J100=%.4f J1G=%.4f"
            % (
                b["net"],
                b["n_vl"],
                b["lmax_sum_b"],
                b["serialize_100Mbps_us"],
                b["serialize_1Gbps_us"],
                b["j_100Mbps_us"],
                b["j_1Gbps_us"],
            )
        )
    lines.append("multi-fragment 8192B (primary Nbw):")
    for m in r["multi_fragment_8192"]:
        lines.append(
            "  %s: n_frags=%d bound=%.4fus  (= (%d-1)*BAG + first_wait + J + last_ser)"
            % (m["vl"], m["n_frags"], m["bound_us"], m["n_frags"])
        )
    for n in r["notes"]:
        lines.append("NOTE: " + n)
    return "\n".join(lines)


def main(argv: Optional[Sequence[str]] = None) -> int:
    p = argparse.ArgumentParser(description="AFDX ES offline delay-bound calculator")
    p.add_argument("--self-check", action="store_true", help="reproduce T13w J=499.36us")
    p.add_argument("--preset", choices=sorted(PRESETS.keys()), help="built-in VL table")
    p.add_argument("--csv", help="VL table CSV: name,lmax_b,bag_us,net,port")
    p.add_argument("--if-mode", type=int, default=0, choices=(0, 1, 2))
    p.add_argument("--json", action="store_true", help="emit JSON")
    args = p.parse_args(argv)

    if args.self_check:
        return self_check()

    if args.csv:
        vls = load_csv(args.csv)
    elif args.preset:
        vls = PRESETS[args.preset]()
    else:
        p.error("need --preset, --csv, or --self-check")
        return 2

    r = compute(vls, if_mode=args.if_mode)
    if args.json:
        print(json.dumps(r, indent=2, ensure_ascii=False))
    else:
        print(fmt_report(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
