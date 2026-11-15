#!/usr/bin/env python3
"""Component version of the iPad models (`models-ipad`, project/docs/update/UPDATE_MANIFEST.md): the same algorithm as
project/packaging/make_update.py `identity` - sha256 over the sorted "relative path NUL file-sha256 newline" of every
file under models/, first 16 hex - computed over project/ipad/app/LRCDF (the zip is rooted there: it holds models/...).
usage: models_version.py [root, default: ipad/app/LRCDF]   prints the version"""
import hashlib, os, sys
SKIP = ("__pycache__", ".DS_Store")
root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ipad", "app", "LRCDF")
names = []
for folder, dirs, files in os.walk(os.path.join(root, "models")):
    rel = os.path.relpath(folder, root)
    dirs[:] = sorted(d for d in dirs if d not in SKIP)
    names += [os.path.join(rel, n) for n in sorted(files) if n not in SKIP and not n.startswith("._")]
h = hashlib.sha256()
for n in sorted(names):
    d = hashlib.sha256()
    with open(os.path.join(root, n), "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""): d.update(block)
    h.update(n.encode()); h.update(b"\0"); h.update(d.hexdigest().encode()); h.update(b"\n")
print(h.hexdigest()[:16])
