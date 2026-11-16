"""Signed Windows updates. The UI owns scheduling, consent and restart timing."""

from __future__ import annotations

import base64
import hashlib
import http.client
import json
import re
import shutil
import stat
import threading
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PureWindowsPath
from urllib.parse import urljoin, urlsplit

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from packaging.version import Version


QUIET_LIMIT = 60_000_000
PIECE_LIMIT = 95_000_000
_BLOCK = 1024 * 1024
_RESTART = {"none", "app", "lightroom", "lightroom-if-menu-changed"}
_TARGETS = {"project", "project/runs", "models", "legacy", "python", "app"}
_COMMON = {"code-win": {"project"}, "models-own-win": {"project/runs"},
           "models-third-win": {"models", "legacy"}, "app-win": {"app"}}
_PLATFORM_PYTHON = {"win-x64-cpu": "python-win-cpu", "win-x64-cu124": "python-win-cu124"}


class UpdateError(Exception):
    """A download or stage could not be prepared."""


class UpdateCancelled(UpdateError):
    pass


class _IntegrityError(UpdateError):
    pass


@dataclass(frozen=True)
class Piece:
    size: int
    sha256: str
    urls: tuple[str, ...]


@dataclass(frozen=True)
class Component:
    name: str
    version: str
    targets: tuple[str, ...]
    keep: tuple[str, ...]
    restart: str
    pieces: tuple[Piece, ...]
    joined: str | None


@dataclass(frozen=True)
class Offer:
    version: str
    notes: dict[str, str]
    bytes: int
    manual: bool
    download_url: str
    components: tuple[Component, ...]
    platform: str
    published: datetime


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _cancelled(stop: threading.Event) -> None:
    if stop.is_set():
        raise UpdateCancelled()


def _read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def _atomic_text(path: Path, content: str) -> None:
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(content, encoding="utf-8")
    temp.replace(path)


def _published(value: str) -> datetime:
    stamp = datetime.fromisoformat(value)
    _require(stamp.tzinfo is not None, "Missing publication timezone")
    return stamp.astimezone(timezone.utc)


def _version(value: str) -> Version:
    _require(isinstance(value, str) and re.fullmatch(r"[0-9][A-Za-z0-9._+-]{0,63}", value) is not None,
             "Invalid release version")
    return Version(value)


def _entries(value, allowed) -> tuple:
    _require(isinstance(value, (str, list)), "Invalid install destinations")
    items = (value,) if isinstance(value, str) else tuple(value)
    _require(bool(items) and all(isinstance(item, str) for item in items) and
             len(set(items)) == len(items) and set(items) <= allowed, "Invalid install destinations")
    return items


def _path_parts(name: str) -> tuple[str, ...]:
    parts = tuple(name.split("/"))
    if not all(part and part not in (".", "..") and part[-1] not in ". "
               and not re.search(r'[<>:"\\|?*\x00-\x1f]', part)
               and not PureWindowsPath(part).is_reserved() for part in parts):
        raise ValueError("Invalid archive or keep path")
    return parts


def _under(path: str, target: str) -> bool:
    return path == target or path.startswith(target + "/")


def _keep(data: dict, targets: tuple[str, ...]) -> tuple[str, ...]:
    paths = data.get("keep", [])
    _require(isinstance(paths, list), "Invalid keep paths")
    for path in paths:
        _require(isinstance(path, str), "Invalid keep path")
        _path_parts(path)
        _require(any(path.startswith(t + "/") for t in targets), "Keep path is outside a target")
    return tuple(dict.fromkeys(paths))


def _digest(value: str) -> str:
    _require(isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{64}", value) is not None,
             "Invalid SHA-256")
    return value.lower()


def _url(url: str):
    parts = urlsplit(url)
    _require(parts.scheme in ("http", "https") and bool(parts.hostname) and
             not parts.username and not parts.password and not parts.fragment, "Invalid update URL")
    return parts


def _component(name: str, data: dict, platform: str) -> Component:
    allowed = _COMMON | {_PLATFORM_PYTHON[platform]: {"python"}}
    targets = _entries(data["install"], _TARGETS)
    _require(name in allowed and set(targets) == allowed[name], "Component targets do not match ownership")
    keep = _keep(data, targets)
    if name == "code-win":
        # Windows keeps its separately versioned desktop app at the plug-in's existing launch path.
        keep = tuple(dict.fromkeys((*keep, "project/runs", "project/app/windows")))
    restart = data.get("restart", "none")
    _require(restart in _RESTART, "Invalid restart kind")
    version = data["version"]
    _require(isinstance(version, str) and bool(version), "Missing component version")
    pieces = []
    for piece in data["files"]:
        size, urls = piece["size"], piece["urls"]
        _require(type(size) is int and 0 < size <= PIECE_LIMIT, "Invalid piece size")
        _require(isinstance(urls, list) and bool(urls), "Missing piece URL")
        for url in urls:
            _url(url)
        pieces.append(Piece(size, _digest(piece["sha256"]), tuple(urls)))
    joined = data.get("sha256_joined")
    _require(bool(pieces) and (len(pieces) == 1 or joined is not None), "Missing piece or joined hash")
    return Component(name, version, targets, keep, restart, tuple(pieces), _digest(joined) if joined is not None else None)


class UpdateClient:
    _sources = (
        "https://gitee.com/YMLFPV/LRCDF/raw/update/manifest.json",
        "https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/update/manifest.json",
    )
    _public_key = "KIaPbT+ihd/fLIOCt51e3HrS5ZykKWXtVuWlmiGU6kU="
    download_url = "https://github.com/dinghao581-cyber/LRCDF/releases"

    def __init__(self, root: Path):
        self.root = Path(root)

    @property
    def installed(self) -> tuple[str, str, dict[str, str]] | None:
        if (self.root / "project" / ".git").exists():
            return None
        try:
            build = _read_json(self.root / ".update_build.json")
            platform, version = build["platform"], build["version"]
            _version(version)
            components = _read_json(self.root / ".components.json")
            _require(platform in _PLATFORM_PYTHON and isinstance(components, dict) and
                     all(isinstance(value, str) for value in components.values()), "Invalid installed record")
            return platform, version, components
        except (OSError, ValueError, KeyError, TypeError):
            return None

    @contextmanager
    def _open(self, url: str, header: str, stop: threading.Event, *, offset: int = 0, manifest: bool = False):
        for _ in range(6):
            _cancelled(stop)
            parsed = _url(url)
            if manifest and "?" in url:
                raise UpdateError("Manifest requests cannot have query parameters")
            connection_class = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
            conn = connection_class(parsed.hostname, parsed.port, timeout=12)
            try:
                path = parsed.path or "/"
                if parsed.query:
                    path += "?" + parsed.query
                conn.putrequest("GET", path, skip_accept_encoding=True)
                conn.putheader("User-Agent", header)
                if offset:
                    conn.putheader("Range", f"bytes={offset}-")
                conn.endheaders()
                response = conn.getresponse()
                if response.status not in (301, 302, 303, 307, 308):
                    yield response
                    return
                location = response.getheader("Location")
                if not location:
                    break
                url = urljoin(url, location)
                if parsed.scheme == "https" and _url(url).scheme != "https":
                    raise UpdateError("Insecure update redirect")
            finally:
                conn.close()
        raise UpdateError("Update redirect did not reach a file")

    def _small_file(self, url: str, header: str, stop: threading.Event, limit: int) -> bytes:
        with self._open(url, header, stop, manifest=True) as response:
            if response.status != 200:
                raise UpdateError("Update manifest unavailable")
            data = response.read(limit + 1)
        _cancelled(stop)
        if len(data) > limit:
            raise UpdateError("Unexpected manifest size")
        return data

    def _newest(self) -> datetime | None:
        try:
            return _published((self.root / ".update_seen").read_text(encoding="utf-8").strip())
        except FileNotFoundError:
            return None

    @staticmethod
    def _agent(platform: str, version: str) -> str:
        return f"LRCDF/{version} ({platform})"

    def _interpret(self, data: bytes, platform: str, current: str, installed: dict[str, str]):
        manifest = json.loads(data)
        schema = manifest["schema"]
        _require(type(schema) is int and schema >= 1, "Invalid manifest schema")
        published = _published(manifest["published"])
        newest = self._newest()
        if newest is not None and published < newest:
            raise ValueError("Older update manifest")

        components = manifest.get("components")
        if schema == 1:
            _require(isinstance(components, dict), "Invalid component table")
        if isinstance(components, dict):
            for value in components.values():
                install = value.get("install") if isinstance(value, dict) else None
                comparable = isinstance(install, str) or (
                    isinstance(install, list) and all(isinstance(path, str) for path in install)
                )
                if schema == 1 or comparable:
                    targets = _entries(install, _TARGETS)
                    if schema == 1:
                        _keep(value, targets)

        if schema > 1:
            releases = manifest.get("releases")
            release = releases.get(platform) if isinstance(releases, dict) else None
            available = release.get("version") if isinstance(release, dict) else None
            version = available if isinstance(available, str) else ""
            offer = Offer(version, {}, 0, True, self.download_url, (), platform, published)
        else:
            _require(manifest["channel"] == "stable", "Unexpected update channel")
            release = manifest["releases"].get(platform)
            offer = None
            if release:
                version = release["version"]
                newer = _version(version) > _version(current)
                names = release["components"]
                _require(isinstance(names, list) and len(set(names)) == len(names), "Invalid release component list")
                checked = tuple(_component(name, components[name], platform) for name in names)
                needed = tuple(part for part in checked if installed.get(part.name) != part.version)
                if newer and needed:
                    notes = release.get("notes") or {}
                    _require(isinstance(notes, dict) and all(isinstance(t, str) for t in notes.values()),
                             "Invalid release notes")
                    size = sum(piece.size for part in needed for piece in part.pieces)
                    offer = Offer(version, notes, size, False, self.download_url, needed, platform, published)
        if newest is None or published > newest:
            _atomic_text(self.root / ".update_seen", published.isoformat().replace("+00:00", "Z"))
        return offer

    def check(self, stop: threading.Event) -> Offer | None:
        """Use the first signed, current manifest. No connection from a developer checkout."""
        _cancelled(stop)
        state = self.installed
        if state is None:
            return None
        platform, current, installed = state
        header = self._agent(platform, current)
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(self._public_key, validate=True))
        for url in self._sources:
            try:
                data = self._small_file(url, header, stop, 1024 * 1024)
                sig = base64.b64decode(self._small_file(url + ".sig", header, stop, 512).strip(), validate=True)
                key.verify(sig, data)
                _cancelled(stop)
                return self._interpret(data, platform, current, installed)
            except UpdateCancelled:
                raise
            except (OSError, http.client.HTTPException, InvalidSignature, UpdateError,
                    ValueError, KeyError, TypeError, AttributeError, OverflowError):
                continue
        return None

    def _fetch_piece(self, piece: Piece, path: Path, header: str, stop: threading.Event) -> None:
        for url in piece.urls:
            _cancelled(stop)
            offset = path.stat().st_size if path.exists() else 0
            if offset > piece.size:
                raise _IntegrityError("Incorrect update piece size")
            if offset == piece.size:
                return
            try:
                with self._open(url, header, stop, offset=offset) as response:
                    if response.status == 200:
                        offset = 0
                    elif response.status == 206 and offset:
                        content_range = response.getheader("Content-Range") or ""
                        if content_range != f"bytes {offset}-{piece.size - 1}/{piece.size}":
                            continue
                    else:
                        continue
                    _cancelled(stop)
                    with path.open("ab" if offset else "wb") as out:
                        while True:
                            _cancelled(stop)
                            block = response.read(min(_BLOCK, piece.size - offset + 1))
                            if not block:
                                break
                            offset += len(block)
                            if offset > piece.size:
                                raise _IntegrityError("Incorrect update piece size")
                            out.write(block)
                if offset == piece.size:
                    return
            except (OSError, http.client.HTTPException, ValueError):
                continue
            except UpdateError as error:
                if isinstance(error, (UpdateCancelled, _IntegrityError)):
                    raise
        raise UpdateError("The update download was interrupted. Try again to resume.")

    def _verified_zip(self, part: Component, downloads: Path, header: str, stop: threading.Event) -> Path:
        archive = downloads / f"{part.name}.zip"
        whole = hashlib.sha256() if part.joined else None
        with archive.open("wb") as output:
            for number, piece in enumerate(part.pieces):
                piece_path = downloads / f"{part.name}-{number}-{piece.sha256}.part"
                self._fetch_piece(piece, piece_path, header, stop)
                received = hashlib.sha256()
                with piece_path.open("rb") as source:
                    for block in iter(lambda: source.read(_BLOCK), b""):
                        _cancelled(stop)
                        received.update(block)
                        if whole is not None:
                            whole.update(block)
                        output.write(block)
                if received.hexdigest() != piece.sha256:
                    raise _IntegrityError("An update piece failed its SHA-256 check")
        if whole is not None and whole.hexdigest() != part.joined:
            raise _IntegrityError("The joined update failed its SHA-256 check")
        return archive

    @staticmethod
    def _extract(part: Component, archive: Path, output: Path, stop: threading.Event) -> None:
        try:
            with zipfile.ZipFile(archive) as package:
                for item in package.infolist():
                    _cancelled(stop)
                    name = item.filename.removesuffix("/") if item.is_dir() else item.filename
                    parts = _path_parts(name)
                    owned = any(_under(name, target) for target in part.targets)
                    if item.is_dir() and any(target.startswith(name + "/") for target in part.targets):
                        continue  # A ZIP can explicitly contain parent folders.
                    mode = stat.S_IFMT(item.external_attr >> 16)
                    if not owned or mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                        raise ValueError("Archive contains files outside its component")
                    if any(_under(name.casefold(), keep.casefold()) for keep in part.keep):
                        raise ValueError("Archive contains a separately owned path")
                    if part.name == "app-win" and not _under(name, "app/windows") and name != "app":
                        raise ValueError("Windows app ZIP must contain app/windows")
                    destination = output.joinpath(*parts)
                    if item.is_dir():
                        destination.mkdir(parents=True, exist_ok=True)
                    else:
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        with package.open(item) as source, destination.open("xb") as target:
                            for block in iter(lambda: source.read(_BLOCK), b""):
                                _cancelled(stop)
                                target.write(block)
            if not all((output / target).is_dir() for target in part.targets):
                raise ValueError("Archive is missing its target folder")
            if part.name == "app-win" and not (output / "app/windows/LRCDF.exe").is_file():
                raise ValueError("Windows app archive is missing its launcher")
        except (OSError, ValueError, RuntimeError, NotImplementedError, zipfile.BadZipFile) as error:
            raise _IntegrityError("An update archive contains invalid files") from error

    def _menu_changed(self, staged_project: Path) -> bool:
        def content(path: Path) -> bytes | None:
            try:
                return path.read_bytes()
            except FileNotFoundError:
                return None

        plugin = Path("plugin/LRCDFAuto.lrplugin")
        old, new = self.root / "project" / plugin, staged_project / plugin
        old_info, new_info = content(old / "Info.lua"), content(new / "Info.lua")
        if old_info != new_info:
            return True
        menus = re.findall(rb"""\bfile\s*=\s*["']([A-Za-z0-9_.-]+\.lua)["']""", new_info or b"")
        return any(content(old / name.decode("ascii")) != content(new / name.decode("ascii")) for name in menus)

    def stage(self, offer: Offer, stop: threading.Event) -> Path:
        """Verify all requested pieces and archives before marking the stage ready."""
        _cancelled(stop)
        state = self.installed
        newest = self._newest()
        if (state is None or offer.manual or not offer.components or offer.platform != state[0] or
                _version(offer.version) <= _version(state[1]) or (newest is not None and offer.published < newest)):
            raise UpdateError("This update is no longer available")
        stage = self.root / ".update" / offer.version
        expected_parent = (self.root / ".update").resolve()
        if stage.resolve().parent != expected_parent:
            raise UpdateError("Invalid update stage")
        if (stage / "READY").is_file():
            plan = _read_json(stage / "plan.json")
            if plan.get("published") == offer.published.isoformat():
                return stage
        (stage / "READY").unlink(missing_ok=True)
        downloads, files = stage / "downloads", stage / "files"
        downloads.mkdir(parents=True, exist_ok=True)
        try:
            header = self._agent(state[0], state[1])
            archives = [(part, self._verified_zip(part, downloads, header, stop)) for part in offer.components]
            if files.exists():
                shutil.rmtree(files)
            targets, restart_lightroom = [], False
            installed = dict(state[2])
            for part, archive in archives:
                output = files / part.name
                self._extract(part, archive, output, stop)
                for target in part.targets:
                    payload = "app/windows" if target == "app" else target
                    targets.append({"target": target, "keep": [p for p in part.keep if p.startswith(target + "/")],
                                    "source": f"files/{part.name}/{payload}"})
                if part.restart == "lightroom" or (
                        part.restart == "lightroom-if-menu-changed" and "project" in part.targets and
                        self._menu_changed(output / "project")):
                    restart_lightroom = True
                installed[part.name] = part.version
            _cancelled(stop)
            targets.sort(key=lambda item: 2 if item["target"] == "app" else item["target"].count("/"))
            plan = {"version": offer.version, "platform": offer.platform, "components": installed,
                    "targets": targets, "restart_lightroom": restart_lightroom,
                    "published": offer.published.isoformat()}
            _atomic_text(stage / "plan.json", json.dumps(plan, ensure_ascii=False))
            _atomic_text(stage / "READY", offer.version)
        except _IntegrityError:
            shutil.rmtree(stage)
            raise
        # Ready stages only need extracted files. Retain piece files only while a download can still resume.
        shutil.rmtree(downloads, ignore_errors=True)
        return stage
