#!/usr/bin/env python3
"""Encode or inspect 615A control files offline. This starts no network or HDL simulation."""
from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sw/golden"))
from a615a_files import (FormatError, Initialization, UploadEntry, UploadFileStatus,
                         UploadRequest, UploadStatus)


def json_value(value):
    if isinstance(value, bytes):
        return {"raw_hex": value.hex(), "interpretation": "UNRESOLVED"}
    raise TypeError(f"not JSON serializable: {type(value).__name__}")


def build(kind: str, data: dict):
    version = data["version"]  # Required; wire tag is not inferred from standard edition.
    if kind in ("LUI", "LCI", "LND", "LNO"):
        return Initialization(version, data["status"], data.get("description", ""))
    if kind == "LUR":
        return UploadRequest(version, tuple(UploadEntry(**item) for item in data["files"]))
    files = tuple(UploadFileStatus(item["filename"], item["part_number"],
                                    bytes.fromhex(item["progress_hex"]), item["status"],
                                    item.get("description", ""))
                  for item in data.get("files", []))
    return UploadStatus(version, data["status"], data["counter"], data["estimated_time"],
                        bytes.fromhex(data["progress_hex"]), files,
                        data.get("description", ""), data.get("exception_timer"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("encode", "decode"))
    parser.add_argument("kind", choices=("LUI", "LCI", "LND", "LNO", "LUR", "LUS"))
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--expected-version", help="Explicit two-byte wire tag, such as A4")
    args = parser.parse_args()
    try:
        if args.action == "encode":
            if args.output is None:
                parser.error("encode requires --output")
            if args.output.exists():
                raise FormatError("output already exists")
            data = json.loads(args.input.read_text(encoding="utf-8-sig"))
            payload = build(args.kind, data).encode()
            if args.expected_version is not None and data["version"] != args.expected_version:
                raise FormatError("input version differs from --expected-version")
            with args.output.open("xb") as stream:
                stream.write(payload)
            print(f"PREPARED {args.kind} bytes={len(payload)}; no DUT verification performed")
        else:
            codec = UploadRequest if args.kind == "LUR" else UploadStatus if args.kind == "LUS" else Initialization
            value = codec.decode(args.input.read_bytes(), expected_version=args.expected_version)
            text = json.dumps(asdict(value), ensure_ascii=False, indent=2, default=json_value) + "\n"
            if args.output is not None:
                with args.output.open("x", encoding="utf-8") as stream:
                    stream.write(text)
            else:
                print(text, end="")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Control-file preparation error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
