"""The Lightroom batch queue, its saved state, and finished-photo review."""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import winreg

from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtGui import QImage

from .i18n import bridge_text, tr
from .bridge import atomic_json, value_of
from .studio import tweak_argument, wheel_arguments


def _csv(items):
    return ",".join(map(str, items))


def _created(lines):
    pairs = value_of("created", lines)
    return {
        old: int(new)
        for item in pairs.split(",") if ":" in item
        for old, new in [item.split(":", 1)]
        if old.isdecimal() and new.isdecimal()
    }


def _count(name, lines):
    # The first oneclick line is "toned=… beautified=… denoised=… failed=…".
    result = re.search(rf"(?:^| ){name}=(\d+)(?= |$)", lines[0]) if lines else None
    return int(result[1]) if result else 0


class Workflow(QObject):
    changed = Signal()

    def __init__(self, studio, bridge, parent=None):
        super().__init__(parent)
        self.studio = studio
        self.bridge = bridge
        self.run = self._last_run()
        self.fraction = 0.0
        self.caption = ""
        self.pause_requested = False
        self.undo_pending = False
        self.review_id = None
        self.review_thumbs = {}
        self.before_image = None
        self.after_image = None
        self.review_loading = False
        self._results = {}
        self._review_generation = 0
        self._running_step = False
        self._chunk_base = 0.0
        self._chunk_span = 0.0
        self._before_queue = []
        self._timer = QTimer(self)
        self._timer.setInterval(400)
        self._timer.timeout.connect(self._read_progress)
        self._timer.start()

    def _last_run(self):
        try:
            return json.loads(self.bridge.run.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None

    @property
    def remaining(self):
        job = self.run
        if not job or job["finished"]:
            return 0
        return len(job["ids"]) - len(job["done"]) - len(job["failed"])

    @property
    def before_directory(self):
        return self.bridge.before / self.run["id"]

    @property
    def after_directory(self):
        return self.bridge.after / self.run["id"]

    @property
    def settings_file(self):
        return self.bridge.undo / f"{self.run['id']}.lua"

    @property
    def people_file(self):
        return self.bridge.undo / f"{self.run['id']}-people.json"

    def _set_stage(self, stage):
        if self.studio.stage == stage:
            self.changed.emit()
            return
        self.studio.stage = stage
        self.studio.changed.emit()
        self.changed.emit()

    def _fail(self, message):
        self.pause_requested = False
        self.studio.error = tr("run.resume_error", message=message)
        self._set_stage("failed")

    def _keep(self):
        try:
            atomic_json(self.bridge.run, self.run)
        except OSError as error:
            self._fail(str(error))
            return False
        self.changed.emit()
        return True

    def retouch(self):
        studio = self.studio
        if studio.stage != "choosing" or not studio.session or studio.nothing_to_do:
            return
        studio.remember_settings()
        self.run = {
            "id": datetime.now().strftime("%Y%m%d-%H%M%S-%f"),
            "ids": list(studio.targets), "look": studio.look, "level": studio.level,
            "slim": False, "denoise": studio.denoise, "tweak": dict(zip(("bright", "warm", "rich"), studio.effective_tweak)),
            "wheels": list(studio.effective_wheels),
            "shapes": list(studio.shape_list), "people": studio.choice_list if studio.people else None,
            "best": studio.best, "saved": False, "denoised": [], "denoiseSwitched": [],
            "toned": False, "tonedIds": [], "done": [], "failed": [], "created": {},
            "finished": False, "undone": False,
        }
        self._clear_review()
        self.work()

    def _weights(self):
        job = self.run
        denoise = 9.0 if job["denoise"] else 0.0
        tone = 1.5 if job["look"] != "none" else 0.0
        beauty = 9.0 if job["level"] != "off" else 0.0
        return denoise, tone, beauty, max(1.0, len(job["ids"]) * (denoise + tone + beauty))

    def _progress(self):
        job = self.run
        denoise, tone, beauty, total = self._weights()
        toned_count = len(job["ids"]) if job["toned"] else len(job.get("tonedIds", []))
        return (len(job["denoised"]) * denoise + toned_count * tone
                + (len(job["done"]) + len(job["failed"])) * beauty) / total

    def work(self):
        job = self.run
        if not job or job["finished"] or self.studio.stage == "working" or self.undo_pending:
            return
        self.pause_requested = False
        self.studio.notice = None
        self.studio.error = None
        self.caption = tr("run.handoff")
        self.fraction = self._progress()
        self._set_stage("working")
        try:
            self.bridge.undo.mkdir(parents=True, exist_ok=True)
            self.before_directory.mkdir(parents=True, exist_ok=True)
        except OSError as error:
            self._fail(str(error))
            return
        if job.get("people") is not None and not self.people_file.exists():
            try:
                shutil.copyfile(self.studio.people_file, self.people_file)
            except OSError as error:
                self._fail(str(error))
                return
        if not self._keep():
            return
        self._before_queue = [
            photo for photo in job["ids"] if not (self.before_directory / f"{photo}.jpg").is_file()
        ] if not (job["toned"] or job.get("tonedIds") or job["done"] or job["denoised"]) else []
        if job["saved"]:
            self._save_before()
        else:
            self.bridge.send(
                {"action": "save", "file": self.settings_file, "ids": _csv(job["ids"])},
                self._saved, timeout=300,
            )

    def _saved(self, lines, error):
        if error is not None:
            self._fail(error)
            return
        if value_of("saved", lines) != str(len(self.run["ids"])):
            self._fail(tr("run.save_failed"))
            return
        self.run["saved"] = True
        if self._keep():
            self._save_before()

    def _save_before(self):
        if self.pause_requested:
            self._pause()
            return
        if not self._before_queue:
            self._next_step()
            return
        ids, self._before_queue = self._before_queue[:20], self._before_queue[20:]
        self.caption = tr("run.save_before")
        self.changed.emit()
        self.bridge.send(
            {"action": "thumbs", "size": 1400, "dir": self.before_directory, "ids": _csv(ids)},
            lambda lines, error: self._before_saved(ids, error), timeout=300,
        )

    def _before_saved(self, ids, error):
        if error is not None:
            self._fail(error)
            return
        if not all((self.before_directory / f"{photo}.jpg").is_file() for photo in ids):
            self._fail(tr("run.before_failed"))
            return
        self._save_before()

    def _read_progress(self):
        if self.studio.stage != "working" or not self._running_step:
            return
        try:
            line = self.bridge.progress.read_text(encoding="utf-8").strip("\r\n")
            fraction, _, caption = line.partition("\t")
            value = min(1.0, max(0.0, float(fraction)))
        except (OSError, ValueError):
            return
        target = max(self.fraction, self._chunk_base + self._chunk_span * value)
        caption = bridge_text(caption) if caption else self.caption
        if (target, caption) != (self.fraction, self.caption):
            self.fraction, self.caption = target, caption
            self.changed.emit()

    def _step(self, arguments, ids, weight, callback):
        try:
            self.bridge.progress.unlink(missing_ok=True)
        except OSError as error:
            self._fail(str(error))
            return
        self._chunk_base = self._progress()
        self._chunk_span = len(ids) * weight / self._weights()[-1]
        self._running_step = True

        def received(lines, error):
            self._read_progress()
            self._running_step = False
            callback(lines or [], error)

        self.bridge.send(
            {"action": "oneclick", **arguments, "progress": self.bridge.progress, "ids": _csv(ids)},
            received, timeout=240 + len(ids) * 200,
        )

    def _next_step(self):
        if self.pause_requested:
            self._pause()
            return
        job = self.run
        denoise_weight, tone_weight, _, _ = self._weights()
        if denoise_weight:
            ids = [photo for photo in job["ids"] if photo not in job["denoised"]][:4]
            if ids:
                self._step({"style": "none", "beauty": "off", "denoise": "1"}, ids, denoise_weight,
                           lambda lines, error: self._denoised(ids, lines, error))
                return
        if tone_weight and not job["toned"]:
            ids = [photo for photo in job["ids"] if photo not in job.get("tonedIds", [])][:150]
            args = {"style": job["look"], "beauty": "off"}
            tweak = tuple(job["tweak"][name] for name in ("bright", "warm", "rich"))
            if any(tweak):
                args["tweak"] = tweak_argument(tweak)
            tint, shadow, high = job.get("wheels") or (0.0, None, None)
            args.update(wheel_arguments((tint, tuple(shadow) if shadow else None, tuple(high) if high else None)))
            self._step(args, ids, tone_weight, lambda lines, error: self._toned(ids, lines, error))
            return
        if job["level"] != "off":
            ids = [photo for photo in job["ids"] if photo not in job["done"] and photo not in job["failed"]][:3]
            if ids:
                self._beauty(ids, {}, 1)
                return
        else:
            job["done"] = list(job["ids"])
        self.fraction = 1.0
        job["finished"] = True
        if self._keep():
            self._set_stage("finished")

    def _denoised(self, ids, lines, error):
        if error is not None:
            self._fail(error)
            return
        new = [int(item) for item in value_of("denoisedids", lines).split(",") if item.isdecimal()]
        job = self.run
        job["denoiseSwitched"] = list(dict.fromkeys(job["denoiseSwitched"] + new))
        failed = _count("failed", lines)
        if failed:
            if self._keep():
                self._fail(tr("run.failed_count", count=failed))
            return
        job["denoised"].extend(ids)
        self._after_step()

    def _toned(self, ids, lines, error):
        if error is not None:
            self._fail(error)
            return
        failed = _count("failed", lines)
        if failed:
            self._fail(tr("run.failed_count", count=failed))
            return
        job = self.run
        job.setdefault("tonedIds", []).extend(ids)
        job["toned"] = len(job["tonedIds"]) == len(job["ids"])
        self._after_step()

    def _beauty(self, ids, made, attempt):
        job = self.run
        args = {"style": "none", "beauty": job["level"], "bits": "16" if job.get("best") else "8"}
        shapes = job.get("shapes")
        if shapes is None:
            shapes = ["slim"] if job["slim"] else []
        args.update(dict.fromkeys(shapes, "1"))
        if job.get("people") is not None:
            args["peoplefile"] = self.people_file
            if job["people"]:
                args["people"] = job["people"]
        pending = [photo for photo in ids if str(photo) not in made]
        self._step(args, pending, self._weights()[2],
                   lambda lines, error: self._beauty_done(ids, made, attempt, lines, error))

    def _beauty_done(self, ids, made, attempt, lines, _error):
        made.update(_created(lines))
        if len(made) < len(ids) and attempt == 1:
            self.caption = tr("run.retrying")
            self.changed.emit()
            self._beauty(ids, made, 2)
            return
        job = self.run
        job["created"].update(made)
        job["done"].extend(photo for photo in ids if str(photo) in made)
        job["failed"].extend(photo for photo in ids if str(photo) not in made)
        self._after_step()

    def _after_step(self):
        self.fraction = max(self.fraction, self._progress())
        if self._keep():
            self._next_step()

    def request_pause(self):
        if self.studio.stage == "working":
            self.pause_requested = True
            self.changed.emit()

    def _pause(self):
        self.pause_requested = False
        self._set_stage("paused")

    def retry_failed(self):
        if not self.run or not self.run["failed"] or self.studio.stage == "working":
            return
        self.run["failed"] = []
        self.run["finished"] = False
        self.work()

    def stop_run(self):
        job = self.run
        if not job or self.studio.stage == "working":
            return
        job["failed"] = []
        job["finished"] = True
        if self._keep():
            self._set_stage("finished" if job["done"] else ("choosing" if self.studio.looks else "waiting"))

    def undo_run(self):
        job = self.run
        if not job or not job["saved"] or job["undone"] or self.undo_pending or self.studio.stage == "working":
            return
        self.undo_pending = True
        self.studio.notice = tr("undo.in_progress")
        self.studio.changed.emit()
        self.changed.emit()
        args = {"action": "undo", "file": self.settings_file, "ids": _csv(job["ids"])}
        if job["created"]:
            args["rejects"] = _csv(job["created"].values())
        if job["denoiseSwitched"]:
            args["denoised"] = _csv(job["denoiseSwitched"])
        self.bridge.send(args, self._undone, timeout=300 + len(job["denoiseSwitched"]) * 6)

    def _undone(self, lines, error):
        job = self.run
        self.undo_pending = False
        if error is None and not any(line.startswith(f"restored={len(job['ids'])} ") for line in lines or []):
            error = tr("undo.restore_failed")
        if error is not None:
            self.studio.notice = tr("undo.failure", error=error)
        else:
            job["finished"] = job["undone"] = True
            if not self._keep():
                return
            self._clear_review()
            self.studio.notice = (
                tr("undo.removed_outputs", count=len(job['created']))
                if job["created"] else tr("undo.restored")
            )
        self.studio.changed.emit()
        self.changed.emit()

    def _clear_review(self):
        self._review_generation += 1
        self.review_thumbs = {}
        self._results = {}
        self.review_id = None
        self.before_image = None
        self.after_image = None
        self.review_loading = False

    def start_review(self):
        job = self.run
        if not job or not job["done"] or job["undone"] or self.undo_pending:
            return
        for photo in job["done"]:
            image = QImage(str(self.before_directory / f"{photo}.jpg"))
            if not image.isNull():
                self.review_thumbs[photo] = image
        self._set_stage("reviewing")
        self.review(self.studio.photo if self.studio.photo in job["done"] else job["done"][0])

    def review(self, photo):
        if self.studio.stage != "reviewing" or photo not in self.run["done"] or self.review_loading:
            return
        self.review_id = photo
        self.before_image = self.review_thumbs.get(photo)
        self.after_image = self._results.get(photo)
        if self.after_image is not None:
            self.changed.emit()
            return
        self.review_loading = True
        self.changed.emit()
        shown = self.run["created"].get(str(photo), photo)
        generation = self._review_generation
        self.bridge.send(
            {"action": "thumbs", "size": 1400, "dir": self.after_directory, "ids": str(shown)},
            lambda lines, error: self._review_ready(photo, generation, lines, error), timeout=120,
        )

    def _review_ready(self, photo, generation, lines, error):
        if generation != self._review_generation or self.studio.stage != "reviewing":
            return
        self.review_loading = False
        if error is None and lines:
            _, _, path = lines[0].partition("\t")
            image = QImage(path)
            if not image.isNull():
                self._results[photo] = self.after_image = image
        if self.after_image is None:
            self.studio.notice = error or tr("preview.unavailable")
            self.studio.changed.emit()
        self.changed.emit()

    def again(self):
        self._clear_review()
        self._set_stage("choosing" if self.studio.looks else "waiting")

    def leave_review(self):
        self._review_generation += 1
        self.review_loading = False
        self._set_stage("finished")

    def back_to_lightroom(self):
        for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            try:
                with winreg.OpenKey(hive, r"Software\Microsoft\Windows\CurrentVersion\App Paths\Lightroom.exe") as key:
                    executable, _ = winreg.QueryValueEx(key, "")
                os.startfile(executable)
                return
            except OSError:
                pass
        executable = Path(os.environ["ProgramFiles"]) / "Adobe" / "Adobe Lightroom Classic" / "Lightroom.exe"
        try:
            os.startfile(executable)
        except OSError:
            self.studio.notice = tr("bridge.open_first")
            self.studio.changed.emit()
