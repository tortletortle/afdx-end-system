"""Hash the retained continue3 deliverables after generated DB cleanup."""
from pathlib import Path
import hashlib
import os

out = Path("C:/Workspace/diansai/out/arena-debug/continue3")
omit_dirs = {"work", "db", "output_files", "incremental_db", "__pycache__"}
omit_names = {".env", "SHA256SUMS.txt"}
lines = []
total_bytes = 0
for directory, dirs, files in os.walk(out):
    dirs[:] = [name for name in dirs if name not in omit_dirs and not name.startswith(".")]
    for name in sorted(files):
        if name in omit_names or ".local." in name or name.startswith("."):
            continue
        p = Path(directory) / name
        if not p.is_file():
            continue
        size = p.stat().st_size
        if size > 50_000_000:
            raise RuntimeError(f"Oversized generated file must be reviewed before hashing: {p.relative_to(out)} ({size} bytes)")
        h = hashlib.sha256()
        with p.open("rb") as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                h.update(block)
        lines.append((p.relative_to(out).as_posix(), h.hexdigest()))
        total_bytes += size
dest = out / "SHA256SUMS.txt"
dest.write_text("".join(f"{digest}  {name}\n" for name, digest in sorted(lines)), encoding="ascii")
print(f"SHA256SUMS: {len(lines)} files, {total_bytes} bytes, excluding manifest itself and generated work/db/output_files")
