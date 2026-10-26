#!/usr/bin/env python3
"""Generate judge-facing layout figures S2–S6 (tables/diagrams, not terminal shots)."""
from __future__ import annotations

import csv
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "doc/submit/figs"
WAVE = ROOT / "out/p9_freeze_dfac58a/wave_png"
METRICS = ROOT / "out/p9_freeze_dfac58a/metrics.json"


def font(size: int):
    for name in (
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simsun.ttc",
        "C:/Windows/Fonts/arial.ttf",
    ):
        p = Path(name)
        if p.is_file():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


def new_canvas(w: int, h: int, title: str):
    img = Image.new("RGB", (w, h), "white")
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, w - 1, 40], fill=(32, 56, 100))
    draw.text((16, 8), title, fill="white", font=font(18))
    draw.rectangle([0, 0, w - 1, h - 1], outline=(180, 180, 180))
    return img, draw


def draw_table(draw, x, y, col_w, row_h, headers, rows, f):
    cols = len(headers)
    # header
    for i, h in enumerate(headers):
        cx = x + sum(col_w[:i])
        draw.rectangle([cx, y, cx + col_w[i], y + row_h], outline=(90, 90, 90), fill=(235, 240, 248))
        draw.text((cx + 6, y + 6), h, fill=(20, 20, 20), font=f)
    for r, row in enumerate(rows):
        yy = y + (r + 1) * row_h
        for i, cell in enumerate(row):
            cx = x + sum(col_w[:i])
            bg = (255, 255, 255) if r % 2 == 0 else (248, 248, 248)
            draw.rectangle([cx, yy, cx + col_w[i], yy + row_h], outline=(90, 90, 90), fill=bg)
            draw.text((cx + 6, yy + 6), str(cell), fill=(20, 20, 20), font=f)


def s2_manifest_sample():
    man = ROOT / "sim/tests.manifest"
    rows = []
    for line in man.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        # id | ... formats vary; keep first token-ish
        parts = [p.strip() for p in s.replace(",", " ").split() if p.strip()]
        tid = parts[0] if parts else s[:12]
        rows.append([tid, "见 tests.manifest", "功能回归项"])
        if len(rows) >= 12:
            break
    img, draw = new_canvas(900, 520, "S2 测试清单摘录（排版示意，非终端截屏）")
    f = font(14)
    draw.text((16, 52), "来源：sim/tests.manifest（节选前若干项；全量以冻结回归 CSV 为准）", fill=(60, 60, 60), font=f)
    draw_table(draw, 16, 80, [120, 420, 320], 28, ["编号", "说明", "类别"], rows, f)
    img.save(OUT / "S2_manifest_table.png")


def s3_smoke_summary(m: dict):
    rows = [
        ["全量回归", f"{m['full_pass']['value']}/{m['full_n']['value']}", "Questa"],
        ["ModelSim SE 全量", str(m["se_full_pass"]["value"]), "SE"],
        ["双仿真器一致", str(m["dual_sim_match"]["value"]), "逐项对照"],
        ["门级 T88b", f"{m['gate_t88b_s1']['value']}/{m['gate_t88b_s2']['value']}/{m['gate_t88b_s3']['value']}", "S1/S2/S3"],
        ["T90 吞吐", f"RX去重 {m['t90_rx_dedup_mbps']['value']} Mbps", "公开口"],
        ["T89 ES时延合计", f"{m['t89_es_total_max_ns']['value']} ns", "公开口"],
    ]
    img, draw = new_canvas(900, 360, "S3 关键结果摘要（排版示意）")
    f = font(14)
    draw.text((16, 52), "数字来自冻结测试结果；本图仅作版面示意。", fill=(60, 60, 60), font=f)
    draw_table(draw, 16, 80, [220, 360, 280], 32, ["项", "结果", "备注"], rows, f)
    img.save(OUT / "S3_result_summary.png")


def s4_flow():
    steps = [
        "冒烟脚本",
        "全量回归\n(Questa)",
        "全量对照\n(ModelSim SE)",
        "双仿真器\n对照表",
        "冻结测试\n结果",
        "文档渲染",
    ]
    img, draw = new_canvas(980, 220, "S4 验证复现流程（排版示意）")
    f = font(13)
    x0, y0, bw, bh, gap = 20, 80, 130, 70, 18
    for i, s in enumerate(steps):
        x = x0 + i * (bw + gap)
        draw.rounded_rectangle([x, y0, x + bw, y0 + bh], radius=8, outline=(32, 56, 100), width=2, fill=(245, 248, 255))
        # multiline
        lines = s.split("\n")
        ty = y0 + 18 if len(lines) == 1 else y0 + 12
        for j, ln in enumerate(lines):
            draw.text((x + 12, ty + j * 18), ln, fill=(20, 20, 20), font=f)
        if i < len(steps) - 1:
            ax0 = x + bw + 2
            ax1 = x + bw + gap - 2
            mid = y0 + bh // 2
            draw.line([ax0, mid, ax1, mid], fill=(32, 56, 100), width=2)
            draw.polygon([(ax1, mid), (ax1 - 8, mid - 5), (ax1 - 8, mid + 5)], fill=(32, 56, 100))
    img.save(OUT / "S4_replay_flow.png")


def s5_package_tree():
    tree = [
        "提交包（示意）",
        "├─ rtl/                 # 可综合 RTL",
        "├─ sim/tb/              # Verilog 测试台",
        "├─ sim/env/             # BFM / 记分板",
        "├─ sw/golden/           # Python 黄金模型",
        "├─ elinx/               # 综合工程与报告",
        "├─ doc/submit/          # 技术文档与附图",
        "└─ evidence/<commit>/   # 冻结测试结果与波形",
    ]
    img, draw = new_canvas(900, 340, "S5 提交包结构（排版示意）")
    f = font(15)
    y = 60
    for line in tree:
        draw.text((28, y), line, fill=(20, 20, 20), font=f)
        y += 28
    img.save(OUT / "S5_package_tree.png")


def s6_synth(m: dict):
    rows = [
        ["综合工具", "eLinx", "—"],
        ["cells", str(m["cells"]["value"]), "综合规模"],
        ["altsyncram", str(m["altsyncram"]["value"]), "存储宏"],
        ["门级切片", "T88b 公开端口回环", "S1/S2/S3 均通过"],
        ["说明", "本作品不做时序签核与板级验证", "赛题未要求"],
    ]
    img, draw = new_canvas(900, 320, "S6 综合结果摘要（排版示意，非 GUI 截屏）")
    f = font(14)
    draw.text((16, 52), "正式 GUI 综合资源页仍须人工截取（见人工截图清单 M2）。", fill=(60, 60, 60), font=f)
    draw_table(draw, 16, 80, [180, 360, 320], 32, ["项", "数值/内容", "备注"], rows, f)
    img.save(OUT / "S6_synth_summary.png")


def copy_waves():
    mapping = {
        "T88_signals.png": "S8_T88_signals.png",
        "T90_signals.png": "S9_T90_signals.png",
        "T10_signals.png": "S10_T10_signals.png",
    }
    for src, dst in mapping.items():
        s = WAVE / src
        if not s.is_file():
            raise SystemExit(f"missing wave {s}")
        data = s.read_bytes()
        (OUT / dst).write_bytes(data)
        print("copied", src, "→", dst)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    m = json.loads(METRICS.read_text(encoding="utf-8"))["metrics"]
    s2_manifest_sample()
    s3_smoke_summary(m)
    s4_flow()
    s5_package_tree()
    s6_synth(m)
    copy_waves()
    print("PASS layout figs →", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
