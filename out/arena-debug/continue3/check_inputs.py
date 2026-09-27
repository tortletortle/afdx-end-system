"""Bind the tested source snapshot to the live RTL without scanning secrets."""
from pathlib import Path
import hashlib

root = Path("C:/Workspace/diansai")
out = root / "out/arena-debug/continue3"
entries = (out / "SOURCE_SHA256.txt").read_text(encoding="ascii").splitlines()
lines = []
for entry in entries:
    expected, name = entry.split("  ", 1)
    for label, p in (("live", root / name), ("snapshot", out / name)):
        actual = hashlib.sha256(p.read_bytes()).hexdigest()
        if actual.lower() != expected.lower():
            raise RuntimeError(f"RTL changed after snapshot: {label} {name}")
    lines.append(f"MATCH {name} sha256={expected}")
for name in ("AFDX_top.qpf", "AFDX_top.qsf"):
    orig = hashlib.sha256((root / "elinx/prj/quartus" / name).read_bytes()).hexdigest()
    copy = hashlib.sha256((out / "project" / name).read_bytes()).hexdigest()
    lines.append(f"PROJECT {name} original_sha256={orig} isolated_sha256={copy} same_at_audit={orig == copy}")
sdc = hashlib.sha256((root / "elinx/sdc/AFDX_top.sdc").read_bytes()).hexdigest()
expected_sdc = "b67bd2d4dc1b6791430c6cfe8d33ac60733e74e660fbd4644ad327f670c027bb"
if sdc != expected_sdc:
    raise RuntimeError("SDC source changed after initial read; cannot compare STA")
lines.append(f"SDC_SOURCE_MATCH sha256={sdc}")
(out / "raw/input_binding.log").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Input binding: {len(entries)}/24 RTL live+snapshot hashes match; SDC unchanged")
