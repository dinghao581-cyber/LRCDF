"""The desktop window: the same screens as RootView in Views.swift, built once and updated in place
(so changes can animate like SwiftUI's), drawn without the Windows title bar."""
import re

from PySide6.QtCore import QEasingCurve, QEvent, QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFontMetricsF, QImage, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QGraphicsBlurEffect, QHBoxLayout, QLabel, QLayout, QScrollArea, QSizePolicy, QStackedLayout,
                               QVBoxLayout, QWidget)

from . import chrome, icons
from .canvas import CompareCanvas
from .rights import Rights
from .theme import display
from .theme import (BOLD, FOCUS, INK, LINE, MEDIUM, PANEL, REGULAR, SEMIBOLD, SOFT, TEXT, Tween, black, css, font,
                    white)
from .i18n import tr
from .widgets import Roll, RollLabel
from .widgets import (AddLookCard, ArcSpinner, CheckBox, ChipGrid, Control, FaceButton, Field, GhostButton, GlowButton,
                      Heading, Icon, InfoButton, LookCard, Para, PersonChip, PhotoThumb, Pill, PlainButton, ScrollStyle,
                      Segmented, Spinner, Surface, IconButton, paint_glass, text_width,
                      Switch, TweakRow, Veil, ZoomCapsule, dim, fade, label, painter, set_color, FACE_TEXT, Elided, PillGrid, ProgressLine, ColorWheel, FocusMark, paint_shadow)

C = Qt.AlignmentFlag.AlignCenter
HC = Qt.AlignmentFlag.AlignHCenter
LEFT = Qt.AlignmentFlag.AlignLeft
TOP = chrome.TOP
# the Chinese "(recommended)" is held together with word joiners so it never breaks across lines (the Mac shot keeps it whole)
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


def display_line(text, size, align=None):
    """A line in the display face (DS.display)."""
    w = line(text, size, BOLD, align=align)
    w.setFont(display(size))
    return w


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

    def __init__(self, left=False, stack=False):
        super().__init__()
        self.left = left
        self.stack = stack            # ViewThatFits { HStack; VStack(alignment: .leading) }: not folding, stacking

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
        if self.stack and width < self._natural():
            return [[w] for w in self._shown()]
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


def lrow(*widgets, spacing=10, stack=False):
    """An HStack of buttons from the leading edge; folds into more rows like hrow (or, with `stack`, one per line)."""
    r = FoldRow(left=True, stack=stack)
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
    """StepRowText: the number (display 24, soft, 20 wide), 14 apart, the text (17), on one baseline; long text wraps."""

    def __init__(self, n, text, width):
        super().__init__()
        self.n, self.text = n, text
        self.room = width - 34
        self.lines = [t.rstrip() for t, _ in Para(text, 17)._lines(self.room)] or [text]
        self.setFixedSize(width, 30 + (len(self.lines) - 1) * 23)

    def paintEvent(self, _e):
        p = painter(self)
        number = display(24)
        p.setFont(number)
        p.setPen(SOFT)
        base = 22                                     # the first line's baseline, shared by the number
        p.drawText(QPointF(0, base), str(self.n))
        p.setFont(font(17))
        p.setPen(TEXT)
        for i, t in enumerate(self.lines):
            p.drawText(QPointF(34, base + i * 23), t)


class Note(QWidget):
    """Label(text, systemImage: 'exclamationmark.circle') in focus yellow; wraps to `width` when it must."""

    def __init__(self, text, size=13, width=None):
        super().__init__()
        self.text = text
        self.f = font(size)
        from .widgets import text_width
        natural = round(size + 6 + text_width(self.f, text)) + 2
        self.lines = [text]
        if width and natural > width:
            self.lines = [t.rstrip() for t, _ in Para(text, size)._lines(width - size - 8)]
            natural = width
        self.step = round(size * 1.5)
        self.setFixedSize(natural, self.step * len(self.lines))

    def paintEvent(self, _e):
        p = painter(self)
        s = self.f.pixelSize()
        icons.exclamation_circle(p, QRectF(0, (self.step - s) / 2, s, s), FOCUS, 0.08)
        p.setFont(self.f)
        p.setPen(FOCUS)
        for i, t in enumerate(self.lines):
            p.drawText(QRectF(s + 6, i * self.step, self.width(), self.step), Qt.AlignmentFlag.AlignVCenter | LEFT, t)


class Card(QWidget):
    """Glass on the dark room (the smoked glass of the next batch will replace the fill): white 0.08, a white 0.10
    hairline, corner `radius`."""

    def __init__(self, radius=24):
        super().__init__()
        self.radius = radius

    def paintEvent(self, _e):
        p = painter(self)
        p.setPen(QPen(white(0.10), 1))
        p.setBrush(white(0.08))
        p.drawRoundedRect(QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5), self.radius, self.radius)


class WaitingPage(QWidget):
    """WaitingView: left-aligned, at most 620 wide, in the middle of the window, 40 around: the app's name (display 52),
    the three steps (14 apart, 28 below it), when Lightroom is not connected the yellow note and "Open Lightroom"
    (side by side, or stacked when they do not fit; 28 below), and LastRunCard (28 below): glass, corner 24, 20
    inside, 12 apart: its line (15 semibold), its buttons (10 apart), the notice (12 medium, soft)."""
    WIDTH = 620

    def __init__(self, win):
        super().__init__()
        self.win = win
        f = win.flow
        self.title = line(tr("app.title"), 52, BOLD)
        self.title.setFont(display(52))
        self.steps = []
        self.step_texts = [re.sub(r"^\d+\s+", "", tr(f"welcome.step{n}")) for n in (1, 2, 3)]   # StepRow draws the number
        self.away = Note(tr("bridge.open_first"), 13, self.WIDTH)
        self.open_lr = GhostButton(tr("welcome.open"), f.back_to_lightroom)
        self.card = Card(24)
        cv = col(12, (20, 20, 20, 20))
        self.card_text = para("", 15, SEMIBOLD, center=False)
        self.card_a = GhostButton(tr("welcome.resume"), f.work)
        self.card_b = GhostButton(tr("welcome.stop"), f.stop_run)
        self.card_c = GhostButton(tr("review.open"), f.start_review)
        self.card_d = GhostButton(tr("undo.last"), f.undo_run)
        self.card_note = para("", 12, MEDIUM, color=SOFT, center=False)
        cv.addWidget(self.card_text)
        cv.addLayout(lrow(self.card_a, self.card_b, self.card_c, self.card_d))
        cv.addWidget(self.card_note)
        self.card.setLayout(cv)
        self.notice = para("", 12, MEDIUM, color=SOFT, center=False)
        self.column = QWidget()
        self.cv = col(0)
        self.column.setLayout(self.cv)
        outer = col(0, (40, 40, 40, 40))
        outer.addStretch(1)
        mid = row(0)
        mid.addStretch(1)
        mid.addWidget(self.column)
        mid.addStretch(1)
        outer.addLayout(mid)
        outer.addStretch(1)
        self.setLayout(outer)
        self._width = None

    def resizeEvent(self, e):
        super().resizeEvent(e)
        width = max(300, min(self.WIDTH, self.width() - 80))
        if width != self._width:
            self._width = width
            self.column.setFixedWidth(width)
            self.title.setFixedWidth(width)
            for w in self.steps:
                w.deleteLater()
            self.steps = [StepRow(i, t, width) for i, t in enumerate(self.step_texts, 1)]
            for w in (self.card_text, self.card_note):
                w.setFixedWidth(width - 40)
            self.notice.setFixedWidth(min(460, width))
            self.refresh()

    def refresh(self):
        if self._width is None:
            return
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
        elif finished:
            self.card_text.setText(tr("welcome.last_count", count=len(done)))
        for b in (self.card_a, self.card_b):
            b.setVisible(unfinished)
        for b in (self.card_c, self.card_d):
            b.setVisible(finished)
        self.card.setEnabled(s.lightroom_open)
        notice = s.notice or ""
        self.card_note.setText(notice)
        self.card_note.setVisible(bool(notice) and in_card)
        self.notice.setText(notice)
        v = self.cv
        while v.count():
            item = v.takeAt(0)
            if item.layout() is not None:
                while item.layout().count():
                    item.layout().takeAt(0)
        for w in (self.away, self.open_lr, self.card, self.notice):
            w.hide()
        v.addWidget(self.title)
        v.addSpacing(28)
        for i, w in enumerate(self.steps):
            if i:
                v.addSpacing(14)
            v.addWidget(w)
            w.show()
        if away:
            v.addSpacing(28)
            side = self.away.width() + 14 + self.open_lr.width() <= self._width     # ViewThatFits: side by side, else stacked
            if side:
                r = row(14)
                r.addWidget(self.away, 0, Qt.AlignmentFlag.AlignVCenter)
                r.addWidget(self.open_lr)
                r.addStretch(1)
                v.addLayout(r)
            else:
                v.addWidget(self.away)
                v.addSpacing(10)
                v.addWidget(self.open_lr, 0, LEFT)
            self.away.show()
            self.open_lr.show()
        if in_card:
            v.addSpacing(28)
            v.addWidget(self.card)
            self.card.show()
        elif notice:
            v.addSpacing(28)
            v.addWidget(self.notice)
            self.notice.show()


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
    """FailedView: a glass card 520 wide, 30 inside, corner 26, 14 apart: the title (display 28), the message (13, soft),
    then the actions 10 apart (6 more above): "Continue" (the main button, only for an unfinished run), "Back to Lightroom",
    "Back" (when there are looks); stacked when they do not fit side by side."""

    def __init__(self, win):
        super().__init__()
        self.win = win
        f = win.flow
        self.card = Card(26)
        self.card.setFixedWidth(520)
        cv = col(14, (30, 30, 30, 30))
        title = line(tr("run.incomplete"), 28, BOLD)
        title.setFont(display(28))
        title.setFixedWidth(460)
        self.message = para("", 13, color=SOFT, width=460, center=False)
        self.message.setFixedWidth(460)
        self.message.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse) if hasattr(self.message, "setTextInteractionFlags") else None
        self.go_on = GlowButton(tr("run.resume"), f.work)
        self.back = GhostButton(tr("lightroom.return"), f.back_to_lightroom)
        self.ret = GhostButton(tr("action.back"), f.again)
        cv.addWidget(title)
        cv.addWidget(self.message)
        cv.addSpacing(6)
        self.actions = lrow(self.go_on, self.back, self.ret, spacing=10)
        cv.addLayout(self.actions)
        self.card.setLayout(cv)
        self.setLayout(centred(self.card))

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


class Glass(Surface):
    """A floating panel of smoked glass with corner `radius` (DS.panel 26, DS.tray 24, the rail 20)."""

    def __init__(self, radius):
        super().__init__()
        self.radius = radius

    def paint_fill(self, p):
        paint_glass(p, QRectF(self.rect()), self.radius)


class PhotoStrip(Glass):
    """PhotoRail: glass 88 wide, corner 20; the thumbnails (60 in 5) 10 apart, 12 in from the top and bottom of the list;
    the hint (10, soft, centred) at the bottom, 4 above it and 10 below."""
    WIDTH = 88

    def __init__(self, hint):
        super().__init__(20)
        self.setFixedWidth(self.WIDTH)
        self.thumbs = []
        self.list = col(10, (0, 12, 0, 12))
        self.list.addStretch(1)
        inner = box(self.list)
        self.mark = FocusMark(inner)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet(ScrollStyle.SHEET)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setWidget(inner)
        self.scroll = scroll
        self.hint = para(hint, 10, color=SOFT)
        self.hint.setFixedWidth(self.WIDTH - 8)
        v = col(0, (4, 0, 4, 10))
        v.addWidget(scroll, 1)
        v.addSpacing(4)
        v.addWidget(self.hint, 0, HC)
        self.setLayout(v)

    def set_photos(self, ids, images, active, loading, flags, on_click):
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
        chosen = next((t for t, id_ in zip(self.thumbs, ids) if id_ == active), None)
        self.mark.follow(chosen)
        if chosen is not None:
            self.scroll.ensureWidgetVisible(chosen, 0, 40)      # scrollTo(now, anchor: .center), roughly


class LookHeadline(QWidget):
    """LookHeadline: the look's name as the one big title (display 30, shrinks to 0.6 to fit one line) over its note
    (13, soft; "keep the original colours" for the original), 4 apart. Before the look is made, the two lines' places: a faint
    capsule 3.2 x 0.5 of the size in a 1.25-size line, and a hairline-coloured one 5 x size wide, 7 high, in 16.
    A new look pushes in from below (the old one leaves upwards, both fading)."""
    SIZE = 30

    def __init__(self):
        super().__init__()
        self.now = None            # (title, note) or None while not made
        self.old = None
        self.push = Tween(1, self.update, self, 320, QEasingCurve.Type.OutCubic)
        self.setFixedHeight(round(self.SIZE * 1.25) + 4 + 16)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def set_look(self, key, title, note, animate=True):
        shown = None if key is None else (key, title, note)
        if shown == self.now:
            return
        if self.now is not None and shown is not None and self.now[0] == shown[0]:
            self.now = shown                                 # same look, words changed (language): no push
            self.update()
            return
        self.old, self.now = self.now, shown
        self.push.to(0, animate=False)
        self.push.to(1, animate=animate)

    def _draw(self, p, shown, dy, alpha):
        size = self.SIZE
        p.save()
        p.translate(0, dy)
        op(p, alpha)
        if shown is None:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(white(0.12))
            line = size * 1.25
            p.drawRoundedRect(QRectF(0, (line - size * 0.5) / 2, size * 3.2, size * 0.5), size * 0.25, size * 0.25)
            p.setBrush(LINE)
            p.drawRoundedRect(QRectF(0, line + 4 + 4.5, size * 5, 7), 3.5, 3.5)
        else:
            _, title, note = shown
            w = self.width()
            f = display(size)
            px = size
            while QFontMetricsF(f).horizontalAdvance(title) > w and px > size * 0.6:     # .minimumScaleFactor(0.6)
                px -= 1
                f = display(px)
            p.setFont(f)
            p.setPen(TEXT)
            p.drawText(QRectF(0, 0, w, size * 1.25), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                       p.fontMetrics().elidedText(title, Qt.TextElideMode.ElideRight, round(w)))
            p.setFont(font(13))
            p.setPen(SOFT)
            p.drawText(QRectF(0, size * 1.25 + 4, w, 16), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                       p.fontMetrics().elidedText(note, Qt.TextElideMode.ElideRight, round(w)))
        p.restore()

    def paintEvent(self, _e):
        p = painter(self)
        p.setClipRect(self.rect())
        t = self.push.value
        h = self.height()
        if t < 1 and self.old is not None or (t < 1 and self.old is None and self.now is not None):
            self._draw(p, self.old, -t * h, 1 - t)
        self._draw(p, self.now, (1 - t) * h, t if t < 1 else 1)


def op(p, value):
    p.setOpacity(value)


class BlankLookCard(Control):
    """EmptyLookCard: the card's shape in the fill of quiet things - a faint 72-high picture (corner 5), then 7 + 5 below
    a faint capsule up to 44 x 8 and, 2 + 5 below that, a hairline-coloured one up to 70 x 6."""

    def __init__(self):
        super().__init__()
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.card_w = 120

    def set_width(self, width):
        self.card_w = width
        self.setFixedSize(width, 72 + 9 + 16 + 5 + 13)

    def paintEvent(self, _e):
        p = painter(self)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(QRectF(0, 0, self.card_w, 72), 5, 5)
        p.drawRoundedRect(QRectF(0, 72 + 12, min(self.card_w, 44), 8), 4, 4)
        p.setBrush(LINE)
        p.drawRoundedRect(QRectF(0, 72 + 12 + 8 + 7, min(self.card_w, 70), 6), 3, 3)


class LookStrip(Glass):
    """LookTray: glass 148 high, corner 24; every card visible at once, 14 apart, the row in the middle; a card is
    min(150, max(60, (width - 36 - 14 (n - 1)) / n)) wide."""
    HEIGHT = 148

    def __init__(self, win):
        super().__init__(24)
        self.win = win
        self.narrow = False             # inside the narrow bar's Looks page: 104-wide cards, the row scrolls
        self.setFixedHeight(self.HEIGHT)
        self.cards = []
        self.blanks = []
        self.add = AddLookCard()
        self.add.clicked.connect(win.open_save)
        self.row = row(14)
        self.row.addStretch(1)
        self.row.addWidget(self.add, 0, Qt.AlignmentFlag.AlignVCenter)
        self.row.addStretch(1)
        self.setLayout(self.row)
        self._shown = ()
        self.mark = FocusMark(self)

    def paint_fill(self, p):
        if not self.narrow:
            super().paint_fill(p)

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
        width = 104 if self.narrow else int(min(150, max(60, (self.width() - 36 - 14 * (n - 1)) / n)))
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
        if self.narrow:
            self.setFixedWidth(12 + n * width + (n - 1) * 14 + 12)
        self._shown = ids
        self.mark.follow(next((c for c, look in zip(self.cards, looks) if look["id"] == s.look), None), animate)


def hairline():
    w = QWidget()
    w.setFixedHeight(1)
    w.setStyleSheet(f"background:{css(LINE)}")
    return w


class Sidebar(Glass):
    """The Mac Inspector: the look's headline (and "Delete this style" for one's own), the tweak rows with the colour wheels
    between them; a hairline; Beauty (15 semibold) with its ? beside it, the level bar, its note, the people, the shape
    chips (3 x 2) and "Keep maximum quality"; a hairline; AI Denoise and its note. Below the scrolling part, fixed: "Skip problem photos",
    the main button and the safety note, 8 apart. 20 inside, 22 at the top."""
    PAD = 20
    WIDTH = 300

    def __init__(self, win):
        super().__init__(26)
        self.win = win
        s = win.studio
        self.setFixedWidth(self.WIDTH)
        inner = self.WIDTH - 2 * self.PAD
        outer = col(0, (0, 0, 0, 0))
        v = col(0, (self.PAD - 12, 22, self.PAD - 12, 10))   # the tweak rows reach 12 further out (Mac .padding(-12))

        def add(widget):
            wrap = col(0, (12, 0, 12, 0))
            wrap.addWidget(widget)
            v.addWidget(box(wrap))

        self.upper = box(v)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setStyleSheet(ScrollStyle.SHEET)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setWidget(self.upper)
        outer.addWidget(self.scroll, 1)
        bottom = col(0, (self.PAD, 6, self.PAD, 16))
        self.headline = LookHeadline()
        add(self.headline)
        self.delete = PlainButton(tr("look.delete"), lambda: self.win.studio.delete_style(self.win.studio.look),
                                  size=12, weight=MEDIUM, color=SOFT)
        self.delete.setFixedHeight(44)
        add(self.delete)
        self.tweaks = []
        tw = col(0)
        ends = [(tr("tweak.dark"), tr("tweak.bright")), (tr("tweak.cool"), tr("tweak.warm")), (tr("tweak.muted"), tr("tweak.rich"))]
        end = TweakRow.end_width([w for pair in ends for w in pair])
        for i, (a, b) in ((0, ends[0]), (2, ends[2])):
            t = TweakRow(a, b, end)
            t.index = i
            t.changed.connect(lambda value, i=i: self.win.studio.set_tweak(i, value))
            t.moving.connect(lambda value, i=i: self.win.studio.set_tweak(i, value, live=True))
            self.tweaks.append(t)
        # .padding(.horizontal, -12): the rows reach 12 into the panel's margins
        tw.addWidget(self.tweaks[0])
        tw.addSpacing(6)
        self.wheel_kinds = ["wb", "shadow", "high"]
        self.wheel_bar = Segmented([tr("wheel.wb"), tr("wheel.shadow"), tr("wheel.high")])
        self.wheel_bar.chosen.connect(lambda i: self.win.studio.select_wheel(self.wheel_kinds[i]))
        wheel_row = col(0, (12, 0, 12, 0))
        wheel_row.addWidget(self.wheel_bar)
        self.wheel = ColorWheel((tr("tweak.warm"), tr("tweak.cool"), tr("wheel.pink"), tr("wheel.green")))
        self.wheel.moving.connect(lambda value: self.win.studio.set_wheel(self.win.studio.wheel, value, live=True))
        self.wheel.changed.connect(lambda value: self.win.studio.set_wheel(self.win.studio.wheel, value))
        self.wheel.reset.connect(lambda: self.win.studio.reset_wheel(self.win.studio.wheel))
        wheel_row.addWidget(self.wheel)
        tw.addWidget(box(wheel_row))
        tw.addSpacing(6)
        tw.addWidget(self.tweaks[1])
        self.tweak_box = box(tw)
        v.addSpacing(6)
        v.addWidget(self.tweak_box)
        v.addSpacing(12)
        add(hairline())
        v.addSpacing(12)
        head = row(0, (12, 0, 0, 0))
        head.addWidget(label(tr("level.section"), 15, SEMIBOLD), 1)
        self.info = InfoButton("")
        self.info.setFixedHeight(30)               # the row is 30 high; the 44 square's height is not given here
        head.addWidget(self.info)
        head_box = box(head)
        head_box.setFixedHeight(30)
        v.addWidget(head_box)
        v.addSpacing(6)
        self.level_keys = list(LEVELS)
        self.levels = Segmented([LEVELS[k][0] for k in self.level_keys])
        self.levels.chosen.connect(lambda i: self.win.studio.select_level(self.level_keys[i]))
        add(self.levels)
        v.addSpacing(7)
        self.level_note = para("", 11, color=SOFT, center=False)
        add(self.level_note)
        self.people_gap = v.count()
        v.addSpacing(12)
        self.people = QWidget()
        self.people.setToolTip(tr("person.tooltip"))
        self.chips_people = {}
        add(self.people)
        v.addSpacing(12)
        self.shapes = {}
        for key, title in SHAPES:
            self.shapes[key] = Pill(title, lambda key=key: self.win.studio.toggle_shape(key), size=13, height=44, corner=12,
                                    off_color=TEXT, animated=False, fill=white(0.12), wrap=True, bounce=True)
        self.shape_box = ChipGrid(list(self.shapes.values()))
        self.shape_box.setToolTip(tr("shape.tooltip"))
        add(self.shape_box)
        v.addSpacing(6)
        self.best = Switch(tr("quality.toggle"), s.best, inner)
        self.best.toggled.connect(lambda on: self.win.change("best", on))
        self.best.setToolTip(tr("quality.tooltip"))
        add(self.best)
        self.beauty_box = [self.people, self.shape_box, self.best]
        v.addSpacing(8)
        add(hairline())
        v.addSpacing(8)
        self.denoise = Switch(tr("denoise.toggle"), s.denoise, inner)
        self.denoise.toggled.connect(lambda on: self.win.change("denoise", on))
        add(self.denoise)
        self.denoise_note = para("", 11, color=SOFT, center=False)
        add(self.denoise_note)
        v.addStretch(1)
        self.skip = Switch("", False, inner)
        self.skip.toggled.connect(lambda on: self.win.change("skip_flagged", on))
        bottom.addWidget(self.skip)
        self.skip_gap = bottom.count()
        bottom.addSpacing(8)
        self.go = GlowButton(tr("batch.retouch_one"), lambda: self.win.flow.retouch(), height=48, stretch=True)
        bottom.addWidget(self.go)
        bottom.addSpacing(8)
        bottom.addWidget(para(tr("batch.original_unchanged"), 11, color=SOFT, center=True))
        self.bottom = bottom
        outer.addLayout(bottom)
        self.setLayout(outer)
        self.v = v
        self._people_ids = ()
        self._info_people = None

    def _place_people(self):
        """LazyVGrid(.adaptive(minimum: 48, maximum: 52), spacing 4), rows 6 apart, leading."""
        chips = list(self.chips_people.values())
        width = self.WIDTH - 2 * self.PAD
        per = max(1, int((width + 4) // 52))
        cell = (width - (per - 1) * 4) / per
        for i, chip in enumerate(chips):
            r, c = divmod(i, per)
            chip.move(round(c * (cell + 4) + (cell - chip.width()) / 2), r * (chip.height() + 6))
        rows = -(-len(chips) // per) if chips else 0
        self.people.setFixedHeight(rows * 61 + max(0, rows - 1) * 6)

    def refresh(self, animate=True):
        s = self.win.studio
        chosen = s.chosen
        if chosen is None and s.look != "none":
            self.headline.set_look(None, "", "", animate)
        else:
            title = chosen["title"] if chosen else tr("look.none.title")
            note = tr("look.original_colors") if s.look == "none" else chosen["note"]
            self.headline.set_look(s.look, title, note, animate)
        mine = bool(chosen) and str(s.look).startswith("u")
        self.delete.setVisible(mine)
        no_look = s.look == "none" or s.chosen is None
        for t in self.tweaks:
            t.set_value(s.tweak[t.index])
        self.wheel_bar.set_index(self.wheel_kinds.index(s.wheel) if s.wheel in self.wheel_kinds else 0, animate)
        self.wheel_bar.set_marks({i for i, kind in enumerate(self.wheel_kinds) if s.wheel_moved(kind)})
        labels = (tr("wheel.warmth"), tr("wheel.tint")) if s.wheel == "wb" else (tr("wheel.hue"), tr("wheel.sat"))
        self.wheel.set_mode("wb" if s.wheel == "wb" else "hue", s.wheel_value(s.wheel), labels, s.wheel_moved(s.wheel))
        self.tweak_box.setEnabled(not no_look)
        dim(self.tweak_box, 0.3 if no_look else 1, 200, animate)
        self.levels.set_index(self.level_keys.index(s.level), animate)
        self.level_note.setText(LEVELS[s.level][1])
        off = s.level == "off"
        people = s.people if len(s.people) > 1 and not off else []
        ids = tuple(p["id"] for p in people)
        if ids != self._people_ids:
            for chip in self.chips_people.values():
                chip.deleteLater()
            self.chips_people = {}
            for person in people:
                chip = PersonChip(person["image"], lambda pid=person["id"]: self.win.studio.choose_person(pid))
                chip.setParent(self.people)
                chip.show()
                self.chips_people[person["id"]] = chip
            self._place_people()
            self._people_ids = ids
            if ids and animate:
                fade(self.people, 0, animate=False)
                fade(self.people, 1, 300)
        for pid, chip in self.chips_people.items():
            chip.set_choice(s.choices.get(pid, "follow"))
        self.people.setVisible(bool(ids))
        self.v.itemAt(self.people_gap).spacerItem().changeSize(0, 12 if ids else 0)
        many = len(s.people) > 1
        if many != self._info_people:              # Explain.beauty(people:)
            parts = ([tr("person.tooltip")] if many else []) + [tr("shape.tooltip"), tr("quality.tooltip")]
            self.info.text = "\n\n".join(parts)
            self._info_people = many
        for key, p in self.shapes.items():
            p.set_selected(key in s.shapes, animate)
        for w in self.beauty_box:
            w.setEnabled(not off)
            dim(w, 0.3 if off else 1, 200, animate)
        self.best.set_checked(s.best, animate)
        self.denoise.set_checked(s.denoise, animate)
        iso = (s.session or {}).get("iso") or 0
        noisy = iso >= 1600
        self.denoise_note.setText(tr("denoise.high_iso", iso=iso) if noisy else tr("denoise.hint"))
        set_color(self.denoise_note, FOCUS if noisy and not s.denoise else SOFT)
        flagged = len(s.flagged)
        self.skip.setVisible(flagged > 0)
        if flagged:
            self.skip.set_text(tr("batch.skip", count=flagged))
            self.skip.set_checked(s.skip_flagged, animate)
        gap = self.bottom.itemAt(self.skip_gap)      # the skip row may be in the narrow bar's More page for now
        if gap is not None and gap.spacerItem() is not None:
            gap.spacerItem().changeSize(0, 8 if flagged and self.skip.parentWidget() is self else 0)
        n = len(s.targets)
        self.go.set_text(tr("batch.retouch_one_or_more", count=n) if n > 1 else tr("batch.retouch_one"))
        self.go.setEnabled(not s.nothing_to_do)
        self.v.invalidate()
        self.bottom.invalidate()


class OpeningPill(QWidget):
    """ProgressLine in the top row: glass capsule 44 high, 16 a side; a 72 x 3 line (faint track, focus-yellow fill with a
    soft glow) and, 10 after it, one line (12 medium, soft, even digits). Where room is short the words first get
    smaller (to 0.85), then lose letters from the middle - the start and the count at the end stay."""
    H, BAR = 44, 72

    def __init__(self):
        super().__init__()
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.f = font(12, MEDIUM, digits=True)
        self.text = self.full = ""
        self.room = 10000
        self.t = Tween(0, self.update, self, 500)
        self.roll = Roll(self)
        self.setFixedHeight(self.H)
        self.hide()

    def natural(self):
        return 16 + self.BAR + 10 + round(QFontMetricsF(font(12, MEDIUM, digits=True)).horizontalAdvance(self.full)) + 16

    def fit(self, room):
        self.room = room
        words = room - (16 + self.BAR + 10 + 16)
        self.f = font(12, MEDIUM, digits=True)
        if QFontMetricsF(self.f).horizontalAdvance(self.full) > words:
            self.f = font(10, MEDIUM, digits=True)        # .minimumScaleFactor(0.85): 12 -> 10 px
        self.text = QFontMetricsF(self.f).elidedText(self.full, Qt.TextElideMode.ElideMiddle, max(0, words))
        self.roll.set(self.text, animate=self.isVisible())
        self.setFixedWidth(min(room, 16 + self.BAR + 10 + round(QFontMetricsF(self.f).horizontalAdvance(self.text)) + 16))
        self.update()

    def set_line(self, line, animate=True):
        if line is None:
            show_soft(self, False)
            return False
        text, fraction = line
        changed = text != self.full
        if changed:
            self.full = text
            self.fit(self.room)
        first = not self.isVisible()
        self.t.to(fraction, animate=animate and not first)
        show_soft(self, True)
        self.update()
        return changed or first

    def paintEvent(self, _e):
        p = painter(self)
        paint_glass(p, QRectF(self.rect()), self.height() / 2)
        track = QRectF(16, (self.height() - 3) / 2, self.BAR, 3)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(track, 1.5, 1.5)
        fill = QRectF(track.left(), track.top(), max(4.0, self.BAR * min(1.0, self.t.value)), 3)
        glow = QColor(FOCUS)
        glow.setAlphaF(0.6)
        paint_shadow(p, fill, 1.5, 4, glow)
        p.setBrush(FOCUS)
        p.drawRoundedRect(fill, 1.5, 1.5)
        p.setFont(self.f)
        p.setPen(SOFT)
        self.roll.draw(p, QRectF(track.right() + 10, 0, self.width() - track.right() - 10, self.height()),
                       Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)


class PhotoStepper(QWidget):
    """‹ 3 / 12 › and the photo's name (or "applies to all N") in one glass capsule, 44 high: the arrows are 44 icon
    buttons, the position 12 semibold (even digits, at least 44 wide), the name 12 soft with 16 after it (2 before
    it after the arrows, 16 when there are none)."""

    def __init__(self, win, on_show=None):
        super().__init__()
        self.win = win
        self.on_show = on_show or win.studio.show
        self.ids, self.photo = [], None
        self.prev = IconButton("chevron_left", lambda: self._step(-1), box=44, glyph=12)
        self.next = IconButton("chevron_right", lambda: self._step(1), box=44, glyph=12)
        for b in (self.prev, self.next):
            b.setParent(self)
        self.pos_f = font(12, SEMIBOLD, digits=True)
        self.name_f = font(12)
        self.position = self.name = ""
        self.roll = Roll(self)
        self.many = False
        self.setFixedHeight(44)

    def _step(self, d):
        if self.photo in self.ids:
            i = self.ids.index(self.photo) + d
            if 0 <= i < len(self.ids):
                self.on_show(self.ids[i])

    def set_state(self, ids, photo, name, room):
        self.ids, self.photo = list(ids), photo
        self.many = len(ids) > 1
        here = ids.index(photo) if photo in ids else 0
        self.position = f"{here + 1} / {len(ids)}"
        self.roll.set(self.position, animate=self.isVisible())
        self.prev.setVisible(self.many)
        self.next.setVisible(self.many)
        self.prev.setEnabled(here > 0)
        self.next.setEnabled(here + 1 < len(ids))
        pos_w = max(44, round(text_width(self.pos_f, self.position)) + 8) if self.many else 0
        x = 0
        if self.many:
            self.prev.move(0, 0)
            self.next.move(44 + pos_w, 0)
            x = 44 + pos_w + 44
        self._pos_w = pos_w
        lead = 2 if self.many else 16
        left = room - x - lead - 16
        self.name = QFontMetricsF(self.name_f).elidedText(name or "", Qt.TextElideMode.ElideMiddle, max(0, left)) if name else ""
        w = x + (lead + round(text_width(self.name_f, self.name)) + 16 if self.name else 0)
        self.setFixedWidth(max(w, 44))
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        paint_glass(p, QRectF(self.rect()), 22)
        x = 0
        if self.many:
            p.setFont(self.pos_f)
            p.setPen(TEXT)
            self.roll.draw(p, QRectF(44, 0, self._pos_w, 44), C)
            x = 44 + self._pos_w + 44
        if self.name:
            p.setFont(self.name_f)
            p.setPen(SOFT)
            lead = 2 if self.many else 16
            p.drawText(QRectF(x + lead, 0, self.width() - x - lead, 44), Qt.AlignmentFlag.AlignVCenter | LEFT, self.name)


class ZoomCluster(QWidget):
    """− Fit window + and the jump from face to face, as one capsule of glass: 4 in at the ends, a 1 x 20 hairline before
    the face button (only when there are faces). The help is the tooltip (Mac .help)."""

    def __init__(self, canvas):
        super().__init__()
        self.canvas = canvas
        self.zoom = ZoomCapsule(lambda: canvas.magnify(1 / 1.5), lambda: canvas.magnify(1.5))
        self.zoom.fit.connect(canvas.fit)
        self.face = FaceButton(canvas.next_face)
        for wdg in (self.zoom, self.face):
            wdg.setParent(self)
        self.setToolTip(tr("zoom.hint"))
        self.setFixedHeight(44)
        canvas.changed.connect(self.sync)
        self.sync()

    def sync(self):
        c = self.canvas
        self.zoom.set_zoom(c.target_zoom)
        n = min(len(c.faces), 4)
        self.face.set_text(FACE_TEXT if c.face is None else (tr("zoom.next_face") if c.face + 1 < n else tr("zoom.full")))
        has = bool(c.faces)
        self.face.setVisible(has)
        self.zoom.move(4, 0)
        w = 4 + self.zoom.width() + (1 + self.face.width() if has else 0) + 4
        self.face.move(4 + self.zoom.width() + 1, 0)
        self.setFixedWidth(w)
        self.update()

    def show_progress(self, progress):
        """The exact picture on its way is shown by the label on the photo (pending), as on the Mac."""

    def paintEvent(self, _e):
        p = painter(self)
        paint_glass(p, QRectF(self.rect()), 22)
        if self.face.isVisible():
            x = 4 + self.zoom.width()
            p.fillRect(QRectF(x, 12, 1, 20), LINE)


class TopRow(QWidget):
    """WideChrome.top: PhotoStepper, 10 after it the progress capsule, then ZoomCluster in the middle of what is left;
    where room is short the progress comes before the name."""

    def __init__(self, win, canvas):
        super().__init__()
        self.win = win
        self.stepper = PhotoStepper(win)
        self.progress = OpeningPill()
        self.cluster = ZoomCluster(canvas)
        for wdg in (self.stepper, self.progress, self.cluster):
            wdg.setParent(self)
        self.narrow = False
        self.setFixedHeight(44)

    def refresh(self, animate=True):
        s = self.win.studio
        ids = (s.session or {}).get("ids", [])
        name = tr("batch.settings", count=len(ids)) if len(ids) > 1 else (s.session or {}).get("name", "")
        line = s.opening_line if s.stage == "choosing" else None
        self._layout(ids, s.photo, name, line, animate)

    def _layout(self, ids, photo, name, line, animate):
        w = self.width()
        if self.narrow:
            self._layout_narrow(ids, photo, line, animate)
            return
        cluster = self.cluster.width()
        self.stepper.set_state(ids, photo, name, max(120, w // 2 - cluster // 2 - 10))
        x = self.stepper.width() + 10
        if line is not None:
            self.progress.full = line[0]
            room = max(120, w - x - cluster - 20)
            if self.progress.natural() > room and name:          # ViewThatFits: the progress before the name
                self.stepper.set_state(ids, photo, None, w)
                x = self.stepper.width() + 10
                room = max(120, w - x - cluster - 20)
            self.progress.fit(room)
            self.progress.move(x, 0)
        self.progress.set_line(line, animate)
        end = x + (self.progress.width() + 10 if line is not None else 0)
        mid = (w - cluster) // 2                            # Spacer, ZoomCluster, Spacer
        self.cluster.move(max(end, mid), 0)

    def _layout_narrow(self, ids, photo, line, animate):
        """The stepper without a name; the zoom cluster before the main button on the right; the progress capsule
        is the page's, on its own line below (StudioPage places it)."""
        w = self.width()
        self.stepper.set_state(ids, photo, None, 300)
        self.stepper.setVisible(len(ids) > 1)
        right = getattr(self.parentWidget(), "go", None)
        go_w = right.width() + 10 if right is not None else 0
        self.cluster.move(max(self.stepper.width() + 10 if len(ids) > 1 else 0, w - go_w - self.cluster.width()), 0)
        if line is not None:
            self.progress.full = line[0]
            self.progress.fit(max(120, w - 20))
        self.progress.set_line(line, animate)
        self.progress.move(0, 52)             # its own line below the row (the page makes the row that tall)

    def resizeEvent(self, _e):
        self.refresh(False)


class StageOverlay(QWidget):
    """StageCard (Views.swift): one card at the bottom for the three states after the button: working, paused,
    finished. The photo above it stays the subject, sharp. The card floats over the bottom of the picture area
    (`host`), as large as itself, so the photo around it still takes the mouse after the work (Mac: only paused
    stops it)."""

    GAP = 14                                   # DS.gap: card to the bottom of the window

    def __init__(self, win, host):
        super().__init__(host)
        self.win, self.host = win, host
        self.card = Glass(26)
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
        self.title = display_line("", 24)
        self.percent = RollLabel()
        self.percent.setFixedWidth(round(QFontMetricsF(self.percent.font()).horizontalAdvance("100%")) + 4)
        self.percent.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.bar = ProgressLine(400, percent=False)
        self.caption = para("", 13, color=SOFT, center=False)
        self.pause = GhostButton(tr("run.pause"), win.flow.request_pause)
        top = row(12)
        top.addWidget(self.title, 1)
        top.addWidget(self.percent, 0, Qt.AlignmentFlag.AlignBottom)
        bottom = row(12)
        bottom.addWidget(self.caption, 1, Qt.AlignmentFlag.AlignVCenter)
        bottom.addWidget(self.pause, 0, Qt.AlignmentFlag.AlignVCenter)
        self.bottom_box = box(bottom)
        self.bottom_box.setMinimumHeight(44)
        self.body.setSpacing(12)
        self.body.addLayout(top)
        self.body.addWidget(self.bar)
        self.body.addWidget(self.bottom_box)

    def fit(self, inner):
        self.bar.set_bar_width(inner)
        self.title.setFixedWidth(inner - 12 - self.percent.width())

    def refresh(self):
        f = self.win.flow
        run = f.run or {}
        n = len(run.get("ids", []))
        self.bar.set_progress(f.fraction)
        self.percent.setText(f"{round(f.fraction * 100)}%")      # its digits roll (RollLabel)
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
        self.body.addWidget(display_line(tr("run.paused"), 24))
        self.body.addWidget(self.text)
        self.body.addSpacing(6)
        self.body.addLayout(lrow(GlowButton(tr("run.resume"), f.work), GhostButton(tr("run.stop"), f.stop_run), stack=True))

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
        self.title = display_line("", 28)
        self.sub = para("", 13, color=SOFT, center=False)
        self.failed = line("", 13, color=FOCUS)
        self.failed.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        self.retry = GhostButton("", f.retry_failed)
        self.failed_row = box(lrow(self.failed, self.retry))
        self.notice = para("", 12, MEDIUM, color=SOFT, center=False)
        self.review = GlowButton(tr("review.open"), f.start_review)
        self.back = GhostButton(tr("lightroom.return"), f.back_to_lightroom)
        self.again = GhostButton(tr("look.try_again"), f.again)
        self.undo = GhostButton(tr("undo.current"), f.undo_run)
        for w in (self.title, self.sub, self.failed_row, self.notice):
            self.body.addWidget(w)
        self.body.addSpacing(6)
        self.body.addLayout(lrow(self.review, self.back, self.again, self.undo, stack=True))

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
    """LoadingPhotoOverlay (the photo behind it is already blurred 14 and at 45 %: StudioPage.dim): a glass card (corner 26, 28 x 22 inside, 10 apart) with
    the title (display 22), the note (13, soft) and an indeterminate line 200 wide (6 more above)."""

    def __init__(self):
        super().__init__()
        card = Card(26)
        cv = col(10, (28, 22, 28, 22))
        t = line(tr("preview.this_photo"), 22, BOLD, align=C)
        t.setFont(display(22))
        s = line(tr("preview.cached"), 13, color=SOFT, align=C)
        from .widgets import text_width
        for w in (t, s):                       # each line as wide as its words (the card is as wide as they are)
            w.setFixedWidth(round(text_width(w.font(), w.text())) + 4)
        self.line = ProgressLine(200, percent=False)
        self.line.set_progress(None)          # the first looks of a photo: nothing to count until they are back
        cv.addWidget(t, 0, HC)
        cv.addWidget(s, 0, HC)
        cv.addSpacing(6)
        cv.addWidget(self.line, 0, HC)
        card.setLayout(cv)
        self.setLayout(centred(card))



def keep_divider(canvas, settings):
    """@AppStorage("divider"): where the divider was left, across photos and launches (0.5 at first)."""
    try:
        canvas.kept = max(0.0, min(1.0, float(settings.value("divider", 0.5))))
    except (TypeError, ValueError):
        canvas.kept = 0.5
    canvas.split = canvas.kept
    canvas.on_kept = lambda value: settings.setValue("divider", float(value))


def QKeyEvent_for(d):
    from PySide6.QtCore import QEvent as _E
    from PySide6.QtGui import QKeyEvent
    return QKeyEvent(_E.Type.KeyPress, Qt.Key.Key_Left if d < 0 else Qt.Key.Key_Right, Qt.KeyboardModifier.NoModifier)


class PageTabs(QWidget):
    """The tabs of the narrow bar: Looks / Colour / Beauty / More on a glass capsule (4 inside); the chosen one in a white
    capsule that slides to it (DS.pick); 13 (semibold, black when chosen), 16 a side, at least 72 wide, 36 high."""
    chosen = Signal(int)

    def __init__(self, titles):
        super().__init__()
        self.titles = titles
        self.index = 0
        self.at = Tween(0, self.update, self, 320, QEasingCurve.Type.OutCubic)
        self.widths = [max(72, round(text_width(font(13, SEMIBOLD), t)) + 32) for t in titles]
        self.setFixedSize(sum(self.widths) + 8, 44)

    def _x(self, i):
        return 4 + sum(self.widths[:i])

    def set_index(self, i, animate=True):
        self.index = i
        self.at.to(i, animate=animate)

    def mouseReleaseEvent(self, e):
        x = e.position().x()
        for i in range(len(self.titles)):
            if self._x(i) <= x < self._x(i) + self.widths[i]:
                self.set_index(i)
                self.chosen.emit(i)
                return

    def paintEvent(self, _e):
        p = painter(self)
        paint_glass(p, QRectF(self.rect()), 22)
        a = self.at.value
        i0 = int(max(0, min(len(self.titles) - 1, a)))
        i1 = min(i0 + 1, len(self.titles) - 1)
        f = a - i0
        x = self._x(i0) + (self._x(i1) - self._x(i0)) * f
        w = self.widths[i0] + (self.widths[i1] - self.widths[i0]) * f
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QColor(255, 255, 255))
        p.drawRoundedRect(QRectF(x, 4, w, 36), 18, 18)
        for i, title in enumerate(self.titles):
            on = i == self.index
            p.setFont(font(13, SEMIBOLD if on else REGULAR))
            k = max(0.0, 1 - abs(a - i))                  # white -> black as the capsule passes under the word
            p.setPen(QColor(round(255 * (1 - k)), round(255 * (1 - k)), round(255 * (1 - k))))
            p.drawText(QRectF(self._x(i), 4, self.widths[i], 36), C, title)


class NarrowBar(QWidget):
    """NarrowChrome's bottom: one glass panel (corner 28, 18 x 12 inside) with the page on show, and 10 below it the
    tabs. The pages hold the inspector's and the tray's own widgets while the window is narrow:
    Looks: the looks in a row that scrolls | a hairline | the two tone rows (240 wide);
    Colour: the wheel picker and the wheel; Beauty: the level bar and its note | a hairline | the people, the shape chips
    (3 columns) and the ?; More: "Keep maximum quality" and AI Denoise side by side, the denoise note, "Skip problem photos", the safety note."""

    def __init__(self, page):
        super().__init__(page)
        self.studio_page = page
        self.panel = Glass(28)
        self.panel.setParent(self)
        self.stack = QStackedLayout(self.panel)
        self.pages = []
        self.slots = {}
        for name in ("look", "tone", "beauty", "more"):
            w = QWidget()
            self.pages.append(w)
            self.stack.addWidget(w)
        # Looks
        look = row(16)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(False)
        self.scroll.setStyleSheet(ScrollStyle.SHEET)
        self.scroll.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.scroll.setFixedHeight(LookStrip.HEIGHT)
        look.addWidget(self.scroll, 1)
        look.addWidget(self._rule())
        self.slots["tweaks"] = col(0)
        tweaks = box(self.slots["tweaks"])
        tweaks.setFixedWidth(240)
        look.addWidget(tweaks, 0, Qt.AlignmentFlag.AlignVCenter)
        look.setContentsMargins(18, 12, 18, 12)
        self.pages[0].setLayout(look)
        # Colour
        tone = row(16)
        self.slots["picker"] = col(0)
        picker = box(self.slots["picker"])
        picker.setFixedWidth(160)
        tone.addStretch(1)
        tone.addWidget(picker, 0, Qt.AlignmentFlag.AlignVCenter)
        self.slots["wheel"] = col(0)
        wheel = box(self.slots["wheel"])
        wheel.setFixedWidth(220)
        tone.addWidget(wheel, 0, Qt.AlignmentFlag.AlignVCenter)
        tone.addStretch(1)
        tone.setContentsMargins(18, 12, 18, 12)
        self.pages[1].setLayout(tone)
        # Beauty
        beauty = row(18)
        self.slots["level"] = col(8)
        level = box(self.slots["level"])
        level.setFixedWidth(330)
        beauty.addWidget(level, 0, Qt.AlignmentFlag.AlignVCenter)
        beauty.addWidget(self._rule())
        self.slots["rest"] = row(14)
        rest = box(self.slots["rest"])
        rest.setMaximumWidth(420)
        beauty.addWidget(rest, 1, Qt.AlignmentFlag.AlignVCenter)
        beauty.setContentsMargins(18, 12, 18, 12)
        self.pages[2].setLayout(beauty)
        # More
        self.slots["more"] = col(2, (18, 12, 18, 12))
        self.pages[3].setLayout(self.slots["more"])
        self.safe = para(tr("batch.original_unchanged"), 11, color=SOFT, center=False)
        self.tabs = PageTabs([tr("look.section"), tr("page.tone"), tr("level.section"), tr("page.more")])
        self.tabs.setParent(self)
        self.tabs.chosen.connect(self.show_page)
        self.moved = []
        self.active = False

    @staticmethod
    def _rule():
        w = QWidget()
        w.setFixedSize(1, 96)
        w.setStyleSheet(f"background:{css(LINE)}")
        return w

    def show_page(self, i):
        self.stack.setCurrentIndex(i)
        self.tabs.set_index(i)
        self.studio_page._place()

    def _take(self, widget, slot, *args):
        """Move a widget of the inspector into a page, remembering where it was."""
        parent = widget.parentWidget()
        lay = parent.layout() if parent is not None else None
        index = lay.indexOf(widget) if lay is not None else -1
        self.moved.append((widget, lay, index, parent))
        if lay is not None:
            lay.removeWidget(widget)
        self.slots[slot].addWidget(widget, *args)

    def activate(self):
        if self.active:
            return
        page = self.studio_page
        side, looks = page.sidebar, page.looks
        self.moved = []
        looks.narrow = True
        self.moved.append((looks, None, -1, looks.parentWidget()))
        self.scroll.setWidget(looks)
        for t in side.tweaks:
            self._take(t, "tweaks")
        side.wheel_bar.set_vertical(True)
        self._take(side.wheel_bar, "picker")
        self._take(side.wheel, "wheel")
        self._take(side.levels, "level")
        self._take(side.level_note, "level")
        self._take(side.people, "rest")
        self._take(side.shape_box, "rest", 1)
        self._take(side.info, "rest")
        switches = row(28)
        self.switch_row = box(switches)
        self.slots["more"].addWidget(self.switch_row)
        self.slots["switches"] = switches
        for sw in (side.best, side.denoise):
            sw.fit(round(text_width(sw.f, sw.text)) + 12 + sw.TRACK)
            self._take(sw, "switches")
        switches.addStretch(1)
        self._take(side.denoise_note, "more")
        self._take(side.skip, "more")
        self.slots["more"].addSpacing(4)
        self.slots["more"].addWidget(self.safe)
        self.slots["more"].addStretch(1)
        self.active = True
        self.show()

    def deactivate(self):
        if not self.active:
            return
        page = self.studio_page
        page.looks.narrow = False
        page.looks.setMinimumWidth(0)
        page.looks.setMaximumWidth(16777215)
        self.scroll.takeWidget()
        # back where they were: undone in the reverse order of taking (each index was read when that widget left)
        for widget, lay, index, parent in reversed(self.moved):
            if lay is None:
                widget.setParent(parent)
                widget.show()
                continue
            widget.setParent(parent)
            lay.insertWidget(index, widget)
            widget.show()
        page.sidebar.wheel_bar.set_vertical(False)
        inner = page.sidebar.WIDTH - 2 * page.sidebar.PAD
        for sw in (page.sidebar.best, page.sidebar.denoise, page.sidebar.skip):
            sw.fit(inner)
        self.slots["more"].removeWidget(self.safe)
        self.safe.setParent(None)
        self.switch_row.setParent(None)
        self.switch_row.deleteLater()
        while self.slots["more"].count():
            self.slots["more"].takeAt(0)
        self.moved = []
        self.active = False
        self.hide()

    def bar_height(self):
        return self._panel_height() + 10 + self.tabs.height()

    def _panel_height(self):
        page = self.stack.currentWidget()
        lay = page.layout()
        h = lay.heightForWidth(self.width() - 36) if lay.hasHeightForWidth() else lay.sizeHint().height()
        return max(60, h)

    def place(self, width, bottom):
        """The bar from 14 above the window's bottom, 14 in from each side."""
        h = self._panel_height()
        total = h + 10 + self.tabs.height()
        self.setGeometry(14, bottom - total, width - 28, total)
        self.panel.setGeometry(0, 0, width - 28, h)
        self.tabs.move((width - 28 - self.tabs.width()) // 2, h + 10)

    def refresh(self, animate=True):
        s = self.studio_page.win.studio
        no_look = s.look == "none" or s.chosen is None
        for i in (1,):
            dim(self.pages[i], 0.3 if no_look else 1, 200, animate)
            self.pages[i].setEnabled(not no_look)
        tweaks = self.slots["tweaks"].parentWidget()
        dim(tweaks, 0.3 if no_look else 1, 200, animate)
        tweaks.setEnabled(not no_look)
        side = self.studio_page.sidebar
        if side.skip.isVisible():
            side.skip.fit(max(200, self.width() - 36))


class Room(QWidget):
    """The room (Views.swift Room): black, lit by the photo on screen far out of focus; a new light fades in over 0.6 s."""

    def __init__(self):
        super().__init__()
        self.room = None                         # (key, pixmap) of the room's light
        self.old_room = None
        self.room_fade = Tween(1, self.update, self, 600, QEasingCurve.Type.InOutQuad)
        self._rooms = {}

    # ------------------------------------------------------------ the room
    def _light(self):
        return None

    def _room_of(self, image):
        """A few dozen pixels are all a blur of this size needs: 96 wide, blurred by going down to 12 and back up,
        saturation 0.6 (40 % of its own grey laid over it), 62 % black."""
        key = image.cacheKey()
        ready = self._rooms.get(key)
        if ready is not None:
            return ready
        small = image.scaledToWidth(96, Qt.TransformationMode.SmoothTransformation).convertToFormat(QImage.Format.Format_RGB32)
        for _ in range(2):
            tiny = small.scaled(12, max(1, round(12 * small.height() / small.width())), Qt.AspectRatioMode.IgnoreAspectRatio,
                                Qt.TransformationMode.SmoothTransformation)
            small = tiny.scaled(96, small.height(), Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
        grey = small.convertToFormat(QImage.Format.Format_Grayscale8).convertToFormat(QImage.Format.Format_RGB32)
        q = QPainter(small)
        q.setOpacity(0.4)
        q.drawImage(0, 0, grey)
        q.setOpacity(1)
        q.fillRect(small.rect(), QColor(0, 0, 0, round(255 * 0.62)))
        q.end()
        ready = QPixmap.fromImage(small)
        self._rooms[key] = ready
        if len(self._rooms) > 16:
            self._rooms.pop(next(iter(self._rooms)))
        return ready

    def _update_room(self, animate):
        image = self._light()
        key = image.cacheKey() if image is not None and not image.isNull() else None
        if self.room is not None and self.room[0] == key:
            return
        new = (key, self._room_of(image)) if key is not None else None
        if new is None and self.room is not None:
            return                               # keep the last light rather than going dark between pictures
        self.old_room, self.room = self.room, new
        self.room_fade.to(0, animate=False)
        self.room_fade.to(1, animate=animate)

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.fillRect(self.rect(), QColor(0, 0, 0))

        def fill(pixmap, opacity):
            size = pixmap.size().scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatioByExpanding)
            r = QRectF((self.width() - size.width()) / 2, (self.height() - size.height()) / 2, size.width(), size.height())
            p.setOpacity(opacity)
            p.drawPixmap(r, pixmap, QRectF(pixmap.rect()))
        t = self.room_fade.value
        if self.old_room is not None and t < 1:
            fill(self.old_room[1], 1)
        if self.room is not None:
            fill(self.room[1], t)
        p.setOpacity(1)



class StudioPage(Room):
    """StudioView in the wide layout. The room (the photo shrunk to 96 wide, blurred, saturation 0.6, 62 % black) fills
    the page; the photo sits in what the glass leaves clear; the glass floats 14 from the edges and from each other:
    the inspector on the right (300 wide, 44 from the top), the look tray along the bottom (148 high), the photo rail
    down the left (88 wide, from 62 to above the tray, only with two or more photos), the top row 8 from the top.
    After the button all three leave (spring 0.55) and the photo takes the room, above the one card."""
    GAP, SIDE = 14, 300

    def __init__(self, win):
        super().__init__()
        self.win = win
        self.center = QWidget(self)
        self.center_layers = QStackedLayout(self.center)
        self.center_layers.setStackingMode(QStackedLayout.StackingMode.StackAll)
        self.photo_wrap = QWidget()
        wrap = col()
        self.photo = Surface()
        self.pv = col(0)
        self.canvas = CompareCanvas()
        self.pv.addWidget(self.canvas, 1)
        self.photo.setLayout(self.pv)
        wrap.addWidget(self.photo)
        self.photo_wrap.setLayout(wrap)
        self.blur = QGraphicsBlurEffect(self.photo)
        self.blur.setBlurRadius(0)
        self.blur.setBlurHints(QGraphicsBlurEffect.BlurHint.PerformanceHint)
        self.blur.setEnabled(False)
        self.photo.setGraphicsEffect(self.blur)
        from PySide6.QtWidgets import QGraphicsOpacityEffect
        self.photo_fade = QGraphicsOpacityEffect(self.canvas)       # the photo at 45 % while another one loads
        self.photo_fade.setOpacity(1)
        self.canvas.setGraphicsEffect(self.photo_fade)
        self.dim = Tween(0, self._dimming, self, 350, QEasingCurve.Type.InOutQuad)
        self.center_layers.addWidget(self.photo_wrap)
        self.loading = LoadingOverlay()
        self.center_layers.addWidget(self.loading)
        self.loading.hide()
        self.working = WorkingOverlay(win, self.center)
        self.paused = PausedOverlay(win, self.center)
        self.finished = FinishedOverlay(win, self.center)
        self.center_layers.setCurrentWidget(self.photo_wrap)
        self.strip = PhotoStrip(tr("strip.choose"))
        self.looks = LookStrip(win)
        self.sidebar = Sidebar(win)
        self.top = TopRow(win, self.canvas)
        self.zoom = self.top.cluster
        self.opening = self.top.progress
        for part in (self.strip, self.looks, self.sidebar, self.top):
            part.setParent(self)
        for part in (self.strip, self.looks, self.sidebar):
            part.veil = Veil(part)
        self.canvas.can_step = self._can_step
        self.canvas.on_step = self._step
        keep_divider(self.canvas, win.studio.settings)
        from PySide6.QtGui import QKeySequence, QShortcut
        for key, d in ((Qt.Key.Key_Left, -1), (Qt.Key.Key_Right, 1)):
            # one shortcut for the window: it steps on whichever page is on show (studio or review)
            QShortcut(QKeySequence(key), self, lambda d=d: self._key_step(d), context=Qt.ShortcutContext.WindowShortcut)
        self.present = Tween(1, self._place, self, 550)
        curve = QEasingCurve(QEasingCurve.Type.OutBack)
        curve.setOvershoot(0.8)                  # spring(duration: 0.55, bounce: 0.12)
        self.present._anim.setEasingCurve(curve)
        self.rail = False
        self.card = None
        self.narrow = False
        self.bar = NarrowBar(self)
        self.bar.hide()
        self.go = GlowButton(tr("batch.retouch_one"), lambda: self.win.flow.retouch(), height=44)   # RetouchButton, top row
        self.go.setParent(self)
        self.go.hide()

    # ------------------------------------------------------------ where everything goes
    def _light(self):
        s = self.win.studio
        return s.after if s.after is not None else s.thumbs.get(s.photo)

    # ------------------------------------------------------------ to another photo: swipe, ← →, the stepper
    def _can_step(self, d):
        s = self.win.studio
        ids = (s.session or {}).get("ids", [])
        if s.stage != "choosing" or s.loading is not None or s.photo not in ids:
            return False
        return 0 <= ids.index(s.photo) + d < len(ids)

    def _step(self, d):
        s = self.win.studio
        if self._can_step(d):
            ids = s.session["ids"]
            s.show(ids[ids.index(s.photo) + d])

    def _key_step(self, d):
        from PySide6.QtWidgets import QApplication, QLineEdit
        focus = QApplication.focusWidget()
        if isinstance(focus, (TweakRow, ColorWheel, QLineEdit)):       # the arrow keys belong to them
            focus.keyPressEvent(QKeyEvent_for(d))
            return
        if self.win._modal is not None:
            return
        page = self.win.pages.currentWidget()
        if page is self:
            self._step(d)
        elif page is self.win.review:
            self.win.review._step(d)

    def _insets(self, choosing):
        """StudioView.insets plus the 12 the picture keeps from what is around it."""
        if choosing and self.narrow:
            top = 64 + (44 + 8 if self.opening.isVisible() else 0)
            return top + 12, 16 + 12, self.bar.bar_height() + self.GAP + 10 + 12, 16 + 12
        if not choosing:
            card = self.card.card_height() if self.card is not None else 170
            return 44 + 12, 40 + 12, card + self.GAP * 2 + 6 + 12, 40 + 12
        left = PhotoStrip.WIDTH + self.GAP * 2 if self.rail else 24
        return 62 + 12, left + 12, LookStrip.HEIGHT + self.GAP * 2 + 4 + 12, self.SIDE + self.GAP * 2 + 10 + 12

    def _place(self):
        W, H, G = self.width(), self.height(), self.GAP
        t = self.present.value
        away = 1 - t
        if self.narrow:
            self._place_narrow(W, H, G, t, away)
            return
        self.sidebar.setGeometry(round(W - G - self.SIDE + (self.SIDE + G + 30) * away), 44, self.SIDE, H - 44 - G)
        self.looks.setGeometry(G, round(H - G - LookStrip.HEIGHT + (LookStrip.HEIGHT + G + 30) * away),
                               W - self.SIDE - 3 * G, LookStrip.HEIGHT)
        rail_h = H - 62 - (LookStrip.HEIGHT + 2 * G)
        self.strip.setGeometry(round(G - (PhotoStrip.WIDTH + G + 30) * away), 62, PhotoStrip.WIDTH, max(80, rail_h))
        self.top.setGeometry(G, round(8 - 70 * away), W - self.SIDE - 3 * G, 44)
        for part in (self.sidebar, self.looks, self.top):
            part.setVisible(t > 0.001)
        self.strip.setVisible(self.rail and t > 0.001)
        a, b = self._insets(True), self._insets(False)
        top, left, bottom, right = (round(b[i] + (a[i] - b[i]) * t) for i in range(4))
        self.center.setGeometry(self.rect())
        self.pv.setContentsMargins(left, top, right, bottom)

    def _place_narrow(self, W, H, G, t, away):
        """NarrowChrome: the top row (the stepper, then the zoom cluster and the main button on the right, 14 in),
        the progress capsule below it on the left, the bar at the bottom; all leave after the button."""
        self.sidebar.hide()
        self.strip.hide()
        rows = 44 + (8 + 44 if self.opening.isVisible() else 0)      # the progress capsule on its own line
        self.top.setFixedHeight(rows)
        right = W - self.win.caption.width() - 10          # clear of the caption buttons, which are where the Mac's lights are not
        self.top.setGeometry(G, round(8 - 70 * away), right - G, rows)
        self.go.adjustSize()
        self.go.move(right - self.go.width(), round(8 - 70 * away))
        self.go.setVisible(t > 0.001)
        self.top.setVisible(t > 0.001)
        self.bar.place(W, round(H - G + (self.bar.bar_height() + G + 30) * away))
        self.bar.setVisible(t > 0.001)
        a, b = self._insets(True), self._insets(False)
        top, left, bottom, right = (round(b[i] + (a[i] - b[i]) * t) for i in range(4))
        self.center.setGeometry(self.rect())
        self.pv.setContentsMargins(left, top, right, bottom)

    def _set_narrow(self, narrow):
        if narrow == self.narrow:
            return
        self.narrow = narrow
        self.top.narrow = narrow
        if narrow:
            self.bar.activate()
        else:
            self.bar.deactivate()
            self.go.hide()
            self.top.setFixedHeight(44)

    def resizeEvent(self, _e):
        self._set_narrow(self.width() < 1000)
        self._place()
        self.top.refresh(False)

    def _dimming(self):
        t = self.dim.value
        self.blur.setEnabled(t > 0.01)
        self.blur.setBlurRadius(14 * t)
        self.photo_fade.setOpacity(1 - 0.55 * t)

    def refresh(self, animate=True):
        s, f = self.win.studio, self.win.flow
        stage = s.stage
        choosing = stage == "choosing"
        ids = (s.session or {}).get("ids", [])
        self.rail = len(ids) > 1
        if self.rail:
            self.strip.set_photos(ids, s.thumbs, s.photo, s.loading, s.flags, s.show)
        self.strip.setEnabled(choosing)
        chosen = s.chosen
        if s.original is not None and chosen is not None and s.after is not None:
            look_at = next((i for i, look in enumerate(s.looks) if look["id"] == s.look), 0)
            self.canvas.set_context(look_at, s.level, bool(s.beauty_shown))
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
        self._update_room(animate)
        working = stage == "working"
        self.canvas.set_sweep(f.fraction if working else None)
        self.canvas.setEnabled(stage != "paused")
        self.zoom.sync()
        # after the button the photo stays sharp above one card; the glass leaves
        card = {"working": self.working, "paused": self.paused, "finished": self.finished}.get(stage)
        self.card = card
        if card is not None:
            card.refresh()
            card.place()
        self.present.to(1 if choosing else 0, animate=animate)
        self._place()
        quiet = (choosing and s.loading is None and s.original is not None) or card is not None
        self.top.refresh(animate)
        self.dim.to(0 if quiet else 1, animate=animate)
        show_soft(self.loading, choosing and s.loading is not None)
        for name, overlay in (("working", self.working), ("paused", self.paused), ("finished", self.finished)):
            show_soft(overlay, stage == name)
        self.looks.refresh(animate)
        self.looks.setEnabled(choosing and s.loading is None)
        self.sidebar.refresh(animate)
        self.sidebar.setEnabled(choosing)
        if self.narrow:
            self.bar.refresh(animate)
            self.bar.setEnabled(choosing and s.loading is None)
            self.go.set_text(self.sidebar.go.text)
            self.go.setEnabled(self.sidebar.go.isEnabled())
            self._place()
        for part in (self.strip, self.looks, self.sidebar, self.top, self.bar, self.go):
            part.raise_()
        self.win.caption.raise_()


class ReviewPage(Room):
    """ReviewView: the room lit by the result; the top row (PhotoStepper without a name when there are two or more,
    ZoomCluster in the middle), 8 from the top; "Undo this retouch" and "Done" in the bottom right, 14 in; the glass rail down
    the left (62 from the top to 14 from the bottom) for two or more; the picture in what they leave clear (+12)."""
    GAP = 14

    def __init__(self, win):
        super().__init__()
        self.win = win
        f = win.flow
        self.canvas = CompareCanvas()
        self.canvas.setParent(self)
        self.canvas.can_step = self._can_step
        self.canvas.on_step = self._step
        keep_divider(self.canvas, win.studio.settings)
        wait_t = line(tr("review.fetching"), 13, color=SOFT, align=C)
        wait_t.setFixedWidth(300)
        bar = ProgressLine(200, percent=False)
        bar.set_progress(None)
        self.wait = box(centred(wait_t, 12, bar))
        self.wait.setParent(self)
        self.strip = PhotoStrip(tr("strip.review"))
        self.strip.setParent(self)
        self.stepper = PhotoStepper(win, f.review)
        self.stepper.setParent(self)
        self.zoom = ZoomCluster(self.canvas)
        self.zoom.setParent(self)
        self.undo = GhostButton(tr("undo.current"), self._undo)
        self.done = GlowButton(tr("review.done"), f.leave_review)
        for wdg in (self.undo, self.done):
            wdg.setParent(self)

    def _undo(self):
        self.win.flow.undo_run()
        self.win.flow.leave_review()

    def _can_step(self, d):
        f = self.win.flow
        ids = (f.run or {}).get("done", [])
        return f.review_id in ids and 0 <= ids.index(f.review_id) + d < len(ids)

    def _step(self, d):
        f = self.win.flow
        if self._can_step(d):
            ids = f.run["done"]
            f.review(ids[ids.index(f.review_id) + d])

    def _light(self):
        f = self.win.flow
        return f.after_image if f.after_image is not None else f.review_thumbs.get(f.review_id)

    def _place(self):
        W, H, G = self.width(), self.height(), self.GAP
        ids = (self.win.flow.run or {}).get("done", [])
        rail = len(ids) > 1
        self.strip.setVisible(rail)
        self.stepper.setVisible(rail)
        self.strip.setGeometry(G, 62, PhotoStrip.WIDTH, max(80, H - 62 - G))
        x = G
        if rail:
            self.stepper.move(G, 8)
            x = G + self.stepper.width() + 10
        self.zoom.move(max(x, (W - self.zoom.width()) // 2), 8)
        self.done.move(W - G - self.done.width(), H - G - self.done.height())
        self.undo.move(self.done.x() - 10 - self.undo.width(), H - G - self.undo.height())
        left = (PhotoStrip.WIDTH + G * 2 if rail else 24) + 12
        top, bottom, right = 62 + 12, 44 + G * 2 + 4 + 12, 24 + 12
        area = QRectF(left, top, W - left - right, H - top - bottom).toRect()
        self.canvas.setGeometry(area)
        self.wait.setGeometry(area)

    def resizeEvent(self, _e):
        self._place()

    def refresh(self, animate=True):
        f = self.win.flow
        ids = (f.run or {}).get("done", [])
        if len(ids) > 1:
            self.strip.set_photos(ids, f.review_thumbs, f.review_id, f.review_id if f.review_loading else None, {}, f.review)
        self.stepper.set_state(ids, f.review_id, None, 300)
        ready = f.before_image is not None and f.after_image is not None
        if ready:
            self.canvas.set_picture(("review", f.review_id), f.before_image, f.after_image, tr("review.result"), False, False)
        self.canvas.setVisible(ready)
        self.wait.setVisible(not ready)
        self.zoom.sync()
        self._update_room(animate)
        self._place()
        for wdg in (self.strip, self.stepper, self.zoom, self.undo, self.done):
            wdg.raise_()


# ====================================================================== modal layer
class Modal(QWidget):
    """DialogPanel: a black 50 % veil with one panel in the middle; the veil fades in, the panel steps forward from
    0.94 (spring 0.45 s, bounce 0.2). While it scales, a picture of the panel is drawn; then the panel itself."""

    def __init__(self, parent, content, dim):
        super().__init__(parent)
        self.dim = dim
        self.content = content
        lay = col()
        lay.addStretch(1)
        lay.addWidget(content, 0, HC)
        lay.addStretch(1)
        self.setLayout(lay)
        self.picture = None
        self.step = Tween(1, self.update, self, 450, QEasingCurve.Type.OutBack)

    def arrive(self):
        self.layout().activate()
        self.picture = self.content.grab()
        self.content.setGraphicsEffect(None)
        fade(self.content, 0, animate=False)
        self.step.to(0, animate=False)
        self.step.to(1)
        QTimer.singleShot(460, self._settled)

    def _settled(self):
        self.picture = None
        fade(self.content, 1, animate=False)
        self.update()

    def shadow_rect(self):
        return QRectF(self.content.geometry())

    def paintEvent(self, _e):
        p = painter(self)
        p.fillRect(self.rect(), black(self.dim))
        from .theme import paint_shadow
        r = self.shadow_rect()
        g = 0.94 + 0.06 * self.step.value if self.picture is not None else 1
        p.save()
        p.translate(r.center())
        p.scale(g, g)
        p.translate(-r.center())
        paint_shadow(p, r, getattr(self.content, "radius", 26), 30, black(0.5), 12)
        if self.picture is not None:
            p.drawPixmap(r.topLeft(), self.picture)
        p.restore()

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
        self.setWindowTitle("LRCDF")         # the name in the taskbar and Alt+Tab, every language (the Mac shows LRCDF in the Dock)
        self.setMinimumSize(760, 620)              # the Mac's minimum: below 1000 wide the narrow layout
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
    def show_modal(self, content, opacity=0.5):
        self.close_modal(animate=False)
        modal = Modal(self, content, 0.5)              # DS.veil, the same behind every dialog
        modal.setGeometry(self.rect())
        self._modal = modal
        fade(modal, 0, animate=False)
        modal.show()
        modal.raise_()
        self.caption.raise_()
        modal.arrive()
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
        """SaveStyleSheet: 460 wide, 26 inside, 14 apart: the title (display 24), the text (13, soft), the field
        (14, 44 high, faint, corner 12), the error (12 medium, focus yellow), then (4 more above) the busy line on
        the left, "Cancel" and "Save" on the right, 10 apart. Esc cancels, Enter saves."""
        s = self.studio
        panel = Panel(26, 460)
        v = col(14, (26, 26, 26, 26))
        title = display_line(tr("look.save"), 24)
        v.addWidget(title)
        text = para(tr("look.save_instructions"),
                    13, color=SOFT, center=False)
        text.setFixedWidth(408)
        v.addWidget(text)
        field = Field(tr("look.placeholder"), sheet=True)
        v.addWidget(field)
        error = para("", 12, MEDIUM, color=FOCUS, center=False)
        error.setFixedWidth(408)
        error.hide()
        v.addWidget(error)
        v.addSpacing(4)
        actions = row(10)
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

        def escape():
            if cancel.isEnabled():
                self.close_modal()

        from PySide6.QtGui import QKeySequence, QShortcut
        QShortcut(QKeySequence(Qt.Key.Key_Escape), panel, escape)      # .keyboardShortcut(.cancelAction)
        self.show_modal(panel, 0.45)
        field.setFocus()
