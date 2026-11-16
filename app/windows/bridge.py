from dataclasses import dataclass
import json
import os
from pathlib import Path
import time
from typing import Callable
from uuid import uuid4

from PySide6.QtCore import QObject, QTimer

from .i18n import bridge_text, tr

LIGHTROOM_AWAY = tr("bridge.disconnected")
NO_ANSWER = tr("bridge.timeout")

Reply = Callable[[list[str] | None, str | None], None]


def atomic_json(path: Path, value) -> None:
    """Store application state in one rename, so readers see only complete JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    draft = path.with_name(f"{path.name}.{uuid4().hex[:8]}.tmp")
    try:
        draft.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        draft.replace(path)
    finally:
        draft.unlink(missing_ok=True)


def value_of(name: str, lines: list[str]) -> str:
    prefix = name + "="
    return next((line[len(prefix):] for line in lines if line.startswith(prefix)), "")


@dataclass
class Pending:
    command: Path
    answer: Path
    deadline: float
    callback: Reply


class Bridge(QObject):
    """Communicate with Lightroom using the same files and commands as Bridge.swift."""

    def __init__(self, root: Path | None = None, parent=None):
        super().__init__(parent)
        self.root = Path(root) if root is not None else Path(os.environ["APPDATA"]) / "LRCDF"
        self.commands = self.root / "cmd"
        self.session = self.root / "session.json"
        self.progress = self.root / "progress.txt"
        self.previews = self.root / "previews"
        self.thumbs = self.root / "thumbs"
        self.before = self.root / "before"
        self.after = self.root / "after"
        self.undo = self.root / "undo"
        self.run = self.root / "run.json"
        self._pending: dict[str, Pending] = {}
        self._poller = QTimer(self, interval=150)
        self._poller.timeout.connect(self._poll)

    @property
    def in_flight(self) -> bool:
        return bool(self._pending)

    def lightroom_is_open(self) -> bool:
        try:
            stamp = float((self.commands / "alive").read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            return False
        return time.time() - stamp < 8

    def send(self, arguments, callback: Reply, timeout: float = 300) -> None:
        # Lightroom cannot update its heartbeat while handling a request.
        if not self.in_flight and not self.lightroom_is_open():
            QTimer.singleShot(0, lambda: callback(None, LIGHTROOM_AWAY))
            return
        name = f"app{time.time_ns() // 1_000_000}_{uuid4().hex[:8]}"
        draft = self.commands / f"{name}.tmp"
        command = draft.with_suffix(".cmd")
        answer = draft.with_suffix(".done")
        fields = arguments.items() if isinstance(arguments, dict) else arguments
        message = "".join(f"{key}={value}\n" for key, value in fields)
        try:
            self.commands.mkdir(parents=True, exist_ok=True)
            draft.write_bytes(message.encode("utf-8"))
            draft.replace(command)
        except OSError as exc:
            message = str(exc)
            QTimer.singleShot(0, lambda: callback(None, message))
            return
        self._pending[name] = Pending(command, answer, time.monotonic() + timeout, callback)
        if not self._poller.isActive():
            self._poller.start()

    def _poll(self) -> None:
        for name, pending in tuple(self._pending.items()):
            try:
                text = pending.answer.read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                text = ""
            if text.endswith("\n"):
                try:
                    pending.answer.unlink()
                except OSError:
                    # Lightroom may still hold the file open on Windows.
                    continue
                lines = [line for line in text.split("\n") if line]
                self._pending.pop(name)
                if lines[0] == "ok":
                    pending.callback(lines[1:], None)
                else:
                    pending.callback(None, bridge_text("\n".join(lines[1:])))
            elif time.monotonic() >= pending.deadline:
                self._pending.pop(name)
                try:
                    pending.command.unlink(missing_ok=True)
                except OSError:
                    pass
                pending.callback(None, NO_ANSWER)
        if not self._pending:
            self._poller.stop()
