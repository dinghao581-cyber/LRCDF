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
                      [--notes zh=… en=…] [--merge <existing manifest.json>] [--min-os 14.0]
      writes the component zips (split into pieces of at most 95 MB), <out>/manifest.json and manifest.json.sig
      (signed with ~/.config/lrcdf/update_signing.key; see sign_manifest.swift). --merge keeps the other platforms'
      releases and components of an existing manifest. The zips go to the release as assets; manifest.json and
      manifest.json.sig go to the `update` branch of the public repository.
  make_update.py ipad <LRCDF-iPad-x.ipa> <out dir> --url https://…/download/ipad-0.2/ [--url …] [--notes zh=… en=…]
                      [--merge <existing manifest.json>] [--models ipad/app/LRCDF]
      the iPad release (docs/update/IPAD.md; AltStore route, no App Store): the models component `models-ipad` (a zip
      rooted at the models folder's parent: it holds models/… only, in pieces of at most 95 MB), the .ipa as the
      component `ipa-ipad` (one file: AltStore needs it whole), `releases.ipad`, manifest.json + .sig, and
      altstore.json (the AltStore / SideStore source; it goes to the `update` branch beside the manifest).
  Both commands take --key <private key file> (default ~/.config/lrcdf/update_signing.key; tests use a throw-away one)."""
import argparse, hashlib, json, os, plistlib, re, shutil, subprocess, time, zipfile

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
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "https://github.com/dinghao581-cyber/LRCDF"


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


def unsigned_digest(path):
    """sha256 of a Mach-O file without its code signature (codesign rewrites the signature embedded in the binary, so
    the same app hashed before and after signing would otherwise differ); other files as they are."""
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe"):
        return digest(path)
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "bin"); shutil.copyfile(path, copy)
        # removing the signature alone is not enough: the linker's signature (swift build) and codesign's leave a
        # different amount of room behind. Signing the lone copy afresh first and then removing it gives the same bytes
        # whichever signature the file had (tested 2026-11-16).
        subprocess.run(["codesign", "--force", "--sign", "-", "-i", "lrcdf.version", copy], capture_output=True)
        subprocess.run(["codesign", "--remove-signature", copy], capture_output=True)
        return digest(copy)


def app_version(app):
    """The app's own identity: everything in the bundle except the payload it installs from and its signature, the
    same before and after signing (make_bundle.sh records it before codesign, pack computes it after)."""
    root, name = os.path.split(os.path.abspath(app))
    names = [n for n in files(root, [name], [os.path.join(name, "Contents", "Resources", "LRCDF")]) if "_CodeSignature" not in n]
    h = hashlib.sha256()
    for n in names:
        full = os.path.join(root, n)
        h.update(n.encode()); h.update(b"\0")
        h.update((os.readlink(full) if os.path.islink(full) else unsigned_digest(full)).encode()); h.update(b"\n")
    return h.hexdigest()[:16]


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
    two.add_argument("--notes", nargs="*", default=[]); two.add_argument("--merge"); two.add_argument("--min-os", default="14.0")
    three = sub.add_parser("ipad"); three.add_argument("ipa"); three.add_argument("out")
    three.add_argument("--url", action="append", required=True); three.add_argument("--notes", nargs="*", default=[])
    three.add_argument("--merge"); three.add_argument("--models", default=os.path.join(HERE, "..", "ipad", "app", "LRCDF"))
    for p in (two, three):
        p.add_argument("--key", default=KEY)
    a = ap.parse_args()
    if a.what == "ipad":
        return ipad(a)
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
    manifest = start(a.merge)
    manifest["releases"][PLATFORM] = dict(version=a.version, min_os=a.min_os, notes=dict(n.split("=", 1) for n in a.notes),
                                          components=["app-mac"] + list(COMPONENTS))
    manifest["components"].update(made)
    finish(manifest, a.out, a.key)
    for cid, c in made.items():
        print(f"{cid:13s} {sum(f['size'] for f in c['files']) / 1e6:8.1f} MB in {len(c['files'])} piece(s)  version {c['version']}")
    print("manifest and signature written to", a.out)


def start(merge):
    """A new manifest, or the current one (--merge) so that the other platforms' entries are kept."""
    m = json.load(open(merge, encoding="utf-8")) if merge else dict(schema=1, channel="stable", keys=dict(next=None), releases={}, components={})
    m["published"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return m


def finish(manifest, out, key):
    path = os.path.join(out, "manifest.json")
    json.dump(manifest, open(path, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    subprocess.run(["swift", os.path.join(HERE, "sign_manifest.swift"), "sign", key, path], check=True)


def entries(files_, urls):
    return [dict(size=os.path.getsize(p), sha256=digest(p), urls=[u.rstrip("/") + "/" + os.path.basename(p) for u in urls]) for p in files_]


def ipa_info(ipa):
    """Info.plist of the app inside an .ipa (Payload/<name>.app/Info.plist)."""
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            raise SystemExit(f"STOP: {ipa} is not an app (.ipa with one Payload/*.app)")
        info = plistlib.loads(z.read(names[0]))
        bad = [n for n in z.namelist() if not n.startswith("Payload/") or "/._" in n or n.endswith(".DS_Store")]
        if bad:
            raise SystemExit(f"STOP: unexpected entries in the .ipa: {bad[:5]}")
    return info


def ipad(a):
    """The iPad release for the AltStore route: models-ipad, ipa-ipad, releases.ipad, signed manifest, altstore.json."""
    info = ipa_info(a.ipa)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if info.get("CFBundleIdentifier") != "com.ding.lrcdf.ipad":
        raise SystemExit(f"STOP: bundle identifier {info.get('CFBundleIdentifier')}")
    root = os.path.abspath(a.models)
    names = files(root, ["models"], [])
    if not names:
        raise SystemExit(f"STOP: no models under {root}/models")
    if any(os.path.islink(os.path.join(root, n)) for n in names):
        raise SystemExit("STOP: links in the models folder (the iPad refuses them)")
    mversion = identity(root, names)
    stamp = os.path.join(root, "BuildStamp.swift")
    built = re.search(r'"([0-9a-f]{16})"', open(stamp).read()).group(1) if os.path.exists(stamp) else None
    if built != mversion:
        print(f"note: the models now ({mversion}) differ from the ones the last build put in the app ({built}):"
              " installed apps will download these models")
    os.makedirs(a.out, exist_ok=True)
    zpath = os.path.join(a.out, f"models-ipad-{mversion}.zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:      # stored/deflated only: what the iPad reads
        for n in names:
            z.write(os.path.join(root, n), n)
    joined = digest(zpath)
    models = dict(version=mversion, install="models", keep=[], restart="none", files=entries(pieces(zpath), a.url))
    if len(models["files"]) > 1:
        models["sha256_joined"] = joined
    ipa = os.path.join(a.out, f"LRCDF-iPad-{version}.ipa")
    if os.path.abspath(a.ipa) != ipa:
        shutil.copyfile(a.ipa, ipa)
    shipped = dict(version=f"{version}-{build}", install="app", keep=[], restart="none", files=entries([ipa], a.url))
    notes = dict(n.split("=", 1) for n in a.notes)
    manifest = start(a.merge)
    manifest["releases"]["ipad"] = dict(version=version, min_os=info.get("MinimumOSVersion", "27.0"), notes=notes,
                                        components=["models-ipad"], ipa="ipa-ipad")
    manifest["components"]["models-ipad"] = models
    manifest["components"]["ipa-ipad"] = shipped
    finish(manifest, a.out, a.key)
    privacy = {k: v for k, v in info.items() if re.fullmatch(r"NS\w+UsageDescription", k)}
    icon = "https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/main/ipad/app/LRCDF/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
    note = notes.get("zh") or notes.get("en") or ""
    altstore = dict(
        name="LRCDF", identifier="io.github.dinghao581-cyber.lrcdf", subtitle="一键修图 for iPad",
        description="LRCDF: one-click portrait retouch, all on the device.", iconURL=icon, website=REPO, tintColor="#F5C400",
        apps=[dict(
            name=info.get("CFBundleDisplayName", "一键修图"), bundleIdentifier=info["CFBundleIdentifier"],
            developerName="LRCDF contributors", subtitle="One-click portrait retouch",
            localizedDescription="Tone looks and skin retouch (frequency separation) on the iPad, offline.",
            iconURL=icon, tintColor="#F5C400", category="photo-video",
            appPermissions=dict(entitlements=[], privacy=privacy),
            versions=[dict(version=version, buildVersion=str(build), date=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                           localizedDescription=note, downloadURL=shipped["files"][0]["urls"][0],
                           size=shipped["files"][0]["size"], minOSVersion=info.get("MinimumOSVersion", "27.0"))])],
        news=[])
    json.dump(altstore, open(os.path.join(a.out, "altstore.json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"models-ipad {sum(f['size'] for f in models['files']) / 1e6:8.1f} MB in {len(models['files'])} piece(s)  version {mversion}")
    print(f"ipa-ipad    {shipped['files'][0]['size'] / 1e6:8.1f} MB  version {version} ({build})")
    print("manifest, signature and altstore.json written to", a.out)


if __name__ == "__main__":
    main()
