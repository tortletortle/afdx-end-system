#!/usr/bin/env python3
"""Freeze a reviewable source snapshot without running a compiler or simulator.

This is an UNVERIFIED source handoff, not the final competition acceptance pack.
Run from any directory. Output must be a new directory below this project/out.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SUFFIXES = {".v", ".sv", ".svh", ".vh", ".py", ".ps1", ".tcl", ".do", ".f",
            ".ys", ".qsf", ".sdc", ".epr", ".yaml", ".yml", ".json", ".hex",
            ".md", ".txt", ".csv", ".tsv", ".manifest", ".sh", ".bat", ".cmd"}
TREES = ("rtl", "sw/golden", "sw/fixtures", "sw/report", "sim/tb", "sim/env", "sim/chk", "sim/vec", "tools", "elinx/prj")
TOP_FILES = (
    "AFDX端系统_总体设计书.md",
    "sim/tests.manifest", "sim/run_regress.ps1", "sim/freeze_regress.py", "sim/SIMULATOR_STARTUP.md",
    "elinx/README.txt", "elinx/AFDX_top_sources.f", "elinx/AFDX_615A_prepare_sources.f",
    "elinx/AFDX_fragment_prepare_sources.f",
    "elinx/gui_afdx/AFDX_top.epr", "elinx/gui_afdx/AFDX_top.qsf",
    "doc/接口契约.md", "doc/赛题最终验收矩阵.md", "doc/赛方答疑原文_20261009.txt",
    "doc/Luna_八小时自主运行安排_20261010.md",
    "doc/Luna_非仿真补齐与后续验证执行计划_20261010.md",
    "doc/答疑对齐补齐记录_20261009.md", "doc/615A_控制文件与接入设计_20261009.md",
    "doc/协议差距清单_20261009.json", "doc/非仿真补齐记录_20261009.md",
    "doc/源代码包使用说明_20261009.md", "doc/615A_公开资料索引_20261009.json",
    "doc/regs.yaml", "doc/regs_pkg.svh",
    "doc/验收尺子.md", "doc/计划执行记录_20261008.md",
    "doc/AFDX端系统_现行架构图.html", "doc/组委会答疑_全量_20260928.md",
    "doc/当前问题分工与闭环计划_20261008.md",
)
ENTRY_TEXT = """# 源码与仿真准备快照

这是供小组阅读和后续验证的源码快照，状态为 SOURCE_SNAPSHOT_UNVERIFIED。
主工程入口是 rtl/top/AFDX_top.v；现有仿真入口是 sim/run_regress.ps1。
环境、命令和限制见 doc/源代码包使用说明_20261009.md。

    当前工作区静态证据在外部 out 目录（不随本包）：生产 TFTP r6、客户端 r6、集成静态 r21；r19为AC28 guard前历史；各自仅证明当时冻结输入的静态结构/AST 检查，不证明功能。生产 TFTP r4、客户端 r3 与早期 B2 helper 检查为历史证据。

独立准备清单含五个615A模块：a615a_init_tx、a615a_lur_rx、a615a_file_rx、a615a_tftp_client_1350、a615a_tftp_file_rx_adapter；另有三个分片辅助模块：IPv4 planner、header formatter、跨块 PMEM byte reader。五个和三个模块均未接入 AFDX_top/生产路径。
分片准备列表还包含 IPv4 planner/header helper 与多块 PMEM byte reader；这些原语没有组合成端到端分片/重组路径。
当前顶层仍没有完整615A控制流程；P06/P07/P08相对本地P7比较基线的IP分片/重组与单个8 kB队列/UDP-SAP消息路径仍缺失。独立P09也有实现差距：本地2005 P7 §3.3.1.2.3/Table 3-1 对最多8 k octets TFTP DATA block的原文表述为“should be able to manage”，并列RFC2348 Blocksize Option；当前固定512 B、无请求/OACK。赛方未指定版次，P7-1正文/赛题范围与615A profile待核。工作区完整2005版PDF（145页，PDF第40页=印刷页32，SHA256 63ef56b2e0061bdb8a8554fc9cdb522d2ba7c4a0dc52003856d7022eb9889f71）与提取文本不随包提供。多块DATA可组成更大文件，不等于单个消息；客户端/file_rx未接入，不宣称大文件端到端。包内说明见非仿真补齐记录。
五个615A准备模块（a615a_init_tx、a615a_lur_rx、a615a_file_rx、a615a_tftp_client_1350、a615a_tftp_file_rx_adapter）及三个分片helper（ipv4_fragment_plan、ipv4_fragment_header、tx_pmem_byte_reader）均为独立准备源码、未接生产顶层且无功能验证；现有 @TEST_COUNT@ 项集合尚无当前完整通过记录。当前功能缺口分别包括完整615A控制、P06/P08单个8 kB消息与P7分片/重组，以及P09单个TFTP DATA block最多8 k octets的协商能力。
本脚本仅复制源码、记录 SHA256、写 ZIP；不会运行编译、综合或仿真。
不附带厂商授权、工具程序、编译库、综合网表、波形或历史 out 目录。
"""
PACKAGE_READMES = {
    "README.md": """# AFDX 源码快照

本包是源码交接快照，状态为 `SOURCE_SNAPSHOT_UNVERIFIED`。当前工作区只完成静态检查；近期TFTP/顶层改动没有功能回归。外部静态记录（不包含在本 ZIP）：生产 TFTP r4 `out/luna_prod_tftp_static_20261010_r4/static_status.json` 是历史版本；当前 server r6 `out/luna_prod_tftp_static_20261010_r6/static_status.json` 与 client r6 `out/luna_b1_client_review_static_20261010_r6/static_status.json` 各为 11/11 检查通过、0 warnings。集成静态 r19 是 AC28 guard 前历史；当前集成静态 r21 `out/luna_b1_client_review_static_20261010_r21/static_status.json` 对45项输入11/11通过并通过 Python AST（仿真/完整综合均未启动）。早期 server r1/r4、client r3 与 B2 helper 静态结果均为历史冻结输入证据。独立RFC1350 octet RRQ/WRQ client core及其文件接收适配器已存在但未接入；准备清单共五个615A模块（a615a_init_tx、a615a_lur_rx、a615a_file_rx、a615a_tftp_client_1350、a615a_tftp_file_rx_adapter）和三个分片辅助模块（ipv4_fragment_plan、ipv4_fragment_header、tx_pmem_byte_reader），均未接入生产路径且未做功能验证。完整615A控制和P06/P07/P08的IP分片/重组、单个8 kB队列/UDP-SAP消息路径仍未实现。P09是另一个本地基线差距：本地2005 P7 §3.3.1.2.3/Table 3-1对每服务TFTP block最多8 k octets原文表述为“should be able to manage”，并列RFC2348 Blocksize Option；当前固定512 B、无请求/OACK。赛方未指定版次，P7-1正文/赛题范围待核。工作区完整本地2005版PDF共145页（PDF第40页=印刷页32，SHA256 63ef56b2e0061bdb8a8554fc9cdb522d2ba7c4a0dc52003856d7022eb9889f71），PDF与提取文本均不随包提供。文件可由多个DATA blocks组成；客户端/file_rx未接入，不宣称大文件端到端。

另含 IPv4 fragment planner/header 与跨 PMEM 块 byte reader 原语；这些 helper 均未接入生产路径，不能视为完整 8 kB 发送或接收功能。

- 快速开始：[START_HERE.md](START_HERE.md)
- 源码与环境：[源码包使用说明](doc/源代码包使用说明_20261009.md)
- 文档索引：[快照文档索引](doc/README.md)
- 协议差距：[协议差距清单](doc/协议差距清单_20261009.json)
- 当前接口：[接口契约](doc/接口契约.md)
- 静态准备计划：[执行计划](doc/Luna_非仿真补齐与后续验证执行计划_20261010.md)

包内不包含历史 `out/`、工具和授权，也不能据旧测试/综合结果推导当前功能通过。
""",
    "README_tools.md": """# 工具与验证入口（源码快照）

- 仅静态检查：[源码包使用说明](doc/源代码包使用说明_20261009.md)。
- 后续回归入口：[sim/run_regress.ps1](sim/run_regress.ps1)，测试清单为 [sim/tests.manifest](sim/tests.manifest)。
- 仿真器启动诊断：[SIMULATOR_STARTUP.md](sim/SIMULATOR_STARTUP.md)。
- 静态检查脚本：[tools/check_non_sim_preparation.py](tools/check_non_sim_preparation.py)。
- 源码快照打包器：[tools/pack_source_snapshot.py](tools/pack_source_snapshot.py)。

本包生成过程只复制源码和核对 ZIP；没有运行功能测试、仿真、完整综合或技术映射。每次命令都应使用唯一 tag 输出目录；打包器不会覆盖已有输出。

```powershell
$tag = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$staticOut = Join-Path 'out' ('luna_non_sim_static_' + $tag)
$sourceOut = Join-Path 'out' ('luna_source_' + $tag)
python .\\tools\\check_non_sim_preparation.py --out-dir $staticOut
python .\\tools\\pack_source_snapshot.py --out-dir $sourceOut
```
""",
    "doc/README.md": """# 源码快照文档索引

本索引只链接本 ZIP 中存在的交接文档，不包含工作区的历史文档目录或 `out/` 证据。

- [非仿真补齐记录](非仿真补齐记录_20261009.md)
- [源码包使用说明](源代码包使用说明_20261009.md)
- [接口契约](接口契约.md)
- [最终验收矩阵](赛题最终验收矩阵.md)
- [615A 控制文件与接入设计](615A_控制文件与接入设计_20261009.md)
- [公开资料索引](615A_公开资料索引_20261009.json)
- [协议差距清单](协议差距清单_20261009.json)
- [本轮执行计划](Luna_非仿真补齐与后续验证执行计划_20261010.md)
- [八小时运行安排](Luna_八小时自主运行安排_20261010.md)
""",
    "rtl/README.md": """# RTL 快照入口

本目录包含本包中的 RTL 源码。生产顶层为 [AFDX_top](top/AFDX_top.v)，生产输入列表见 [AFDX_top_sources.f](../elinx/AFDX_top_sources.f)。615A 与分片准备模块尚未接入生产顶层，边界见 [接口契约](../doc/接口契约.md) 和 [源码包使用说明](../doc/源代码包使用说明_20261009.md)。
""",
    "sim/README.md": """# 仿真目录快照入口

回归入口为 [run_regress.ps1](run_regress.ps1)，清单为 [tests.manifest](tests.manifest)，全量结果冻结器为 [freeze_regress.py](freeze_regress.py)，工具启动诊断见 [SIMULATOR_STARTUP.md](SIMULATOR_STARTUP.md)。本次任务没有运行功能测试或仿真；历史闭环记录未随此快照提供。详细状态见 [源码包使用说明](../doc/源代码包使用说明_20261009.md)。
""",
    "tools/README.md": """# 工具目录快照入口

- [非仿真静态检查器](check_non_sim_preparation.py)
- [源码快照打包器](pack_source_snapshot.py)
- [配置份额生成器](gen_cfg_shares.py)

本包未运行功能测试、仿真、完整综合或技术映射；详细状态见 [源码包使用说明](../doc/源代码包使用说明_20261009.md)。
""",
    "sim/仿真闭环执行记录_20261008.md": """# 历史仿真闭环记录（快照说明）

为避免旧结果被误读为当前 RTL 证据，原工作区历史记录不包含在此源码快照中。本文件是包内说明；当前状态见 [非仿真补齐记录](../doc/非仿真补齐记录_20261009.md)。
""",
    "sim/仿真问题分析与闭环计划_20261008.md": """# 历史仿真问题计划（快照说明）

原工作区历史计划不包含在此源码快照中。本文件是包内说明；本轮范围见 [后续验证执行计划](../doc/Luna_非仿真补齐与后续验证执行计划_20261010.md)。
""",
    "doc/计划执行记录_20261008.md": """# 历史计划执行记录（快照说明）

原工作区记录保留在工作区，本源码包以此导航页占位，避免依赖未随包提供的历史 `out/` 证据。当前进展与限制见 [非仿真补齐记录](非仿真补齐记录_20261009.md)。
""",
    "doc/组委会答疑_全量_20260928.md": """# 历史答疑索引（快照说明）

历史全量答疑档案未随此源码快照提供。包内可核对的近期赛方原文见 [赛方答疑原文](赛方答疑原文_20261009.txt)；工程接口约束见 [接口契约](接口契约.md)。
""",
    "doc/当前问题分工与闭环计划_20261008.md": """# 历史问题分工计划（快照说明）

原工作区历史问题分工文件未随本源码快照提供。本文件为导航占位；本轮缺口及后续工作见 [非仿真补齐与后续验证执行计划](Luna_非仿真补齐与后续验证执行计划_20261010.md)。
""",
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def inventory() -> list[Path]:
    selected: set[Path] = set()
    for name in TREES:
        for path in (ROOT / name).rglob("*"):
            if not path.is_file() or path.suffix.lower() not in SUFFIXES:
                continue
            relative = path.relative_to(ROOT)
            if any(part in {"__pycache__", ".git", "out", "node_modules"} for part in relative.parts):
                continue
            if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
                raise ValueError(f"Source path escapes the project: {relative}")
            selected.add(path)
    # Top-level simulator scripts are source; simulator build directories are not.
    for path in (ROOT / "sim").iterdir():
        if path.is_file() and path.suffix.lower() in SUFFIXES:
            selected.add(path)
    for name in TOP_FILES:
        path = ROOT / name
        if not path.is_file():
            raise FileNotFoundError(f"Required source/document missing: {name}")
        selected.add(path)
    for path in selected:
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError(f"Source path escapes the project: {path.relative_to(ROOT)}")
    return sorted(selected, key=lambda path: path.relative_to(ROOT).as_posix())


def package(destination: Path) -> dict:
    destination = destination.resolve()
    if not destination.is_relative_to((ROOT / "out").resolve()):
        raise ValueError("Output must be below this project's out directory")
    if destination.exists():
        raise FileExistsError("Output exists; use a fresh output directory")
    payloads = {path.relative_to(ROOT).as_posix(): path.read_bytes() for path in inventory()}
    for name, content in PACKAGE_READMES.items():
        payloads[name] = content.encode("utf-8")
    for name in ("elinx/AFDX_top_sources.f", "elinx/AFDX_615A_prepare_sources.f",
                 "elinx/AFDX_fragment_prepare_sources.f"):
        for raw in payloads[name].decode("utf-8-sig").splitlines():
            relative = raw.strip()
            if relative and not relative.startswith("#") and relative not in payloads:
                raise ValueError(f"Source list input is missing from snapshot: {relative}")
    test_ids = [raw.split()[0] for raw in payloads["sim/tests.manifest"].decode("utf-8-sig").splitlines()
                if raw.strip() and not raw.lstrip().startswith("#")]
    if len(test_ids) != len(set(test_ids)):
        raise ValueError("Duplicate test ID in source manifest")
    payloads["START_HERE.md"] = ENTRY_TEXT.replace("@TEST_COUNT@", str(len(test_ids))).encode("utf-8")
    records = [{"path": name, "bytes": len(data), "sha256": digest(data)} for name, data in payloads.items()]
    manifest = {
        "schema": "afdx-source-snapshot-v1",
        "status": "SOURCE_SNAPSHOT_UNVERIFIED",
        "registered_test_count": len(test_ids),
        "generated_metadata_members": ["README.md", "README_tools.md", "doc/README.md", "START_HERE.md", "SOURCE_MANIFEST.json"],
        "generated_documentation_overrides": ["README.md", "README_tools.md", "doc/README.md",
            "rtl/README.md", "sim/README.md", "tools/README.md",
            "sim/仿真闭环执行记录_20261008.md", "sim/仿真问题分析与闭环计划_20261008.md",
            "doc/计划执行记录_20261008.md", "doc/组委会答疑_全量_20260928.md",
            "doc/当前问题分工与闭环计划_20261008.md"],
        "manifest_self_reference": "SOURCE_MANIFEST.json is the sole archive member intentionally omitted from files because it contains this manifest; generated README files and START_HERE.md are included and hashed.",
        "compiler_started_by_packager": False,
        "synthesis_started_by_packager": False,
        "simulation_started_by_packager": False,
        "preparation_modules_connected_to_top": False,
        "files": records,
        "open_requirements": [
            "615A target operation integration and active client route integration",
            "615A normative field/role/timing confirmation, including progress encoding",
            "IP fragmentation/reassembly and 8 kB queued/SAP messages",
            "Current complete RTL and synthesized functional business evidence",
            "Final acceptance package replay",
        ],
    }
    payloads["SOURCE_MANIFEST.json"] = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    destination.mkdir(parents=True)
    source_dir = destination / "source"
    for name, data in payloads.items():
        path = source_dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    archive = destination / "afdx_source_preparation.zip"
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for name, data in sorted(payloads.items()):
            # Stable source timestamps make content changes easy to distinguish.
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 9, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, data)
    report = {"status": manifest["status"], "source_file_count": len(records) - len(manifest["generated_metadata_members"]) + 1,
              "manifested_file_count": len(records), "archive_member_count": len(payloads),
              "generated_metadata_members": manifest["generated_metadata_members"],
              "archive": archive.name, "archive_bytes": archive.stat().st_size,
              "archive_sha256": digest(archive.read_bytes()),
              "manifest_sha256": digest(payloads["SOURCE_MANIFEST.json"]),
              "registered_test_count": len(test_ids), "simulation_started": False}
    (destination / "package_status.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        destination = args.out_dir if args.out_dir.is_absolute() else ROOT / args.out_dir
        report = package(destination)
    except (OSError, ValueError) as exc:
        parser.exit(2, f"Source preparation failed: {exc}\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())



