"""The Windows update settings and the desktop-to-installer handoff."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

from PySide6.QtCore import QObject, QTimer, QUrl, Signal
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QApplication

from .chrome import CaptionButton
from .i18n import LANGUAGE
from .theme import SEMIBOLD, SOFT, TEXT
from .widgets import GhostButton, GlowButton, Switch, dim
from .update_core import QUIET_LIMIT, UpdateCancelled, UpdateClient


UPDATE_TEXT = json.loads(Path(__file__).with_name("update_strings.json").read_text(encoding="utf-8"))
AUTO_SETTING = "automaticUpdates"
DAILY = 24 * 60 * 60 * 1000


class WindowsUpdater(QObject):
    """One background request at a time, with the opt-out stored by the app."""

    completed = Signal(str, object, object)

    def __init__(self, window, studio, workflow, bridge, *, client=None, settings=None):
        super().__init__(window)
        self.window, self.studio, self.workflow, self.bridge = window, studio, workflow, bridge
        root = Path(__file__).resolve().parents[3]
        self.root = root if client is None else client.root
        self.client = client if client is not None else UpdateClient(root)
        self.settings = settings if settings is not None else studio.settings
        self.enabled = self.settings.value(AUTO_SETTING, True, type=bool)
        self.language = LANGUAGE
        self.state = "idle" if self.enabled else "off"
        self.offer = None
        self.stage = None
        self.worker_stop = None
        self.helper = None
        self.result_message = []
        self.last_check_day = QTimer(self, interval=DAILY)
        self.last_check_day.timeout.connect(self.check)
        self.handoff_poll = QTimer(self, interval=70)
        self.handoff_poll.timeout.connect(self._wait_for_helper)
        self.completed.connect(self._receive)
        self._make_widgets()
        self.studio.changed.connect(self.render)
        self.workflow.changed.connect(self.render)
        self.render()

    def _text(self, key, **value):
        return UPDATE_TEXT.get(self.language, UPDATE_TEXT["en"])[key].format(**value)

    def _make_widgets(self):
        """The gear left of the window buttons, drawn like them. The settings open as a sheet in the window
        (like the save-style sheet), built each time it opens; `render` keeps what it shows in `self.view`."""
        self.entry = CaptionButton("gear", self.open_settings, 40)
        self.entry.setToolTip(self._text("settings"))
        self.entry.setAccessibleName(self._text("settings"))
        self.window.caption.add_first(self.entry)
        self.panel = None
        self.view = {}

    def _build_panel(self):
        """UpdateSettings on the Mac: 440 wide, 24 padding; the switch, what is going on, the buttons."""
        from .window import FoldRow, Panel, col, line, para
        panel = Panel(12, 440)
        v = col(14, (24, 24, 24, 24))
        v.addWidget(line(self._text("settings"), 18, SEMIBOLD))
        self.toggle = Switch(self._text("auto"), self.enabled)
        self.toggle.toggled.connect(self.set_enabled)
        v.addWidget(self.toggle)
        self.status = para("", 13, color=TEXT, center=False)
        self.status.setFixedWidth(392)
        v.addWidget(self.status)
        self.details = para("", 12, color=SOFT, center=False)
        self.details.setFixedWidth(392)
        v.addWidget(self.details)
        self.back = GhostButton(self._text("back"), lambda: self._start_helper("Rollback"))
        close = GhostButton(self._text("close"), self.close_settings)
        self.action = GlowButton("", self._act)
        actions = FoldRow()
        actions.setContentsMargins(0, 0, 0, 0)
        actions.setSpacing(8)
        actions.addWidget(self.back)
        actions.addStretch(1)
        actions.addWidget(close)
        actions.addWidget(self.action)
        v.addSpacing(4)
        v.addLayout(actions)
        panel.setLayout(v)
        panel.destroyed.connect(self._panel_gone)
        return panel

    def _panel_gone(self):
        self.panel = None

    def open_settings(self):
        self.show_settings(force=True)

    def close_settings(self):
        if self.panel is not None and self.window._modal is not None and self.window._modal.content is self.panel:
            self.window.close_modal()

    @property
    def settings_open(self):
        return self.panel is not None

    def start(self):
        self._read_result()
        if self.client.installed is None:
            self.state = "unmanaged"
        elif self.enabled:
            self.check()
            self.last_check_day.start()
        self.render()
        if self.result_message:
            self.show_settings()

    def stop(self):
        self.last_check_day.stop()
        if self.worker_stop is not None:
            self.worker_stop.set()

    def set_enabled(self, enabled):
        self.enabled = enabled
        self.settings.setValue(AUTO_SETTING, enabled)
        self.settings.sync()
        if enabled:
            self.state = "idle"
            self.last_check_day.start()
            self.check()
        else:
            self.stop()
            self.offer = self.stage = None
            self.state = "off"
        self.render()

    def show_settings(self, force=False):
        """Open the sheet. When it opens by itself (an update arrived, a result to report) it waits rather than
        replace another sheet the user is in, such as saving a style."""
        if self.panel is not None:
            self.render()
            return
        other = self.window._modal
        if other is not None and not force:
            return
        self.panel = self._build_panel()
        self.render()
        self.window.show_modal(self.panel, 0.45)

    def check(self):
        if self.enabled and self.worker_stop is None and self.helper is None:
            if self.offer is None:
                self.state = "checking"
            self._work("check", self.client.check)
            self.render()

    def _download(self):
        if self.enabled and self.offer is not None and self.worker_stop is None:
            self.state = "downloading"
            offer = self.offer
            self._work("stage", lambda stop: self.client.stage(offer, stop))
            self.render()

    def _work(self, action, operation):
        stop = threading.Event()
        self.worker_stop = stop

        def run():
            value = problem = None
            try:
                value = operation(stop)
            except Exception as error:
                problem = error
            self.completed.emit(action, value, (stop, problem))

        threading.Thread(target=run, daemon=True, name="LRCDF updater").start()

    def _receive(self, action, value, outcome):
        stop, problem = outcome
        self.worker_stop = None
        if not self.enabled:
            return
        if stop.is_set() or isinstance(problem, UpdateCancelled):
            self.state = "idle"
            self.check()
        elif problem is not None:
            self.state = "failed" if action == "stage" else "idle"
        elif action == "stage":
            self.stage, self.state = value, "ready"
        elif value is None:
            if self.offer is None:
                self.state = "idle"
        elif value != self.offer:
            self.offer, self.stage = value, None
            self.state = "manual" if value.manual else "available"
            self.show_settings()
            if not value.manual and value.bytes <= QUIET_LIMIT:
                self._download()
        self.render()

    def _busy(self):
        return (self.bridge.in_flight or self.studio.stage in {"preparing", "working", "paused"}
                or self.studio.saving_style or self.workflow.undo_pending)

    def _lightroom_blocks_install(self):
        return (self.state == "ready" and self.offer is not None and self.bridge.lightroom_is_open()
                and any(target != "app" for part in self.offer.components for target in part.targets))

    def _offer_text(self):
        if self.offer is None:
            return ""
        language = self.language.split("-")[0]
        candidates = (self.language, self.language.lower(), language, "en", "zh")
        notes = next((self.offer.notes[tag] for tag in candidates if self.offer.notes.get(tag)), "")
        if self.offer.manual:
            summary = self._text("future", version=self.offer.version)
        else:
            summary = self._text("offer", version=self.offer.version, size=f"{self.offer.bytes / 1_000_000:.1f}")
        return "\n\n".join(item for item in (summary, notes) if item)

    def render(self):
        status = self._text(self.state)
        lines = [part for part in self.result_message + [status] if part]
        actions = {"manual": "open", "available": "download", "ready": "install", "failed": "download"}
        action = actions.get(self.state)
        can_act = self.enabled and action is not None and self.offer is not None
        busy = self._busy()
        has_previous = self.client.installed is not None and (self.root / ".previous" / "rollback.json").is_file()
        if busy and (can_act and self.state == "ready" or has_previous):
            lines.append(self._text("busy"))
        if self._lightroom_blocks_install():
            lines.append(self._text("lightroom_open"))
        self.view = {
            "status": chr(10).join(lines),
            "details": self._offer_text() if self.offer is not None else "",
            "action": self._text(action) if can_act else None,
            "action_enabled": can_act and self.worker_stop is None and
                              (self.state != "ready" or not (busy or self._lightroom_blocks_install())),
            "back": has_previous,
            "back_enabled": not busy and self.helper is None and self.worker_stop is None,
            "toggle_enabled": self.state != "unmanaged" and self.helper is None,
        }
        if self.panel is not None:
            self._apply()

    def _apply(self):
        v = self.view
        self.toggle.set_checked(self.enabled)
        self.toggle.setEnabled(v["toggle_enabled"])
        dim(self.toggle, 1 if v["toggle_enabled"] else 0.35, animate=False)
        self.status.setText(v["status"])
        self.status.setVisible(bool(v["status"]))
        self.details.setText(v["details"])
        self.details.setVisible(bool(v["details"]))
        self.action.setVisible(v["action"] is not None)
        if v["action"] is not None:
            self.action.set_text(v["action"])
            self.action.setEnabled(v["action_enabled"])
            dim(self.action, 1 if v["action_enabled"] else 0.35, animate=False)
        self.back.setVisible(v["back"])
        self.back.setEnabled(v["back_enabled"])
        dim(self.back, 1 if v["back_enabled"] else 0.35, animate=False)
        self.panel.adjustSize()

    def _act(self):
        if self.offer is None or not self.enabled:
            return
        if self.state == "manual":
            QDesktopServices.openUrl(QUrl(self.offer.download_url))
        elif self.state in {"available", "failed"}:
            self._download()
        elif self.state == "ready" and not self._lightroom_blocks_install():
            self._start_helper("Install")

    def _start_helper(self, mode):
        if self._busy() or self.helper is not None or self.worker_stop is not None:
            self.render()
            return
        script = Path(__file__).with_name("Update-Windows.ps1")
        detached = self.root / ".update" / script.name
        powershell = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
        try:
            detached.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(script, detached)
            arguments = [
                str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-File", str(detached), "-Mode", mode, "-Root", str(self.root), "-WaitForPid", str(os.getpid()),
            ]
            if mode == "Install":
                arguments.extend(("-Stage", str(self.stage)))
            self.helper = subprocess.Popen(
                arguments, cwd=self.root, creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except OSError:
            self.result_message = [self._text("apply_failed")]
            self.show_settings()
            return
        self.pre_handoff_state = self.state
        self.state = "applying"
        self.handoff_deadline = time.monotonic() + 12
        self.window.setEnabled(False)
        self.handoff_poll.start()
        self.render()

    def _wait_for_helper(self):
        exited = self.helper.poll() is not None
        if not exited:
            try:
                with (self.root / ".update" / "installing").open("rb"):
                    pass
            except PermissionError:
                if not self._busy():
                    self.handoff_poll.stop()
                    QApplication.instance().quit()
                    return
            except FileNotFoundError:
                pass
        if exited or self._busy() or time.monotonic() >= self.handoff_deadline:
            if not exited:
                self.helper.terminate()
            self.helper = None
            self.handoff_poll.stop()
            self.window.setEnabled(True)
            self.state = self.pre_handoff_state
            self.result_message = [self._text("apply_failed")]
            self.show_settings()

    def _read_result(self):
        path = self.root / ".update_result.json"
        try:
            result = json.loads(path.read_text(encoding="utf-8-sig"))
            path.unlink()
        except (OSError, ValueError):
            return
        if result.get("ok"):
            code = "rolled_back" if result.get("mode") == "Rollback" else "installed"
        else:
            code = result.get("reason") if result.get("reason") in {"lightroom_open", "runtime_busy", "stale_plan"} else "apply_failed"
        self.result_message = [self._text(code)]
        if result.get("restart_lightroom"):
            self.result_message.append(self._text("restart"))
