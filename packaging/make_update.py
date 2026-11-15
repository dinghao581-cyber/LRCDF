#!/usr/bin/env python3
"""Updates in parts: what an installed LRCDF downloads instead of the whole 1.8 GB app.
The contract is docs/update/UPDATE_MANIFEST.md: one signed manifest for every platform, `releases` per platform and
`components` that are downloaded only when their version changed. On the Mac an installation is made of:
  app-mac       LRCDF.app without its payload              about 1 MB   changes with almost every release
  code          project/ without runs (scripts, plug-in)   about 1 MB   changes with almost every release
  models-own    project/runs (our own trained models)      ~200 MB      when a model is retrained
  models-third  models/ and legacy/ (third-party models)   ~1.2 GB      hardly ever
  python-mac    python/ (interpreter and packages)         ~0.4 GB      rarely
A component's version is a hash of its contents (over the sorted list of files and their hashes): the manifest only
asks "equal or not", so nothing has to be numbered by hand and an unchanged component is never downloaded again.

usage:
  make_update.py ids <LRCDF.app>
      writes <app>/Contents/Resources/LRCDF/COMPONENTS.json (the versions of what the all-in-one app installs);
      packaging/make_bundle.sh calls it, first_run.sh copies it to ~/LRCDF/.components.json
  make_update.py pack <LRCDF.app> <out dir> --version 0.1.2 --url https://…/download/v0.1.2/ [--url …]
                      [--notes zh=… en=…] [--merge <existing manifest.json>] [--min-os 26.0]
      writes the component zips (split into pieces of at most 95 MB), <out>/manifest.json and manifest.json.sig
      (signed with ~/.config/lrcdf/update_signing.key; see sign_manifest.swift). --merge keeps the other platforms'
      releases and components of an existing manifest. The zips go to the release as assets; manifest.json and
      manifest.json.sig go to the `update` branch of the public repository."""
import argparse, hashlib, json, os, shutil, subprocess, time

COMPONENTS = {      # id -> (install targets relative to ~/LRCDF, paths inside them that are another component's, restart)
    "code": (["project"], ["project/runs"], "lightroom-if-menu-changed"),
    "models-own": (["project/runs"], [], "none"),
    "models-third": (["models", "legacy"], [], "none"),
    "python-mac": (["python"], [], "app"),
}
PLATFORM = "mac-arm64"
PIECE = 95_000_000
SKIP = ("__pycache__", ".DS_Store")
KEY = os.path.expanduser("~/.config/lrcdf/update_signing.key")


def files(root, paths, without):
    out = []
    for p in paths:
        for folder, dirs, names in os.walk(os.path.join(root, p)):
            rel = os.path.relpath(folder, root)
            dirs[:] = sorted(d for d in dirs if d not in SKIP and os.path.join(rel, d) not in without)
            out += [os.path.join(rel, n) for n in sorted(names) if n not in SKIP and not n.startswith("._")]
    return sorted(out)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def identity(root, names):
    h = hashlib.sha256()
    for name in names:
        full = os.path.join(root, name)
        h.update(name.encode()); h.update(b"\0")
        h.update((os.readlink(full) if os.path.islink(full) else digest(full)).encode()); h.update(b"\n")
    return h.hexdigest()[:16]


def app_version(app):
    """The app's own identity: everything in the bundle except the payload it installs from and its signature."""
    root, name = os.path.split(os.path.abspath(app))
    names = [n for n in files(root, [name], [os.path.join(name, "Contents", "Resources", "LRCDF")]) if "_CodeSignature" not in n]
    return identity(root, names)


def versions(app):
    payload = os.path.join(app, "Contents", "Resources", "LRCDF")
    out = {cid: identity(payload, files(payload, paths, without)) for cid, (paths, without, _) in COMPONENTS.items()}
    out["app-mac"] = app_version(app)
    return out


def pieces(path):
    """Split a file into pieces of at most PIECE bytes (path.001, …) if it is larger; returns the piece paths."""
    if os.path.getsize(path) <= PIECE:
        return [path]
    out = []
    with open(path, "rb") as f:
        while True:
            block = f.read(PIECE)
            if not block:
                break
            out.append(f"{path}.{len(out) + 1:03d}")
            open(out[-1], "wb").write(block)
    os.remove(path)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="what", required=True)
    one = sub.add_parser("ids"); one.add_argument("app")
    two = sub.add_parser("pack"); two.add_argument("app"); two.add_argument("out")
    two.add_argument("--version", required=True); two.add_argument("--url", action="append", required=True)
    two.add_argument("--notes", nargs="*", default=[]); two.add_argument("--merge"); two.add_argument("--min-os", default="26.0")
    a = ap.parse_args()
    if a.what == "ids":
        json.dump(versions(a.app), open(os.path.join(a.app, "Contents", "Resources", "LRCDF", "COMPONENTS.json"), "w"), indent=1)
        return
    payload = os.path.join(a.app, "Contents", "Resources", "LRCDF")
    os.makedirs(a.out, exist_ok=True)
    made = {}
    for cid, (paths, without, restart) in COMPONENTS.items():
        names = files(payload, paths, without)
        version = identity(payload, names)
        target = os.path.join(a.out, f"{cid}-{version}.zip")
        stage = target + ".stage"
        shutil.rmtree(stage, ignore_errors=True)
        for n in names:         # the zip is rooted at the installation folder: it holds exactly the install targets
            dest = os.path.join(stage, n); os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.islink(os.path.join(payload, n)):
                os.symlink(os.readlink(os.path.join(payload, n)), dest)
            else:
                shutil.copy2(os.path.join(payload, n), dest)
        subprocess.run(["ditto", "-c", "-k", "--norsrc", stage, target], check=True)
        shutil.rmtree(stage)
        made[cid] = dict(version=version, install=paths if len(paths) > 1 else paths[0], keep=without, restart=restart, _zip=target)
    slim = os.path.join(a.out, "app.stage", "LRCDF.app")       # the app without the payload it installs from
    shutil.rmtree(os.path.dirname(slim), ignore_errors=True)
    subprocess.run(["ditto", "--norsrc", a.app, slim], check=True)
    shutil.rmtree(os.path.join(slim, "Contents", "Resources", "LRCDF"))
    subprocess.run(["codesign", "--force", "--sign", "-", slim], check=True, capture_output=True)
    version = app_version(a.app)
    target = os.path.join(a.out, f"app-mac-{version}.zip")
    subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", slim, target], check=True)
    shutil.rmtree(os.path.dirname(slim))
    made["app-mac"] = dict(version=version, install="app", keep=[], restart="app", _zip=target)
    for cid, c in made.items():
        joined = digest(c["_zip"])
        c["files"] = [dict(size=os.path.getsize(p), sha256=digest(p), urls=[u.rstrip("/") + "/" + os.path.basename(p) for u in a.url])
                      for p in pieces(c.pop("_zip"))]
        if len(c["files"]) > 1:
            c["sha256_joined"] = joined
    manifest = json.load(open(a.merge, encoding="utf-8")) if a.merge else dict(schema=1, channel="stable", keys=dict(next=None), releases={}, components={})
    manifest["published"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    manifest["releases"][PLATFORM] = dict(version=a.version, min_os=a.min_os, notes=dict(n.split("=", 1) for n in a.notes),
                                          components=["app-mac"] + list(COMPONENTS))
    manifest["components"].update(made)
    path = os.path.join(a.out, "manifest.json")
    json.dump(manifest, open(path, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run(["swift", os.path.join(here, "sign_manifest.swift"), "sign", KEY, path], check=True)
    for cid, c in made.items():
        print(f"{cid:13s} {sum(f['size'] for f in c['files']) / 1e6:8.1f} MB in {len(c['files'])} piece(s)  version {c['version']}")
    print("manifest and signature written to", a.out)


if __name__ == "__main__":
    main()
