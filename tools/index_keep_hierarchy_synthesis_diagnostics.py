"""Index a preserved KeepHierarchy synthesis log without launching synthesis."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    text = args.log.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    warning_re = re.compile(r"Warning: multiple conflicting drivers for .*?\\([^\\]+?)\.\$abc:")
    module_counts = Counter()
    for line in lines:
        match = warning_re.search(line)
        if match:
            module_counts[match.group(1)] += 1

    diagnostics = {
        "schema": "keep-hierarchy-synthesis-diagnostic-index-v1",
        "status": "READ_ONLY_INDEX_NO_SYNTHESIS_LAUNCH",
        "log": str(args.log),
        "log_sha256": sha(args.log),
        "candidate": str(args.candidate),
        "candidate_sha256": sha(args.candidate / "candidate.json"),
        "synthesis_status_sha256": sha(args.candidate / "synthesis_status.json"),
        "line_count": len(lines),
        "conflicting_driver_warning_count": sum(module_counts.values()),
        "conflicting_driver_modules": dict(module_counts.most_common()),
        "bad_allocation_count": sum("ERROR: bad allocation" in line for line in lines),
        "logic_loop_warning_count": sum("Warning: found logic loop" in line for line in lines),
        "last_error_line": next((index + 1 for index, line in reversed(list(enumerate(lines))) if "ERROR:" in line), None),
        "scope": "Diagnostic indexing only; no source edit, no synthesis retry, no netlist or business conclusion.",
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(diagnostics, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(diagnostics, ensure_ascii=False))


if __name__ == "__main__":
    main()
