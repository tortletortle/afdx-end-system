"""Retain tool reports, then drop disposable large databases INSIDE continue3."""
from pathlib import Path
import hashlib
import shutil

out = Path("C:/Workspace/diansai/out/arena-debug/continue3")
raw = out / "raw"
if (raw / "sta.rc").read_text(encoding="ascii").strip() != "0":
    raise RuntimeError("STA must complete successfully before deleting its database")

records = []
qout = out / "project/output_files"
for name in ("AFDX_top.map.rpt", "AFDX_top.map.summary"):
    src = qout / name
    if src.is_file():
        dst = raw / name
        shutil.copyfile(src, dst)
        digest = hashlib.sha256(dst.read_bytes()).hexdigest()
        records.append(f"COPIED {src.relative_to(out)} -> {dst.relative_to(out)} sha256={digest}")
    else:
        records.append(f"NOT_FOUND {src.relative_to(out)}")

generated = (
    out / "project/db", out / "project/incremental_db", qout,
    out / "sim/work", out / "sim/vsim.wlf", out / "work",
)
for path in generated:
    if not path.exists():
        continue
    if path.is_symlink() or not path.resolve().is_relative_to(out.resolve()):
        raise RuntimeError(f"Refusing unsafe cleanup target: {path}")
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()
    records.append(f"REMOVED_GENERATED {path.relative_to(out)}")
(raw / "cleanup.log").write_text("\n".join(records) + "\n", encoding="utf-8")
print("Safe cleanup finished; retained map reports in raw/ where present")
