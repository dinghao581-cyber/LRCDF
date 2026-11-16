"""Keeps the folder of preview pictures from growing without end (main session, 2026-11-16; the Mac's Cache.swift):
every photo looked at leaves its looks there, and a whole batch is now loaded at once. Above 3 GB the photo folders
least recently changed go first, until it is below 2 GB.

What may be deleted, and nothing else: a folder directly inside the previews folder, whose name is a photo's id and
the picture size ("2243_2600", "<UUID>_2600"), that is not a link or junction, whose resolved path is under the
resolved previews folder, and that is not one of the folders `keep` names (the batch on screen). The previews folder
itself, thumbs, before, after and anything outside are never touched; any check that fails skips that folder."""
import os
import re
import shutil
import stat
import threading
from pathlib import Path

LIMIT = 3_000_000_000
TARGET = 2_000_000_000
NAME = re.compile(r"^(?:[0-9]+|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})_[0-9]+$")


def _linked(path: Path) -> bool:
    """A symbolic link or a directory junction (Windows): never followed, never deleted."""
    try:
        if path.is_symlink() or os.path.isjunction(path):
            return True
        attributes = getattr(os.lstat(path), "st_file_attributes", 0)
        return bool(attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)
    except OSError:
        return True


def _size(path: Path) -> int:
    """The bytes of the files under a folder (or of one file), without following links."""
    try:
        if not path.is_dir() or _linked(path):
            return os.lstat(path).st_size
    except OSError:
        return 0
    total = 0
    for top, dirs, files in os.walk(path, followlinks=False):
        dirs[:] = [d for d in dirs if not _linked(Path(top) / d)]
        for name in files:
            try:
                total += os.lstat(os.path.join(top, name)).st_size
            except OSError:
                pass
    return total


def trim_now(base: Path, keep=()) -> list[str]:
    """Delete old photo folders while the previews folder is over the limit; returns the names deleted."""
    base = Path(base)
    if base.name != "previews" or base.parent.name != "LRCDF" or _linked(base) or not base.is_dir():
        return []
    root = base.resolve()
    kept = {str(Path(k).resolve()).casefold() for k in keep}
    folders, total = [], 0
    for entry in os.scandir(base):
        path = base / entry.name
        size = _size(path)
        total += size
        try:
            if entry.is_dir(follow_symlinks=False):
                folders.append((entry.stat(follow_symlinks=False).st_mtime, path, size))
        except OSError:
            continue
    if total <= LIMIT:
        return []
    removed = []
    for _when, path, size in sorted(folders, key=lambda f: f[0]):
        if total <= TARGET:
            break
        try:
            real = path.resolve()
        except OSError:
            continue
        if (not NAME.match(path.name) or _linked(path) or real.parent != root
                or not str(real).casefold().startswith(str(root).casefold() + os.sep)
                or str(real).casefold() in kept):
            continue
        try:
            shutil.rmtree(real)
        except OSError:
            continue
        total -= size
        removed.append(path.name)
    return removed


def trim(base: Path, keep=(), done=None) -> None:
    """trim_now in the background; `done(removed)` is called on that thread when it is over (may be None)."""
    def run():
        removed = trim_now(base, keep)
        if done is not None:
            done(removed)
    threading.Thread(target=run, name="preview-cache-trim", daemon=True).start()
