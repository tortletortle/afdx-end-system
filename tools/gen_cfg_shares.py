#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 O-27 算 TX VL 的 Q20 份额并输出 0x0480~0x04FF 前门写入 CSV。

例：python tools/gen_cfg_shares.py --n 128 --lmax 1518 --bag-us 8000 --allow-overload --out sim/vec/t05c_cfg_shares.csv
CSV 每行一个启用的 VL：字地址, VL 序号, Q20 份额；先写份额及 TX w1~w4，最后写 w0.valid。
默认拒绝超额映像；只有 T05c 负例测试显式传 --allow-overload 才可输出超额 CSV。
只有活跃 VL 输出行；其余 VL 的 w0.valid 应为 0。脚本只算份额，不能代替 RTL/T05c 验收。
"""
import argparse
import csv
import sys
from pathlib import Path

from bag_model import OH, Q20, metrics

BASE_ADDR = 0x0480
MAX_TX_VL = 128
MAX_SHARE = (1 << 21) - 1


def share_q20(lmax: int, bag_us: int, link_mbps: int = 100) -> int:
    if not (64 <= lmax <= 1518):
        raise ValueError("Lmax 必须是含 FCS 的以太帧长，64~1518 B")
    if bag_us <= 0:
        raise ValueError("BAG 必须是正整数 μs")
    if link_mbps not in (100, 1000):
        raise ValueError("link_mbps 必须为 100（旧字节槽）或 1000（125MHz PHY GMII）")
    # 100 Mbps => 每 μs 100 bit；线上字节数为 (Lmax+20)。逐 VL 向上取整，绝不先合计。
    n = (lmax + OH) * 8 * Q20
    den = bag_us * link_mbps
    share = (n + den - 1) // den
    if share > MAX_SHARE:
        raise ValueError("单 VL 份额超过 21 bit 前门字段；应在软件侧先拒绝非法 BAG")
    assert metrics(1, lmax + OH, bag_us, link_bps=link_mbps * 1000000)["q20"] == share
    return share


def selftest() -> None:
    expected = [
        (32, 303, 8000, 3387, 108384, True),
        (32, 303, 828, 32724, 1047168, True),
        (128, 1518, 8000, 16128, 2064384, False),
        (1, 79, 1000, 8305, 8305, True),
    ]
    for n, lmax, bag, per_vl, total, legal in expected:
        val = share_q20(lmax, bag)
        assert (val, n * val, n * val <= Q20) == (per_vl, total, legal)
    for lmax, bag in ((63, 1000), (1519, 1000), (79, 0), (1518, 1)):
        try:
            share_q20(lmax, bag)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid config accepted")
    print("CFG_SHARE MODEL PASS: T05a/b/c + T22a, invalid range rejected")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--n', type=int, default=64, help='active VL count, 1..128 (default 64: legal 8ms full frame)')
    p.add_argument('--start-vl', type=int, default=0, help='first VL index, default 0')
    p.add_argument('--lmax', type=int, default=1518, help='Ethernet frame bytes incl. FCS')
    p.add_argument('--bag-us', type=int, default=8000, help='BAG in integer microseconds')
    p.add_argument('--link-mbps', type=int, choices=(100, 1000), default=100,
                   help='physical link capacity used to normalize Q20; IF_MODE=2 at 125MHz uses 1000')
    p.add_argument('--out', type=Path, help='output CSV path, default stdout')
    p.add_argument('--allow-overload', action='store_true', help='negative test only: emit an over-budget CSV')
    p.add_argument('--selftest', action='store_true', help='verify 4 published vectors & bad args')
    args = p.parse_args()
    if args.selftest:
        selftest()
        return 0
    if not (1 <= args.n <= MAX_TX_VL and 0 <= args.start_vl < MAX_TX_VL and
            args.start_vl + args.n <= MAX_TX_VL):
        p.error("VL 区间必须落在 0..127 内，且 n >= 1")
    try:
        share = share_q20(args.lmax, args.bag_us, args.link_mbps)
    except ValueError as e:
        p.error(str(e))
    total = args.n * share
    if total > Q20 and not args.allow_overload:
        p.error(f"CFG_SUM={total}>{Q20} 超额；正式映像拒绝生成。仅 T05c 负例使用 --allow-overload")
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        output = args.out.open('w', newline='', encoding='utf-8')
    else:
        output = sys.stdout
    with output if args.out else _no_close(output) as f:
        writer = csv.writer(f, lineterminator='\n')
        writer.writerow(['word_addr', 'vl_index', 'q20_share'])
        for vl in range(args.start_vl, args.start_vl + args.n):
            writer.writerow([f'0x{BASE_ADDR + vl:04X}', vl, share])
    print(f'CFG_SHARE: n={args.n}, Lmax={args.lmax} B, BAG={args.bag_us} us, link={args.link_mbps} Mbps; '
          f'each={share}, CFG_SUM={total}/{Q20}, '
          f'{"LEGAL" if total <= Q20 else "REJECT BAG_OVF"}', file=sys.stderr)
    return 0


class _no_close:
    def __init__(self, stream):
        self.stream = stream
    def __enter__(self):
        return self.stream
    def __exit__(self, exc_type, exc, tb):
        return False


if __name__ == '__main__':
    sys.exit(main())
