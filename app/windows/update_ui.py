"""The Windows update settings and the desktop-to-installer handoff."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

from PySide6.QtCore import QEvent, QObject, QPointF, QRectF, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QPainterPath, QPalette, QPen
from PySide6.QtWidgets import (QApplication, QCheckBox, QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget)

from .chrome import CaptionButton
from .i18n import LANGUAGE
from .theme import FOCUS, SOFT, TEXT, Tween, font
from .widgets import Para, PlainButton, paint_glass, painter, text_width
from .update_core import QUIET_LIMIT, UpdateCancelled, UpdateClient


UPDATE_TEXT = json.loads(Path(__file__).with_name("update_strings.json").read_text(encoding="utf-8"))
AUTO_SETTING = "automaticUpdates"
DAILY = 24 * 60 * 60 * 1000


class UpdateBanner(QWidget):
    """UpdateHost: one line of glass at the bottom (corner 28, 22 x 6 inside, at most 760 wide, 14 from what is below
    it): the arrow.down.circle, the words (14, wrapping), then the action (focus yellow) and "Later" (soft) as plain
    words in 44 rows. Comes up from below and fades in; not shown while photos are being worked on."""

    def __init__(self, window, updater):
        super().__init__(window)
        self.window, self.updater = window, updater
        self.line = None
        self.text = ""
        self.lines = []
        self.f = font(14)
        self.action = PlainButton("", self._act, size=14, color=FOCUS)
        self.later = PlainButton(updater._text("later"), updater.later, size=14, color=SOFT)
        for b in (self.action, self.later):
            b.setParent(self)
            b.setFixedHeight(44)
        self.rise = Tween(0, self._rising, self, 450)
        window.installEventFilter(self)
        self.hide()

    def _act(self):
        if self.line and self.line.get("action"):
            self.line["run"]()

    def eventFilter(self, obj, e):
        if obj is self.window and e.type() == QEvent.Type.Resize and self.isVisible():
            self.place()
        return False

    def _area(self):
        """Where the line goes: above the look tray (wide), above the narrow bar, or at the window's bottom."""
        win = self.window
        page = getattr(win, "studio_page", None)
        if page is not None and win.pages.currentWidget() is page and page.isVisible():
            if getattr(page, "narrow", False) and page.bar.isVisible():
                top = page.bar.mapTo(win, page.bar.rect().topLeft()).y()
                return 14, win.width() - 28, top - 10
            if page.looks.isVisible():
                tray = page.looks.mapTo(win, page.looks.rect().topLeft())
                return tray.x(), page.looks.width(), tray.y() - 14
        return 14, win.width() - 28, win.height() - 14

    def place(self):
        left, width, bottom = self._area()
        w = min(760, width)
        right = 22 + (self.action.width() + 14 if self.action.isVisible() else 0) + \
            (self.later.width() + 14 if self.later.isVisible() else 0)
        room = w - 22 - 18 - 14 - right - 12
        self.lines = [s.rstrip() for s, _ in Para(self.text, 14)._lines(max(80, room))] or [self.text]
        h = max(56, 12 + len(self.lines) * 20 + 12)
        self.resize(w, h)
        x = left + (width - w) // 2
        self.move(x, bottom - h + round(self.rise.value))
        x2 = w - 22
        for b in (self.later, self.action):
            if b.isVisible():
                x2 -= b.width()
                b.move(x2, (h - 44) // 2)
                x2 -= 14

    def _rising(self):
        if self.isVisible():
            self.place()

    def show_line(self, line):
        if line is None:
            if self.isVisible():
                self.hide()
            self.line = None
            return
        self.line, self.text = line, line["text"]
        self.action.setVisible(bool(line.get("action")))
        if line.get("action"):
            self.action.text = line["action"]
            self.action.f = font(14)
            self.action.setFixedSize(round(text_width(self.action.f, line["action"])) + 4, 44)
            self.action.setEnabled(line.get("enabled", True))
            self.action.update()
        self.later.setVisible(line.get("dismissable", True))
        first = not self.isVisible()
        if first:
            self.rise.to(70, animate=False)
            self.show()
            self.rise.to(0)
        self.raise_()
        self.place()
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        paint_glass(p, QRectF(self.rect()), 28)
        c = QPointF(22 + 9, self.height() / 2)
        pen = QPen(TEXT, 1.4)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(c, 8, 8)                      # arrow.down.circle
        p.drawLine(QPointF(c.x(), c.y() - 4), QPointF(c.x(), c.y() + 4))
        path = QPainterPath(QPointF(c.x() - 3.5, c.y() + 0.5))
        path.lineTo(c.x(), c.y() + 4.2)
        path.lineTo(c.x() + 3.5, c.y() + 0.5)
        p.drawPath(path)
        p.setFont(self.f)
        p.setPen(TEXT)
        x = 22 + 18 + 14
        top = (self.height() - len(self.lines) * 20) / 2
        for i, s in enumerate(self.lines):
            p.drawText(QRectF(x, top + i * 20, self.width() - x, 20), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, s)


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
        """The gear left of the window buttons, drawn like them, opens the settings: a small window of its own
        (UpdateSettings), built each time it opens. What is going on is the line at the bottom (UpdateHost).
        `render` keeps what both show in `self.view`."""
        self.entry = CaptionButton("gear", self.open_settings, 40)
        self.entry.setToolTip(self._text("settings"))
        self.entry.setAccessibleName(self._text("settings"))
        self.window.caption.add_first(self.entry)
        self.panel = None
        self.view = {}
        self.manual = False            # a check the user asked for: its "checking" and "no update" are shown
        self.dismissed = None          # the line the user put off with "Later"
        self.banner = UpdateBanner(self.window, self)

    def _build_panel(self):
        """UpdateSettings: its own window, 440 wide, 24 inside, in the system's light or dark (the app's dark palette
        is not used here, as on the Mac); the switch (a check box), the note, "Check for updates now" and, when there is a
        previous version, "Go back to the previous version". The Store build shows only that updates come through the Store."""
        panel = QWidget(None, Qt.WindowType.Window | Qt.WindowType.WindowCloseButtonHint)
        panel.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        panel.setWindowTitle(self._text("settings"))
        panel.setPalette(QApplication.style().standardPalette() if QApplication.styleHints().colorScheme() != Qt.ColorScheme.Dark
                         else QApplication.palette())
        v = QVBoxLayout(panel)
        v.setContentsMargins(24, 24, 24, 24)
        v.setSpacing(8)
        self.toggle = self.check_button = self.back = None
        if self.client.channel == "store":
            note = QLabel(self._text("store_note"))
            note.setWordWrap(True)
            v.addWidget(note)
        else:
            self.toggle = QCheckBox(self._text("auto"))
            self.toggle.setChecked(self.enabled)
            self.toggle.toggled.connect(self.set_enabled)
            v.addWidget(self.toggle)
            note = QLabel(self._text("auto_note"))
            note.setWordWrap(True)
            small = note.font()
            small.setPointSizeF(max(8.0, small.pointSizeF() - 1))
            note.setFont(small)
            note.setForegroundRole(QPalette.ColorRole.PlaceholderText)
            v.addWidget(note)
            row = QHBoxLayout()
            row.setSpacing(8)
            self.check_button = QPushButton(self._text("check_now"))
            self.check_button.clicked.connect(self.check_now)
            row.addWidget(self.check_button)
            self.back = QPushButton(self._text("back"))
            self.back.clicked.connect(lambda: self._start_helper("Rollback"))
            row.addWidget(self.back)
            row.addStretch(1)
            v.addSpacing(4)
            v.addLayout(row)
        panel.setFixedWidth(440)
        panel.destroyed.connect(self._panel_gone)
        return panel

    def _panel_gone(self):
        self.panel = None

    def open_settings(self):
        self.show_settings(force=True)

    def close_settings(self):
        if self.panel is not None:
            self.panel.close()

    def check_now(self):
        """Check for updates now: its checking and its answer are shown in the line at the bottom."""
        self.manual = True
        self.dismissed = None
        if not self.enabled and self.client.channel != "store":
            self.render()
            return
        self.check()

    def later(self):
        """Later: the line goes until something new is to be said."""
        self.dismissed = self.view.get("line_key")
        self.manual = False
        self.result_message = []
        self.render()

    @property
    def settings_open(self):
        return self.panel is not None

    def start(self):
        self._read_result()
        if self.client.channel == "store":           # updates come through the Store: no check, no line
            self.state = "store"
            self.render()
            return
        if self.client.installed is None:
            self.state = "unmanaged"
        elif self.enabled:
            self.check()
            self.last_check_day.start()
        self.render()

    def stop(self):
        self.last_check_day.stop()
        if self.worker_stop is not None:
            self.worker_stop.set()

    def set_enabled(self, enabled):
        if self.client.channel == "store":
            return
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
        """Open the settings window (only when asked: what is going on is said by the line at the bottom)."""
        if self.panel is not None:
            self.render()
            self.panel.raise_()
            self.panel.activateWindow()
            return
        if not force:
            self.render()
            return
        self.panel = self._build_panel()
        self.render()
        self.panel.adjustSize()
        g = self.window.frameGeometry()
        self.panel.move(g.center().x() - self.panel.width() // 2, g.top() + 80)
        self.panel.show()

    def check(self):
        if self.client.channel == "store":
            return
        if self.enabled and self.worker_stop is None and self.helper is None:
            if self.offer is None:
                self.state = "checking"
            self._work("check", self.client.check)
            self.render()

    def _download(self):
        if self.client.channel != "store" and self.enabled and self.offer is not None and self.worker_stop is None:
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
        status = self._text(self.state) if self.state in UPDATE_TEXT["en"] else ""
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
        line = self._line(busy)
        self.view = {
            "line": line,
            "line_key": (line or {}).get("key"),
            "status": chr(10).join(lines),
            "details": self._offer_text() if self.offer is not None else "",
            "action": self._text(action) if can_act else None,
            "action_enabled": can_act and self.worker_stop is None and
                              (self.state != "ready" or not (busy or self._lightroom_blocks_install())),
            "back": has_previous,
            "back_enabled": not busy and self.helper is None and self.worker_stop is None,
            "toggle_enabled": self.state != "unmanaged" and self.helper is None,
        }
        hidden = self.studio.stage in {"working", "paused"} or line is None or line.get("key") == self.dismissed
        self.banner.show_line(None if hidden else line)
        if self.panel is not None:
            self._apply()

    def _line(self, busy):
        """UpdateHost.line: what the bottom line says, its action, and whether "Later" puts it off."""
        if self.state in {"store", "off", "unmanaged"}:
            return None
        if self.result_message:
            return {"key": ("result", tuple(self.result_message)), "text": " ".join(self.result_message)}
        version = self.offer.version if self.offer is not None else ""
        if self.state == "checking":
            return {"key": ("checking",), "text": self._text("checking"), "dismissable": False} if self.manual else None
        if self.state == "idle":
            return {"key": ("idle",), "text": self._text("idle")} if self.manual else None
        if self.state == "applying":
            return {"key": ("applying",), "text": self._text("applying"), "dismissable": False}
        if self.state == "downloading":
            return {"key": ("downloading", version), "text": self._text("downloading"), "dismissable": False}
        if self.offer is None:
            return None
        summary = self._offer_text().split("\n\n")[0]
        if self.state == "manual":
            return {"key": ("manual", version), "text": summary, "action": self._text("open"), "run": self._act}
        if self.state == "available":
            return {"key": ("available", version), "text": summary, "action": self._text("download"), "run": self._act}
        if self.state == "failed":
            return {"key": ("failed", version), "text": self._text("failed"), "action": self._text("download"), "run": self._act}
        if self.state == "ready":
            words = [self._text("ready")]
            if busy:
                words.append(self._text("busy"))
            if self._lightroom_blocks_install():
                words.append(self._text("lightroom_open"))
            return {"key": ("ready", version), "text": " ".join(words), "action": self._text("install"), "run": self._act,
                    "enabled": not (busy or self._lightroom_blocks_install())}
        return None

    def _apply(self):
        v = self.view
        if self.toggle is not None:
            self.toggle.blockSignals(True)
            self.toggle.setChecked(self.enabled)
            self.toggle.blockSignals(False)
            self.toggle.setEnabled(v["toggle_enabled"])
        if self.check_button is not None:
            self.check_button.setEnabled(self.enabled and self.worker_stop is None and self.helper is None)
        if self.back is not None:
            self.back.setVisible(v["back"])
            self.back.setEnabled(v["back_enabled"])
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
            self.render()
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
            self.render()

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
