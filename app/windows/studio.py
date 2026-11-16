import json
from pathlib import Path
import time

from PySide6.QtCore import QObject, QSettings, QTimer, Signal
from PySide6.QtGui import QImage

from .bridge import atomic_json
from .i18n import look_text, tr
from .quick import Quick


LEVELS = ("off", "auto", "natural", "refined")
SHAPES = ("slim", "bigeyes", "chest", "waist", "legs", "light")
PERSON_LEVELS = ("follow", "light", "natural", "refined", "off")
ZERO_TWEAK = (0.0, 0.0, 0.0)
TWEAK_STEP = 0.05


def quantize_tweak(value):
    """One tweak value as the plug-in takes it: -2 ... 2 (1 = one of the old steps), in steps of 0.05."""
    return round(round(min(2.0, max(-2.0, float(value))) / TWEAK_STEP) * TWEAK_STEP, 2)


def tweak_argument(tweak):
    """`tweak=` for the plug-in: at most two decimals, no trailing zeros ("0.35,-1.2,0")."""
    def one(v):
        text = f"{quantize_tweak(v):.2f}".rstrip("0").rstrip(".")
        return "0" if text in ("-0", "") else text
    return ",".join(one(v) for v in tweak)


def quantize_zone(zone):
    """A shadow / highlight wheel as the plug-in takes it: hue in steps of 5 degrees, amount in steps of 5; None when
    the wheel was not moved (not sent: the look keeps its own colour). Amount 0 = no colour (spec 2026-11-15 23:36)."""
    if zone is None:
        return None
    hue, amount = zone
    amount = max(0, min(100, round(amount / 5) * 5))
    # amount 0 = "no colour here" (dragged back to the centre); its hue is always written 0 (spec 23:36)
    return ((round(hue / 5) * 5) % 360 if amount else 0), amount


NO_WHEELS = (0.0, None, None)          # tint, shadow, high: nothing beyond the look


def tweak_name(style, tweak, wheels=NO_WHEELS):
    """The plug-in's file name for an exact tweak preview: each value x 100, e.g. d_t35_-120_0, then the wheels that
    are not zero in a fixed order: _n<tint x 100>, _s<hue>-<amount>, _h<hue>-<amount> (spec 2026-11-15)."""
    name = f"{style}_t{'_'.join(str(round(quantize_tweak(v) * 100)) for v in tweak)}"
    tint, shadow, high = wheels
    if quantize_tweak(tint):
        name += f"_n{round(quantize_tweak(tint) * 100)}"
    for letter, zone in (("s", shadow), ("h", high)):
        if zone is not None:                  # moved, even back to the centre (= no colour, "_s0-0")
            name += f"_{letter}{zone[0]}-{zone[1]}"
    return name


def wheel_arguments(wheels):
    """The optional tweakpreview / oneclick arguments of the wheels; none for what is not set."""
    tint, shadow, high = wheels
    out = {}
    if quantize_tweak(tint):
        out["tint"] = tweak_argument((tint,))
    for key, zone in (("shadow", shadow), ("high", high)):
        if zone is not None:                  # sent once moved; "0,0" = take the look's own colour away
            out[key] = f"{zone[0]},{zone[1]}"
    return out


def _json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def _image(path):
    image = QImage(str(path))
    return None if image.isNull() else image


def _ids(ids):
    return ",".join(map(str, ids))


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


CACHE_LIMIT = 2 * 1024 ** 3      # above this the second round only covers the photos looked at


class Studio(QObject):
    """The desktop state for Lightroom hand-offs and interactive previews."""

    changed = Signal()
    session_opened = Signal()

    def __init__(self, bridge, parent=None):
        super().__init__(parent)
        self.bridge = bridge
        self.settings = QSettings("LRCDF", "LRCDF")
        self.quick = Quick()
        self.stage = "waiting"
        self.session = None
        self.photo = 0
        self.previews = {}
        self.thumbs = {}
        self.flags = {}
        self.people = []
        self.choices = {}
        self.loading = None
        self.error = None
        self.notice = None
        self.style_error = None
        self.saving_style = False
        self.look = self.settings.value("look", "d", type=str)
        self.level = self.settings.value("beautyLevel", "auto", type=str)
        if self.level not in LEVELS:
            self.level = "auto"
        self.shapes = set(self.settings.value("shapes", [], type=list))
        self.tweak = ZERO_TWEAK
        self.tweaking = False          # a tweak slider is being dragged: the quick picture follows, nothing is asked
        self.tint = 0.0                # the white balance wheel's green-pink (-2 ... 2); its warm-cool is tweak[1]
        self.shadow = None             # (hue, amount) once the shadow wheel is moved; None = the look's own colour
        self.high = None
        self.wheel = "wb"              # which wheel is shown
        self.denoise = self.settings.value("denoise", False, type=bool)
        self.best = self.settings.value("best", False, type=bool)
        self.skip_flagged = False
        self.zoom = 1.0
        self.centre = (0.5, 0.5)
        self.face = None
        self.lightroom_open = bridge.lightroom_is_open()
        self.people_file = bridge.before / "people.json"
        self.known_file = bridge.root / "known_people.json"
        self._everyone = set()
        self.opening = None            # the loading behind the main screen after a hand-over; None once all is done
        self._busy = False             # one of its requests is on its way (never more than one)
        self._viewed = []              # the photos looked at, most recent first
        self._pictures = {}
        self._making = set()
        self._seen = 0.0
        self._poller = QTimer(self, interval=400)
        self._poller.timeout.connect(self._check)
        self._preview_timer = QTimer(self, singleShot=True, interval=450)
        self._preview_timer.timeout.connect(self._request_pictures)
        self._idle_preview_timer = QTimer(self, singleShot=True, interval=700)
        self._idle_preview_timer.timeout.connect(lambda: self._request_pictures(background=True))

    def start(self):
        self._check()
        self._poller.start()

    @property
    def count(self):
        return len(self.session["ids"]) if self.session else 0

    @property
    def noisy(self):
        return bool(self.session and (self.session.get("iso") or 0) >= 1600)

    @property
    def flagged(self):
        ids = self.session["ids"] if self.session else []
        return [id_ for id_ in ids if self.flags.get(id_)]

    @property
    def targets(self):
        ids = self.session["ids"] if self.session else []
        return [id_ for id_ in ids if not self.skip_flagged or not self.flags.get(id_)]

    @property
    def nothing_to_do(self):
        return (not self.targets or self.chosen is None
                or (self.look == "none" and self.level == "off" and not self.denoise))

    @property
    def looks(self):
        return self.previews.get(self.photo, {}).get("looks", [])

    @property
    def original(self):
        return next((card["image"] for card in self.looks if card["id"] == "none"), None)

    @property
    def chosen(self):
        return next((card for card in self.looks if card["id"] == self.look), None)

    @property
    def faces(self):
        return self.previews.get(self.photo, {}).get("faces", [])

    @property
    def effective_tweak(self):
        """The tweak as Lightroom gets it (quantized to 0.05); `self.tweak` keeps what the sliders show."""
        return ZERO_TWEAK if self.look == "none" else tuple(quantize_tweak(v) for v in self.tweak)

    @property
    def shape_list(self):
        return [s for s in SHAPES if s in self.shapes] if self.level != "off" else []

    @property
    def choice_list(self):
        if self.level == "off":
            return ""
        return ",".join(f"{id_}:{value}" for id_, value in sorted(self.choices.items())
                        if id_ in self._everyone and value != "follow")

    @property
    def _person_arguments(self):
        if not self.people or self.level == "off":
            return {}
        return {"peoplefile": self.people_file, **({"people": self.choice_list} if self.choice_list else {})}

    @property
    def effective_wheels(self):
        """tint, shadow, high as Lightroom gets them (quantized); nothing with the original picture."""
        if self.look == "none":
            return NO_WHEELS
        return quantize_tweak(self.tint), quantize_zone(self.shadow), quantize_zone(self.high)

    def look_zones(self):
        """The chosen look's own split toning, in wheel units, from the previews answer (`wheels=`)."""
        own = (self.chosen or {}).get("wheels") or (0, 0, 0, 0)
        return (own[0], own[1]), (own[2], own[3])

    def wheel_value(self, kind):
        if kind == "wb":
            return round(self.tweak[1] * 50), round(self.tint * 50)
        zone = self.shadow if kind == "shadow" else self.high
        return zone if zone is not None else self.look_zones()[0 if kind == "shadow" else 1]

    def wheel_moved(self, kind):
        if kind == "wb":
            return self.wheel_value("wb") != (0, 0)
        return (self.shadow if kind == "shadow" else self.high) is not None

    def select_wheel(self, kind):
        if kind != self.wheel:
            self.wheel = kind
            self.changed.emit()

    def set_wheel(self, kind, value, live=False):
        """A wheel moved: white balance = (warmth, tint) units, the others (hue, amount). Like set_tweak: `live`
        while dragging (no request; the quick picture follows, quick.py), the
        release asks for the exact picture."""
        if self.look == "none":
            return
        if kind == "wb":
            values = list(self.tweak)
            values[1] = max(-100, min(100, round(value[0]))) / 50
            self.tweak = tuple(values)
            self.tint = max(-100, min(100, value[1])) / 50
        elif kind == "shadow":
            self.shadow = (int(value[0]) % 360, max(0, min(100, int(value[1]))))
        else:
            self.high = (int(value[0]) % 360, max(0, min(100, int(value[1]))))
        self.tweaking = live
        if live:
            self._preview_timer.stop()
            self._idle_preview_timer.stop()
            self.changed.emit()
        else:
            self._controls_changed()

    def reset_wheel(self, kind):
        """Back to how the look made it: the centre for white balance, the look's own colour for the others."""
        if kind == "wb":
            self.tint = 0.0
            values = list(self.tweak)
            values[1] = 0.0
            self.tweak = tuple(values)
        elif kind == "shadow":
            self.shadow = None
        else:
            self.high = None
        self.tweaking = False
        self._controls_changed()

    def _look_key(self, tweak, wheels=None):
        return self.photo, self.look, tweak, self.effective_wheels if wheels is None else wheels

    def _beauty_key(self, tweak, level):
        return self._look_key(tweak) + (level, tuple(self.shape_list), self.choice_list)

    @property
    def _picture_context(self):
        return self.photo, self.look, self.level, tuple(self.shape_list), self.choice_list

    @property
    def _plain(self):
        """Nothing beyond the look: its own preview is the exact picture."""
        return self.effective_tweak == ZERO_TWEAK and self.effective_wheels == NO_WHEELS

    @property
    def beauty_shown(self):
        return self.level != "off" and self._beauty_key(self.effective_tweak, self.level) in self._pictures

    @property
    def picture_exact(self):
        return ((self._plain or self._look_key(self.effective_tweak) in self._pictures)
                and (self.level == "off" or self.beauty_shown))

    @property
    def after(self):
        chosen = self.chosen
        if chosen is None:
            return None
        # While a wheel is dragged (or its exact picture is on its way) the quick picture now follows it too: the
        # Mac's approximation of green-pink and split toning (quick.py), laid on the look's own picture, so nothing
        # jumps back to the plain look (which is why the last exact picture used to be held here).
        tweak = self.effective_tweak
        if self.beauty_shown:
            return self._pictures[self._beauty_key(tweak, self.level)]
        if self._plain:
            return chosen["image"]
        if self.level != "off":
            key = self._beauty_key(ZERO_TWEAK, self.level)[:2] + (ZERO_TWEAK, NO_WHEELS) + self._beauty_key(ZERO_TWEAK, self.level)[4:]
            if key in self._pictures:
                return self.quick.picture(self._pictures[key], key, tweak, self._quick_wheels, self.look_zones())
        exact = self._pictures.get(self._look_key(tweak))
        return exact if exact is not None else self.quick.picture(chosen["image"], (self.photo, self.look), tweak,
                                                                  self._quick_wheels, self.look_zones())

    @property
    def _quick_wheels(self):
        """The wheels as the screen shows them (not quantized), for the quick picture."""
        if self.look == "none":
            return NO_WHEELS
        return self.tint, self.shadow, self.high

    @property
    def progress(self):
        """What the preview progress line shows: None when nothing is on its way, or (fraction or None) - None when
        what is coming cannot be counted (the first looks of a photo, a single request on its way). Only counts the
        app really has: look cards come / expected, and of the requests the picture needs (the exact tweak, the
        retouched preview) how many are back."""
        if self.stage == "preparing" or (self.stage == "choosing" and self.loading is not None):
            return (None,)
        if self.stage != "choosing" or self.chosen is None or self.tweaking:
            return None
        done = total = 0
        entry = self.previews.get(self.photo, {})
        expected = entry.get("expected", 0)
        if len(self.looks) + entry.get("given_up", 0) < expected:
            done, total = len(self.looks) + entry.get("given_up", 0), expected
        tweak = self.effective_tweak
        steps = [] if self._plain else [self._look_key(tweak)]
        if self.level != "off":
            steps.append(self._beauty_key(tweak, self.level))
        if any(key not in self._pictures for key in steps):
            done += sum(key in self._pictures for key in steps)
            total += len(steps)
        if total == 0:
            return None
        if total - done == total == 1:
            return (None,)
        return (done / total,)

    def _check(self):
        is_open = self.bridge.in_flight or self.bridge.lightroom_is_open()
        if is_open != self.lightroom_open:
            self.lightroom_open = is_open
            self.changed.emit()
        if self.stage == "choosing":
            self._pump()
        if self.stage in {"preparing", "working", "paused"}:
            return
        incoming = _json(self.bridge.session, {})
        if not isinstance(incoming, dict):
            return
        stamp = incoming.get("time", 0)
        if not isinstance(stamp, (int, float)) or stamp <= self._seen:
            return
        self._seen = stamp
        photo = incoming.get("active")
        if time.time() - stamp >= 120 or not photo or photo not in incoming.get("ids", []):
            return
        self._open_session(incoming)

    def _open_session(self, incoming):
        self._preview_timer.stop()
        self._idle_preview_timer.stop()
        self.session = incoming
        self.photo = incoming["active"]
        self.previews.clear()
        self.thumbs.clear()
        self.flags.clear()
        self.people = []
        self.choices.clear()
        self._everyone.clear()
        self._pictures.clear()
        self._making.clear()
        self.quick.forget()
        self.loading = None
        self.error = None
        self.notice = None
        self.skip_flagged = False
        self.tweak = ZERO_TWEAK
        self.tint, self.shadow, self.high = 0.0, None, None
        self.zoom, self.centre, self.face = 1.0, (0.5, 0.5), None
        ids = incoming["ids"]
        strip = list(ids[:120]) if len(ids) > 1 else []
        self._busy = False
        self._viewed = [self.photo]
        self.opening = {"first": False, "read": 0, "to_read": len(strip), "made": 0, "to_make": 0,
                        "checked": 0, "to_check": len(ids), "more": 0, "to_more": None, "round2": [], "failed": set(),
                        "strip": [i for i in strip if i != self.photo], "cull": list(ids), "fresh": True}
        # straight to the main screen (DESIGN.md 7): what is not made yet stands in place, the button waits for the
        # look on show, and the small progress line tells what goes on behind
        self.stage = "choosing"
        self.changed.emit()
        self.session_opened.emit()

        def ready(error):
            if self.session is not incoming:
                return
            if error:
                self.opening = None
                self.error = error
                self.stage = "failed"
            else:
                self.opening["first"] = True
                self._want_pictures()
                QTimer.singleShot(300, self._pump)
            self.changed.emit()

        def thumb(lines, error):
            if self.session is not incoming:
                return
            self._take_thumbs(lines)
            if strip:
                self.opening["read"] += 1
            self.changed.emit()
            self._load_looks(self.photo, ready)

        self._send_thumbs([self.photo], thumb)

    def _read_people(self):
        people = []
        for item in _json(self.people_file, {}).get("people", []):
            width = item.get("width", 0)
            if width >= 60 and (image := _image(item.get("thumb", ""))) is not None:
                people.append({"id": item["id"], "image": image, "auto": item.get("auto") or "follow",
                               "vec": item.get("vec", []), "photos": len(item.get("photos", [None])), "width": width})
        people.sort(key=lambda p: (p["photos"], p["width"]), reverse=True)
        previous = self.choice_list
        previously_had_people = bool(self.people)
        self._everyone = {p["id"] for p in people}
        self.people = people[:6]
        if len(self.people) > 1:
            known = _json(self.known_file, [])
            for person in people:
                if person["id"] in self.choices:
                    continue
                best = max(((_dot(entry["vec"], person["vec"]), entry["choice"]) for entry in known),
                           key=lambda pair: pair[0], default=(0, "follow"))
                self.choices[person["id"]] = best[1] if best[0] >= .4 else person["auto"]
        return self.choice_list != previous or bool(self.people) != previously_had_people

    def choose_person(self, id_):
        person = next((p for p in self.people if p["id"] == id_), None)
        if person is None or self.level == "off":
            return
        current = self.choices.get(id_, "follow")
        next_level = PERSON_LEVELS[(PERSON_LEVELS.index(current) + 1) % len(PERSON_LEVELS)]
        self.choices[id_] = next_level
        if person["vec"]:
            known = [entry for entry in _json(self.known_file, []) if _dot(entry["vec"], person["vec"]) < .4]
            known.append({"vec": person["vec"], "choice": next_level})
            try:
                atomic_json(self.known_file, known[-300:])
            except OSError:
                pass
        self._controls_changed()

    def _ask_looks(self, photo, only, callback):
        def received(lines, error):
            if error:
                callback([], None, [], error)
                return
            cards, missing = [], []
            folder = None
            for line in lines or []:
                parts = line.split("\t")
                if len(parts) < 4:
                    continue
                id_, path, title, note = parts[:4]
                wheels = None
                if len(parts) >= 5 and parts[4].startswith("wheels="):
                    try:
                        wheels = tuple(int(float(n)) for n in parts[4][7:].split(","))[:4]
                    except ValueError:
                        wheels = None
                image = _image(path) if path else None
                if image is None:
                    missing.append(id_)
                else:
                    folder = Path(path).parent
                    title, note = look_text(id_, title, note)
                    cards.append({"id": id_, "title": title, "note": note, "image": image,
                                  "wheels": wheels if wheels and len(wheels) == 4 else None})
            callback(cards, folder, missing, None)

        self.bridge.send({"action": "previews", "size": "2600", "only": only,
                          "dir": self.bridge.previews, "ids": photo}, received, 300)

    def _store_looks(self, photo, cards, folder, missing, error):
        """Keep what came back for a photo; False when it is not a usable answer."""
        if error or not folder or len(cards) < 2 or not any(c["id"] == "none" for c in cards):
            return False
        self.previews[photo] = {"looks": cards, "folder": folder, "faces": self._read_faces(folder),
                                "expected": len(cards) + len(missing), "given_up": 0, "missing": list(missing)}
        return True

    def _load_looks(self, photo, complete, preferred=None):
        incoming = self.session
        wanted = preferred or ("d" if self.look == "none" else self.look)

        def loaded(cards, folder, missing, error):
            if self.session is not incoming:
                return
            if not self._store_looks(photo, cards, folder, missing, error):
                complete(error or tr("preview.unavailable"))
                return
            if preferred and any(c["id"] == preferred for c in cards):
                self.look = preferred
            elif not any(c["id"] == self.look for c in cards):
                self.look = next(c["id"] for c in cards if c["id"] != "none")
            o = self.opening
            if o is not None and photo == incoming["active"] and not o["first"]:
                o["made"], o["to_make"] = len(cards), len(cards) + len(missing)
                self.settings.setValue("lookCount", len(cards) + len(missing))
            complete(None)

        self._ask_looks(photo, f"none,{wanted}", loaded)

    @staticmethod
    def _read_faces(folder: Path):
        return [(x0, y0, x1 - x0, y1 - y0) for box in _json(folder / "faces.json", [])
                if len(box) == 4 for x0, y0, x1, y1 in [box]]

    # ------------------------------------------------------------------ loading behind the main screen
    # DESIGN.md 7 "先进界面，后台准备" and the request of 2026-11-16 (all photos load once they are handed over):
    # the photo on show first, then, one request at a time and only while nothing else is asked for, the small
    # pictures, the rest of its looks, the closed-eyes check, then every other photo (analysis + original + the look
    # chosen: round one), then their other looks (round two). Every number on the progress line is a count of answers
    # that came back.

    @property
    def look_guess(self):
        """How many looks there were last time: that many empty cards stand in until the real ones come."""
        return max(2, self.settings.value("lookCount", 8, type=int) or 8)

    @property
    def starting(self):
        """The photo on show has no picture yet: the screen is there, the button is not to be pressed."""
        return self.opening is not None and not self.opening["first"]

    @property
    def opening_line(self):
        """(text, fraction) for the small progress line, or None when nothing is loading behind the screen."""
        o = self.opening
        if o is None or self.stage != "choosing":
            return None
        ids = self.session["ids"]
        have = sum(1 for i in ids if i in self.previews or i in o["failed"])     # photos loaded (or given up)
        if not o["first"]:
            text = (tr("progress.reading", done=0, total=o["to_read"]) if o["to_read"] and o["read"] == 0
                    else tr("progress.first"))
        elif o["read"] < o["to_read"]:
            text = tr("progress.reading", done=o["read"], total=o["to_read"])
        elif o["made"] < o["to_make"]:
            text = tr("progress.looks", done=o["made"], total=o["to_make"])
        elif o["checked"] < o["to_check"]:
            text = tr("progress.checking", done=o["checked"], total=o["to_check"])
        elif have < len(ids):
            text = tr("progress.loading", done=have, total=len(ids))
        else:
            text = tr("progress.looks", done=o["more"], total=o["to_more"] or 0)
        # the line: what is done of everything; the looks still to come are counted from what is known
        # (the photos loaded so far) and, for the photos not loaded yet, last time's number of looks
        if o["to_more"] is None:
            known = sum(len(e.get("missing", ())) for i, e in self.previews.items() if i != self.photo)
            more = known + max(0, self.look_guess - 2) * (len(ids) - have)
        else:
            more = o["to_more"]
        total = o["to_read"] + (o["to_make"] or self.look_guess) + o["to_check"] + len(ids) + more
        done = o["read"] + o["made"] + o["checked"] + have + o["more"]
        return text, done / max(total, 1)

    def _quiet(self):
        """Nothing the user asked for is on its way or about to be: only then does a background request go."""
        return (self.stage == "choosing" and self.loading is None and not self._making and not self.tweaking
                and not self.bridge.in_flight and not self._preview_timer.isActive()
                and not self._idle_preview_timer.isActive())

    def _pump(self):
        o, incoming = self.opening, self.session
        if o is None or not o["first"] or self._busy or not self._quiet():
            return
        job = self._next_job()
        if job is None:
            self.opening = None
            self.changed.emit()
            return
        kind, what = job
        self._busy = True

        def finished():
            self._busy = False
            if self.session is incoming and self.opening is o:
                self.changed.emit()
                QTimer.singleShot(300, self._pump)

        if kind == "thumbs":
            o["strip"] = o["strip"][len(what):]

            def thumbs(lines, error):
                if self.session is incoming:
                    if error:
                        o["strip"] = []
                        o["to_read"] = o["read"]          # whatever could not be read is not waited for
                    else:
                        self._take_thumbs(lines)
                        o["read"] += len(what)
                finished()

            self._send_thumbs(what, thumbs)
        elif kind == "cull":
            o["cull"] = o["cull"][len(what):]

            def judged(lines, error):
                if self.session is incoming:
                    if error:
                        o["cull"] = []
                        o["to_check"] = o["checked"]
                    else:
                        o["fresh"] = False
                        for line in lines or []:
                            parts = line.split("\t")
                            if len(parts) >= 2 and parts[0].isdigit():
                                self.flags[int(parts[0])] = parts[1].split(",") if parts[1] else []
                        if self._read_people():
                            self._want_pictures()
                        o["checked"] += len(what)
                finished()

            self.bridge.send({"action": "cull", "size": "1400", "dir": self.bridge.before,
                              "fresh": "1" if o["fresh"] else "0", "ids": _ids(what)}, judged, 240)
        elif kind == "first":
            def loaded(cards, folder, missing, error):
                if self.session is incoming:
                    if not self._store_looks(what, cards, folder, missing, error):
                        o["failed"].add(what)             # not waited for again; the count still moves on
                finished()

            wanted = "d" if self.look == "none" else self.look
            self._ask_looks(what, f"none,{wanted}", loaded)
        else:                                             # "look": one more look of one photo
            photo, name = what
            entry = self.previews[photo]
            entry["missing"] = [m for m in entry.get("missing", ()) if m != name]
            counted_now = photo == incoming["active"] and o["made"] < o["to_make"]
            counted_later = o["to_more"] is not None and photo in o["round2"]

            def more(cards, folder, missing, error):
                if self.session is incoming and photo in self.previews:
                    if not error and cards:
                        self.previews[photo]["looks"] = cards
                    if not any(c["id"] == name for c in self.previews[photo]["looks"]):
                        self.previews[photo]["given_up"] = self.previews[photo].get("given_up", 0) + 1   # this look will not come; the count still moves on
                    if counted_now:
                        o["made"] += 1
                    elif counted_later:
                        o["more"] += 1
                finished()

            self._ask_looks(photo, name, more)

    def _next_job(self):
        o = self.opening
        if o["strip"]:
            return "thumbs", o["strip"][:12]
        for photo in (self.photo, self.session["active"]):  # the photo on show, then the one first handed over
            entry = self.previews.get(photo)
            if entry and entry.get("missing"):
                return "look", (photo, entry["missing"][0])
        if o["cull"]:
            return "cull", o["cull"][:6]
        ids = self.session["ids"]
        for id_ in ids:                                     # round one
            if id_ not in self.previews and id_ not in o["failed"]:
                return "first", id_
        if o["to_more"] is None:                            # round two: decide once which photos it covers
            order = [i for i in self._viewed if i in self.previews] + [i for i in ids if i not in self._viewed]
            if self._cache_size() > CACHE_LIMIT:
                order = [i for i in self._viewed if i in self.previews]     # a big cache: only the photos looked at
            o["round2"] = [i for i in order if i in self.previews]
            o["to_more"] = sum(len(self.previews[i].get("missing", ())) for i in o["round2"])
        for id_ in o["round2"]:
            entry = self.previews.get(id_)
            if entry and entry.get("missing"):
                return "look", (id_, entry["missing"][0])
        return None

    def _cache_size(self):
        total = 0
        for folder in (self.bridge.previews,):
            try:
                for path in folder.rglob("*"):
                    if path.is_file():
                        total += path.stat().st_size
            except OSError:
                pass
        return total

    def _send_thumbs(self, ids, callback):
        self.bridge.send({"action": "thumbs", "size": "240", "dir": self.bridge.thumbs, "ids": _ids(ids)}, callback, 300)

    def _take_thumbs(self, lines):
        for line in lines or []:
            parts = line.split("\t")
            if len(parts) >= 2 and parts[0].isdigit() and (image := _image(parts[1])) is not None:
                self.thumbs[int(parts[0])] = image

    def show(self, id_):
        if self.stage != "choosing" or self.loading is not None or id_ == self.photo:
            return
        self.zoom, self.centre, self.face = 1.0, (0.5, 0.5), None
        self._viewed = [id_] + [i for i in self._viewed if i != id_]
        if id_ in self.previews:
            self.photo = id_
            if self.chosen is None and self.looks:
                self.look = next((card["id"] for card in self.looks if card["id"] != "none"), "none")
            self._controls_changed()
            return
        self.loading = id_
        self.changed.emit()

        def loaded(error):
            self.loading = None
            if not error:
                self.photo = id_
            self._controls_changed()

        self._load_looks(id_, loaded)

    def select_look(self, id_):
        if any(c["id"] == id_ for c in self.looks) and self.look != id_:
            self.look = id_
            self._controls_changed()

    def select_level(self, level):
        if level in LEVELS and self.level != level:
            self.level = level
            self._controls_changed()

    def toggle_shape(self, key):
        if self.level != "off" and key in SHAPES:
            if key in self.shapes:
                self.shapes.remove(key)
            else:
                self.shapes.add(key)
            self._controls_changed()

    def set_tweak(self, index, value, live=False):
        """`live` while a slider is dragged: the quick picture follows and nothing goes to Lightroom (an exact
        picture takes about 10 s); the release sends the final value."""
        value = max(-100, min(100, round(float(value) * 50))) / 50     # whole units on screen
        values = list(self.tweak)
        if self.look == "none":
            return
        self.tweaking = live
        if values[index] != value:
            values[index] = value
            self.tweak = tuple(values)
        if live:
            self._preview_timer.stop()
            self._idle_preview_timer.stop()
            self.changed.emit()
        else:
            self._controls_changed()

    def _controls_changed(self):
        self._want_pictures()
        self.changed.emit()

    def _want_pictures(self):
        self._idle_preview_timer.stop()
        if self.stage == "choosing" and self.chosen is not None:
            self._preview_timer.start()

    def _request_pictures(self, background=False):
        if self.stage != "choosing" or self.chosen is None or self.tweaking:
            return
        if background and (self.bridge.in_flight or self._making or self.loading is not None
                           or self._preview_timer.isActive()):
            self._idle_preview_timer.start()
            return
        incoming = self.session
        photo, style, level, tweak = self.photo, self.look, self.level, self.effective_tweak
        wheels = self.effective_wheels
        folder = self.previews[photo]["folder"]
        shaped, own = tuple(self.shape_list), self.choice_list
        people = self._person_arguments
        base_key = self._look_key(tweak)
        plain = self._plain
        name = style if plain else tweak_name(style, tweak, wheels)

        def still_wanted():
            return (self.session is incoming and self.stage == "choosing"
                    and self._look_key(self.effective_tweak) == base_key
                    and tuple(self.shape_list) == shaped and self.choice_list == own)

        def request_beauty():
            if not still_wanted() or self.level == "off":
                return
            keys = {item: base_key + (item, shaped, own) for item in LEVELS[1:]}
            selected = self.level
            if keys[selected] in self._pictures:
                missing = [item for item in LEVELS[1:] if keys[item] not in self._pictures
                           and keys[item] not in self._making]
                if not missing:
                    return
                if not background:
                    self._idle_preview_timer.start()
                    return
                selected = missing[0]
            elif background:
                self._want_pictures()
                return
            want = keys[selected]
            if want in self._making:
                return
            self._making.add(want)

            def received(lines, error):
                if self.session is not incoming:
                    return
                for line in lines or []:
                    parts = line.split("\t")
                    if (len(parts) >= 2 and parts[0] == selected
                            and (image := _image(parts[1])) is not None):
                        self._pictures[want] = image
                self._making.discard(want)
                if photo in self.previews and not self.previews[photo]["faces"]:
                    self.previews[photo]["faces"] = self._read_faces(folder)
                self.changed.emit()
                if still_wanted() and want in self._pictures:
                    self._idle_preview_timer.start()

            self.bridge.send({"action": "beautypreview", "dir": folder, "look": name,
                              "levels": selected, **dict.fromkeys(shaped, "1"), **people},
                             received, 240)

        if plain or base_key in self._pictures:
            request_beauty()
        elif base_key not in self._making:
            self._making.add(base_key)

            def exact(lines, error):
                if self.session is not incoming:
                    return
                self._making.discard(base_key)
                if lines:
                    parts = lines[0].split("\t")
                    if len(parts) >= 2 and (image := _image(parts[1])) is not None:
                        self._pictures[base_key] = image
                        self.changed.emit()
                        if still_wanted():
                            request_beauty()
                        else:
                            self._want_pictures()

            self.bridge.send({"action": "tweakpreview", "dir": folder, "look": style,
                              "tweak": tweak_argument(tweak), **wheel_arguments(wheels),
                              "size": "2600", "ids": photo}, exact, 120)

    def save_style(self, name, callback):
        if self.stage != "choosing" or self.saving_style:
            return
        incoming = self.session
        photo = self.photo
        all_ids = [photo, *(i for i in incoming["ids"] if i != photo)]
        name = " ".join(name.strip().replace("\t", " ").splitlines()) or tr("look.mine.title")
        self.style_error = None
        self.saving_style = True
        self.changed.emit()

        def complete(error):
            self.saving_style = False
            self.style_error = error
            self._controls_changed()
            callback(error)

        def learned(lines, error):
            if error or not lines:
                complete(error or tr("preview.unavailable"))
                return
            for id_ in list(self.previews):
                if id_ != photo:
                    del self.previews[id_]
            self._load_looks(photo, complete, preferred=lines[0])

        self.bridge.send({"action": "learnstyle", "name": name, "ids": _ids(all_ids)}, learned, 600)

    def delete_style(self, id_):
        def deleted(lines, error):
            if error:
                return
            for preview in self.previews.values():
                preview["looks"] = [card for card in preview["looks"] if card["id"] != id_]
            if self.look == id_:
                self.look = "d"
            self._controls_changed()

        self.bridge.send({"action": "forgetstyle", "key": id_}, deleted, 60)

    def remember_settings(self):
        for key, value in (("look", self.look), ("beautyLevel", self.level), ("shapes", sorted(self.shapes)),
                           ("denoise", self.denoise), ("best", self.best)):
            self.settings.setValue(key, value)

    def fit(self):
        self.zoom, self.centre, self.face = 1.0, (0.5, 0.5), None
        self.changed.emit()

    def _bounded_centre(self, x, y):
        half = .5 / self.zoom
        return min(1 - half, max(half, x)), min(1 - half, max(half, y))

    def pan_to(self, x, y):
        self.centre = self._bounded_centre(x, y)
        self.changed.emit()

    def zoom_by(self, factor, anchor=(.5, .5)):
        old = self.zoom
        self.zoom = min(8, max(1, old * factor))
        if self.zoom == 1:
            self.face = None
        x, y = ((p - .5) * (1 / old - 1 / self.zoom) + c for p, c in zip(anchor, self.centre))
        self.pan_to(x, y)

    def next_face(self):
        if not self.faces:
            return
        next_index = 0 if self.face is None else self.face + 1
        if next_index >= min(len(self.faces), 4):
            self.fit()
            return
        x, y, w, h = self.faces[next_index]
        self.face = next_index
        self.zoom = min(7, max(1.6, .55 / max(h, .02)))
        self.pan_to(x + w / 2, y + h / 2)
