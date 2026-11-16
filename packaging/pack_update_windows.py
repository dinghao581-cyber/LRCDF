"""Build the unsigned Windows release entries, or record the contents of a full Windows bundle."""
import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path
from urllib.parse import urlsplit
from zipfile import ZIP_DEFLATED, ZIP64_LIMIT, ZipFile, ZipInfo


PART_SIZE = 95_000_000
BLOCK_SIZE = 1 << 20
VARIANTS = ("cpu", "cu124")
# Each pair maps a manifest-relative name to the folder in a Windows full bundle.
APP_TREE = ("app/windows", "project/app/windows")
# Only project/app/windows belongs to the separate Windows app component.
SHARED = (
    ("code", (("project", "project"),), ("project/app/windows", "project/runs")),
    ("models-own", (("project/runs", "project/runs"),), ()),
    ("models-third", (("models", "models"), ("legacy", "legacy")), ()),
)
SKIP = {"__pycache__", ".DS_Store"}


def component_files(root, trees, exclude=()):
    entries = []
    for logical, physical in trees:
        source = root / physical
        if not source.is_dir():
            raise ValueError(f"Missing component folder: {source}")
        for directory, folders, names in os.walk(source):
            parent = Path(directory)
            logical_parent = Path(logical) / parent.relative_to(source)
            folders[:] = [
                name for name in folders
                if name not in SKIP and (logical_parent / name).as_posix() not in exclude
            ]
            entries.extend(
                ((logical_parent / name).as_posix(), parent / name)
                for name in names if name not in SKIP and not name.startswith("._")
            )
    if not entries:
        raise ValueError(f"Empty component: {trees[0][0]}")
    return sorted(entries)


def file_digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def component_version(entries):
    """Use make_update.py's sorted path NUL sha256 newline identity, with manifest slashes."""
    digest = hashlib.sha256()
    for logical, path in entries:
        contents = os.readlink(path) if path.is_symlink() else file_digest(path)
        digest.update(f"{logical}\0{contents}\n".encode("utf-8"))
    return digest.hexdigest()[:16]


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def release_version(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", value):
        raise argparse.ArgumentTypeError("Expected a numeric release version, such as 0.1.2.")
    return value


def record_bundle(root, variant, version):
    identities = {
        component: component_version(component_files(root, trees, exclude))
        for component, trees, exclude in SHARED
    }
    identities["app-win"] = component_version(component_files(root, (APP_TREE,)))
    identities[f"python-win-{variant}"] = component_version(
        component_files(root, (("python", "python"),))
    )
    write_json(root / ".components.json", identities)
    write_json(root / ".update_build.json", {"platform": f"win-x64-{variant}", "version": version})


def build_record(root, variant):
    record = json.loads((root / ".update_build.json").read_text(encoding="utf-8"))
    if record["platform"] != f"win-x64-{variant}":
        raise ValueError(f"{root} is not a Windows {variant} bundle.")
    return release_version(record["version"])


def create_zip(path, entries):
    # Fixed ZIP metadata makes one content identity produce one archive.
    with ZipFile(path, "w", compression=ZIP_DEFLATED) as archive:
        for logical, source in entries:
            if source.is_symlink():
                raise ValueError(f"Windows update archives require regular files: {source}")
            member = ZipInfo(logical)
            member.compress_type = ZIP_DEFLATED
            member.file_size = source.stat().st_size
            with source.open("rb") as source_stream:
                with archive.open(member, "w", force_zip64=member.file_size >= ZIP64_LIMIT) as destination:
                    shutil.copyfileobj(source_stream, destination, BLOCK_SIZE)


def file_entry(path, urls, sha256):
    return {
        "size": path.stat().st_size,
        "sha256": sha256,
        "urls": [f"{folder.rstrip('/')}/{path.name}" for folder in urls],
    }


def zip_parts(archive_path, urls):
    if archive_path.stat().st_size <= PART_SIZE:
        return [file_entry(archive_path, urls, file_digest(archive_path))], None

    entries = []
    joined = hashlib.sha256()
    with archive_path.open("rb") as source:
        while block := source.read(min(BLOCK_SIZE, PART_SIZE)):
            path = archive_path.with_suffix(f"{archive_path.suffix}.{len(entries) + 1:03d}")
            digest = hashlib.sha256()
            remaining = PART_SIZE
            with path.open("xb") as part:
                while block:
                    part.write(block)
                    digest.update(block)
                    joined.update(block)
                    remaining -= len(block)
                    if remaining == 0:
                        break
                    block = source.read(min(BLOCK_SIZE, remaining))
            entries.append(file_entry(path, urls, digest.hexdigest()))
    archive_path.unlink()
    return entries, joined.hexdigest()


def pack_component(out, urls, component, target, version, entries):
    archive_path = out / f"{component}-{version}.zip"
    create_zip(archive_path, entries)
    files, joined = zip_parts(archive_path, urls)
    result = {"version": version, "install": target, "restart": "app", "files": files}
    if joined is not None:
        result["sha256_joined"] = joined
    print(f"{component}: {version}, {len(files)} part(s), {sum(part['size'] for part in files)} bytes")
    return result


def pack_windows(out, urls, cpu, cuda, notes):
    version = build_record(cpu, "cpu")
    if build_record(cuda, "cu124") != version:
        raise ValueError("The CPU and CUDA bundles must have the same release version.")
    app = component_files(cpu, (APP_TREE,))
    app_version = component_version(app)
    if component_version(component_files(cuda, (APP_TREE,))) != app_version:
        raise ValueError("The CPU and CUDA desktop files must match. Reuse the CPU build's LRCDF.exe.")
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        raise ValueError(f"Choose an empty output directory: {out}")

    components = {"app-win": pack_component(out, urls, "app-win", "app", app_version, app)}
    releases = {}
    for variant, bundle in zip(VARIANTS, (cpu, cuda)):
        component = f"python-win-{variant}"
        entries = component_files(bundle, (("python", "python"),))
        components[component] = pack_component(
            out, urls, component, "python", component_version(entries), entries
        )
        releases[f"win-x64-{variant}"] = {
            "version": version,
            "min_os": "10.0",
            "notes": notes,
            "components": ["app-win", "code", "models-own", "models-third", component],
        }

    # The release Mac merges this input, adds shared components and published, and signs once.
    manifest = {
        "schema": 1, "channel": "stable", "keys": {"next": None},
        "releases": releases, "components": components,
    }
    write_json(out / "windows-manifest.json", manifest)


def asset_folder(value):
    uri = urlsplit(value)
    if uri.scheme not in {"http", "https"} or not uri.hostname or uri.query or uri.fragment:
        raise argparse.ArgumentTypeError("Expected an HTTP(S) asset folder URL without query or fragment.")
    return value


def note(value):
    language, equals, message = value.partition("=")
    if not language or not equals or not message:
        raise argparse.ArgumentTypeError("Expected an update note in language=text form.")
    return language, message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    ids = commands.add_parser("ids", help="record the contents of a full Windows bundle")
    ids.add_argument("bundle", type=Path, help="the LRCDF payload directory")
    ids.add_argument("--variant", required=True, choices=VARIANTS)
    ids.add_argument("--version", required=True, type=release_version)
    pack = commands.add_parser("pack", help="make unsigned Windows update archives and entries")
    pack.add_argument("out", type=Path)
    pack.add_argument("--cpu", required=True, type=Path, help="the CPU bundle's LRCDF payload directory")
    pack.add_argument("--cu124", required=True, type=Path, help="the CUDA bundle's LRCDF payload directory")
    pack.add_argument("--url", required=True, action="append", type=asset_folder)
    pack.add_argument("--notes", nargs="*", default=[], type=note, metavar="language=text")
    args = parser.parse_args()
    try:
        if args.command == "ids":
            record_bundle(args.bundle, args.variant, args.version)
        else:
            pack_windows(args.out, args.url, args.cpu, args.cu124, dict(args.notes))
    except (OSError, ValueError, KeyError, argparse.ArgumentTypeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
