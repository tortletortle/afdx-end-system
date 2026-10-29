#!/usr/bin/env python3
"""Draw the afdx_app_top wrapper block diagram -> doc/submit/figs/fig_app_top.png (PIL, no mermaid needed)."""
from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "doc/submit/figs/fig_app_top.png"


def font(size: int, bold: bool = False):
    for name in ("C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simsun.ttc"):
        if Path(name).is_file():
            return ImageFont.truetype(name, size)
    return ImageFont.load_default()


W, H = 1500, 760
img = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(img)
f_title, f_box, f_small = font(22, True), font(19, True), font(16)

BLUE, GREEN, GREY, ORANGE = (222, 235, 250), (226, 242, 226), (240, 240, 240), (253, 240, 215)
DARK = (40, 40, 40)
LOOP = (160, 60, 30)


def box(x, y, w, h, title, lines=(), fill=BLUE):
    d.rounded_rectangle([x, y, x + w, y + h], radius=8, outline=(40, 60, 100), width=2, fill=fill)
    d.text((x + w / 2, y + 12), title, font=f_box, fill=(10, 20, 60), anchor="mt")
    for i, ln in enumerate(lines):
        d.text((x + w / 2, y + 46 + i * 24), ln, font=f_small, fill=(30, 30, 30), anchor="mt")


def head(x2, y2, ang, color):
    for s in (-0.45, 0.45):
        d.line([x2, y2, x2 - 14 * math.cos(ang + s), y2 - 14 * math.sin(ang + s)], fill=color, width=3)


def arrow(x1, y1, x2, y2, label="", dy=-18, color=DARK):
    d.line([x1, y1, x2, y2], fill=color, width=3)
    head(x2, y2, math.atan2(y2 - y1, x2 - x1), color)
    if label:
        d.text(((x1 + x2) / 2, (y1 + y2) / 2 + dy), label, font=f_small, fill=(30, 30, 30), anchor="mm")


d.text((W / 2, 20), "评测封装 afdx_app_top：应用字节流（VLID + 载荷）进出，核心 AFDX_top 不改", font=f_title, fill=(10, 20, 60), anchor="mt")

# wrapper frame
d.rounded_rectangle([250, 70, 1250, 700], radius=12, outline=(120, 120, 120), width=2, fill=(250, 250, 250))
d.text((262, 78), "afdx_app_top", font=f_box, fill=(90, 90, 90))

# application side
box(20, 190, 190, 120, "应用 / 评测 TB", ["tx_data[7:0]  (入)", "tx_valid  (入)", "tx_ready  (出)"], GREY)
box(20, 470, 190, 120, "应用 / 评测 TB", ["rx_data[7:0]  (出)", "rx_valid  (出)", "rx_ready  (入)"], GREY)

# wrapper blocks
box(280, 170, 280, 160, "afdx_app_tx", ["收 VLID + 载荷", "载荷缓存 512x32（同步读）", "申请块 → 写 PMEM", "→ 写 MSG_WR"])
box(280, 440, 280, 160, "afdx_app_rx", ["轮询 126 个 VL 的 MSG_CNT", "读描述符 → 读 PMEM", "输出 VLID + 载荷", "→ 写 MSG_RD 释放"])
box(630, 100, 220, 120, "afdx_app_init", ["上电配置 128 TX VL", "+ 126 RX VL + SAP", "完成后 cfg_done=1"], ORANGE)
box(630, 300, 220, 140, "afdx_app_host_arb", ["主机访问仲裁", "优先级 init > tx > rx"], ORANGE)
box(990, 250, 230, 300, "AFDX_top（核心）", ["TX：BAG 调度 / 组帧", "双网复制 / MAC", "RX：查表 / 过滤", "IC / RM / 块池", "host_* 前门"], GREEN)

# connections
arrow(210, 250, 280, 250)
arrow(280, 520, 210, 520)
arrow(560, 250, 630, 340)
arrow(560, 520, 630, 410)
arrow(740, 220, 740, 300)
arrow(850, 350, 990, 350, "host 请求", dy=-16)
arrow(990, 400, 850, 400, "rdata / ack", dy=16)

# GMII loopback inside the wrapper: core TX (left) -> core RX (right), one U-shaped path
d.line([1040, 550, 1040, 640, 1170, 640, 1170, 556], fill=LOOP, width=3)
head(1170, 552, -math.pi / 2, LOOP)
d.text((1105, 655), "GMII A/B 内部回环（cfg_done 之后接通）", font=f_small, fill=LOOP, anchor="mt")

# observation ports
arrow(1220, 340, 1255, 340)
d.text((1260, 322), "gmii_tx_*_a/b", font=f_small, fill=(90, 90, 90))
d.text((1260, 346), "（观察口，非必需）", font=f_small, fill=(90, 90, 90))

d.text((W / 2, 725), "T92–T95 在本封装口测试（RTL 仿真，TB 以层次引用读内部计数器）；门级证据为 T88b。", font=f_small, fill=(60, 60, 60), anchor="mt")

OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print("wrote", OUT)
