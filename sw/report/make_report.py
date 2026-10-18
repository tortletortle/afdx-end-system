#!/usr/bin/env python3
"""Design book §12.4: regress.csv + metrics/*.csv -> text indicator table.
Does not claim 95% line coverage or draw waveforms.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8", errors="replace") as f:
        return list(csv.DictReader(f))


def sum_int_col(rows: list[dict[str, str]], key: str) -> int:
    n = 0
    for r in rows:
        try:
            n += int(r.get(key, "0") or 0)
        except ValueError:
            pass
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--regress", default="sim/out/regress.csv")
    ap.add_argument("--metrics", default="sim/out/metrics")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    regress = Path(args.regress)
    metrics = Path(args.metrics)
    out = Path(args.out) if args.out else metrics / "summary.txt"

    lines: list[str] = []
    lines.append("AFDX ES verification summary (design book 12.4)")
    lines.append("Not a 95% coverage close-out. Not Fit/STA.")
    lines.append("")
    rows = read_csv(regress)
    if rows:
        npass = sum(1 for r in rows if r.get("result") == "PASS")
        lines.append(f"regress: {npass}/{len(rows)} PASS  file={regress}")
        for r in rows:
            lines.append(
                f"  {r.get('test_id','?'):5} {r.get('result','?'):4}  {r.get('wall_s','?')}s  {r.get('summary','')}"
            )
    else:
        lines.append(f"regress: missing {regress}")

    ic = read_csv(metrics / "cover_ic.csv")
    rm = read_csv(metrics / "cover_rm.csv")
    lines.append("")
    lines.append("12.3 hand bins (bind final dump, summed):")
    if ic:
        lines.append(
            "  IC  ok={0} reset={1} lost1={2} ooo={3} first_fail={4} netA={5} netB={6}".format(
                sum_int_col(ic, "ok"),
                sum_int_col(ic, "reset"),
                sum_int_col(ic, "lost1"),
                sum_int_col(ic, "ooo"),
                sum_int_col(ic, "first_fail"),
                sum_int_col(ic, "net_a"),
                sum_int_col(ic, "net_b"),
            )
        )
    else:
        lines.append("  IC  (no cover_ic.csv)")
    if rm:
        lines.append(
            "  RM  fwd={0} dup={1} skew={2} bypass={3}".format(
                sum_int_col(rm, "fwd"),
                sum_int_col(rm, "dup"),
                sum_int_col(rm, "skew"),
                sum_int_col(rm, "bypass"),
            )
        )
    else:
        lines.append("  RM  (no cover_rm.csv)")
    flt = read_csv(metrics / "cover_flt.csv")
    if flt:
        lines.append(
            "  FLT pass={0} unconf={1} net={2} lmax={3} vlid={4}".format(
                sum_int_col(flt, "pass"),
                sum_int_col(flt, "unconf"),
                sum_int_col(flt, "net"),
                sum_int_col(flt, "lmax"),
                sum_int_col(flt, "vlid"),
            )
        )
    rsrc = read_csv(metrics / "cover_rsrc.csv")
    if rsrc:
        lines.append(
            "  RSRC free0={0} free1={1} free2={2} >2={3} sample={4} q={5} ovf={6} drop={7}".format(
                sum_int_col(rsrc, "free0"),
                sum_int_col(rsrc, "free1"),
                sum_int_col(rsrc, "free2"),
                sum_int_col(rsrc, "free_gt2"),
                sum_int_col(rsrc, "sample"),
                sum_int_col(rsrc, "queue"),
                sum_int_col(rsrc, "ovf"),
                sum_int_col(rsrc, "pdrop"),
            )
        )
    hand = metrics / "cover_hand.csv"
    if hand.is_file():
        lines.append(f"  TX  {hand.read_text(encoding='utf-8', errors='replace').strip()}")
    leng = read_csv(metrics / "cover_len.csv")
    if leng:
        lines.append(
            "  LEN L8={0} L17={1} L18={2} L19={3} L1470={4} L1471={5} SN1={6} SN2={7} SN254={8} SN255={9}".format(
                sum_int_col(leng, "len8"),
                sum_int_col(leng, "len17"),
                sum_int_col(leng, "len18"),
                sum_int_col(leng, "len19"),
                sum_int_col(leng, "len1470"),
                sum_int_col(leng, "len1471"),
                sum_int_col(leng, "sn1"),
                sum_int_col(leng, "sn2"),
                sum_int_col(leng, "sn254"),
                sum_int_col(leng, "sn255"),
            )
        )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(out.read_text(encoding="utf-8"), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
