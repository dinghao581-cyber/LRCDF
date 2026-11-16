"""The desktop window: the same screens as RootView in Views.swift, built once and updated in place
(so changes can animate like SwiftUI's), drawn without the Windows title bar."""
import re

from PySide6.QtCore import QEasingCurve, QEvent, QPointF, QRectF, QSize, Qt, QTimer
from PySide6.QtGui import QColor, QFontMetricsF, QPainter, QPen
from PySide6.QtWidgets import (QGraphicsBlurEffect, QHBoxLayout, QLabel, QLayout, QScrollArea, QSizePolicy, QStackedLayout,
                               QVBoxLayout, QWidget)

from . import chrome, icons
from .canvas import CompareCanvas
from .rights import Rights
from .theme import (BOLD, FOCUS, INK, LINE, MEDIUM, PANEL, REGULAR, SEMIBOLD, SOFT, TEXT, Tween, black, css, font,
                    white)
from .i18n import tr
from .widgets import (AddLookCard, ArcSpinner, CheckBox, Control, FaceButton, Field, GhostButton, GlowButton, Heading,
                      Icon, LookCard, Para, PersonChip, PhotoThumb, Pill, ScrollStyle, Spinner, Surface,
                      Switch, TweakRow, Veil, ZoomCapsule, dim, fade, label, painter, set_color, FACE_TEXT, Elided, PillGrid, ProgressLine, ColorWheel, FocusMark, paint_shadow)

C = Qt.AlignmentFlag.AlignCenter
HC = Qt.AlignmentFlag.AlignHCenter
LEFT = Qt.AlignmentFlag.AlignLeft
TOP = chrome.TOP
# "（推荐）" is held together with word joiners so it never breaks across lines (the Mac shot keeps it whole)
LEVELS = {key: (tr(f"level.{key}"), tr(f"level.{key}.note").replace("（推荐）", "（\u2060推\u2060荐\u2060）"))
          for key in ("off", "auto", "natural", "refined")}
SHAPES = [(key, tr(f"shape.{key}")) for key in ("slim", "bigeyes", "waist", "chest", "legs", "light")]
CALLOUT = 12          # .callout on macOS


def row(spacing=0, margins=(0, 0, 0, 0)):
    x = QHBoxLayout()
    x.setContentsMargins(*margins)
    x.setSpacing(spacing)
    return x


def col(spacing=0, margins=(0, 0, 0, 0)):
    x = QVBoxLayout()
    x.setContentsMargins(*margins)
    x.setSpacing(spacing)
    return x


def box(layout, parent=None):
    w = QWidget(parent)
    w.setLayout(layout)
    w.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
    return w


def line(text="", size=13, weight=REGULAR, color=TEXT, align=None):
    """A one-line Text, as tall as SwiftUI makes it (SF's line height, 1.2 em, also for Chinese)."""
    w = label(text, size, weight, color, align=align)
    w.setFixedHeight(round(size * 1.2))
    return w


class FitLine(QLabel):
    """A one-line Text that refits (fit_line) to whatever width the layout gives it - the sidebar loses 8 to its
    scroll bar in a small window."""

    def __init__(self, text, size, weight, color, smallest):
        from .widgets import label
        super().__init__()
        self.full, self.size_, self.weight, self.smallest = text, size, weight, smallest
        model = label(text, size, weight, color)
        self.setFont(model.font())
        self.setStyleSheet(model.styleSheet())
        self.setTextFormat(Qt.TextFormat.PlainText)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.setMinimumWidth(0)
        self.setFixedHeight(round(size * 1.2))
        self.set_full(text)

    def set_full(self, text):
        self.full = text
        fit_line(self, text, self.size_, self.weight, self.width() if self.width() > 50 else 252, self.smallest)

    def resizeEvent(self, e):
        super().resizeEvent(e)
        fit_line(self, self.full, self.size_, self.weight, self.width(), self.smallest)


def fit_line(w, text, size, weight, width, smallest):
    """Set a one-line Text that may be a long translation: the given size when it fits (so Chinese stays exactly as
    it was), else a smaller size down to `smallest` (like SwiftUI's minimumScaleFactor), and only then "…"."""
    from .widgets import text_width, tidy
    text = tidy(text)
    for s in range(size, smallest - 1, -1):
        if text_width(font(s, weight), text) <= width:
            break
    f = font(s, weight)
    w.setFont(f)
    if text_width(f, text) > width:
        from PySide6.QtGui import QFontMetricsF
        text = QFontMetricsF(f).elidedText(text, Qt.TextElideMode.ElideRight, width)
    w.setText(text)


def para(text="", size=13, weight=REGULAR, color=TEXT, width=None, center=True):
    w = Para(text, size, weight, color, center)
    if width:
        w.setMaximumWidth(width)
    return w


def centred(*widgets, spacing=0):
    """A VStack in the middle of the space it is given."""
    v = col(spacing)
    v.addStretch(1)
    for w in widgets:
        if isinstance(w, int):
            v.addSpacing(w)
        elif hasattr(w, "addWidget") or hasattr(w, "addLayout"):
            v.addLayout(w)
        else:
            v.addWidget(w, 0, HC)
    v.addStretch(1)
    return v


class FoldRow(QHBoxLayout):
    """An HStack of buttons centred in its space. When a translation makes the buttons wider than the space, they
    fold into centred rows (in order) instead of being squeezed on top of each other; while they fit, it is the
    plain QHBoxLayout, pixel for pixel."""

    def __init__(self, left=False):
        super().__init__()
        self.left = left

    @staticmethod
    def _size(w):
        return w.sizeHint().expandedTo(w.minimumSize()).boundedTo(w.maximumSize())

    def _shown(self):
        out = []
        for i in range(self.count()):
            w = self.itemAt(i).widget()
            if w is not None and not w.isHidden():
                out.append(w)
        return out

    def _rows(self, width):
        rows, used = [[]], 0
        for w in self._shown():
            need = self._size(w).width() + (self.spacing() if rows[-1] else 0)
            if rows[-1] and used + need > width:
                rows.append([])
                used, need = 0, self._size(w).width()
            rows[-1].append(w)
            used += need
        return [r for r in rows if r]

    def _natural(self):
        shown = self._shown()
        return sum(self._size(w).width() for w in shown) + self.spacing() * max(0, len(shown) - 1)

    def _line(self):
        return max([self._size(w).height() for w in self._shown()] or [0])

    def minimumSize(self):
        return QSize(max([self._size(w).width() for w in self._shown()] or [0]), super().minimumSize().height())

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, width):
        if width >= self._natural():
            return super().sizeHint().height()
        n = len(self._rows(width))
        return n * self._line() + (n - 1) * self.spacing()

    def setGeometry(self, r):
        if r.width() >= self._natural():
            super().setGeometry(r)
            return
        QLayout.setGeometry(self, r)
        h, y = self._line(), r.y()
        for line in self._rows(r.width()):
            width = sum(self._size(w).width() for w in line) + self.spacing() * (len(line) - 1)
            x = r.x() if self.left else r.x() + (r.width() - width) // 2
            for w in line:
                w.setGeometry(x, y + (h - self._size(w).height()) // 2, self._size(w).width(), self._size(w).height())
                x += self._size(w).width() + self.spacing()
            y += h + self.spacing()


def hrow(*widgets, spacing=10):
    r = FoldRow()
    r.setContentsMargins(0, 0, 0, 0)
    r.setSpacing(spacing)
    r.addStretch(1)
    for w in widgets:
        r.addWidget(w)
    r.addStretch(1)
    return r


def lrow(*widgets, spacing=10):
    """An HStack of buttons from the leading edge; folds into more rows like hrow."""
    r = FoldRow(left=True)
    r.setContentsMargins(0, 0, 0, 0)
    r.setSpacing(spacing)
    for w in widgets:
        r.addWidget(w)
    r.addStretch(1)
    return r


def show_soft(widget, on, duration=300):
    """Fade a view in or out (the default SwiftUI .transition(.opacity))."""
    if on:
        if not widget.isVisible() or getattr(widget, "_leaving", False):
            widget._leaving = False
            fade(widget, 0, animate=False)
            widget.show()
            widget.raise_()
            if hasattr(widget, "arrive"):
                widget.arrive()
            fade(widget, 1, duration)
    elif widget.isVisible() and not getattr(widget, "_leaving", False):
        widget._leaving = True
        if hasattr(widget, "leave"):
            widget.leave(duration)
        fade(widget, 0, duration)
        QTimer.singleShot(duration, lambda: widget.hide() if getattr(widget, "_leaving", False) else None)


class Snapshot(QWidget):
    """Crossfades a page change: a picture of the old page fading out over the new one."""

    def __init__(self, parent):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.pixmap = None
        self.t = Tween(0, self._step, self, 400, QEasingCurve.Type.InOutQuad)
        self.hide()

    def start(self, pixmap, duration=400):
        self.pixmap = pixmap
        self.setGeometry(self.parentWidget().rect())
        self.t.to(1, animate=False)
        self.show()
        self.raise_()
        self.t.to(0, duration)

    def _step(self):
        if self.t.value <= 0.001:
            self.hide()
            self.pixmap = None
        self.update()

    def paintEvent(self, _e):
        if self.pixmap is not None:
            p = QPainter(self)
            p.setOpacity(self.t.value)
            p.drawPixmap(0, 0, self.pixmap)


# ====================================================================== pages
class StepRow(QWidget):
    """StepRow: a 24 pt disc (white 0.1) with the number (13 bold rounded), the text (15, soft); 380 wide."""

    def __init__(self, n, text):
        super().__init__()
        self.n, self.text = n, text
        # a translation that does not fit 344 wraps; the disc stays with the first line
        self.lines = [t.rstrip() for t, _ in Para(text, 15)._lines(344)] or [text]
        self.setFixedSize(380, 24 + (len(self.lines) - 1) * 18)

    def paintEvent(self, _e):
        p = painter(self)
        d = QRectF(0, 0, 24, 24)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.1))
        p.drawEllipse(d)
        p.setFont(font(13, BOLD))
        p.setPen(TEXT)
        p.drawText(d, C, str(self.n))
        p.setFont(font(15))
        p.setPen(SOFT)
        if len(self.lines) == 1:
            p.drawText(QRectF(36, 0, 344, 24), Qt.AlignmentFlag.AlignVCenter | LEFT, self.text)
            return
        for i, t in enumerate(self.lines):
            p.drawText(QRectF(36, 3 + i * 18, 344, 18), Qt.AlignmentFlag.AlignVCenter | LEFT, t)


class Note(QWidget):
    """Label(text, systemImage: 'exclamationmark.circle') in focus yellow."""

    def __init__(self, text, size=CALLOUT):
        super().__init__()
        self.text = text
        self.f = font(size)
        from .widgets import text_width
        self.setFixedSize(round(size + 6 + text_width(self.f, text)) + 2, round(size * 1.5))

    def paintEvent(self, _e):
        p = painter(self)
        s = self.f.pixelSize()
        icons.exclamation_circle(p, QRectF(0, (self.height() - s) / 2, s, s), FOCUS, 0.08)
        p.setFont(self.f)
        p.setPen(FOCUS)
        p.drawText(QRectF(s + 6, 0, self.width(), self.height()), Qt.AlignmentFlag.AlignVCenter | LEFT, self.text)


class Card(QWidget):
    """LastRunCard's background: corner 14, white 0.04."""

    def paintEvent(self, _e):
        p = painter(self)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.04))
        p.drawRoundedRect(QRectF(self.rect()), 14, 14)


class WaitingPage(QWidget):
    """WaitingView: VStack(spacing 22) of the sparkles, the title, the steps (+6), the Lightroom note (+8) and
    button, and LastRunCard (+10); 40 padding."""

    def __init__(self, win):
        super().__init__()
        self.win = win
        f = win.flow
        self.icon = Icon("sparkles", 54, None, icons.LIGHT)
        self.title = line(tr("app.title"), 30, SEMIBOLD, align=C)
        self.title.setFixedWidth(400)
        steps = col(10)
        for i, t in enumerate([re.sub(r"^\d+\s+", "", tr(f"welcome.step{n}")) for n in (1, 2, 3)], 1):   # StepRow draws the number
            steps.addWidget(StepRow(i, t), 0, HC)
        self.steps = box(steps)
        self.away = Note(tr("bridge.open_first"))
        self.open_lr = GhostButton(tr("welcome.open"), f.back_to_lightroom)
        self.card = Card()
        cv = col(10, (18, 18, 18, 18))
        self.card_text = line("", 13, MEDIUM, align=C)
        self.card_text.setFixedWidth(440)
        self.card_a = GhostButton(tr("welcome.resume"), f.work)
        self.card_b = GhostButton(tr("welcome.stop"), f.stop_run)
        self.card_c = GhostButton(tr("review.open"), f.start_review)
        self.card_d = GhostButton(tr("undo.last"), f.undo_run)
        self.card_note = para("", 12, color=SOFT, width=440)
        cv.addWidget(self.card_text, 0, HC)
        cv.addLayout(hrow(self.card_a, self.card_b, self.card_c, self.card_d))
        cv.addWidget(self.card_note, 0, HC)
        self.card.setLayout(cv)
        self.notice = para("", 12, color=SOFT, width=440)
        self.notice.setFixedWidth(440)
        self.v = col(0, (40, 40, 40, 40))
        self.setLayout(self.v)

    def refresh(self):
        s, f = self.win.studio, self.win.flow
        away = not s.lightroom_open
        run = f.run
        has = bool(run) and not run.get("undone", False)
        unfinished = has and not run.get("finished", False)
        done = (run or {}).get("done", [])
        finished = has and not unfinished and bool(done)
        in_card = unfinished or finished
        if unfinished:
            self.card_text.setText(tr("welcome.incomplete", remaining=f.remaining, done=len(done)))
            self.card_text.setFont(font(13, MEDIUM))
            set_color(self.card_text, TEXT)
        elif finished:
            self.card_text.setText(tr("welcome.last_count", count=len(done)))
            self.card_text.setFont(font(13))
            set_color(self.card_text, SOFT)
        for b in (self.card_a, self.card_b):
            b.setVisible(unfinished)
        for b in (self.card_c, self.card_d):
            b.setVisible(finished)
        self.card.setEnabled(s.lightroom_open)
        notice = s.notice or ""
        self.card_note.setText(notice)
        self.card_note.setVisible(bool(notice) and in_card)
        self.notice.setText(notice)
        items = [(self.icon, 0), (self.title, 0), (self.steps, 6)]
        if away:
            items += [(self.away, 8), (self.open_lr, 0)]
        if in_card:
            items.append((self.card, 10))
        elif notice:
            items.append((self.notice, 10))
        v = self.v
        while v.count():
            v.takeAt(0)
        for w in (self.away, self.open_lr, self.card, self.notice):
            w.hide()
        v.addStretch(1)
        for i, (w, extra) in enumerate(items):
            if i:
                v.addSpacing(22 + extra)
            v.addWidget(w, 0, HC)
            w.show()
        v.addStretch(1)


class PreparingPage(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.sub = line("", CALLOUT, color=SOFT, align=C)
        self.sub.setFixedWidth(600)
        self.line = ProgressLine(200, percent=False)
        self.line.set_progress(None)          # waiting for the first look: nothing to count yet (DESIGN.md: no big spinner)
        self.setLayout(centred(self.line, 20, line(tr("preview.first_photo"), 20, SEMIBOLD, align=C), 20, self.sub))
        self.layout().itemAt(3).widget().setFixedWidth(600)

    def refresh(self):
        name = (self.win.studio.session or {}).get("name", "")
        self.sub.setText(tr("preview.wait", name=name) if name else "")


class FailedPage(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        f = win.flow
        self.message = para("", CALLOUT, color=SOFT, width=460)
        self.message.setFixedWidth(460)
        self.go_on = GhostButton(tr("run.resume"), f.work)
        self.back = GhostButton(tr("lightroom.return"), f.back_to_lightroom)
        self.ret = GhostButton(tr("action.back"), f.again)
        self.setLayout(centred(Icon("warning", 40, FOCUS, icons.LIGHT), 18, line(tr("run.incomplete"), 22, SEMIBOLD, align=C), 18,
                               self.message, 18, hrow(self.go_on, self.back, self.ret, spacing=12)))
        self.layout().itemAt(3).widget().setFixedWidth(400)

    def refresh(self):
        s, f = self.win.studio, self.win.flow
        self.message.setText(s.error or "")
        self.go_on.setVisible(bool(f.run) and not f.run.get("finished"))
        self.ret.setVisible(bool(s.looks))


# ====================================================================== studio parts
class _Tail(QWidget):
    """Where the hint and the progress line take turns: as wide as the hint asks, so nothing moves."""

    def __init__(self, bar):
        super().__init__()
        self.bar = bar

    def sizeHint(self):
        return QSize(max(self.bar.hint.natural, self.bar.progress.width()), 30)

    def minimumSizeHint(self):
        return QSize(0, 30)


class ZoomBar(QWidget):
    """ZoomBar: zoom capsule, the face button, the hint (11, white 0.3); 8 apart."""

    def __init__(self, canvas):
        super().__init__()
        self.canvas = canvas
        self.zoom = ZoomCapsule(lambda: canvas.magnify(1 / 1.5), lambda: canvas.magnify(1.5))
        self.zoom.fit.connect(canvas.fit)
        self.face = FaceButton(canvas.next_face)
        self.hint = Elided(tr("zoom.hint"), 11, white(0.3))
        # the preview progress takes the hint's place while a preview is on its way; the place keeps the hint's
        # width so the buttons do not move
        self.progress = ProgressLine(140)
        self.tail = _Tail(self)
        self.tail_stack = QStackedLayout(self.tail)
        hint_holder = QWidget()
        hh = col()
        hh.addWidget(self.hint, 0, Qt.AlignmentFlag.AlignVCenter)
        hint_holder.setLayout(hh)
        self.tail_stack.addWidget(hint_holder)
        holder = QWidget()
        hl = row()
        hl.addWidget(self.progress, 0, Qt.AlignmentFlag.AlignVCenter)
        hl.addStretch(1)
        holder.setLayout(hl)
        self.tail_stack.addWidget(holder)
        self.tail.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)
        self.tail.setMinimumWidth(0)
        r = row(8)
        r.addWidget(self.zoom)
        r.addWidget(self.face)
        r.addWidget(self.tail)
        self.setLayout(r)
        self.setFixedHeight(30)
        canvas.changed.connect(self.sync)

    def sync(self):
        c = self.canvas
        self.zoom.set_zoom(c.target_zoom)
        n = min(len(c.faces), 4)
        self.face.set_text(FACE_TEXT if c.face is None else (tr("zoom.next_face") if c.face + 1 < n else tr("zoom.full")))
        self.face.setVisible(bool(c.faces))

    def show_progress(self, progress):
        """`progress` as Studio.progress gives it: None hides the line and brings the hint back."""
        if progress is None:
            self.tail_stack.setCurrentIndex(0)
            return
        self.progress.set_progress(progress[0])
        self.tail_stack.setCurrentIndex(1)


class PhotoStrip(Surface):
    """PhotoStrip: 104 wide on the panel colour with a line on its right; 'N 张' (12 semibold, soft) 46 from the
    top; 76 pt thumbnails 10 apart; the hint (10, white 0.35) at the bottom."""

    def __init__(self, hint):
        super().__init__(PANEL, right_line=True)
        self.setFixedWidth(104)
        self.count = line("", 12, SEMIBOLD, SOFT, align=C)
        self.thumbs = []
        self.list = col(10, (0, 6, 0, 6))
        self.list.addStretch(1)
        inner = box(self.list)
        self.mark = FocusMark(inner)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet(ScrollStyle.SHEET)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setWidget(inner)
        self.hint = para(hint, 10, color=white(0.35))
        v = col(0, (0, TOP + 46, 0, 0))
        v.addWidget(self.count)
        v.addSpacing(10)
        v.addWidget(scroll, 1)
        v.addSpacing(12)
        v.addWidget(self.hint)
        v.addSpacing(12)
        self.setLayout(v)

    def set_photos(self, ids, images, active, loading, flags, on_click):
        self.count.setText(tr("batch.count", count=len(ids)))
        while len(self.thumbs) < len(ids):
            t = PhotoThumb()
            t.clicked.connect(lambda t=t: t.on_click(t.photo))
            self.list.insertWidget(self.list.count() - 1, t, 0, HC)
            self.thumbs.append(t)
        for t, id_ in zip(self.thumbs, ids):
            t.photo, t.on_click = id_, on_click
            t.set_state(images.get(id_), id_ == active, id_ == loading, flags.get(id_, []))
            t.show()
        for t in self.thumbs[len(ids):]:
            t.hide()
        self.mark.follow(next((t for t, id_ in zip(self.thumbs, ids) if id_ == active), None))


class BlankLookCard(Control):
    """A look that is not made yet (DESIGN.md 7): the card's shape in faint, two short bars where the name and the line
    about it go. A real card takes its place when the look comes."""

    def __init__(self):
        super().__init__()
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.card_w = 120

    def set_width(self, width):
        self.card_w = width
        self.setFixedSize(width, min(104, round(width * 0.66)) + 7 + 16 + 7 + 13)

    def paintEvent(self, _e):
        p = painter(self)
        pic = QRectF(0, 0, self.card_w, min(104, round(self.card_w * 0.66)))
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(pic, 9, 9)
        p.setBrush(white(0.10))
        y = pic.bottom() + 7
        p.drawRoundedRect(QRectF(0, y + 3, self.card_w * 0.55, 10), 5, 5)
        p.drawRoundedRect(QRectF(0, y + 23 + 2, self.card_w * 0.8, 8), 4, 4)


class LookStrip(Surface):
    """LookStrip: 176 high, panel 0.6 with a line on top; every card visible at once, 12 apart."""

    def __init__(self, win):
        super().__init__(QColor(PANEL.red(), PANEL.green(), PANEL.blue(), 153), top_line=True)
        self.win = win
        self.setFixedHeight(176)
        self.cards = []
        self.blanks = []
        self.add = AddLookCard()
        self.add.clicked.connect(win.open_save)
        self.row = row(12)
        self.row.addStretch(1)
        self.row.addWidget(self.add, 0, Qt.AlignmentFlag.AlignVCenter)
        self.row.addStretch(1)
        self.setLayout(self.row)
        self._shown = ()
        self.mark = FocusMark(self)

    def refresh(self, animate=True):
        s = self.win.studio
        looks = s.looks
        entry = s.previews.get(s.photo)
        if s.stage != "choosing":
            blanks = 0
        elif entry is None:
            blanks = s.look_guess if s.loading is None else 0
        else:
            blanks = max(0, entry.get("expected", 0) - len(looks) - entry.get("given_up", 0))
        n = len(looks) + blanks + 1
        width = int(min(170, max(70, (self.width() - 48 - 12 * (n - 1)) / n)))
        while len(self.blanks) < blanks:
            b = BlankLookCard()
            self.row.insertWidget(self.row.indexOf(self.add), b, 0, Qt.AlignmentFlag.AlignVCenter)
            self.blanks.append(b)
        for i, b in enumerate(self.blanks):
            b.set_width(width)
            b.setVisible(i < blanks)
        while len(self.cards) < len(looks):
            c = LookCard()
            c.clicked.connect(lambda c=c: self.win.studio.select_look(c.look["id"]))
            c.delete.connect(lambda c=c: self.win.studio.delete_style(c.look["id"]))
            self.row.insertWidget(self.row.indexOf(self.cards[-1]) + 1 if self.cards else 1, c, 0, Qt.AlignmentFlag.AlignVCenter)
            self.cards.append(c)
        ids = tuple(l["id"] for l in looks)
        for i, (c, look) in enumerate(zip(self.cards, looks)):
            new = look["id"] not in self._shown and bool(self._shown)
            c.set_look(look, s.look == look["id"], width, animate)
            if not c.isVisible():
                c.show()
                if new and animate:            # looks arriving one by one: easeInOut 0.3
                    fade(c, 0, animate=False)
                    fade(c, 1, 300)
        for c in self.cards[len(looks):]:
            c.hide()
        self.add.set_width(width)
        self._shown = ids
        self.mark.follow(next((c for c, look in zip(self.cards, looks) if look["id"] == s.look), None), animate)


class Sidebar(Surface):
    def __init__(self, win):
        super().__init__(PANEL, left_line=True)
        self.win = win
        s = win.studio
        self.setFixedWidth(300)
        outer = col(0, (0, 0, 0, 0))
        v = col(0, (24, TOP + 44, 24, 0))
        self.upper = box(v)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet(ScrollStyle.SHEET)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setWidget(self.upper)
        outer.addWidget(self.scroll, 1)
        bottom = col(0, (24, 0, 24, 22))
        # long translations (Polish) shrink to fit, Chinese stays as it was
        self.title = FitLine(tr("app.action"), 22, SEMIBOLD, TEXT, 16)
        self.subtitle = FitLine("", 12, REGULAR, SOFT, 10)
        v.addWidget(self.title)
        v.addSpacing(6)
        v.addWidget(self.subtitle)
        v.addSpacing(22)
        v.addWidget(Heading("1", tr("look.section")))
        v.addSpacing(8)
        self.look_note = para("", 13, color=SOFT, center=False)
        v.addWidget(self.look_note)
        v.addSpacing(10)
        self.tweaks = []
        tw = col(6)
        ends = [(tr("tweak.dark"), tr("tweak.bright")), (tr("tweak.cool"), tr("tweak.warm")), (tr("tweak.muted"), tr("tweak.rich"))]
        end = TweakRow.end_width([w for pair in ends for w in pair])
        for i, (a, b) in ((0, ends[0]), (2, ends[2])):
            t = TweakRow(a, b, end)
            t.index = i
            t.changed.connect(lambda value, i=i: self.win.studio.set_tweak(i, value))
            t.moving.connect(lambda value, i=i: self.win.studio.set_tweak(i, value, live=True))
            self.tweaks.append(t)
        # the colour wheels between the dark/light and muted/rich rows (DESIGN.md 7): the picker, then one wheel;
        # white balance's warm-cool is the old cool/warm row
        tw.addWidget(self.tweaks[0])
        tw.addSpacing(4)
        self.wheel_pills = {}
        for kind, key in (("wb", "wheel.wb"), ("shadow", "wheel.shadow"), ("high", "wheel.high")):
            self.wheel_pills[kind] = Pill(tr(key), lambda kind=kind: self.win.studio.select_wheel(kind), size=12,
                                          height=28, corner=8)
        tw.addWidget(PillGrid(list(self.wheel_pills.values())))
        self.wheel = ColorWheel((tr("tweak.warm"), tr("tweak.cool"), tr("wheel.pink"), tr("wheel.green")))
        self.wheel.moving.connect(lambda value: self.win.studio.set_wheel(self.win.studio.wheel, value, live=True))
        self.wheel.changed.connect(lambda value: self.win.studio.set_wheel(self.win.studio.wheel, value))
        self.wheel.reset.connect(lambda: self.win.studio.reset_wheel(self.win.studio.wheel))
        tw.addWidget(self.wheel)
        tw.addWidget(self.tweaks[1])
        self.tweak_box = box(tw)
        v.addWidget(self.tweak_box)
        v.addSpacing(22)
        v.addWidget(Heading("2", tr("level.section")))
        v.addSpacing(10)
        self.levels = {}
        for key, (title, _) in LEVELS.items():
            self.levels[key] = Pill(title, lambda key=key: self.win.studio.select_level(key))
        v.addWidget(PillGrid(list(self.levels.values())))
        v.addSpacing(7)
        self.level_note = para("", 11, color=white(0.4), center=False)
        v.addWidget(self.level_note)
        self.people_gap = v.count()
        v.addSpacing(10)
        self.people = box(row(8))
        self.people.setToolTip(tr("person.tooltip"))
        self.chips_people = {}
        v.addWidget(self.people)
        v.addSpacing(10)
        self.shapes = {}
        for key, title in SHAPES:
            self.shapes[key] = Pill(title, lambda key=key: self.win.studio.toggle_shape(key), size=12, height=28, corner=8,
                                    off_color=white(0.75), animated=False)
        self.shape_box = PillGrid(list(self.shapes.values()))
        self.shape_box.setToolTip(tr("shape.tooltip"))
        v.addWidget(self.shape_box)
        v.addSpacing(8)
        self.best = Switch(tr("quality.toggle"), s.best)
        self.best.toggled.connect(lambda on: self.win.change("best", on))
        self.best.setToolTip(tr("quality.tooltip"))
        v.addWidget(self.best)
        v.addSpacing(22)
        v.addWidget(Heading("3", tr("denoise.section")))
        v.addSpacing(10)
        self.denoise = Switch(tr("denoise.toggle"), s.denoise)
        self.denoise.toggled.connect(lambda on: self.win.change("denoise", on))
        v.addWidget(self.denoise)
        v.addSpacing(7)
        self.denoise_note = para("", 11, color=white(0.35), center=False)
        v.addWidget(self.denoise_note)
        v.addStretch(1)
        bottom.addSpacing(14)                       # Spacer(minLength: 14)
        self.skip = CheckBox("", False, size=12)
        self.skip.toggled.connect(lambda on: self.win.change("skip_flagged", on))
        bottom.addWidget(self.skip)
        self.skip_gap = bottom.count()
        bottom.addSpacing(10)
        self.go = GlowButton(tr("batch.retouch_one"), lambda: self.win.flow.retouch(), height=48, stretch=True)
        bottom.addWidget(self.go)
        bottom.addSpacing(10)
        bottom.addWidget(para(tr("batch.original_unchanged"), 11, color=white(0.35), center=False))
        self.bottom = bottom
        outer.addLayout(bottom)
        self.setLayout(outer)
        self.v = v
        self._people_ids = ()

    def refresh(self, animate=True):
        s = self.win.studio
        self.subtitle.set_full(tr("batch.settings", count=s.count) if s.count > 1 else (s.session or {}).get("name", ""))
        chosen = s.chosen
        self.look_note.setText(tr("look.original_colors") if s.look == "none" else (f"{chosen['title']} · {chosen['note']}" if chosen else ""))
        no_look = s.look == "none" or s.chosen is None
        for t in self.tweaks:
            t.set_value(s.tweak[t.index])
        for kind, pill in self.wheel_pills.items():
            pill.set_selected(s.wheel == kind, animate)
            pill.mark = s.wheel_moved(kind)
            pill.update()
        labels = (tr("wheel.warmth"), tr("wheel.tint")) if s.wheel == "wb" else (tr("wheel.hue"), tr("wheel.sat"))
        self.wheel.set_mode("wb" if s.wheel == "wb" else "hue", s.wheel_value(s.wheel), labels, s.wheel_moved(s.wheel))
        self.tweak_box.setEnabled(not no_look)
        dim(self.tweak_box, 0.3 if no_look else 1, 200, animate)
        for key, p in self.levels.items():
            p.set_selected(s.level == key, animate)
        self.level_note.setText(LEVELS[s.level][1])
        off = s.level == "off"
        # people: up to six faces when two or more people are in the photos
        people = s.people[:6] if len(s.people) > 1 and not off else []
        ids = tuple(p["id"] for p in people)
        if ids != self._people_ids:
            lay = self.people.layout()
            while lay.count():
                w = lay.takeAt(0).widget()
                if w:
                    w.deleteLater()
            self.chips_people = {}
            for person in people:
                chip = PersonChip(person["image"], lambda pid=person["id"]: self.win.studio.choose_person(pid))
                lay.addWidget(chip, 0, Qt.AlignmentFlag.AlignTop)
                self.chips_people[person["id"]] = chip
            lay.addStretch(1)
            self._people_ids = ids
            if ids and animate:
                fade(self.people, 0, animate=False)
                fade(self.people, 1, 300)
        for pid, chip in self.chips_people.items():
            chip.set_choice(s.choices.get(pid, "follow"))
        self.people.setVisible(bool(ids))
        self.v.itemAt(self.people_gap).spacerItem().changeSize(0, 10 if ids else 0)
        for key, p in self.shapes.items():
            p.set_selected(key in s.shapes, False)
        self.shape_box.setEnabled(not off)
        dim(self.shape_box, 0.35 if off else 1, 200, animate)
        self.best.set_checked(s.best, animate)
        self.best.setEnabled(not off)
        dim(self.best, 0.35 if off else 1, 200, animate)
        self.denoise.set_checked(s.denoise, animate)
        iso = (s.session or {}).get("iso") or 0
        noisy = iso >= 1600
        self.denoise_note.setText(tr("denoise.high_iso", iso=iso) if noisy
                                  else tr("denoise.hint"))
        set_color(self.denoise_note, FOCUS if noisy and not s.denoise else white(0.35))
        flagged = len(s.flagged)
        self.skip.setVisible(flagged > 0)
        if flagged:
            text = tr("batch.skip", count=flagged)
            if text != self.skip.text:
                self.skip.text = text
                # one line may run into the right margin (the Chinese line is 274, as it always was); wrapped lines keep it
                self.skip.fit(276, 252)
            self.skip.checked = s.skip_flagged
            self.skip.update()
        self.bottom.itemAt(self.skip_gap).spacerItem().changeSize(0, 10 if flagged else 0)
        n = len(s.targets)
        self.go.set_text(tr("batch.retouch_one_or_more", count=n) if n > 1 else tr("batch.retouch_one"))
        self.go.setEnabled(not s.nothing_to_do)
        self.v.invalidate()
        self.bottom.invalidate()


class OpeningPill(QWidget):
    """The small progress of the loading behind the main screen (DESIGN.md 7 先进界面，后台准备): a capsule at the top
    of the picture area, a 72 x 3 line (faint track, focus-yellow fill with a soft yellow glow) and one 12 pt soft line,
    even digits. Comes and goes softly; not shown once the work has begun."""

    H, BAR = 36, 72

    def __init__(self, host):
        super().__init__(host)
        self.host = host
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.f = font(12, MEDIUM, digits=True)
        self.text = self.full = ""
        self.t = Tween(0, self.update, self, 400)
        host.installEventFilter(self)
        self.hide()

    def eventFilter(self, obj, e):
        if obj is self.host and e.type() == QEvent.Type.Resize:
            self._place()
        return False

    def _place(self):
        room = self.host.width() - 32 - (16 + self.BAR + 10 + 18)           # what the words may take
        size = 12
        self.f = font(size, MEDIUM, digits=True)
        while QFontMetricsF(self.f).horizontalAdvance(self.full) > room and size > 10:
            size -= 1                                                       # first smaller (to 10) ...
            self.f = font(size, MEDIUM, digits=True)
        self.text = QFontMetricsF(self.f).elidedText(self.full, Qt.TextElideMode.ElideRight, room)   # ... then "..."
        w = 16 + self.BAR + 10 + round(QFontMetricsF(self.f).horizontalAdvance(self.text)) + 18
        self.setGeometry((self.host.width() - w) // 2, 16, w, self.H)

    def set_line(self, line, animate=True):
        if line is None:
            show_soft(self, False)
            return
        text, fraction = line
        if text != self.full:
            self.full = text
            self._place()
        first = not self.isVisible()
        self.t.to(fraction, animate=animate and not first)
        show_soft(self, True)
        self.raise_()
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(LINE, 1))
        p.setBrush(QColor(PANEL.red(), PANEL.green(), PANEL.blue(), 224))
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        track = QRectF(16, (self.height() - 3) / 2, self.BAR, 3)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(track, 1.5, 1.5)
        fill = QRectF(track.left(), track.top(), max(3.0, self.BAR * min(1.0, self.t.value)), 3)
        glow = QColor(FOCUS)
        glow.setAlphaF(0.6)
        paint_shadow(p, fill, 1.5, 4, glow)
        p.setBrush(FOCUS)
        p.drawRoundedRect(fill, 1.5, 1.5)
        p.setFont(self.f)
        p.setPen(SOFT)
        p.drawText(QRectF(track.right() + 10, 0, self.width() - track.right() - 10, self.height()),
                   Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, self.text)


class StageOverlay(QWidget):
    """StageCard (Views.swift): one card at the bottom for the three states after the button: working, paused,
    finished. The photo above it stays the subject, sharp. The card floats over the bottom of the picture area
    (`host`), as large as itself, so the photo around it still takes the mouse after the work (Mac: only paused
    stops it)."""

    GAP = 16                                   # card to the bottom of the picture area

    def __init__(self, win, host):
        super().__init__(host)
        self.win, self.host = win, host
        self.card = Panel(18)
        self.body = col(10, (26, 20, 26, 20))
        self.card.setLayout(self.body)
        outer = col()
        outer.addWidget(self.card)
        self.setLayout(outer)
        host.installEventFilter(self)
        self.rise = Tween(0, self._rising, self, 550, QEasingCurve.Type.OutBack)
        self.hide()

    def eventFilter(self, obj, e):
        if obj is self.host and e.type() == QEvent.Type.Resize:
            self.place()
        return False

    def _width(self):
        return max(240, min(620, self.host.width() - 28))

    def fit(self, inner):
        """Size what has to know the inner width (lines that wrap, the progress line)."""

    def card_height(self):
        """The card's height at the width it will have (asked before it is shown, so not its current size)."""
        width = self._width()
        self.fit(width - 52)
        lay = self.card.layout()
        lay.invalidate()
        h = lay.heightForWidth(width) if lay.hasHeightForWidth() else -1
        return h if h > 0 else lay.sizeHint().height()

    def room(self):
        """How much of the bottom of the picture area the card takes."""
        return self.card_height() + self.GAP

    def place(self):
        width, h = self._width(), self.card_height()
        self.card.setFixedSize(width, h)
        self.setGeometry((self.host.width() - width) // 2, self._top(h) + round(self.rise.value), width, h)

    def _top(self, h=None):
        return self.host.height() - self.GAP - (self.height() if h is None else h)

    def _rising(self):
        self.move(self.x(), self._top() + round(self.rise.value))

    def arrive(self):
        """Come up from below the bottom edge, from the card's own height plus the gap (DS.stage spring, 0.55 s)."""
        if self.rise.value < 1:
            self.rise.to(self.height() + self.GAP, animate=False)
        self.rise._anim.setEasingCurve(QEasingCurve.Type.OutBack)
        self.rise.to(0, 550)

    def leave(self, duration=300):
        """Go back down while fading (show_soft hides it at the end); no bounce on the way out."""
        self.rise._anim.setEasingCurve(QEasingCurve.Type.InCubic)
        self.rise.to(self.height() + self.GAP, duration)


class WorkingOverlay(StageOverlay):
    """While Lightroom works: the name of the work and the per cent on top, a 4 pt line, then what is happening and
    Pause. The result spreads across the photo as far as the work has got (CompareCanvas.set_sweep)."""

    def __init__(self, win, host):
        super().__init__(win, host)
        self.title = line("", 19, SEMIBOLD)
        self.percent = line("", 24, SEMIBOLD)
        self.percent.setFont(font(24, SEMIBOLD, digits=True))
        self.percent.setFixedWidth(round(QFontMetricsF(self.percent.font()).horizontalAdvance("100%")) + 4)
        self.percent.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.bar = ProgressLine(400, percent=False)
        self.caption = para("", CALLOUT, color=SOFT, center=False)
        self.pause = GhostButton(tr("run.pause"), win.flow.request_pause)
        top = row(12)
        top.addWidget(self.title, 1)
        top.addWidget(self.percent, 0, Qt.AlignmentFlag.AlignBottom)
        bottom = row(12)
        bottom.addWidget(self.caption, 1)
        bottom.addWidget(self.pause, 0, Qt.AlignmentFlag.AlignVCenter)
        self.body.setSpacing(12)
        self.body.addLayout(top)
        self.body.addWidget(self.bar)
        self.body.addLayout(bottom)

    def fit(self, inner):
        self.bar.set_bar_width(inner)
        self.title.setFixedWidth(inner - 12 - self.percent.width())

    def refresh(self):
        f = self.win.flow
        run = f.run or {}
        n = len(run.get("ids", []))
        self.bar.set_progress(f.fraction)
        self.percent.setText(f"{round(f.fraction * 100)}%")
        self.title.setText(tr("run.working_count", count=n) if n > 1 else tr("run.working_one"))
        done = len(run.get("done", []))
        self.caption.setText(tr("run.completed_fraction", done=done, total=n, caption=f.caption) if run.get("level") != "off" and n > 1 else f.caption)
        self.pause.setVisible(n > 3)
        self.pause.set_text(tr("run.pause_pending") if f.pause_requested else tr("run.pause"))
        self.pause.setEnabled(not f.pause_requested)


class PausedOverlay(StageOverlay):
    """Paused: the title, how many are done and left, then Go on (the one primary button) and Stop here."""

    def __init__(self, win, host):
        super().__init__(win, host)
        f = win.flow
        self.text = para("", 13, color=SOFT, center=False)
        self.body.addWidget(line(tr("run.paused"), 22, SEMIBOLD))
        self.body.addWidget(self.text)
        self.body.addSpacing(6)
        self.body.addLayout(lrow(GlowButton(tr("run.resume"), f.work), GhostButton(tr("run.stop"), f.stop_run)))

    def fit(self, inner):
        self.text.setFixedWidth(inner)

    def refresh(self):
        f = self.win.flow
        done = len((f.run or {}).get("done", []))
        self.text.setText(tr("run.resume_info", done=done, remaining=f.remaining))


class FinishedOverlay(StageOverlay):
    """Finished (or undone): the title, where the results are, the failed ones with Retry, a notice, then the
    actions in one row, folding into more rows when a translation is too long (ViewThatFits)."""

    def __init__(self, win, host):
        super().__init__(win, host)
        f = win.flow
        self.title = line("", 24, SEMIBOLD)
        self.sub = para("", 13, color=SOFT, center=False)
        self.failed = line("", 13, color=FOCUS)
        self.failed.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        self.retry = GhostButton("", f.retry_failed)
        self.failed_row = box(lrow(self.failed, self.retry))
        self.notice = para("", 12, color=SOFT, center=False)
        self.review = GlowButton(tr("review.open"), f.start_review)
        self.back = GhostButton(tr("lightroom.return"), f.back_to_lightroom)
        self.again = GhostButton(tr("look.try_again"), f.again)
        self.undo = GhostButton(tr("undo.current"), f.undo_run)
        for w in (self.title, self.sub, self.failed_row, self.notice):
            self.body.addWidget(w)
        self.body.addSpacing(6)
        self.body.addLayout(lrow(self.review, self.back, self.again, self.undo))

    def fit(self, inner):
        self.title.setFixedWidth(inner)
        self.sub.setFixedWidth(inner)
        self.notice.setFixedWidth(inner)

    def refresh(self):
        f = self.win.flow
        run = f.run or {}
        undone = run.get("undone", False)
        done, failed = run.get("done", []), run.get("failed", [])
        self.title.setText(tr("undo.done") if undone else (tr("run.finished_count", count=len(done)) if len(done) > 1 else tr("run.finished_one")))
        self.sub.setText("" if undone else (tr("run.created") if run.get("created") else tr("run.color_saved")))
        self.sub.setVisible(not undone)
        show_failed = bool(failed) and not undone
        self.failed_row.setVisible(show_failed)
        if show_failed:
            self.failed.setText(tr("run.failed_count", count=len(failed)))
            from .widgets import text_width
            self.failed.setFixedWidth(round(text_width(self.failed.font(), self.failed.text())) + 2)
            self.retry.set_text(tr("run.retry_count", count=len(failed)))
            self.failed_row.setFixedHeight(self.retry.height())
        notice = self.win.studio.notice or ""
        self.notice.setText(notice)
        self.notice.setVisible(bool(notice))
        self.review.setVisible(not undone)
        self.undo.setVisible(not undone)


class LoadingOverlay(QWidget):
    def __init__(self):
        super().__init__()
        t = line(tr("preview.this_photo"), 17, SEMIBOLD, align=C)
        t.setFixedWidth(400)
        s = line(tr("preview.cached"), CALLOUT, color=SOFT, align=C)
        s.setFixedWidth(400)
        self.line = ProgressLine(160, percent=False)
        self.line.set_progress(None)          # the first looks of a photo: nothing to count until they are back
        self.setLayout(centred(self.line, 14, t, 14, s))


class StudioPage(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        h = row()
        self.strip = PhotoStrip(tr("strip.choose"))
        h.addWidget(self.strip)
        middle = col()
        self.center = QWidget()
        self.center_layers = QStackedLayout(self.center)
        self.center_layers.setStackingMode(QStackedLayout.StackingMode.StackAll)
        # the picture (blurred and faded behind the overlays)
        self.photo_wrap = QWidget()
        wrap = col()
        self.photo = Surface()
        pv = col(12, (28, TOP + 40, 28, 12))
        self.canvas = CompareCanvas()
        pv.addWidget(self.canvas, 1)
        self.zoom = ZoomBar(self.canvas)
        pv.addWidget(self.zoom, 0, HC)
        self.photo.setLayout(pv)
        wrap.addWidget(self.photo)
        self.photo_wrap.setLayout(wrap)
        self.blur = QGraphicsBlurEffect(self.photo)
        self.blur.setBlurRadius(0)
        self.blur.setBlurHints(QGraphicsBlurEffect.BlurHint.PerformanceHint)
        self.blur.setEnabled(False)
        self.photo.setGraphicsEffect(self.blur)
        self.photo_veil = Veil(self.photo_wrap)
        self.dim = Tween(0, self._dimming, self, 350, QEasingCurve.Type.InOutQuad)
        self.center_layers.addWidget(self.photo_wrap)
        self.loading = LoadingOverlay()
        self.center_layers.addWidget(self.loading)
        self.loading.hide()
        self.opening = OpeningPill(self.center)
        # the cards after the button float over the bottom of the picture area (StageOverlay)
        self.working = WorkingOverlay(win, self.center)
        self.paused = PausedOverlay(win, self.center)
        self.finished = FinishedOverlay(win, self.center)
        self.center_layers.setCurrentWidget(self.photo_wrap)
        middle.addWidget(self.center, 1)
        self.looks = LookStrip(win)
        middle.addWidget(self.looks)
        h.addLayout(middle, 1)
        self.sidebar = Sidebar(win)
        h.addWidget(self.sidebar)
        self.setLayout(h)
        for part in (self.strip, self.looks, self.sidebar):
            part.veil = Veil(part)

    def _dimming(self):
        t = self.dim.value
        self.blur.setEnabled(t > 0.01)
        self.blur.setBlurRadius(14 * t)
        self.photo_veil.set_opacity(1 - 0.55 * t, animate=False)

    def refresh(self, animate=True):
        s, f = self.win.studio, self.win.flow
        stage = s.stage
        choosing = stage == "choosing"
        ids = (s.session or {}).get("ids", [])
        self.strip.setVisible(len(ids) > 1)
        if len(ids) > 1:
            self.strip.set_photos(ids, s.thumbs, s.photo, s.loading, s.flags, s.show)
        self.strip.setEnabled(choosing)
        self.strip.veil.set_opacity(1 if choosing else 0.35, animate)
        chosen = s.chosen
        if s.original is not None and chosen is not None and s.after is not None:
            name = chosen["title"]
            pending = not s.picture_exact
            name += tr("preview.retouch_pending") if pending else (tr("preview.retouch_on") if s.beauty_shown else "")
            self.canvas.set_picture(("studio", s.photo), s.original, s.after, name, s.look == "none" and not s.beauty_shown,
                                    pending, s.faces)
            self.photo_wrap.setVisible(True)
        elif choosing and s.loading is None:
            thumb = s.thumbs.get(s.photo)
            if thumb is not None:
                self.canvas.set_picture(("thumb", s.photo), thumb, thumb, "", True, False)
            self.photo_wrap.setVisible(thumb is not None)
        working = stage == "working"
        self.canvas.set_sweep(f.fraction if working else None)
        self.canvas.setEnabled(stage != "paused")
        self.zoom.sync()
        self.zoom.show_progress(s.progress if choosing and s.loading is None else None)
        self.zoom.setVisible(stage not in ("working", "paused", "finished"))     # the card takes its place
        # after the button the photo stays sharp above one card, which takes the bottom of the picture area
        card ={"working": self.working, "paused": self.paused, "finished": self.finished}.get(stage)
        if card is not None:
            card.refresh()
            card.place()
        self.photo.layout().setContentsMargins(28, TOP + 40, 28, 12 + (card.room() if card is not None else 0))
        quiet = (choosing and s.loading is None and s.original is not None) or card is not None
        self.opening.set_line(s.opening_line, animate)
        self.dim.to(0 if quiet else 1, animate=animate)
        show_soft(self.loading, choosing and s.loading is not None)
        for name, overlay in (("working", self.working), ("paused", self.paused), ("finished", self.finished)):
            show_soft(overlay, stage == name)
        self.looks.refresh(animate)
        self.looks.setEnabled(choosing and s.loading is None)
        self.looks.veil.set_opacity(1 if choosing else 0.35, animate)
        self.sidebar.refresh(animate)
        self.sidebar.setEnabled(choosing)
        self.sidebar.veil.set_opacity(1 if choosing else 0.35, animate)


class ReviewPage(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        f = win.flow
        h = row()
        self.strip = PhotoStrip(tr("strip.review"))
        h.addWidget(self.strip)
        right = Surface()
        v = col(12, (28, TOP + 40, 28, 20))
        self.stack = QStackedLayout()
        self.canvas = CompareCanvas()
        self.stack.addWidget(self.canvas)
        wait_t = line(tr("review.fetching"), CALLOUT, color=SOFT, align=C)
        wait_t.setFixedWidth(300)
        self.wait = box(centred(Spinner(32), 12, wait_t))
        self.stack.addWidget(self.wait)
        v.addLayout(self.stack, 1)
        bottom = row(12)
        self.zoom = ZoomBar(self.canvas)
        bottom.addWidget(self.zoom)
        bottom.addStretch(1)
        bottom.addWidget(GhostButton(tr("undo.current"), self._undo))
        bottom.addWidget(GlowButton(tr("review.done"), f.leave_review))
        v.addLayout(bottom)
        right.setLayout(v)
        h.addWidget(right, 1)
        self.setLayout(h)

    def _undo(self):
        self.win.flow.undo_run()
        self.win.flow.leave_review()

    def refresh(self, animate=True):
        f = self.win.flow
        ids = (f.run or {}).get("done", [])
        self.strip.set_photos(ids, f.review_thumbs, f.review_id, f.review_id if f.review_loading else None, {}, f.review)
        if f.before_image is not None and f.after_image is not None:
            self.canvas.set_picture(("review", f.review_id), f.before_image, f.after_image, tr("review.result"), False, False)
            self.stack.setCurrentWidget(self.canvas)
        else:
            self.stack.setCurrentWidget(self.wait)
        self.zoom.sync()


# ====================================================================== modal layer
class Modal(QWidget):
    """A dimmed layer with one panel in the middle (sheets, the rights prompt and card); fades in 0.2 s."""

    def __init__(self, parent, content, dim):
        super().__init__(parent)
        self.dim = dim
        self.content = content
        lay = col()
        lay.addStretch(1)
        lay.addWidget(content, 0, HC)
        lay.addStretch(1)
        self.setLayout(lay)

    def shadow_rect(self):
        return QRectF(self.content.geometry())

    def paintEvent(self, _e):
        p = painter(self)
        p.fillRect(self.rect(), black(self.dim))
        from .theme import paint_shadow
        r = self.shadow_rect()
        paint_shadow(p, r, 18, 30, black(0.5), 12)

    def mousePressEvent(self, e):
        e.accept()


class Panel(Surface):
    """A sheet / card: panel colour, corner `r`, a line round it (and the shadows of its buttons)."""

    def __init__(self, radius=18, width=None, height=None):
        super().__init__()
        self.radius = radius
        if width:
            self.setFixedWidth(width)
        if height:
            self.setFixedHeight(height)

    def paint_fill(self, p):
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(LINE)
        p.setBrush(PANEL)
        p.drawRoundedRect(r, self.radius, self.radius)


# ====================================================================== the window
class Window(QWidget):
    def __init__(self, studio, flow):
        chrome.identity()
        super().__init__()
        self.studio, self.flow = studio, flow
        # Qt draws no frame; chrome.prepare gives the Windows frame styles back (edges, snapping, shadow)
        self.setWindowFlags(Qt.WindowType.Window | Qt.WindowType.FramelessWindowHint)
        self.setWindowTitle(tr("app.title"))
        self.setMinimumSize(1040, 680)
        self.resize(1240, 800)
        self.setFont(font(13))
        self.setAutoFillBackground(True)
        pal = self.palette()
        pal.setColor(self.backgroundRole(), INK)
        self.setPalette(pal)
        self.setStyleSheet("QToolTip{background:#2b2b30;color:rgb(239,239,243);border:1px solid rgba(255,255,255,30);"
                           "border-radius:6px;padding:5px 8px;}")
        self.rights = Rights(self)
        self.pages = QStackedLayout(self)
        self.waiting = WaitingPage(self)
        self.preparing = PreparingPage(self)
        self.failed = FailedPage(self)
        self.studio_page = StudioPage(self)
        self.review = ReviewPage(self)
        for p in (self.waiting, self.preparing, self.failed, self.studio_page, self.review):
            self.pages.addWidget(p)
        self.canvas = self.studio_page.canvas
        self.snapshot = Snapshot(self)
        self.caption = chrome.Caption(self, self.rights.open_card)
        self._modal = None
        self._page = None
        self._last_session = None
        self._close_when_safe = False
        self._scheduled = False
        self._prepared = False
        studio.changed.connect(self.schedule)
        flow.changed.connect(self.schedule)
        self.refresh(animate=False)
        QTimer.singleShot(0, self.rights.launch_prompt)

    # ------------------------------------------------------------ frame
    def showEvent(self, e):
        super().showEvent(e)
        if not self._prepared:
            self._prepared = True
            chrome.prepare(self)
        self.caption.sync()

    def nativeEvent(self, event_type, message):
        if event_type == b"windows_generic_MSG" or event_type == "windows_generic_MSG":
            handled, result = chrome.handle(self, message, self._draggable)
            if handled:
                return True, result
        return super().nativeEvent(event_type, message)

    def _draggable(self, point):
        child = self.childAt(point.toPoint())
        while child is not None:
            if isinstance(child, Control) or child is self.caption:
                return False
            if child is self._modal and self._modal is not None:
                return not self._modal.content.geometry().contains(point.toPoint())
            child = child.parentWidget()
        return True

    def changeEvent(self, e):
        super().changeEvent(e)
        if hasattr(self, "caption"):
            self.caption.sync()

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self.caption.sync()
        if self._modal is not None:
            self._modal.setGeometry(self.rect())
        if hasattr(self, "_scheduled"):
            self.schedule()

    # ------------------------------------------------------------ state
    def schedule(self):
        if not self._scheduled:
            self._scheduled = True
            QTimer.singleShot(0, self.refresh)

    def change(self, name, value):
        setattr(self.studio, name, bool(value))
        self.schedule()

    def _page_for(self, stage):
        return {"waiting": self.waiting, "preparing": self.preparing, "failed": self.failed,
                "reviewing": self.review}.get(stage, self.studio_page)

    def refresh(self, animate=True):
        self._scheduled = False
        s = self.studio
        stage = s.stage
        if self._close_when_safe and stage != "working":
            self._close_when_safe = False
            self.close()
            return
        page = self._page_for(stage)
        if page is not self._page:
            if self._page is not None and animate and self.isVisible():
                self.snapshot.start(self.grab(self.rect()), 400)      # easeInOut 0.35-0.5 between screens
            self._page = page
            self.pages.setCurrentWidget(page)
        if page is self.studio_page:
            page.refresh(animate)
        elif page is self.review:
            page.refresh(animate)
        else:
            page.refresh()
        self.snapshot.raise_()
        if self._modal is not None:
            self._modal.raise_()
        self.caption.raise_()
        session = s.session
        if session and session is not self._last_session:
            self._last_session = session
            if self.isMinimized():
                self.showNormal()
            self.raise_()
            self.activateWindow()

    def closeEvent(self, event):
        if self.studio.stage == "working":
            self._close_when_safe = True
            self.flow.request_pause()
            event.ignore()
        else:
            super().closeEvent(event)

    # ------------------------------------------------------------ modals
    def show_modal(self, content, opacity=0.62):
        self.close_modal(animate=False)
        modal = Modal(self, content, opacity)
        modal.setGeometry(self.rect())
        self._modal = modal
        fade(modal, 0, animate=False)
        modal.show()
        modal.raise_()
        self.caption.raise_()
        fade(modal, 1, 200)
        return modal

    def close_modal(self, animate=True):
        modal, self._modal = self._modal, None
        if modal is None:
            return
        if animate:
            fade(modal, 0, 200)
            QTimer.singleShot(210, modal.deleteLater)
            modal.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        else:
            modal.deleteLater()

    def open_save(self):
        """SaveStyleSheet: 440 wide, 24 padding, 14 apart."""
        s = self.studio
        panel = Panel(12, 440)
        v = col(14, (24, 24, 24, 24))
        v.addWidget(line(tr("look.save"), 18, SEMIBOLD))
        text = para(tr("look.save_instructions"),
                    12, color=SOFT, center=False)
        text.setFixedWidth(392)
        v.addWidget(text)
        field = Field(tr("look.placeholder"))
        v.addWidget(field)
        error = para("", 12, color=FOCUS, center=False)
        error.setFixedWidth(392)
        error.hide()
        v.addWidget(error)
        actions = row(8)
        busy = box(row(6))
        busy.layout().addWidget(Spinner(16))
        busy.layout().addWidget(line(tr("look.learning"), 12, color=SOFT))
        busy.layout().itemAt(1).widget().setFixedWidth(120)
        busy.layout().itemAt(1).widget().setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        busy.hide()
        actions.addWidget(busy)
        actions.addStretch(1)
        cancel = GhostButton(tr("action.cancel"), self.close_modal)
        save = GlowButton(tr("action.save"))
        actions.addWidget(cancel)
        actions.addWidget(save)
        v.addLayout(actions)
        panel.setLayout(v)

        def finish(problem=None):
            busy.hide()
            cancel.setEnabled(True)
            save.setEnabled(True)
            if problem:
                error.setText(str(problem))
                error.show()
            else:
                self.close_modal()

        def submit():
            cancel.setEnabled(False)
            save.setEnabled(False)
            error.hide()
            busy.show()
            s.save_style(field.text(), finish)

        save.clicked.connect(submit)
        field.returnPressed.connect(submit)
        self.show_modal(panel, 0.45)
        field.setFocus()
