#!/usr/bin/env python3
"""Build official-template tech report (docx + optional PDF) from 报告模板.docx.

- Preserves template paragraph styles (Heading 2 / Normal / List Paragraph).
- Fills {{metric:key}} from freeze metrics.json.
- Counts non-whitespace chars per capped section; writes delivery table.
- De-identifies absolute Windows paths / usernames in output text.
- PDF via Word COM when available.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Cm, Pt

ROOT = Path(__file__).resolve().parents[1]
ANCHOR = re.compile(r"\{\{metric:([a-zA-Z0-9_.-]+)\}\}")
ABS_PATH = re.compile(
    r"(?i)(?:[A-Z]:\\|\\\\)[^\s\"'<>|]+|(?:/Users|/home)/[^\s\"'<>|]+"
)
USERISH = re.compile(r"(?i)\b(tortl|Administrator)\b")


def count_chars(text: str) -> int:
    return sum(1 for c in text if not c.isspace())


def load_metrics(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    catalog = data.get("metrics") or {}
    return data, catalog


def fmt_metric(catalog: dict, key: str) -> str:
    if key not in catalog:
        return f"«MISSING:{key}»"
    entry = catalog[key]
    v = entry.get("value") if isinstance(entry, dict) else entry
    if v is None:
        return "null"
    return str(v)


def render(text: str, catalog: dict) -> tuple[str, set[str]]:
    missing: set[str] = set()

    def repl(m: re.Match[str]) -> str:
        key = m.group(1)
        if key not in catalog:
            missing.add(key)
        return fmt_metric(catalog, key)

    out = ANCHOR.sub(repl, text)
    out = ABS_PATH.sub("<path-redacted>", out)
    out = USERISH.sub("<user-redacted>", out)
    return out, missing


def set_run_font(run, east_asia: str = "宋体", ascii_font: str = "Times New Roman", size_pt: float | None = None):
    run.font.name = ascii_font
    r = run._element
    rPr = r.get_or_add_rPr()
    rFonts = rPr.get_or_add_rFonts()
    rFonts.set(qn("w:eastAsia"), east_asia)
    if size_pt is not None:
        run.font.size = Pt(size_pt)


def add_para(doc, text: str, style: str = "Normal", bold: bool = False, first_line: bool = False):
    p = doc.add_paragraph(style=style)
    if first_line and p.paragraph_format is not None:
        p.paragraph_format.first_line_indent = Cm(0.74)
    run = p.add_run(text)
    set_run_font(run)
    run.bold = bold
    return p


def add_heading_like(doc, text: str, style: str = "Normal"):
    """Template uses Normal for part titles and List Paragraph for numbered items."""
    p = doc.add_paragraph(style=style)
    run = p.add_run(text)
    set_run_font(run, size_pt=12)
    run.bold = True
    return p


def add_caption(doc, text: str):
    p = doc.add_paragraph(style="Normal")
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run(text)
    set_run_font(run, size_pt=10.5)
    run.italic = True
    return p


def try_add_picture(doc, path: Path, width_cm: float = 14.0) -> bool:
    if not path.is_file():
        add_para(doc, f"【图位待补：{path.name}】", style="Normal")
        return False
    p = doc.add_paragraph(style="Normal")
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run()
    run.add_picture(str(path), width=Cm(width_cm))
    return True


def _set_cell_border(cell) -> None:
    tc = cell._tc
    tcPr = tc.get_or_add_tcPr()
    tcBorders = tcPr.find(qn("w:tcBorders"))
    if tcBorders is None:
        tcBorders = tcPr.makeelement(qn("w:tcBorders"), {})
        tcPr.append(tcBorders)
    for edge in ("top", "left", "bottom", "right"):
        el = tcBorders.find(qn(f"w:{edge}"))
        if el is None:
            el = tcBorders.makeelement(qn(f"w:{edge}"), {})
            tcBorders.append(el)
        el.set(qn("w:val"), "single")
        el.set(qn("w:sz"), "4")
        el.set(qn("w:space"), "0")
        el.set(qn("w:color"), "000000")


def add_table(doc, headers: list[str], rows: list[list[str]]):
    table = doc.add_table(rows=1 + len(rows), cols=len(headers))
    # 模板未必含 Table Grid；手工描边以保留可读性
    for i, h in enumerate(headers):
        cell = table.rows[0].cells[i]
        cell.text = ""
        p = cell.paragraphs[0]
        run = p.add_run(h)
        set_run_font(run, size_pt=10.5)
        run.bold = True
        _set_cell_border(cell)
    for ri, row in enumerate(rows):
        for ci, val in enumerate(row):
            cell = table.rows[ri + 1].cells[ci]
            cell.text = ""
            p = cell.paragraphs[0]
            run = p.add_run(val)
            set_run_font(run, size_pt=10.5)
            _set_cell_border(cell)
    doc.add_paragraph()


def clear_body(doc: Document) -> None:
    body = doc.element.body
    for child in list(body):
        if child.tag == qn("w:sectPr"):
            continue
        body.remove(child)


def export_pdf_word_com(docx_path: Path, pdf_path: Path) -> tuple[bool, str]:
    try:
        import pythoncom
        from win32com.client import Dispatch
    except ImportError as e:
        return False, f"pywin32 missing ({e})"

    pythoncom.CoInitialize()
    word = None
    try:
        word = Dispatch("Word.Application")
        word.Visible = False
        word.DisplayAlerts = 0
        doc = word.Documents.Open(str(docx_path.resolve()), ReadOnly=True)
        # wdFormatPDF = 17
        pdf_path.parent.mkdir(parents=True, exist_ok=True)
        if pdf_path.exists():
            pdf_path.unlink()
        doc.SaveAs(str(pdf_path.resolve()), FileFormat=17)
        doc.Close(False)
        ver = str(word.Version)
        return True, f"Word COM {ver}"
    except Exception as e:
        return False, str(e)
    finally:
        if word is not None:
            try:
                word.Quit()
            except Exception:
                pass
        try:
            pythoncom.CoUninitialize()
        except Exception:
            pass


def build_sections(catalog: dict) -> dict[str, str]:
    """Return raw section texts (with metric anchors) for counting after render."""

    abstract = """本作品实现面向航电确定性以太网的AFDX（ARINC 664 Part 7）端系统协议逻辑，以FPGA RTL交付。公开网络口为双网GMII（A/B），主机侧为扩展寄存器与表项前门；默认配置支持128条发送虚拟链路与4096条接收虚拟链路能力声明，单时钟功能仿真按与千兆GMII线速匹配的125 MHz拍运行。功能覆盖五类：发送侧端口排队、BAG调度与帧构造；接收侧过滤、完整性检查（IC）与冗余管理（RM）；主机接口与共享报文存储；管理面SNMP v1子集、615A/TFTP加卸载子集与RTC/PPS驯服；以及可复现的自建验证环境。管理面与数据面均在同一FPGA内完成，不依赖片上软核或嵌入式软件栈。开发上先按规范与答疑划定可交付子集，再完成RTL与独立黄金模型；随后用清单化测试台做双仿真器全量回归，并结合综合与公开端口综合后仿真切片，把关键数字冻结进实测数据包供文档引用。验证以自建测试台为主：功能全量回归{{metric:full_pass}}/{{metric:full_n}}，Questa与ModelSim SE逐项一致{{metric:dual_sim_match}}项；公开端口门级切片T88b三场景均为PASS；变异测试（新增28个）与历史基线分列报告。吞吐、时延、抖动与规模能力等四项指标均绑定具体测试编号与场景参数。官方字面端到端SFD→SFD在单端系统回环下缺少网络段，故不作为已测通过项写入。本作品不做时序签核与板级验证（赛题未要求），亦不宣称完整ARINC认证、4096路同时接收或门级全量矩阵。正文数字以冻结测试结果为准，不手写拼接历史轮次。"""

    s11 = """本设计在FPGA内实现AFDX端系统收发与管理子集。发送链：主机写入端口缓冲后，由虚拟链路调度器按BAG与份额约束选路，序列号生成与帧构建模块组装以太网/IP/UDP/SN，经双网复制与MAC整形从GMII发出。接收链：双网MAC收帧入共享存储，经哈希查表、过滤、IC、RM去重后解析交付主机或管理SAP。管理面含SNMP v1（GET/GETNEXT/SET子集）、TFTP/615A加卸载子集与PPS/FLL时钟驯服，均为硬件状态机。接口模式参数可在历史口与公开GMII间切换而复用同一套协议逻辑。特性侧重可综合、可仿真复现与证据可追溯，而非认证实验室结论。"""

    s12 = """目标应用为综合模块化航电等场景下的端系统通信节点：连接主机应用与AFDX交换网络，按虚拟链路提供确定性发送整形与双网冗余接收。亦可作为协议芯片原型，供教学、预研与自建测试台对照。本作品交付为可综合RTL与仿真验证包，评测环境为自建测试台；不替代适航取证、交换机实现或对端真实端系统闭环。物理层侧对接标准GMII语义的千兆以太网PHY接口模型；主机侧以寄存器与表项配置虚拟链路、端口与管理参数。应用边界以赛题评分项与已披露协议子集为准。"""

    s13 = """（1）全硬件数据面与管理面同片实现，无嵌入式CPU或软核协议栈。（2）接收侧4096 VL能力采用双表并行、每表2-way流水查表，配置期离线摆放；无反压时结果延迟可预算，有反压则交付时间不固定，且非每拍可接收。（3）收发共享报文块池，顶层唯一free_pipe按优先级互斥归还并以valid/ready反压保持，维持块所有权不变量。（4）验证方法学：独立Python黄金模型、双仿真器同清单、变异分列报告、覆盖率统一表并列、形式验证边界如实披露、文档数字来自冻结测试结果。（5）接口模式参数化，公开GMII与内部口复用同一RTL。eLinx综合规模：cells {{metric:cells}}、altsyncram {{metric:altsyncram}}。不做Fit或STA签核表述。"""

    s15 = """1. 全硬件管理面：SNMP、TFTP·615A与RTC均在FPGA内，无软核。2. 4096接收VL双表4-way流水查表，离线摆放换常量延迟。3. 验证方法学：黄金模型、双仿真器{{metric:dual_sim_match}}项一致、变异测试（新增28个）杀死{{metric:c3_mutants_killed}}/{{metric:c3_mutants_total}}、单一冻结测试结果。4. IF_MODE三模式复用同一套收发RTL。"""

    s16 = """先按赛题五功能与四指标拆解，并对照规范与答疑划定协议子集；再分模块实现发送、接收与管理RTL，同时编写独立黄金模型与向量；随后用清单化测试台做Questa与ModelSim SE双仿真器全量，经eLinx综合与公开端口综合后仿真切片后，冻结实测数据并渲染文档。未完成项不写成已通过，历史数字不与现行结果拼装。"""

    s41 = """后续可在不改变公开口契约的前提下扩展：补齐615A更完整状态机与错误码覆盖；加强分片重组负路径激励；将门级切片从单帧回环扩展到受控吞吐场景（须新测试编号与墙钟预算）；对覆盖率热点模块补定向用例；在获得规范现行版后对照修订完整性检查与冗余管理细节。若进入板级，需另建PHY、时钟与主机桥接工程并重新定义时序闭合目标——上述均超出本赛题必交范围，本冻结不提前宣称。"""

    return {
        "abstract": abstract,
        "1.1": s11,
        "1.2": s12,
        "1.3": s13,
        "1.5": s15,
        "1.6": s16,
        "4.1": s41,
    }


def docx_full_text(doc: Document) -> str:
    parts: list[str] = []
    for p in doc.paragraphs:
        parts.append(p.text)
    for t in doc.tables:
        for row in t.rows:
            parts.append("|".join(c.text for c in row.cells))
    return "\n".join(parts)


def count_residue(text: str) -> dict[str, int]:
    """Judge-facing residue counts in finished docx body."""
    return {
        "metrics": len(re.findall(r"(?i)\bmetrics\b", text)),
        "口径": text.count("口径"),
        "旁证": text.count("旁证"),
        "C3": len(re.findall(r"\bC3\b", text)),
        "P/I/F等级标注": len(
            re.findall(r"(?:等级\s*[PIF]|（[PIF]）|标为仅实现|禁止宣称)", text)
        ),
    }


def count_identity(text: str) -> dict[str, tuple[int, list[str]]]:
    """Scan for identity leaks; return pattern → (total_hits, ≤5 unique samples)."""
    patterns = {
        "大学": r".{0,12}大学.{0,12}",
        "学院": r".{0,12}学院.{0,12}",
        "学校": r".{0,12}学校.{0,12}",
        "老师": r".{0,12}老师.{0,12}",
        "导师": r".{0,12}导师.{0,12}",
        "本机用户名": r"(?i)\b(tortl|Administrator)\b",
        "盘符路径": r"(?i)(?:[A-Z]:\\|\\\\)[^\s\"'<>|]{3,}",
    }
    out: dict[str, tuple[int, list[str]]] = {}
    for name, pat in patterns.items():
        hits = [m.group(0).replace("\n", " ") for m in re.finditer(pat, text)]
        seen: set[str] = set()
        uniq: list[str] = []
        for h in hits:
            if h not in seen:
                seen.add(h)
                uniq.append(h)
            if len(uniq) >= 5:
                break
        out[name] = (len(hits), uniq)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--metrics",
        type=Path,
        default=ROOT / "out/p9_freeze_dfac58a/metrics.json",
    )
    ap.add_argument("--template", type=Path, default=ROOT / "报告模板.docx")
    ap.add_argument(
        "--out-docx",
        type=Path,
        default=ROOT / "doc/submit/AFDX端系统_技术文档_官方模板.docx",
    )
    ap.add_argument(
        "--out-pdf",
        type=Path,
        default=ROOT / "doc/submit/AFDX端系统_技术文档_官方模板.pdf",
    )
    ap.add_argument(
        "--delivery",
        type=Path,
        default=ROOT / "doc/submit/技术文档_官方模板_交付表.md",
    )
    ap.add_argument("--skip-pdf", action="store_true")
    args = ap.parse_args()

    data, catalog = load_metrics(args.metrics)
    commit = str(data.get("commit") or fmt_metric(catalog, "freeze_commit"))
    figs = ROOT / "doc/submit/figs"

    raw = build_sections(catalog)
    rendered: dict[str, str] = {}
    missing: set[str] = set()
    counts: dict[str, int] = {}
    limits = {
        "abstract": 800,
        "1.1": 400,
        "1.2": 400,
        "1.3": 400,
        "1.4": 200,
        "1.5": 200,
        "1.6": 200,
        "4.1": 300,
        "4.2": 1000,
    }
    for k, v in raw.items():
        t, miss = render(v, catalog)
        rendered[k] = t
        missing |= miss
        counts[k] = count_chars(t)

    # 1.4：无「等级」列；字数≤200
    rows_14 = [
        [
            "吞吐",
            "≥100 Mbps（RX去重）",
            f"T90 {fmt_metric(catalog,'t90_tx_a_mbps')}/{fmt_metric(catalog,'t90_rx_dedup_mbps')} Mbps",
        ],
        [
            "时延",
            "ES贡献",
            f"T89 {fmt_metric(catalog,'t89_es_total_max_ns')} ns",
        ],
        [
            "抖动",
            "同VL max−min",
            f"T42 {fmt_metric(catalog,'t42_jitter_max_us')} μs；T89 {fmt_metric(catalog,'t89_max_jit_ns')} ns",
        ],
        [
            "规模",
            "128 TX/4096 RX",
            "T34p/T35p；T90同时",
        ],
    ]
    note_14 = "测试条件：IF_MODE=2；T90为128 VL同时；仿真125 MHz；单ES回环不做官方SFD→SFD宣称。"
    text_14 = "".join("".join(r) for r in rows_14) + note_14
    counts["1.4"] = count_chars(text_14)
    reflection_path = ROOT / "doc/submit/心得体会_4.2.txt"
    reflection = ""
    if reflection_path.is_file():
        reflection = reflection_path.read_text(encoding="utf-8").strip()
    counts["4.2"] = count_chars(reflection) if reflection else 0

    over = {k: counts[k] for k in limits if k in counts and counts[k] > limits[k]}
    if over:
        print("FAIL word-limit:", over, file=sys.stderr)
        for k, n in sorted(counts.items()):
            print(f"  {k}: {n}/{limits.get(k,'?')}", file=sys.stderr)
        return 2

    if not args.template.is_file():
        print(f"FAIL missing template {args.template}", file=sys.stderr)
        return 1

    doc = Document(str(args.template))
    clear_body(doc)

    # Title
    p = doc.add_paragraph(style="Heading 2")
    run = p.add_run("AFDX 端系统协议芯片")
    set_run_font(run, size_pt=16)
    run.bold = True
    add_para(doc, "（正文不含队属单位、指导教师或个人信息。）")

    add_heading_like(doc, "摘要")
    add_para(doc, rendered["abstract"], first_line=True)

    add_heading_like(doc, "第一部分  作品概述")

    add_heading_like(doc, "1.1 功能与特性", style="List Paragraph")
    add_para(doc, rendered["1.1"], first_line=True)

    add_heading_like(doc, "1.2 应用领域", style="List Paragraph")
    add_para(doc, rendered["1.2"], first_line=True)

    add_heading_like(doc, "1.3 主要技术特点", style="List Paragraph")
    add_para(doc, rendered["1.3"], first_line=True)

    add_heading_like(doc, "1.4 主要性能指标", style="List Paragraph")
    add_table(
        doc,
        ["指标", "要求/测量条件摘要", "实测数据（冻结测试结果）"],
        rows_14,
    )
    add_para(doc, note_14)

    add_heading_like(doc, "1.5 主要创新点", style="List Paragraph")
    add_para(doc, rendered["1.5"], first_line=True)

    add_heading_like(doc, "1.6 设计流程", style="List Paragraph")
    add_para(doc, rendered["1.6"], first_line=True)
    try_add_picture(doc, figs / "fig_design_flow.png", 13.5)
    add_caption(doc, "图 设计流程")

    add_heading_like(doc, "第二部分  系统组成及功能说明")
    add_para(doc, "阐述具体的设计细节（图文结合）。本节「硬件」指 FPGA RTL 逻辑；「软件」指 PC 端验证环境；本作品无嵌入式软件，不涉及机械结构。")

    add_heading_like(doc, "2.1 整体介绍", style="List Paragraph")
    add_para(
        doc,
        "系统由三部分组成：（1）FPGA 内 AFDX 端系统逻辑（硬件，见 2.2）；（2）PC 端验证与复现环境（软件，见 2.3）；（3）综合与门级切片证据链（见第三部分）。"
        "整体数据流见图：主机前门译码在顶层完成；发送经端口、BAG 调度、组帧、双网 MAC 出 GMII；"
        "接收经双网 MAC、查表、过滤、IC、RM、解析后交付主机或管理 SAP。"
        f"默认参数：双网使能、128 发送 VL、4096 接收 VL、公开口模式。功能全量 {fmt_metric(catalog,'full_pass')}/{fmt_metric(catalog,'full_n')}。"
        "模块关系为流水互联，管理面旁路占用独立 SAP，不插入数据面关键路径。",
        first_line=True,
    )
    try_add_picture(doc, figs / "fig1_dataflow.png", 14.0)
    add_caption(doc, "图 总体数据流")

    add_heading_like(doc, "2.2 硬件系统介绍", style="List Paragraph")
    add_para(doc, "本节「硬件」指 FPGA 上的 RTL 逻辑实现，不是板级原理图或 PCB。")

    add_heading_like(doc, "2.2.1 硬件整体介绍", style="List Paragraph")
    add_para(
        doc,
        "顶层模块汇聚复位同步、微秒时基、上电清表、发送子系统、接收子系统、管理面与统计页。"
        "主机通过地址映射读写控制/状态、虚拟链路表、哈希映像、端口表与报文存储窗口。"
        "发送与接收共享物理报文存储空间；接收块由块池分配回收。"
        "控制字可开关发送/接收/完整性检查/冗余管理/SNMP/TFTP/RTC 等功能。"
        "接口侧提供双网 GMII 字节流与 PPS 相关引脚。硬件目标是可综合、可门级加载的确定性数据通路，而不是片上软核系统。"
        "工程界面截图 M1 为占位，与演示视频同期补入。",
        first_line=True,
    )

    add_heading_like(doc, "2.2.2 机械设计介绍", style="List Paragraph")
    add_para(doc, "本作品不涉及机械结构。")

    add_heading_like(doc, "2.2.3 电路各模块介绍", style="List Paragraph")
    add_para(doc, "以下「电路模块」均指 RTL 子模块及其输入输出语义。", first_line=True)

    add_para(doc, "发送通路", bold=True)
    add_para(
        doc,
        "端口缓冲承接主机消息；虚拟链路调度器按 BAG 与份额选择到期链路；序列号模块维护每链路序号；"
        "帧构建模块组装以太网/IP/UDP/SN；冗余发送模块做双网字节复制；整形与 MAC 输出前导、SFD、FCS 与帧间隙。"
        "关键输入为表项配置与端口写；输出为 GMII 发送字节与有效指示。",
        first_line=True,
    )
    try_add_picture(doc, figs / "fig_tx_modules.png", 13.5)
    add_caption(doc, "图 发送通路模块框图")

    add_para(doc, "接收通路", bold=True)
    add_para(
        doc,
        "双网 MAC 收帧并写入报文存储；双表 4-way 哈希查表得到虚拟链路索引；过滤、完整性检查与 SkewMax 去重依次执行；"
        "解析后进入端口队列或管理 SAP。关键输入为双网 GMII 接收；输出为主机可读消息与管理旁路。",
        first_line=True,
    )
    try_add_picture(doc, figs / "fig_rx_modules.png", 13.5)
    add_caption(doc, "图 接收通路模块框图")

    add_para(doc, "管理面", bold=True)
    add_para(
        doc,
        "SNMP v1 子集、TFTP/615A 加卸载子集与 PPS/时基驯服均为硬件状态机。"
        "输入为 SAP 分流帧与 PPS；输出为响应帧与时间状态。",
        first_line=True,
    )
    try_add_picture(doc, figs / "fig_mgmt_modules.png", 12.0)
    add_caption(doc, "图 管理面模块框图")

    add_para(doc, "存储与公共（块池释放）", bold=True)
    add_para(
        doc,
        "接收块 6..15 由块池分配；顶层唯一 free_pipe 口按拍互斥归还，优先级："
        "RM 输出 > IC 拒绝 > FLT 拒绝 > drain（AFDX_top 注释与 L2106–L2110 优先级链）。"
        "未获准来源通过 valid/ready 反压保持到握手（例如 ic_out_ready、flt_out_ready、rm_out_ready，"
        "见 AFDX_top L1794、L1797–L1799、L2010），不是一拍脉冲，仲裁落选不会丢失释放请求。"
        "证据：块池有界 BMC（形式侧 I）与 T22 族回环。公共模块含复位同步与统计寄存器页。块所有权关系见图。",
        first_line=True,
    )
    try_add_picture(doc, figs / "fig2_block_owner.png", 12.0)
    add_caption(doc, "图 接收块所有权关系")

    add_para(doc, "BAG 锚定与查表时延（答辩易混点）", bold=True)
    add_para(
        doc,
        "BAG：pop 时 next_tx ← cycle_count + bag_arr（tx_vl_scheduler L207），"
        "以实际上线时刻为锚，禁止写成 next_tx += bag；延迟后同 VL 间隔仍 ≥ BAG，不会追赶。"
        "长阻塞后恢复无专用测试编号，由锚定方式保证；相关测试见 T05b/T05c/T27。"
        "查表：无反压首次握手 5 拍（rx_vl_lookup L8）；"
        "无反压最小再接受间隔 6 拍（L8+L180–182+L133–134）；"
        "下游反压交付不固定；仅 IDLE 时 in_ready。"
        "勿写「任何情况下固定拍数」。"
        "资源：eLinx 综合分层报告（页眉 eLinx 64-Bit Version 3.0；"
        "elinx/gui_afdx/.../AFDX_top.map.rpt §7）"
        "rx_vl_lookup cells 604、4×altsyncram。",
        first_line=True,
    )

    add_heading_like(doc, "2.3 软件系统介绍", style="List Paragraph")
    add_heading_like(doc, "2.3.1 软件整体介绍", style="List Paragraph")
    add_para(
        doc,
        "本作品无嵌入式软件、无片上 CPU/软核固件。所谓「软件」专指 PC 端验证环境："
        "Verilog 测试台与总线功能模型、Python 黄金模型与向量生成、回归/冻结/指标复算脚本，以及文档数字渲染工具。"
        "仿真器为 Questa 与 ModelSim SE；综合工具为 eLinx。"
        "软件职责是激励、观测、独立复算与证据归档，不参与芯片内协议实时处理。",
        first_line=True,
    )
    try_add_picture(doc, figs / "S2_manifest_table.png", 14.0)
    add_caption(doc, "图 测试清单摘录（排版示意）")
    try_add_picture(doc, figs / "S3_result_summary.png", 14.0)
    add_caption(doc, "图 关键结果摘要（排版示意）")

    add_heading_like(doc, "2.3.2 软件各模块介绍", style="List Paragraph")
    add_para(
        doc,
        "测试台按清单编号覆盖公开端口回环、指标场与管理演示等；环境库提供主机与 MAC/GMII 总线功能模型及记分板；"
        "黄金模型以独立 Python 实现帧格式、BAG、IC/RM 等语义；回归与复现脚本支持冒烟、全量、双仿真器对照与冻结；"
        "指标复算脚本对时延/吞吐 CSV 二次校验；变异注入期望失败。"
        "覆盖率并列两种测量条件：设计单元加权，以及含测试台与绑定的实例统计，二者不可混称。",
        first_line=True,
    )
    try_add_picture(doc, figs / "S4_replay_flow.png", 14.5)
    add_caption(doc, "图 验证复现流程（排版示意）")

    add_heading_like(doc, "第三部分  完成情况及性能参数")
    add_para(doc, "阐述最终实现的成果（图文结合）。本作品为 FPGA 协议逻辑与仿真验证交付，无机械整机实物。")

    add_heading_like(doc, "3.1 整体介绍", style="List Paragraph")
    add_para(
        doc,
        "整体成果以可复现工程包呈现：RTL 源、仿真环境、综合网表与报告、门级切片日志与冻结测试结果。"
        "全局性展示以工程树与关键证据代替实物正面/斜45°照片。"
        f"冻结提交可核对 commit={commit[:12]}…；功能全量 {fmt_metric(catalog,'full_pass')}/{fmt_metric(catalog,'full_n')}。",
        first_line=True,
    )
    try_add_picture(doc, figs / "S5_package_tree.png", 14.0)
    add_caption(doc, "图 提交包结构（排版示意）")

    add_heading_like(doc, "3.2 工程成果", style="List Paragraph")
    add_heading_like(doc, "3.2.1 机械成果", style="List Paragraph")
    add_para(doc, "本作品不涉及机械结构。")

    add_heading_like(doc, "3.2.2 电路成果", style="List Paragraph")
    add_para(
        doc,
        "电路成果指可综合 RTL 与综合/门级证据，而非 PCB 实物。"
        f"eLinx 综合：cells {fmt_metric(catalog,'cells')}，altsyncram {fmt_metric(catalog,'altsyncram')}。"
        f"综合后仿真门级切片 T88b：S1={fmt_metric(catalog,'gate_t88b_s1')}，"
        f"S2={fmt_metric(catalog,'gate_t88b_s2')}，S3={fmt_metric(catalog,'gate_t88b_s3')}；"
        f"VO 内容哈希前缀 {fmt_metric(catalog,'gate_vo_sha256')[:16]}…。"
        "测试条件：公开端口双网回环切片；不含门级全量矩阵与 SDF 时序仿真；综合数字不等于 GUI LUT；"
        "不做时序签核与板级验证。eLinx 工程界面、综合资源页与 ModelSim Transcript（M1–M3）为占位，与演示视频同期补入。",
        first_line=True,
    )
    try_add_picture(doc, figs / "S6_synth_summary.png", 14.0)
    add_caption(doc, "图 综合结果摘要（排版示意）")

    add_heading_like(doc, "3.2.3 软件成果", style="List Paragraph")
    add_para(
        doc,
        "软件成果为 PC 端验证输出：回归 CSV、双仿真器对照表、指标控制台、覆盖率摘要与一键复现说明。"
        "仿真器 transcript 与波形窗口（M3–M4）为占位，与演示视频同期补入；信号活动图见下文 S8–S10。无嵌入式图形界面或移动端应用。",
        first_line=True,
    )

    add_heading_like(doc, "3.3 特性成果", style="List Paragraph")
    add_para(
        doc,
        "四项指标见表 1.4。"
        f"补充：T89 ES 分列 commit→TX SFD {fmt_metric(catalog,'t89_tx_commit2sfd_max_ns')} ns、"
        f"RX SFD→host {fmt_metric(catalog,'t89_rx_sfd2host_max_ns')} ns；"
        f"T90 在 128 发送 VL 同时活动下 RX 去重吞吐 {fmt_metric(catalog,'t90_rx_dedup_mbps')} Mbps。"
        f"测试条件：T89 场景抖动对照 40+Σ={fmt_metric(catalog,'t89_bound_40sig_us')} μs；"
        f"T88 演示步进 {fmt_metric(catalog,'t88_steps_ok')} 步通过（分段演示，非一次上电连续八步）。"
        f"功能回归 {fmt_metric(catalog,'full_pass')}/{fmt_metric(catalog,'full_n')}；"
        f"ModelSim SE 全量 {fmt_metric(catalog,'se_full_pass')}；双仿真器一致 {fmt_metric(catalog,'dual_sim_match')}。"
        f"变异测试（新增 {fmt_metric(catalog,'c3_mutants_total')} 个）：杀死 {fmt_metric(catalog,'c3_mutants_killed')}，"
        f"存活 {fmt_metric(catalog,'c3_mutants_survived')}，已证等价 {fmt_metric(catalog,'c3_mutants_equiv')}；"
        f"历史 {fmt_metric(catalog,'mutants_historical_detected')}/{fmt_metric(catalog,'mutants_historical_total')} 分列，不得拼成现行。"
        f"覆盖率统一表（测试报告 §7.1）：设计单元加权语句 {fmt_metric(catalog,'coverage_stmt_pct')}% / "
        f"分支 {fmt_metric(catalog,'coverage_branch_pct')}%（不含 TB）；"
        "实例 BY INSTANCES 语句 58.73% / 分支 44.63%（含 TB/bind）；顶层单 DU 参考另列——均 I，不可混称。"
        f"BAG 形式验证未闭合（bmc_bag_grade={fmt_metric(catalog,'bmc_bag_grade')}）；"
        f"lint 错误计数 {fmt_metric(catalog,'lint_error')}。",
        first_line=True,
    )
    add_para(doc, "验证剩余项（与学习材料 08 同步）", bold=True)
    add_para(
        doc,
        "新增变异存活 5 体：bag_ge_to_gt、skip_scan_lanes 归「已激活未检出」；"
        "comm_len_unchecked、pdu_tag_accept_all 归「未激活」；fll_gain_zero 归「已激活未检出」；已证等价 0。"
        "BAG BMC：cover 可达；bmc20 空真；bmc40 反例。分类为环境约束不完整（wrapper）最可能，真实反例未排除；"
        "形式侧未闭合，不写入成果宣称；不影响已冻结功能仿真证据（全量与双仿真器一致）。"
        "块池有界 BMC 与 BAG BMC 分列。"
        "细表见仓内学习材料「验证剩余项一页」（不进提交包）。",
        first_line=True,
    )
    try_add_picture(doc, figs / "S8_T88_signals.png", 14.0)
    add_caption(doc, "图 T88 信号活动（取自调试运行；功能判定以全量回归为准）")
    try_add_picture(doc, figs / "S9_T90_signals.png", 14.0)
    add_caption(doc, "图 T90 信号活动（取自调试运行；功能判定以全量回归为准）")
    try_add_picture(doc, figs / "S10_T10_signals.png", 14.0)
    add_caption(doc, "图 T10 信号活动（取自调试运行；功能判定以全量回归为准）")

    add_heading_like(doc, "第四部分  总结")
    add_heading_like(doc, "4.1 可扩展之处", style="List Paragraph")
    add_para(doc, rendered["4.1"], first_line=True)

    add_heading_like(doc, "4.2 心得体会", style="List Paragraph")
    if reflection:
        add_para(doc, reflection, first_line=True)
    else:
        add_para(
            doc,
            "（待填。定稿由队员提供后写入；非空白字符不超过 1000；勿写入队属单位或姓名；数字须能指回冻结测试结果或日志。）",
        )

    add_heading_like(doc, "AI 工具使用说明")
    add_para(
        doc,
        "使用的工具为编辑器内的 AI 编程助手（对话代理一类）。综合网表、仿真判决由本机 Questa、ModelSim SE、eLinx 执行，不由该助手生成。",
        first_line=True,
    )
    add_para(
        doc,
        "用途限于辅助：代码（RTL 与测试台的修改建议和缺陷排查）、文档（结构与措辞起草）、脚本（回归调度、打包与工程元数据）。",
        first_line=True,
    )
    add_para(
        doc,
        "写入本文的结论以各次运行目录中的仿真日志、CSV 与 transcript 为准，并经人工核对。AI 输出不作为签核，不替代组委会原文。",
        first_line=True,
    )

    add_heading_like(doc, "第五部分  参考文献")
    add_para(doc, "按照 GB/T 7714 格式著录；仅列正文实际引用，限 20 篇以内。")
    refs = [
        "[1] AERONAUTICAL RADIO, INC. ARINC Specification 664 Part 7: Avionics Full Duplex Switched Ethernet (AFDX) Network[S]. 2005.",
        "[2] XILINX. Architecting ARINC 664, Part 7 (AFDX) Solutions: XAPP1130[R]. 2010.",
        "[3] PAGH R, RODLER F F. Cuckoo hashing[J]. Journal of Algorithms, 2004, 51(2): 122-144.",
        "[4] DIETZFELBINGER M, WEIDLING C. Balanced allocation and dictionaries with tightly packed constant size bins[J]. Theoretical Computer Science, 2007, 380(1-2): 47-68.",
        "[5] KIRSCH A, MITZENMACHER M, WIEDER U. More robust hashing: Cuckoo hashing with a stash[J]. SIAM Journal on Computing, 2009, 39(4): 1543-1561.",
        "[6] KEKELY L, et al. Fast lookup for dynamic packet filtering in FPGA[C]//IEEE International Symposium on Design and Diagnostics of Electronic Circuits and Systems. 2014: 219-222.",
        "[7] TRAN N, KITTITORNKUN S. FPGA-based cuckoo hashing for network intrusion detection[C]//Asia-Pacific Network Operations and Management Symposium. 2007: 334-343.",
        "[8] CHARARA H, et al. Methods for bounding end-to-end delays on an AFDX network[C]//Euromicro Conference on Real-Time Systems. 2006.",
        "[9] AL SHEIKH A, et al. Optimal design of virtual links in AFDX networks[J]. Real-Time Systems, 2013, 49(3): 308-336.",
        "[10] CASE J, et al. Version 2 of the Protocol Operations for the Simple Network Management Protocol (SNMP): RFC 3416[S]. IETF, 2002.",
        "[11] KENT S. IP Encapsulating Security Payload (ESP): RFC 4303[S]. IETF, 2005.",
        "[12] JIA Y, HARMAN M. An analysis and survey of the development of mutation testing[J]. IEEE Transactions on Software Engineering, 2011, 37(5): 649-678.",
        "[13] BUTKA N. Advanced Verification Methods for Safety-Critical Airborne Electronic Hardware: DOT/FAA/TC-14/41[R]. Federal Aviation Administration, 2015.",
        "[14] SELIGMAN E, et al. Formal Verification: An Essential Toolkit for Modern VLSI Design[M]. Morgan Kaufmann, 2015.",
        "[15] CHOUDHURY A K, HAHNE E L. Dynamic queue length thresholds for shared-memory packet switches[J]. IEEE/ACM Transactions on Networking, 1998, 6(2): 130-140.",
        "[16] BENAMMAR N, et al. Tighter buffer dimensioning in AFDX networks[J]. ACM SIGBED Review, 2016, 13(4): 37-42.",
        "[17] NIKOLOGIANNIS A, et al. An FPGA-based queue management system for accurate delay analysis[J]. Microprocessors and Microsystems, 2004, 28(5-6): 223-236.",
        "[18] 武华, 马捷中, 翟正军. AFDX端系统通信端口的设计与实现[J]. 测控技术, 2009, 28(3): 56-59.",
        "[19] 王纯委, 郝玉锴, 杨军祥, 等. 一种航电系统AFDX网络管理技术的研究与实现[J]. 电光与控制, 2015(9): 64-67.",
        "[20] 徐进, 黄玉港, 王静玲, 等. AFDX网络冗余管理技术分析[J]. 电子科技, 2017, 30(3): 101-103.",
    ]
    for r in refs:
        add_para(doc, r)

    add_heading_like(doc, "附录  截图说明")
    add_para(
        doc,
        "自动排版图 S2–S6 与调试波形图 S8–S10 已嵌入正文。"
        "人工截图 M1–M4 为占位，推迟到封装测试台与最终冻结完成后，与演示视频同时补拍。"
        "四张仍为：eLinx 工程界面、eLinx 综合资源页、ModelSim Transcript（T88b PASS 且 Errors: 0）、"
        "ModelSim 波形窗口（T88 或 T90）。窗口布局与去身份要求见同目录《人工截图清单》。",
        first_line=True,
    )
    add_para(
        doc,
        f"第二轮生成时间 {datetime.now().strftime('%Y-%m-%d %H:%M')}；冻结 commit={commit}。"
        "已嵌入：总体数据流、发送/接收/管理面框图、设计流程图、块所有权图、S2–S6 排版图、S8–S10 波形图。",
    )

    args.out_docx.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(args.out_docx))
    print(f"PASS docx → {args.out_docx}")

    body_text = docx_full_text(doc)
    residue = count_residue(body_text)
    identity = count_identity(body_text)
    print("residue", residue)
    print("identity", {k: n for k, (n, _) in identity.items()})

    pdf_ok = False
    pdf_msg = "skipped"
    if not args.skip_pdf:
        pdf_ok, pdf_msg = export_pdf_word_com(args.out_docx, args.out_pdf)
        if pdf_ok:
            size_mb = args.out_pdf.stat().st_size / (1024 * 1024)
            print(f"PASS pdf → {args.out_pdf} ({size_mb:.2f} MB) via {pdf_msg}")
            if size_mb > 50:
                print("WARN pdf > 50 MB", file=sys.stderr)
        else:
            print(f"WARN pdf not exported: {pdf_msg}", file=sys.stderr)

    # Delivery table
    def rel(p: Path) -> str:
        try:
            return p.resolve().relative_to(ROOT).as_posix()
        except Exception:
            return p.name

    lines = [
        "# 技术文档官方模板 · 交付表（第二轮）",
        "",
        f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 冻结测试结果：`{rel(args.metrics)}`",
        f"- commit：`{commit}`",
        f"- docx：`{rel(args.out_docx)}`",
        f"- pdf：{'已导出 '+rel(args.out_pdf) if pdf_ok else '未导出 — '+pdf_msg}",
        "- 本机 PDF 工具：Word COM 可用" if pdf_ok else "- 本机 PDF：Word COM 失败或跳过；请用 Word「另存为 PDF」",
        "",
        "## 字数（非空白字符；上限来自官方模板）",
        "",
        "| 节 | 字数 | 上限 | 状态 |",
        "|---|---:|---:|---|",
    ]
    for k in ["abstract", "1.1", "1.2", "1.3", "1.4", "1.5", "1.6", "4.1", "4.2"]:
        lim = limits[k]
        n = counts.get(k, 0)
        if k == "4.2" and n == 0:
            st = "待填"
        else:
            st = "OK" if n <= lim else "超限"
        name = {"abstract": "摘要"}.get(k, k)
        lines.append(f"| {name} | {n} | {lim} | {st} |")
    lines += [
        "",
        "## 评委向残留统计（docx 正文+表格）",
        "",
        "| 词/模式 | 次数 |",
        "|---|---:|",
    ]
    for k, v in residue.items():
        lines.append(f"| {k} | {v} |")
    lines += [
        "",
        "> 目标均为 0。`P/I/F等级标注` 统计模式：`等级P/I/F`、`（P/I/F）`、`标为仅实现`、`禁止宣称`。",
        "",
        "## 章节映射核对",
        "",
        "| 模板节 | 本作品写法 |",
        "|---|---|",
        "| 2.2 硬件 | FPGA RTL 逻辑 |",
        "| 2.2.2 / 3.2.1 机械 | 本作品不涉及机械结构 |",
        "| 2.3 软件 | PC 端验证环境（Verilog TB、Python 黄金模型、回归脚本）；无嵌入式软件 |",
        "| 3.2.2 电路成果 | eLinx 综合 + 综合后仿真（T88b） |",
        "| 3.3 特性成果 | 四指标、波形图、145 回归、双仿真器、变异/BMC 剩余项、覆盖率统一表 |",
        "| 2.2.3 块池 | free_pipe 单口优先级 + valid/ready 反压保持 |",
        "",
        "## 去身份抽查（docx 全文自动扫描）",
        "",
        "| 模式 | 命中次数 | 样例（≤5） |",
        "|---|---:|---|",
    ]
    for k, (n, samples) in identity.items():
        sample_s = "；".join(samples) if samples else "（无）"
        lines.append(f"| {k} | {n} | {sample_s} |")
    lines += [
        "",
        "> 目标：队属学校/老师/导师/本机用户名/盘符路径均为 0。"
        "作者姓名「黄玉港」等出现在期刊题录属文献信息，不是队属身份。",
        "",
        "## 图与截图",
        "",
        "| 项 | 状态 |",
        "|---|---|",
        f"| 架构/模块/流程框图 | 已嵌入 |",
        f"| S2–S6 排版图 | {'有' if (figs/'S2_manifest_table.png').is_file() else '缺'} |",
        f"| S8–S10 波形 | {'有' if (figs/'S8_T88_signals.png').is_file() else '缺'} |",
        "| 人工 M1–M4 | 占位；封装测试台与最终冻结后，与演示视频同期补拍 |",
        "",
        "## 参考文献 [18]–[20]",
        "",
        "- [18] 武华等，《测控技术》2009, 28(3): 56-59（仓内原文 PDF）。",
        "- [19] 已替换学位论文为期刊：王纯委等，《电光与控制》2015(9): 64-67"
        "（L072，仓内 `一种航电系统AFDX网络管理技术的研究与实现_王纯委.pdf`；题录不含学校名）。",
        "- [20] 徐进等，《电子科技》2017, 30(3): 101-103（仓内原文 PDF）。",
        "- 编号 [1]–[20] 与正文一致；正文无单独改号的内联引用需核对（参考文献表整表列出）。",
        "",
        "## 外部评审意见处理",
        "",
        "| # | 意见 | 处理结果 | 落点 |",
        "|---|---|---|---|",
        "| 1 | free_pipe 单口优先级与反压保持 | 已写清优先级 RM>IC>FLT>drain；列出 ready 门控；非一拍脉冲、不丢失；证据 pool BMC(I)+T22 | 设计 §2.2.3/§7.2；学习 03；官方 2.2.3 |",
        "| 2 | BAG 锚定 next_tx←cycle+BAG | 改为 L207 锚定；不追赶；长阻塞恢复未单独测 | 设计 §9.1；学习 02；官方 2.2.3 附段 |",
        "| 3 | 查表时延三分法 | 无反压 5 拍/反压不固定/非每拍可收；删固定拍数宣称 | 设计 §3.2/§9.2；学习 03/06/07 |",
        "| 4 | 存活变异+BAG BMC | 新建学习 08；同步设计 §3.5 与官方 §3.3 | doc/学习/08_验证剩余项一页.md |",
        "| 5 | 覆盖率统一表 | 测试报告 §7.1；修正学习 07 第15题 | 测试报告；学习 05/07；答辩要点 |",
        "| 6 | 哈希方案对比表 | 周期 5/6 拍（RTL 确定值）；资源 eLinx map.rpt（页眉 3.0）§7 分层 604+4×altsyncram；线性/CAM 估算 | 设计 §3.2 |",
        "| 7 | 重生 docx/PDF + run_all | 本轮执行 | 本交付表 |",
        "| 8 | 冻结前小修 | map.rpt 标明 eLinx 3.0；6 拍确定值+RTL 行号；学习07第12题不主动报 fmax | 设计 §3.2；学习 07 |",
        "",
        "## 验收卡",
        "",
        "```",
        "改动：文末 AI 说明压成 3 段；4.2 待队员定稿；M1–M4 改为占位并与演示视频同期",
        "触及模块：tools/build_official_tech_report.py、doc/submit 截图与上传说明；无 rtl/sim/tb/manifest",
        "宣称等级：文档对齐；无新仿真宣称",
        "对应 T 号：无，故 I",
        "实际跑了：build_official_tech_report（docx/PDF）",
        "日志路径：本交付表",
        "未跑的相关 T：全量/门级未因文档重跑",
        "面积/时序：未重测（数字保持改前）",
        "禁止写出的句子：4.2 已由队员定稿；M1–M4 已拍入；AI 输出即签核",
        "```",
        "",
    ]
    args.delivery.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"PASS delivery → {args.delivery}")
    if missing:
        print("FAIL missing metrics:", ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    if any(v > 0 for v in residue.values()):
        print("WARN residue non-zero:", residue, file=sys.stderr)
    for k, n in counts.items():
        print(f"count {k}={n}/{limits.get(k, '-')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
