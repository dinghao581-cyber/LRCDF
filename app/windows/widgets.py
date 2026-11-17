"""Painted controls that copy the SwiftUI views in Views.swift: sizes, radii, opacities and timings are taken
from there. Qt's own widgets are only used for text entry and scrolling."""
import math
import re

from PySide6.QtCore import QEasingCurve, QEvent, QPoint, QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QBrush, QColor, QFontMetricsF, QImage, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QGraphicsOpacityEffect, QHBoxLayout, QLabel, QLineEdit, QMenu, QSizePolicy, QWidget

from . import icons
from .theme import CJK
from .i18n import tr
from .theme import (FOCUS, INK, LINE, LINK, MEDIUM, PANEL, REGULAR, SEMIBOLD, BOLD,
                    SOFT, TEXT, Tween, black, css, font, mix, paint_shadow, rounded, white)

AA = QPainter.RenderHint.Antialiasing | QPainter.RenderHint.SmoothPixmapTransform | QPainter.RenderHint.TextAntialiasing
CENTER = Qt.AlignmentFlag.AlignCenter
LEFT = Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter

FACE_TEXT = tr("zoom.face").lstrip("☺ ")    # the face icon is drawn, not typed


_BASE = {}


def painter(widget):
    """A painter whose opacity already includes the dimming (`dim`) of the view and its parents; Qt draws
    nested opacity effects in the wrong place, so views inside dimmed groups dim themselves."""
    p = QPainter(widget)
    p.setRenderHints(AA)
    o, w = 1.0, widget
    while w is not None:
        o *= getattr(w, "_dim_value", 1.0)
        w = w.parentWidget()
    _BASE[id(p)] = o
    p.setOpacity(o)
    return p


def op(p, value):
    p.setOpacity(_BASE.get(id(p), 1.0) * value)


def dim(widget, value, duration=200, animate=True):
    """SwiftUI .opacity(value) for a group of painted views."""
    t = getattr(widget, "_dim", None)
    if t is None:
        widget._dim_value = 1.0

        def step():
            widget._dim_value = widget._dim.value
            widget.update()
            for c in widget.findChildren(QWidget):
                c.update()
        t = widget._dim = Tween(1.0, step, widget, duration)
    t.to(value, duration, animate)


class Veil(QWidget):
    """.opacity(x) for a whole opaque area: the window's ink laid over it at 1 - x."""

    def __init__(self, target, color=INK):
        super().__init__(target)
        self.color = color
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.t = Tween(0, self._step, self, 350)
        target.installEventFilter(self)
        self.setGeometry(target.rect())
        self.hide()

    def eventFilter(self, obj, e):
        if e.type() == e.Type.Resize:
            self.setGeometry(obj.rect())
        return False

    def _step(self):
        self.setVisible(self.t.value > 0.001)
        self.raise_()
        self.update()

    def set_opacity(self, opacity, animate=True):
        self.t.to(1 - opacity, animate=animate)

    def paintEvent(self, _e):
        p = QPainter(self)
        c = QColor(self.color)
        c.setAlphaF(self.t.value)
        p.fillRect(self.rect(), c)


def text_width(f, text):
    return QFontMetricsF(f).horizontalAdvance(text)


def tidy(text):
    """Noto Sans SC draws '·' a full em wide; without the spaces round it the gap matches PingFang's. Other
    languages draw it narrow (theme.font turns on proportional widths) and keep the spaces."""
    return text.replace(" · ", "·") if text and CJK else text


class Text(QLabel):
    def setText(self, text):
        super().setText(tidy(text))


def label(text="", size=13, weight=REGULAR, color=TEXT, wrap=False, align=None, width=None):
    w = Text(tidy(text))
    w.setFont(font(size, weight))
    w.setTextFormat(Qt.TextFormat.PlainText)
    w.setStyleSheet(f"color:{css(color)}; background:transparent; border:0;")
    w.setWordWrap(wrap)
    if align is not None:
        w.setAlignment(align)
    if width is not None:
        w.setFixedWidth(width)
    if not wrap:
        w.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        w.setMinimumWidth(0)
    return w


class Para(QWidget):
    """Wrapped text laid out like SwiftUI: lines 1.2 em apart (SF's line height, which Chinese text in SwiftUI
    inherits), centred or leading."""

    def __init__(self, text="", size=13, weight=REGULAR, color=TEXT, center=True):
        super().__init__()
        self.text_ = tidy(text)
        self.f = font(size, weight)
        self.color = color
        self.center = center
        self.step = round(size * 1.2)
        self.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)
        self._w = None

    def text(self):
        return self.text_

    def setText(self, text):
        text = tidy(text)
        if text != self.text_:
            self.text_ = text
            self._relayout()

    def set_color(self, color):
        self.color = color
        self.update()

    def setFixedWidth(self, w):
        super().setFixedWidth(w)
        self._relayout()

    def setMaximumWidth(self, w):
        super().setMaximumWidth(w)
        self._relayout()

    def _lines(self, width):
        from PySide6.QtGui import QTextLayout, QTextOption
        out = []
        for part in self.text_.split(chr(10)):
            layout = QTextLayout(part, self.f)
            opt = QTextOption()
            opt.setWrapMode(QTextOption.WrapMode.WrapAtWordBoundaryOrAnywhere)
            layout.setTextOption(opt)
            layout.beginLayout()
            while True:
                l = layout.createLine()
                if not l.isValid():
                    break
                l.setLineWidth(width)
                out.append((part[l.textStart():l.textStart() + l.textLength()], l.naturalTextWidth()))
            layout.endLayout()
        return out

    def _relayout(self):
        width = self.maximumWidth() if self.maximumWidth() < 5000 else max(self.width(), 100)
        if self.text_:
            lines = self._lines(width)
            natural = max(w for _, w in lines) if lines else 0
            if self.maximumWidth() < 5000 and self.minimumWidth() != self.maximumWidth():
                self.setMinimumWidth(min(width, int(natural) + 2))
            self.setFixedHeight(len(lines) * self.step)
        else:
            self.setFixedHeight(0)
        self.update()

    def resizeEvent(self, e):
        if self._w != self.width():
            self._w = self.width()
            if self.text_:
                self.setFixedHeight(len(self._lines(self.width())) * self.step)

    def paintEvent(self, _e):
        if not self.text_:
            return
        p = painter(self)
        p.setFont(self.f)
        p.setPen(self.color)
        y = 0
        for text, _ in self._lines(self.width()):
            p.drawText(QRectF(0, y, self.width(), self.step), (CENTER if self.center else LEFT), text.rstrip())
            y += self.step


def set_color(w, color):
    if isinstance(w, Para):
        w.set_color(color)
        return
    w.setStyleSheet(f"color:{css(color)}; background:transparent; border:0;")


# ---------------------------------------------------------------- animation of whole views
def fade(widget, opacity, duration=200, animate=True):
    """SwiftUI .opacity(...) with an animation: an opacity effect that tweens."""
    effect = widget.graphicsEffect()
    if not isinstance(effect, QGraphicsOpacityEffect):
        effect = QGraphicsOpacityEffect(widget)
        effect.setOpacity(1.0)
        widget.setGraphicsEffect(effect)
        widget._fade = Tween(1.0, lambda: effect.setOpacity(widget._fade.value), widget, duration)
    widget._fade.to(opacity, duration, animate)
    if opacity >= 0.999 and not animate:
        effect.setEnabled(False)
    else:
        effect.setEnabled(True)


class Ticker:
    """One timer for every spinner on screen."""
    _timer = None
    _views = set()
    phase = 0

    @classmethod
    def join(cls, view):
        if cls._timer is None:
            cls._timer = QTimer()
            cls._timer.setInterval(16)
            cls._timer.timeout.connect(cls._tick)
        cls._views.add(view)
        if not cls._timer.isActive():
            cls._timer.start()

    @classmethod
    def leave(cls, view):
        cls._views.discard(view)
        if not cls._views and cls._timer is not None:
            cls._timer.stop()

    @classmethod
    def _tick(cls):
        cls.phase += 16
        for v in list(cls._views):
            try:
                if v.isVisible():
                    v.update()
            except RuntimeError:
                cls._views.discard(v)


def draw_petals(p, centre, size, color=QColor(235, 235, 240)):
    """macOS ProgressView spinner: twelve spokes, the brightest one going round once a second."""
    step = (Ticker.phase // 83) % 12
    p.save()
    p.translate(centre)
    pen = QPen(color, max(1.2, size * 0.085))
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    for i in range(12):
        age = (step - i) % 12
        c = QColor(color)
        c.setAlphaF(max(0.18, 1 - age / 12 * 0.9))
        pen.setColor(c)
        p.setPen(pen)
        p.save()
        p.rotate(i * 30)
        p.drawLine(QPointF(0, -size * 0.25), QPointF(0, -size * 0.46))
        p.restore()
    p.restore()


class Spinner(QWidget):
    """ProgressView(): `size` 32 = .large, 18 = .small, 12 = .mini."""

    def __init__(self, size=32):
        super().__init__()
        self.size_ = size
        self.setFixedSize(size, size)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def showEvent(self, e):
        Ticker.join(self)

    def hideEvent(self, e):
        Ticker.leave(self)

    def paintEvent(self, _e):
        p = painter(self)
        draw_petals(p, QPointF(self.width() / 2, self.height() / 2), self.size_)


class ArcSpinner(QWidget):
    """PreparingView: a 44 pt ring, trimmed 0.1-0.9, focus yellow, one turn in 1.1 s."""

    def __init__(self, size=44):
        super().__init__()
        self.setFixedSize(size, size)

    def showEvent(self, e):
        Ticker.join(self)

    def hideEvent(self, e):
        Ticker.leave(self)

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(self.rect()).adjusted(1.5, 1.5, -1.5, -1.5)
        p.translate(r.center())
        p.rotate((Ticker.phase % 1100) / 1100 * 360)
        p.translate(-r.center())
        pen = QPen(QBrush(FOCUS), 3)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        p.setPen(pen)
        # SwiftUI trims from 3 o'clock clockwise; Qt angles run counter-clockwise from 3 o'clock
        p.drawArc(r, round(-0.1 * 360 * 16), round(-0.8 * 360 * 16))


class ProgressLine(QWidget):
    """The preview progress (DESIGN.md, the expression of progress): a 4 pt white line on a faint track and the
    per cent beside it, from counts the app really has. `set_progress(None)` is the indeterminate form for a wait
    nothing can be counted in (a short segment going to and fro); no fake per cent that creeps up."""

    LINE, GAP = 4, 10

    def __init__(self, width=160, size=11, percent=True):
        super().__init__()
        self.bar_w = width
        self.f = font(size, MEDIUM, digits=True)
        self.text_w = round(text_width(self.f, "100%")) + 2 if percent else -self.GAP
        self.fraction = None
        self.t = Tween(0, self.update, self, 500)
        self.setFixedSize(width + self.GAP + self.text_w, max(18, round(size * 1.5)))

    def set_bar_width(self, width):
        if width != self.bar_w:
            self.bar_w = width
            self.setFixedWidth(width + self.GAP + self.text_w)

    def set_progress(self, fraction):
        """`fraction` 0..1, or None when nothing can be counted."""
        if fraction is None:
            self.fraction = None
            self.update()
            return
        fraction = min(1.0, max(0.0, fraction))
        if self.fraction is None:
            self.t.to(fraction, animate=False)
        elif abs(self.t.target - fraction) > 1e-6:
            self.t.to(fraction)
        self.fraction = fraction
        self.update()

    def showEvent(self, e):
        Ticker.join(self)

    def hideEvent(self, e):
        Ticker.leave(self)

    def paintEvent(self, _e):
        p = painter(self)
        y = (self.height() - self.LINE) / 2
        track = QRectF(0, y, self.bar_w, self.LINE)
        r = self.LINE / 2
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(track, r, r)
        p.setBrush(QColor(255, 255, 255))
        if self.fraction is None:
            # a quarter of the track going to and fro once every 1.6 s
            seg = self.bar_w * 0.25
            phase = (Ticker.phase % 1600) / 1600
            x = (1 - abs(1 - 2 * phase)) * (self.bar_w - seg)
            p.drawRoundedRect(QRectF(x, y, seg, self.LINE), r, r)
            return
        w = max(self.LINE, self.bar_w * self.t.value)
        p.drawRoundedRect(QRectF(0, y, w, self.LINE), r, r)
        p.setFont(self.f)
        p.setPen(SOFT)
        p.drawText(QRectF(self.bar_w + self.GAP, 0, self.text_w, self.height()), LEFT | Qt.AlignmentFlag.AlignVCenter,
                   f"{round(self.fraction * 100)}%")


class Icon(QWidget):
    def __init__(self, kind, size, brush=None, weight=icons.LIGHT):
        super().__init__()
        self.kind, self.brush, self.weight = kind, brush, weight
        self.setFixedSize(size, size)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

    def set_kind(self, kind):
        self.kind = kind
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(self.rect())
        brush = self.brush if self.brush is not None else QBrush(FOCUS)
        if self.kind == "check":
            icons.check_circle_fill(p, r, brush, INK)
        else:
            getattr(icons, self.kind)(p, r, brush, self.weight)


# ---------------------------------------------------------------- the surface that paints shadows
class Surface(QWidget):
    """A view with an optional fill that also paints the soft shadows of the views inside it
    (Qt clips each view to its own box, SwiftUI shadows spill over)."""

    def __init__(self, fill=None, *, left_line=False, right_line=False, top_line=False):
        super().__init__()
        self.fill = fill
        self.lines = (left_line, right_line, top_line)

    def paint_fill(self, p):
        if self.fill is not None:
            p.fillRect(self.rect(), self.fill)

    def paintEvent(self, _e):
        p = painter(self)
        self.paint_fill(p)
        for child in self.findChildren(QWidget):
            spec = getattr(child, "shadow", None)
            if spec is None or not child.isVisible() or not child.isVisibleTo(self):
                continue
            if child.window() is not self.window() or not callable(spec):
                continue
            s = spec()
            if not s:
                continue
            rect, corner, radius, color, dy = s
            # only draw for the nearest surface
            host = child.parentWidget()
            while host is not None and not isinstance(host, Surface):
                host = host.parentWidget()
            if host is not self:
                continue
            p.save()
            op(p, getattr(child, "shadow_opacity", 1.0))
            offset = child.mapTo(self, QPointF(0, 0))
            paint_shadow(p, rect.translated(offset), corner, radius, color, dy)
            p.restore()
        left, right, top = self.lines
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(LINE)
        if left:
            p.drawRect(QRectF(0, 0, 1, self.height()))
        if right:
            p.drawRect(QRectF(self.width() - 1, 0, 1, self.height()))
        if top:
            p.drawRect(QRectF(0, 0, self.width(), 1))


GLASS = QColor(20, 20, 20, 140)          # rgba(20, 20, 20, 0.55)
GLASS_LINE = QColor(255, 255, 255, 26)   # 1 px white 0.10


def paint_glass(p, rect, radius):
    """Smoked glass (FOR_WINDOWS.md, "what to do about the glass", option 1): the room behind is already blurred, so a translucent fill and a
    hairline are enough."""
    r = QRectF(rect).adjusted(0.5, 0.5, -0.5, -0.5)
    p.setPen(QPen(GLASS_LINE, 1))
    p.setBrush(GLASS)
    p.drawRoundedRect(r, radius, radius)


def host_update(widget):
    w = widget.parentWidget()
    while w is not None and not isinstance(w, Surface):
        w = w.parentWidget()
    if w is not None:
        w.update()


# ---------------------------------------------------------------- buttons
class Control(QWidget):
    clicked = Signal()

    def __init__(self):
        super().__init__()
        self.pressed = False
        self.hovering = False
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)

    def enterEvent(self, e):
        self.hovering = True
        self.on_hover(True)
        self.update()

    def leaveEvent(self, e):
        self.hovering = False
        self.on_hover(False)
        self.update()

    def on_hover(self, inside):
        pass

    def on_press(self, down):
        pass

    def mousePressEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton and self.isEnabled():
            self.pressed = True
            self.on_press(True)
            self.update()

    def mouseReleaseEvent(self, e):
        if e.button() != Qt.MouseButton.LeftButton or not self.pressed:
            return
        self.pressed = False
        self.on_press(False)
        self.update()
        if self.rect().contains(e.position().toPoint()) and self.isEnabled():
            self.clicked.emit()

    def changeEvent(self, e):
        super().changeEvent(e)
        self.update()


class GhostButton(Control):
    """QuietButton (Design.swift): everything else you can press. 14 medium, 18 side padding, a 44 pt capsule,
    white 0.08 (0.14 pressed) for the glass."""

    def __init__(self, text, action=None, *, size=14, weight=MEDIUM, height=44, pad=18):
        super().__init__()
        self.text = text
        self.f = font(size, weight)
        self.pad = pad
        self.setFixedHeight(height)
        self._fit()
        if action:
            self.clicked.connect(action)

    def _fit(self):
        self.setFixedWidth(round(text_width(self.f, self.text) + 2 * self.pad))

    def set_text(self, text):
        if text != self.text:
            self.text = text
            self._fit()
            self.update()

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 1 if self.isEnabled() else 0.45)
        r = QRectF(self.rect())
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.14 if self.pressed else 0.08))
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        p.setFont(self.f)
        p.setPen(TEXT)
        p.drawText(r, CENTER, self.text)


class GlowButton(Control):
    """PrimaryButton (Design.swift): the one action of a screen, a solid white capsule with black 15 semibold words,
    44 high (48 when it fills the panel); pressed 0.97 and 0.85 opacity; disabled only the fill drops to 0.35.
    No shadow."""

    def __init__(self, text, action=None, *, size=15, weight=SEMIBOLD, height=44, pad=24, stretch=False):
        super().__init__()
        self.text = text
        self.f = font(size, weight)
        self.pad = pad
        self.stretch = stretch
        self.press = Tween(0, self._pressing, self, 120, QEasingCurve.Type.OutQuad)
        self.setFixedHeight(height)
        if stretch:
            self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        else:
            self._fit()
        if action:
            self.clicked.connect(action)

    def _fit(self):
        if not self.stretch:
            self.setFixedWidth(round(text_width(self.f, self.text) + 2 * self.pad))

    def set_text(self, text):
        if text != self.text:
            self.text = text
            self._fit()
            self.update()

    def _pressing(self):
        self.update()
        host_update(self)

    def on_press(self, down):
        self.press.to(1 if down else 0)

    def changeEvent(self, e):
        super().changeEvent(e)
        host_update(self)

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 1 - 0.15 * self.press.value)
        r = QRectF(self.rect())
        s = 1 - 0.03 * self.press.value
        p.translate(r.center())
        p.scale(s, s)
        p.translate(-r.center())
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(1 if self.isEnabled() else 0.35))
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        p.setFont(self.f)
        p.setPen(black(0.85))
        p.drawText(r, CENTER, self.text)


class CapsuleButton(Control):
    """The two buttons of RightsPrompt: a solid white capsule (the primary one), or an outlined one."""

    def __init__(self, text, action, *, filled):
        super().__init__()
        self.text, self.filled = text, filled
        self.f = font(14, SEMIBOLD if filled else REGULAR)
        self.setFixedSize(round(text_width(self.f, text) + 36), 38)
        self.clicked.connect(action)

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 0.75 if self.pressed else 1)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        if self.filled:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 255, 255))
        else:
            p.setPen(QPen(LINE, 1))
            p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(r, r.height() / 2, r.height() / 2)
        p.setFont(self.f)
        p.setPen(QColor(0, 0, 0) if self.filled else TEXT)
        p.drawText(r, CENTER, self.text)


class PlainButton(Control):
    """A Button with .buttonStyle(.plain): only its label, dimmed while pressed."""

    def __init__(self, text, action=None, *, size=14, weight=REGULAR, color=TEXT):
        super().__init__()
        self.text, self.color = text, color
        self.f = font(size, weight)
        self.setFixedSize(round(text_width(self.f, text)) + 2, round(size * 1.6))
        if action:
            self.clicked.connect(action)

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 0.55 if self.pressed else 1)
        p.setFont(self.f)
        p.setPen(self.color)
        p.drawText(QRectF(self.rect()), CENTER, self.text)


class IconButton(Control):
    def __init__(self, kind, action, *, box=26, glyph=11, weight=icons.BOLD, color=TEXT, disc=None):
        super().__init__()
        self.kind, self.glyph, self.weight, self.color, self.disc = kind, glyph, weight, color, disc
        self.setFixedSize(box, box)
        self.clicked.connect(action)

    def paintEvent(self, _e):
        p = painter(self)
        op(p, (0.4 if not self.isEnabled() else 1) * (0.55 if self.pressed else 1))
        if self.disc is not None:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(self.disc)
            p.drawEllipse(QRectF(self.rect()))
        g = self.glyph
        r = QRectF((self.width() - g) / 2, (self.height() - g) / 2, g, g)
        getattr(icons, self.kind)(p, r, self.color, self.weight)


# ---------------------------------------------------------------- sidebar parts
class Pill(Control):
    """LevelPill (13, 32 high, corner 9) and the shaping chips (12, 28 high, corner 8)."""

    def __init__(self, text, action, *, size=13, height=32, corner=9, off_color=white(0.8), animated=True,
                 fill=white(0.06), wrap=False, bounce=False):
        super().__init__()
        self.text, self.size_, self.corner, self.off_color = text, size, corner, off_color
        self.fill, self.wrap, self.bounce = fill, wrap, bounce
        self.animated = animated
        self.selected = False
        self.t = Tween(0, self.update, self, 250)
        self.setFixedHeight(height)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setMinimumWidth(10)
        self.clicked.connect(action)

    def set_selected(self, on, animate=True):
        if on != self.selected or self.t.target != (1 if on else 0):
            self.selected = on
            if self.bounce:               # the shape chips: .bouncy(0.3) from 0.97 to 1
                self.t._anim.setEasingCurve(QEasingCurve.Type.OutBack if on else QEasingCurve.Type.OutCubic)
            self.t.to(1 if on else 0, animate=animate and (self.animated or self.bounce))

    @property
    def mark(self):
        return getattr(self, "_mark", False)

    @mark.setter
    def mark(self, value):
        if value != self.mark:
            self._mark = value
            grid = self.parentWidget()
            if isinstance(grid, PillGrid):
                grid.resizeEvent(None)

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(self.rect())
        t = self.t.value
        if self.bounce:
            g = 0.97 + 0.03 * t
            p.translate(r.center())
            p.scale(g, g)
            p.translate(-r.center())
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(self.fill)
        p.drawRoundedRect(r, self.corner, self.corner)
        if t > 0:
            op(p, min(1, t))
            p.setBrush(QBrush(FOCUS))
            p.drawRoundedRect(r, self.corner, self.corner)
            op(p, 1)
        mark = getattr(self, "mark", False)
        f = font(self.size_, SEMIBOLD if self.selected else REGULAR)
        fit = r.width() - 4 - (12 if mark else 0)      # room for the dot when there is one
        w = text_width(f, self.text)
        if self.wrap and w > fit:     # .lineLimit(2): two words may take two lines, then shrink to 0.7
            size = self.size_
            while size > math.floor(self.size_ * 0.7) and not self._two_lines(font(size, SEMIBOLD if self.selected else REGULAR), fit - 8):
                size -= 1
            f = font(size, SEMIBOLD if self.selected else REGULAR)
            longest = max(text_width(f, word) for word in self.text.split())
            if longest > fit - 8:                    # one word wider than the chip: squeezed, never broken or cut
                f.setStretch(max(60, int(100 * (fit - 8) / longest)))
        elif w > fit:               # .minimumScaleFactor(0.8); pixel sizes round, so round down to really fit
            size = max(math.floor(self.size_ * 0.75), math.floor(self.size_ * fit / w))
            f = font(size, SEMIBOLD if self.selected else REGULAR)
        p.setFont(f)
        p.setPen(mix(self.off_color, black(0.85), min(1, t)))
        text_r =r.adjusted(0, 0, -12, 0) if mark else r
        flags = CENTER | (Qt.TextFlag.TextWordWrap if self.wrap else 0)
        p.drawText(text_r.adjusted(4, 0, -4, 0) if self.wrap else text_r, flags, self.text)
        if mark:
            # the wheel picker: a 5 pt dot after the word when that wheel has been moved
            x = min(text_r.center().x() + text_width(f, self.text) / 2 + 6, r.right() - 6)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(black(0.85) if t > 0.5 else QBrush(FOCUS))
            p.drawEllipse(QPointF(x, r.center().y()), 2.5, 2.5)


    def _two_lines(self, f, width):
        lines = Para(self.text, f.pixelSize())._lines(width)
        return len(lines) <= 2 and all(text_width(f, t.rstrip()) <= width for t, _ in lines)


class ChipGrid(QWidget):
    """ShapeChips: a fixed number of columns (3), 8 apart both ways."""

    def __init__(self, chips, columns=3, spacing=8):
        super().__init__()
        self.chips, self.columns, self.spacing = chips, columns, spacing
        for c in chips:
            c.setParent(self)
        rows = -(-len(chips) // columns)
        self.h = chips[0].height()
        self.setFixedHeight(rows * self.h + (rows - 1) * spacing)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def resizeEvent(self, _e):
        cell = (self.width() - (self.columns - 1) * self.spacing) / self.columns
        for i, c in enumerate(self.chips):
            r, k = divmod(i, self.columns)
            x = round(k * (cell + self.spacing))
            c.setGeometry(x, r * (self.h + self.spacing), round((k + 1) * cell + k * self.spacing) - x, self.h)


class Roll:
    """.contentTransition(.numericText()): when a text changes, the characters that changed roll - the new ones in from
    below (from above when the number went down), the old ones out the other way, fading, 0.3 s; the rest stays.
    Texts of different lengths roll as a whole. `draw` paints it into a rect with an alignment, like drawText."""

    def __init__(self, owner, text=""):
        self.owner = owner
        self.old = self.new = text
        self.down = False
        self.t = Tween(1, owner.update, owner, 300, QEasingCurve.Type.OutCubic)

    @staticmethod
    def _number(text):
        digits = re.findall(r"\d+", text)
        return int(digits[0]) if digits else None

    def set(self, text, animate=True):
        if text == self.new:
            return
        a, b = self._number(self.new), self._number(text)
        self.down = a is not None and b is not None and b < a
        self.old, self.new = self.new, text
        self.t.to(0, animate=False)
        self.t.to(1, animate=animate and bool(self.old))

    def draw(self, p, rect, align):
        t = self.t.value
        fm = QFontMetricsF(p.font())
        if t >= 1 or self.old == self.new:
            p.drawText(rect, align, self.new)
            return
        h = fm.height() * 0.7
        sign = -1 if self.down else 1
        width = fm.horizontalAdvance(self.new)
        if align & Qt.AlignmentFlag.AlignRight:
            x0 = rect.right() - width
        elif align & Qt.AlignmentFlag.AlignHCenter:
            x0 = rect.center().x() - width / 2
        else:
            x0 = rect.left()
        base = rect.center().y() + (fm.ascent() - fm.descent()) / 2
        pen = p.pen()
        colour = pen.color()
        opacity = p.opacity()

        def put(text, x, dy, alpha):
            p.setOpacity(opacity * alpha)
            p.drawText(QPointF(x, base + dy), text)

        if len(self.old) != len(self.new):                     # a different number of characters: the whole text rolls
            ow = fm.horizontalAdvance(self.old)
            ox = x0 if not (align & (Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignHCenter)) else \
                (rect.right() - ow if align & Qt.AlignmentFlag.AlignRight else rect.center().x() - ow / 2)
            put(self.old, ox, -sign * h * t, 1 - t)
            put(self.new, x0, sign * h * (1 - t), t)
        else:
            x = x0
            for i, ch in enumerate(self.new):
                if ch == self.old[i]:
                    put(ch, x, 0, 1)
                else:
                    put(self.old[i], x, -sign * h * t, 1 - t)
                    put(ch, x, sign * h * (1 - t), t)
                x = x0 + fm.horizontalAdvance(self.new[:i + 1])
        p.setOpacity(opacity)
        p.setPen(QPen(colour))


class RollLabel(QLabel):
    """A one-line label whose digits roll when the text changes (the working card's per cent)."""

    def __init__(self, text="", size=24, weight=SEMIBOLD):
        super().__init__(text)
        self.setFont(font(size, weight, digits=True))
        self.setStyleSheet("background:transparent;")
        self.roll = Roll(self, text)

    def setText(self, text):
        super().setText(text)
        self.roll.set(text, animate=self.isVisible())

    def paintEvent(self, _e):
        p = painter(self)
        p.setFont(self.font())
        p.setPen(TEXT)
        self.roll.draw(p, QRectF(self.rect()), self.alignment())


class Segmented(QWidget):
    """LevelBar and the wheel picker: a faint track (3 inside), one segment per choice, the chosen one a focus-yellow
    capsule that slides to it (snappy 0.32). Text 13 (semibold, black on the capsule); when a language's words do not
    fit, 11.5, then squeezed. `marks`: a 5 pt focus dot after the words of choices that have been set (wheel picker)."""
    chosen = Signal(int)

    def __init__(self, titles, *, height=38, corner=None):
        super().__init__()
        self.titles = list(titles)
        self.index = 0
        self.marks = set()
        self.corner = corner                     # None: a capsule
        self.at = Tween(0, self.update, self, 320, QEasingCurve.Type.OutCubic)
        self.pressed = None
        self.vertical = False            # picker(vertical: true): the choices one under the other, 32 high each
        self._height = height
        self.setFixedHeight(height + 6)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setMinimumWidth(10)
        self.setCursor(Qt.CursorShape.PointingHandCursor)

    def set_index(self, index, animate=True):
        if index != self.index or self.at.target != index:
            self.index = index
            self.at.to(index, animate=animate)

    def set_marks(self, marks):
        if set(marks) != self.marks:
            self.marks = set(marks)
            self.update()

    def _layout(self):
        """ViewThatFits as LevelBar: each segment takes what its word needs (9 a side) and the rest is shared out,
        at 13, then at 11.5; only when that does not fit either do the segments share the width equally and a word
        is squeezed. Returns (size, [(x, width)], squeeze)."""
        room = self.width() - 6
        n = max(1, len(self.titles))
        for size in (13, 11.5):
            need = [text_width(font(size, SEMIBOLD), t) + 18 + (11 if i in self.marks else 0)
                    for i, t in enumerate(self.titles)]
            if sum(need) <= room:
                extra = (room - sum(need)) / n
                xs, x = [], 3.0
                for w in need:
                    xs.append((x, w + extra))
                    x += w + extra
                return size, xs, False
        cell = room / n
        return 11.5, [(3 + i * cell, cell) for i in range(n)], True

    def set_vertical(self, on):
        """The wheel picker in the narrow bar stacks (Mac WheelGroup compact): 32 a choice, the track corner 19."""
        if on == self.vertical:
            return
        self.vertical = on
        self.setFixedHeight(len(self.titles) * 32 + 6 if on else self._height + 6)
        self.update()

    def _hit(self, x, y=None):
        if self.vertical and y is not None:
            return int(max(0, min(len(self.titles) - 1, (y - 3) // 32)))
        for i, (left, w) in enumerate(self._layout()[1]):
            if x < left + w:
                return i
        return len(self.titles) - 1

    def mousePressEvent(self, e):
        if e.button() == Qt.MouseButton.LeftButton and self.isEnabled():
            self.pressed = self._hit(e.position().x(), e.position().y())

    def mouseReleaseEvent(self, e):
        which, self.pressed = self.pressed, None
        if which is not None and self.rect().contains(e.position().toPoint()):
            if which == self._hit(e.position().x(), e.position().y()):
                self.set_index(which)
                self.chosen.emit(which)

    def _paint_vertical(self, p):
        r = QRectF(self.rect())
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(r, 19, 19)
        y = 3 + self.at.value * 32
        p.setBrush(QBrush(FOCUS))
        p.drawRoundedRect(QRectF(3, y, r.width() - 6, 32), 16, 16)
        for i, title in enumerate(self.titles):
            on = i == self.index
            box = QRectF(3, 3 + i * 32, r.width() - 6, 32)
            f = font(13, SEMIBOLD if on else REGULAR)
            mark = i in self.marks and not on
            w = min(text_width(f, title), box.width() - 12 - (11 if mark else 0))
            p.setFont(f)
            p.setPen(mix(TEXT, black(0.85), max(0.0, 1 - abs(self.at.value - i))))
            tb = QRectF(box.center().x() - w / 2 - (5.5 if mark else 0), box.top(), w + 1, box.height())
            p.drawText(tb, CENTER, title)
            if mark:
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(QBrush(FOCUS))
                p.drawEllipse(QPointF(tb.right() + 6.5, box.center().y()), 2.5, 2.5)

    def paintEvent(self, _e):
        p = painter(self)
        if self.vertical:
            self._paint_vertical(p)
            return
        r = QRectF(self.rect())
        h = r.height() - 6
        outer = self.corner + 3 if self.corner is not None else r.height() / 2
        inner = self.corner if self.corner is not None else h / 2
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))
        p.drawRoundedRect(r, outer, outer)
        size, cells, squeeze = self._layout()
        at = max(0.0, min(len(cells) - 1.0, self.at.value))
        i0 = int(at)
        i1 = min(i0 + 1, len(cells) - 1)
        t = at - i0
        kx = cells[i0][0] + (cells[i1][0] - cells[i0][0]) * t
        kw = cells[i0][1] + (cells[i1][1] - cells[i0][1]) * t
        p.setBrush(QBrush(FOCUS))
        p.drawRoundedRect(QRectF(kx, 3, kw, h), inner, inner)
        for i, title in enumerate(self.titles):
            on = i == self.index
            box = QRectF(cells[i][0], 3, cells[i][1], h)
            f = font(size, SEMIBOLD if on else REGULAR)        # 11.5 rounds to 12 px
            mark = i in self.marks and not on
            room = box.width() - (8 if squeeze else 18) - (11 if mark else 0)
            w = text_width(f, title)
            if w > room:                                       # only then is a word squeezed (minimumScaleFactor 0.7)
                f.setStretch(max(70, int(100 * room / w)))
                w = room
            p.setFont(f)
            near = max(0.0, 1 - abs(self.at.value - i))       # the capsule passing under the word turns it black
            p.setPen(mix(TEXT, black(0.85), near))
            tb = QRectF(box.center().x() - w / 2 - (5.5 if mark else 0), box.top(), w + 1, box.height())
            p.drawText(tb, CENTER, title)
            if mark:
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(QBrush(FOCUS))
                p.drawEllipse(QPointF(tb.right() + 6.5, box.center().y()), 2.5, 2.5)


class InfoButton(Control):
    """What a control does, for those who want to know: pressed, not hovered. A 14 pt question-mark circle (soft) in a
    44 touch square; a press opens a bubble (13, 300 wide, 16 inside) beside it."""

    def __init__(self, text):
        super().__init__()
        self.text = text
        self.setFixedSize(44, 44)
        self.setAccessibleName(tr("app.help"))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.bubble = None
        self.clicked.connect(self._toggle)

    def _toggle(self):
        if self.bubble is not None and self.bubble.isVisible():
            self.bubble.close()
            return
        self.bubble = Bubble(self.text, self)
        self.bubble.show_beside(self)

    def paintEvent(self, _e):
        p = painter(self)
        c = QPointF(self.width() / 2, self.height() / 2)
        p.setPen(QPen(SOFT if not self.pressed else TEXT, 1.3))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(c, 7, 7)
        f = font(10, SEMIBOLD)
        p.setFont(f)
        p.drawText(QRectF(c.x() - 7, c.y() - 7.5, 14, 14), CENTER, "?")


class Bubble(QWidget):
    """The popover of InfoButton: a dark rounded panel, text 13, 300 wide with 16 inside; closes on any click outside."""

    def __init__(self, text, owner):
        super().__init__(owner.window(), Qt.WindowType.Popup | Qt.WindowType.FramelessWindowHint
                         | Qt.WindowType.NoDropShadowWindowHint)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        self.f = font(13)
        blocks = []
        for part in text.split("\n"):
            blocks += [t.rstrip() for t, _ in Para(part, 13)._lines(268)] if part.strip() else [""]
        self.lines = blocks
        self.setFixedSize(300, 32 + len(blocks) * 19)

    def show_beside(self, owner):
        g = owner.mapToGlobal(QPoint(0, owner.height() // 2))
        screen = owner.screen().availableGeometry()
        x = g.x() - self.width() - 4                      # arrowEdge .leading: the bubble opens towards the photo
        y = max(screen.top() + 8, min(g.y() - 24, screen.bottom() - self.height() - 8))
        self.move(max(screen.left() + 8, x), y)
        self.show()

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(self.rect()).adjusted(0.5, 0.5, -0.5, -0.5)
        p.setPen(QPen(white(0.12), 1))
        p.setBrush(QColor(38, 38, 42, 250))
        p.drawRoundedRect(r, 12, 12)
        p.setFont(self.f)
        p.setPen(TEXT)
        for i, line in enumerate(self.lines):
            p.drawText(QRectF(16, 16 + i * 19, 268, 19), LEFT, line)


class PillGrid(QWidget):
    """A row of pills that folds into 2 or 3 rows when a translation will not fit one row (Chinese stays in one
    row, as on the Mac). A word may shrink to 0.8 like .minimumScaleFactor before the row folds. One row is an
    ordinary QHBoxLayout so it lands on exactly the same pixels as before."""

    def __init__(self, pills, spacing=6):
        super().__init__()
        self.pills, self.spacing = pills, spacing
        self.h = pills[0].height()
        self.row = QHBoxLayout(self)
        self.row.setContentsMargins(0, 0, 0, 0)
        self.row.setSpacing(spacing)
        for p in pills:
            self.row.addWidget(p, 1)
        self.folded = False
        self.setFixedHeight(self.h)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

    def _columns(self, width):
        n = len(self.pills)
        for rows in range(1, n + 1):
            cols = -(-n // rows)
            cell = (width - (cols - 1) * self.spacing) / cols
            if all(text_width(font(p.size_, SEMIBOLD), p.text) * 0.8 <= cell - 4 - (12 if p.mark else 0)
                   for p in self.pills):
                return cols
        return 1

    def resizeEvent(self, _e):
        width = self.width()
        cols = self._columns(width)
        if cols == len(self.pills):
            if self.folded:
                for p in self.pills:
                    self.row.addWidget(p, 1)
                self.folded = False
                self.row.setGeometry(self.rect())
            self.setFixedHeight(self.h)
            return
        if not self.folded:
            for p in self.pills:
                self.row.removeWidget(p)
            self.folded = True
        rows = -(-len(self.pills) // cols)
        cell = (width - (cols - 1) * self.spacing) / cols
        for i, p in enumerate(self.pills):
            r, c = divmod(i, cols)
            x = round(c * (cell + self.spacing))
            p.setGeometry(x, r * (self.h + self.spacing), round((c + 1) * cell + c * self.spacing) - x, self.h)
        self.setFixedHeight(rows * self.h + (rows - 1) * self.spacing)


class Elided(QWidget):
    """One line of text that ends in "…" when the space runs out; the whole text is in the tooltip then."""

    def __init__(self, text, size, color):
        super().__init__()
        self.text, self.f, self.color = tidy(text), font(size), color
        self.natural = round(text_width(self.f, self.text)) + 2
        self.setFixedHeight(round(size * 1.2) + 2)
        self.setMinimumWidth(0)
        self.setSizePolicy(QSizePolicy.Policy.Preferred, QSizePolicy.Policy.Fixed)

    def sizeHint(self):
        return QSize(self.natural, self.height())

    def resizeEvent(self, _e):
        self.setToolTip(self.text if self.width() < self.natural else "")

    def paintEvent(self, _e):
        p = painter(self)
        p.setFont(self.f)
        p.setPen(self.color)
        p.drawText(QRectF(self.rect()), LEFT, p.fontMetrics().elidedText(self.text, Qt.TextElideMode.ElideRight, self.width()))


class Heading(QWidget):
    """Heading: an 18 pt focus-yellow disc with the number (11 bold rounded), then the title (13 semibold, kerning 1)."""

    def __init__(self, number, title):
        super().__init__()
        self.number, self.title = number, title
        self.setFixedHeight(18)

    def paintEvent(self, _e):
        p = painter(self)
        disc = QRectF(0, 0, 18, 18)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QBrush(FOCUS))
        p.drawEllipse(disc)
        p.setFont(font(11, BOLD))
        p.setPen(black(0.8))
        p.drawText(disc.adjusted(0, -0.5, 0, -0.5), CENTER, self.number)
        f = font(13, SEMIBOLD)
        f.setLetterSpacing(f.SpacingType.AbsoluteSpacing, 1)
        p.setFont(f)
        p.setPen(TEXT)
        p.drawText(QRectF(26, 0, self.width() - 26, 18), LEFT, self.title)


class TweakRow(QWidget):
    """The stepless tweak row of DESIGN.md section 7 (user 2026-11-16, the same on Mac, iPad and Windows):
    [low] track [high] number. Whole units -100 ... +100 (value x 50; 1.0 = one old step), the number always
    shown. A drag counts from where the knob is - pressing anywhere never makes it jump - and within 4 of 0 it
    catches 0. The words step 5 a click and keep going while held. A double click on the track, or a click on
    the number, goes back to 0. Arrow keys step 5 (the one adjustable element of the row).
    `moving` while dragging (the quick picture follows), `changed` once it settles (the exact picture is asked).
    Sizes as the Mac ToneRow: 44 high; the words are plain 13 medium in a touch column at least 44 wide; the number
    column at least 38."""
    changed = Signal(float)
    moving = Signal(float)
    KNOB, NUMBER, STEP, CATCH = 16, 38, 5, 4
    H = 44

    def __init__(self, low, high, end=44):
        super().__init__()
        self.low, self.high = low, high
        self.end = end
        self.units = 0                 # what the number shows
        self.dragging = False
        self.pressed = None
        self._grab = None
        self.number_f = font(12, MEDIUM, digits=True)
        self.repeat = QTimer(self, interval=80)
        self.repeat.timeout.connect(self._repeat)
        self.setFixedHeight(self.H)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setAccessibleName(f"{low} {high}")

    @staticmethod
    def end_width(words):
        """A touch column (44) unless a word needs more: then the word and 6 a side (Mac: .padding(6), minWidth 44)."""
        return max(44, max(round(text_width(font(13, MEDIUM), w)) + 12 for w in words))

    @staticmethod
    def shown(units):
        return "0" if units == 0 else f"{units:+d}".replace("-", "\u2212")

    @property
    def value(self):
        return self.units / 50

    def set_value(self, v):
        units = max(-100, min(100, round(float(v) * 50)))
        if not self.dragging and units != self.units:
            self.units = units
            self.update()

    def _zones(self):
        e, w, h = self.end, self.width(), self.H
        left = QRectF(0, 0, e, h)
        number = QRectF(w - self.NUMBER, 0, self.NUMBER, h)
        right = QRectF(number.left() - e, 0, e, h)
        track = QRectF(left.right(), 0, right.left() - left.right(), h)
        return left, right, track, number

    def _set(self, units, final):
        units = max(-100, min(100, int(units)))
        if units != self.units:
            self.units = units
            (self.changed if final else self.moving).emit(self.value)
            self.update()
        elif final:
            self.changed.emit(self.value)

    def _step(self, sign):
        self._set(self.units + sign * self.STEP, True)

    def _repeat(self):
        self.repeat.setInterval(80)
        self._step(-1 if self.pressed == "low" else 1)

    def mousePressEvent(self, e):
        if e.button() != Qt.MouseButton.LeftButton or not self.isEnabled():
            return
        left, right, track, number = self._zones()
        pos = e.position()
        if left.contains(pos) or right.contains(pos):
            self.pressed = "low" if left.contains(pos) else "high"
            self._step(-1 if self.pressed == "low" else 1)
            self.repeat.setInterval(400)          # held: keeps going after a short pause
            self.repeat.start()
        elif number.contains(pos):
            self.pressed = "number"
        elif track.adjusted(-4, 0, 4, 0).contains(pos):
            self.pressed = "track"
            self._grab = (pos.x(), self.units)
        self.update()

    def mouseMoveEvent(self, e):
        if self.pressed != "track":
            return
        _, _, track, _ = self._zones()
        x0, start = self._grab
        span = max(track.width() - self.KNOB, 1)
        units = round(start + (e.position().x() - x0) / span * 200)
        if abs(units) < self.CATCH:
            units = 0
        if units != self.units or not self.dragging:
            self.dragging = True
            self._set(units, False)

    def mouseReleaseEvent(self, e):
        which, self.pressed = self.pressed, None
        self.repeat.stop()
        if which == "track" and self.dragging:
            self.dragging = False
            self.changed.emit(self.value)
        elif which == "number" and self._zones()[3].contains(e.position()):
            self._set(0, True)
        self.dragging = False
        self.update()

    def mouseDoubleClickEvent(self, e):
        if self.isEnabled() and self._zones()[2].adjusted(-4, 0, 4, 0).contains(e.position()):
            self.pressed = None
            self._set(0, True)
        else:
            self.mousePressEvent(e)

    def keyPressEvent(self, e):
        if e.key() in (Qt.Key.Key_Left, Qt.Key.Key_Down):
            self._step(-1)
        elif e.key() in (Qt.Key.Key_Right, Qt.Key.Key_Up):
            self._step(1)
        else:
            super().keyPressEvent(e)

    def focusInEvent(self, e):
        self.update()

    def focusOutEvent(self, e):
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        left, right, track, number = self._zones()
        p.setFont(font(13, MEDIUM))
        for r, text, key in ((left, self.low, "low"), (right, self.high, "high")):
            op(p, 0.55 if self.pressed == key else 1)
            p.setPen(TEXT)
            p.drawText(r, CENTER, text)
        op(p, 1)
        cy = track.center().y()
        x0, span = track.left() + self.KNOB / 2, max(track.width() - self.KNOB, 1)
        at = x0 + (self.units + 100) / 200 * span
        mid = x0 + span / 2
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.12))                              # faint, 2 pt
        p.drawRoundedRect(QRectF(x0, cy - 1, span, 2), 1, 1)
        p.setBrush(SOFT)                                      # the 5 pt "as it was" dot
        p.drawEllipse(QPointF(mid, cy), 2.5, 2.5)
        moved = self.units != 0
        if moved:
            fill = QRectF(min(at, mid), cy - 1, abs(at - mid), 2)
            p.setBrush(QBrush(FOCUS))
            p.drawRoundedRect(fill, 1, 1)
        knob = QRectF(at - self.KNOB / 2, cy - self.KNOB / 2, self.KNOB, self.KNOB)
        paint_shadow(p, knob, self.KNOB / 2, 2, black(0.35), 0.5)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QBrush(FOCUS) if moved else QColor(255, 255, 255))
        p.drawEllipse(knob)
        if self.hasFocus() and self.pressed is None:
            p.setPen(QPen(white(0.55), 1.2))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawEllipse(knob.adjusted(-2.5, -2.5, 2.5, 2.5))
        p.setFont(self.number_f)
        p.setPen(QPen(QBrush(FOCUS), 1) if moved else SOFT)
        p.drawText(number, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, self.shown(self.units))


class ColorWheel(QWidget):
    """The colour wheel of DESIGN.md section 7 (user 2026-11-16, the same on all three): a 150 pt disc - white
    balance (warm right, cool left, pink up, green down, a word at each side) or a hue wheel (red right, then
    anticlockwise yellow, green, cyan, blue, magenta) - its colours pulled 40 % towards mid grey; a cross through
    the middle (white 16 %), a 5 pt centre dot, a 1 pt white 20 % rim. The 18 pt dot is white at the centre, focus-
    yellow away from it with a 2 pt line back to the centre. A drag counts from where the dot is (never jumps),
    stops at the rim and catches the centre within 4 units. A double click on the disc, or a click on the numbers
    below, goes back (`reset`). Hit area: the disc and 12 around it.
    White balance: (warmth, tint) each -100 ... +100. Hue wheels: (hue 0 ... 359, amount 0 ... 100)."""
    moving = Signal(object)
    changed = Signal(object)
    reset = Signal()
    D, DOT, LABEL, NUMBERS, GAP = 150, 18, 18, 18, 6

    def __init__(self, words=("", "", "", "")):
        super().__init__()
        self.mode = "wb"
        self.words = words                       # right, left, up, down (white balance only)
        self.point = (0.0, 0.0)                  # in the unit disc, y up
        self.labels = ("", "")
        self.drag = None
        self.dragging = False
        self.f = font(13, MEDIUM)
        self.num_f = font(12, MEDIUM, digits=True)
        self._faces = {}
        self.setFixedHeight(self.LABEL + self.D + self.LABEL + self.GAP + self.NUMBERS)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    # -------------------------------------------------------------- values
    def set_mode(self, mode, value, labels, touched=None):
        """`touched`: the wheel has left its start (the look's own colour, or the centre for white balance)."""
        self.mode, self.labels = mode, labels
        if touched is not None:
            self.touched = touched
        if not self.dragging:
            self.point = self._point(value)
        self.update()

    def _point(self, value):
        a, b = value
        if self.mode == "wb":
            return a / 100, b / 100
        r = b / 100
        return r * math.cos(math.radians(a)), r * math.sin(math.radians(a))

    def value(self):
        x, y = self.point
        if self.mode == "wb":
            return round(x * 100), round(y * 100)
        r = math.hypot(x, y)
        return (round(math.degrees(math.atan2(y, x))) % 360 if r > 0 else 0), round(r * 100)

    def numbers(self):
        a, b = self.value()
        if self.mode == "wb":
            sign = lambda n: "0" if n == 0 else f"{n:+d}".replace("-", "\u2212")
            return f"{self.labels[0]} {sign(a)}", f"{self.labels[1]} {sign(b)}"
        return f"{self.labels[0]} {a}\u00b0", f"{self.labels[1]} {b}"

    # -------------------------------------------------------------- geometry
    def _disc(self):
        return QRectF((self.width() - self.D) / 2, self.LABEL, self.D, self.D)

    def _numbers_rect(self):
        return QRectF(0, self.LABEL + self.D + self.LABEL + self.GAP, self.width(), self.NUMBERS)

    def _number_layout(self):
        """Keep the existing centred pair when it fits; give long translations the unused space first."""
        texts = self.numbers()
        nr = self._numbers_rect()
        f = self.num_f
        widths = [text_width(f, text) + 2 for text in texts]
        available = nr.width() - 16
        if sum(widths) > available:
            f = font(math.floor(self.num_f.pixelSize() * available / sum(widths)), MEDIUM, digits=True)
            widths = [text_width(f, text) + 2 for text in texts]
        split = max(widths[0] + 8, min(nr.width() / 2, nr.width() - widths[1] - 8))
        return f, (QRectF(nr.left(), nr.top(), split - 8, nr.height()),
                   QRectF(nr.left() + split + 8, nr.top(), nr.width() - split - 8, nr.height()))

    def _in_disc(self, pos, grow=12):
        c = self._disc().center()
        return math.hypot(pos.x() - c.x(), pos.y() - c.y()) <= self.D / 2 + grow

    # -------------------------------------------------------------- input
    def mousePressEvent(self, e):
        if e.button() != Qt.MouseButton.LeftButton or not self.isEnabled():
            return
        pos = e.position()
        if self._in_disc(pos):
            self.drag = (pos, self.point)
        elif self._numbers_rect().contains(pos):
            self.drag = "numbers"

    def mouseMoveEvent(self, e):
        if not isinstance(self.drag, tuple):
            return
        start, (x0, y0) = self.drag
        R = self.D / 2
        x = x0 + (e.position().x() - start.x()) / R
        y = y0 - (e.position().y() - start.y()) / R
        r = math.hypot(x, y)
        if r > 1:
            x, y = x / r, y / r                  # stops on the rim
        if r * 100 < 4:
            x = y = 0.0                          # the centre catches
        if (x, y) != self.point or not self.dragging:
            self.dragging = True
            self.point = (x, y)
            self.moving.emit(self.value())
            self.update()

    def mouseReleaseEvent(self, e):
        drag, self.drag = self.drag, None
        if isinstance(drag, tuple) and self.dragging:
            self.dragging = False
            self.changed.emit(self.value())
        elif drag == "numbers" and self._numbers_rect().contains(e.position()):
            self.reset.emit()
        self.dragging = False

    def mouseDoubleClickEvent(self, e):
        if self.isEnabled() and self._in_disc(e.position(), 0):
            self.drag = None
            self.reset.emit()
        else:
            self.mousePressEvent(e)

    # -------------------------------------------------------------- painting
    def _face(self, mode, size, ratio):
        key = (mode, size, ratio)
        if key not in self._faces:
            import numpy as np
            n = max(2, round(size * ratio))
            c = (np.arange(n) + 0.5) / n * 2 - 1
            x, y = np.meshgrid(c, -c)
            r = np.hypot(x, y)
            if mode == "wb":
                grey = np.array([128.0, 128.0, 128.0])
                warm, cool = np.array([255.0, 150.0, 60.0]), np.array([70.0, 140.0, 255.0])
                pink, green = np.array([255.0, 110.0, 190.0]), np.array([90.0, 200.0, 110.0])
                px, py = x[..., None], y[..., None]
                rgb = (grey + np.clip(px, 0, None) * (warm - grey) + np.clip(-px, 0, None) * (cool - grey)
                       + np.clip(py, 0, None) * (pink - grey) + np.clip(-py, 0, None) * (green - grey))
            else:
                h = (np.degrees(np.arctan2(y, x)) % 360) / 60
                s = np.clip(r, 0, 1)
                v = 0.85
                i = np.floor(h).astype(int) % 6
                f = h - np.floor(h)
                p_, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
                choices = [(v, t, p_), (q, v, p_), (p_, v, t), (p_, q, v), (t, p_, v), (v, p_, q)]
                rgb = np.zeros(x.shape + (3,))
                for k, (a, b, cc) in enumerate(choices):
                    m = i == k
                    for ch, src in enumerate((a, b, cc)):
                        rgb[..., ch][m] = (src if np.isscalar(src) else src[m])
                rgb = rgb * 255
            rgb = rgb * 0.6 + 128 * 0.4                          # pulled 40 % towards mid grey
            alpha = np.clip((1 - r) * n / 2 + 0.5, 0, 1) * 255   # a soft edge one pixel wide
            img = np.dstack([np.clip(rgb, 0, 255), alpha]).astype(np.uint8)
            q_img = QImage(img.tobytes(), n, n, n * 4, QImage.Format.Format_RGBA8888).copy()
            q_img.setDevicePixelRatio(ratio)
            self._faces[key] = q_img
        return self._faces[key]

    def paintEvent(self, _e):
        p = painter(self)
        disc = self._disc()
        c = disc.center()
        R = self.D / 2
        p.drawImage(disc.topLeft(), self._face(self.mode, self.D, self.devicePixelRatioF()))
        p.setPen(QPen(white(0.16), 1))
        p.drawLine(QPointF(disc.left(), c.y()), QPointF(disc.right(), c.y()))
        p.drawLine(QPointF(c.x(), disc.top()), QPointF(c.x(), disc.bottom()))
        p.setPen(QPen(white(0.2), 1))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(disc.adjusted(0.5, 0.5, -0.5, -0.5))
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.55))
        p.drawEllipse(c, 2.5, 2.5)
        if self.mode == "wb":
            p.setFont(self.f)
            p.setPen(TEXT)
            right, left, up, down = self.words
            # the side words get what is left beside the disc; a long translation (Polish "Chłodniej") shrinks to 9
            # and only then ends in "…"
            room = max(20.0, (self.width() - self.D) / 2 - 4)
            for word, r_, align in ((right, QRectF(disc.right() + 4, c.y() - 9, room, 18), LEFT),
                                    (left, QRectF(disc.left() - 4 - room, c.y() - 9, room, 18), Qt.AlignmentFlag.AlignRight)):
                size = 13
                while size > 9 and text_width(font(size, MEDIUM), word) > room:
                    size -= 1
                f = font(size, MEDIUM)
                p.setFont(f)
                if text_width(f, word) > room:
                    word = p.fontMetrics().elidedText(word, Qt.TextElideMode.ElideRight, int(room))
                p.drawText(r_, align | Qt.AlignmentFlag.AlignVCenter, word)
            p.setFont(self.f)
            p.drawText(QRectF(c.x() - 60, 0, 120, self.LABEL), CENTER, up)
            p.drawText(QRectF(c.x() - 60, disc.bottom(), 120, self.LABEL), CENTER, down)
        x, y = self.point
        at = QPointF(c.x() + x * R, c.y() - y * R)
        # DESIGN.md 7: the dot is white at its start and focus yellow once moved; the line back to the centre is
        # grey while untouched (a look's own colour starts off the centre); the numbers are soft only at the centre
        moved = (x, y) != (0.0, 0.0)
        touched = getattr(self, "touched", moved) or self.dragging
        dot = QRectF(at.x() - self.DOT / 2, at.y() - self.DOT / 2, self.DOT, self.DOT)
        if moved:
            pen = QPen(QBrush(FOCUS) if touched else white(0.35), 2)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            p.setPen(pen)
            p.drawLine(c, at)
        paint_shadow(p, dot, self.DOT / 2, 2, black(0.4), 0.5)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(QBrush(FOCUS) if touched else QColor(255, 255, 255))
        p.drawEllipse(dot)
        if self.hasFocus():
            p.setPen(QPen(white(0.55), 1.2))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawEllipse(dot.adjusted(-2.5, -2.5, 2.5, 2.5))
        a, b = self.numbers()
        number_font, (left_number, right_number) = self._number_layout()
        p.setFont(number_font)
        nr = self._numbers_rect()
        p.setPen(QPen(QBrush(FOCUS), 1) if moved else SOFT)
        p.drawText(left_number, Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, a)
        p.drawText(right_number, LEFT | Qt.AlignmentFlag.AlignVCenter, b)


class Switch(Control):
    """SwitchRow: the title (13) on the left, the switch tinted focus yellow on the right, the row at least 44 high;
    a long title wraps (.fixedSize(vertical: true)). The switch as measured on the Mac shot: a 30 x 17 track of
    white 0.10 with a faint lighter rim, a 15 pt light-grey knob (white when on). `fit(width)` sets the row's width."""
    toggled = Signal(bool)
    TRACK = 30

    def __init__(self, text, checked=False, width=None):
        super().__init__()
        self.text = text
        self.f = font(13)
        self.checked = checked
        self.lines = [text]
        self.t = Tween(1 if checked else 0, self.update, self, 200)
        self.clicked.connect(self._flip)
        self.fit(width or round(text_width(self.f, text)) + 12 + self.TRACK)

    def fit(self, width):
        room = width - 12 - self.TRACK
        self.lines = [self.text] if text_width(self.f, self.text) <= room else \
            [t.rstrip() for t, _ in Para(self.text, 13)._lines(room)]
        self.setFixedSize(width, max(44, len(self.lines) * 18 + 16))
        self.update()

    def set_text(self, text, width=None):
        if text != self.text:
            self.text = text
            self.fit(width or self.width())

    def _flip(self):
        self.set_checked(not self.checked)
        self.toggled.emit(self.checked)

    def set_checked(self, on, animate=True):
        if on != self.checked:
            self.checked = on
            self.t.to(1 if on else 0, animate=animate)

    def paintEvent(self, _e):
        p = painter(self)
        p.setFont(self.f)
        p.setPen(TEXT)
        top = (self.height() - len(self.lines) * 18) / 2
        for i, line in enumerate(self.lines):
            p.drawText(QRectF(0, top + i * 18, self.width() - 12 - self.TRACK, 18), LEFT, line)
        t = self.t.value
        track = QRectF(self.width() - self.TRACK, (self.height() - 17) / 2, self.TRACK, 17)
        p.setPen(QPen(mix(white(0.16), FOCUS, t), 1))
        p.setBrush(mix(white(0.10), FOCUS, t))
        p.drawRoundedRect(track.adjusted(0.5, 0.5, -0.5, -0.5), 8, 8)
        knob = QRectF(track.left() + 1 + t * 13, track.top() + 1, 15, 15)
        paint_shadow(p, knob, 7.5, 2, black(0.3), 0.5)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(mix(QColor(198, 198, 200), QColor(255, 255, 255), t) if not self.pressed else QColor(225, 225, 228))
        p.drawEllipse(knob)


class CheckBox(Control):
    """Toggle(.checkbox): a 14 pt rounded box in the system accent colour when ticked."""
    toggled = Signal(bool)
    ACCENT = QColor(10, 132, 255)

    def __init__(self, text, checked=False, *, size=13, color=TEXT):
        super().__init__()
        self.text, self.color, self.size_ = text, color, size
        self.f = font(size)
        self.checked = checked
        self.line_h = max(18, round(size * 1.5))
        self.lines = [text]
        self.setFixedSize(round(text_width(self.f, text)) + 22, self.line_h)
        self.clicked.connect(self._flip)

    def fit(self, width, wrap=None):
        """One line if it fits in `width`, else wrapped to `wrap` (default `width`) at word boundaries, 1.2 em apart."""
        natural = round(text_width(self.f, self.text)) + 22
        if natural <= width:
            self.lines = [self.text]
            self.setFixedSize(natural, self.line_h)
        else:
            width = wrap or width
            self.lines = [t for t, _ in Para(self.text, self.size_)._lines(width - 22)]
            step = round(self.size_ * 1.2)
            self.setFixedSize(width, self.line_h + (len(self.lines) - 1) * step)
        self.update()

    def _flip(self):
        self.checked = not self.checked
        self.update()
        self.toggled.emit(self.checked)

    def paintEvent(self, _e):
        p = painter(self)
        y = (self.line_h - 14) / 2
        box = QRectF(0.5, y + 0.5, 14, 14)
        if self.checked:
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(self.ACCENT.darker(115) if self.pressed else self.ACCENT)
            p.drawRoundedRect(box, 3.5, 3.5)
            pen = QPen(QColor(255, 255, 255), 1.8)
            pen.setCapStyle(Qt.PenCapStyle.RoundCap)
            pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
            p.setPen(pen)
            path = QPainterPath(QPointF(box.left() + 3.5, box.top() + 7.4))
            path.lineTo(box.left() + 6, box.top() + 10)
            path.lineTo(box.left() + 10.6, box.top() + 4.2)
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawPath(path)
        else:
            p.setPen(QPen(white(0.22), 1))
            p.setBrush(white(0.16 if self.pressed else 0.08))
            p.drawRoundedRect(box, 3.5, 3.5)
        p.setFont(self.f)
        p.setPen(self.color)
        lines = self.lines if len(self.lines) > 1 else [self.text]
        step = (self.height() - self.line_h) / max(1, len(lines) - 1)
        for i, t in enumerate(lines):
            p.drawText(QRectF(22, i * step, self.width() - 22, self.line_h), LEFT, t.rstrip())


# ---------------------------------------------------------------- pictures
_SMALL = {}


def smooth(image, w, h, ratio=1.0):
    """.interpolation(.high): a big picture drawn small is first scaled down properly (Qt's painter only
    filters bilinearly, which aliases at 1/20 size). Cached per picture and size."""
    w, h = max(1, round(w * ratio)), max(1, round(h * ratio))
    if image.width() <= w * 1.5 and image.height() <= h * 1.5:
        return image
    key = (image.cacheKey(), w, h)
    hit = _SMALL.get(key)
    if hit is None:
        hit = image.scaled(w, h, Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
        while image.width() > hit.width() * 3:      # step down to stay sharp and fast
            image = image.scaled(image.width() // 2, image.height() // 2, Qt.AspectRatioMode.IgnoreAspectRatio,
                                 Qt.TransformationMode.SmoothTransformation)
            hit = image.scaled(w, h, Qt.AspectRatioMode.IgnoreAspectRatio, Qt.TransformationMode.SmoothTransformation)
        _SMALL[key] = hit
        if len(_SMALL) > 120:
            _SMALL.pop(next(iter(_SMALL)))
    return hit


def draw_cover(p, image, r):
    if image is None or image.isNull():
        return False
    scale = max(r.width() / image.width(), r.height() / image.height())
    w, h = image.width() * scale, image.height() * scale
    ratio = p.device().devicePixelRatioF() if p.device() else 1.0
    p.drawImage(QRectF(r.center().x() - w / 2, r.center().y() - h / 2, w, h), smooth(image, w, h, ratio))
    return True


def brackets(p, r, arm=11):
    """Brackets (Design.swift): four corners as a viewfinder marks focus, 2 pt focus yellow, round caps."""
    a = min(arm, r.width() / 3, r.height() / 3)
    path = QPainterPath()
    for x, y, dx, dy in ((r.left(), r.top(), 1, 1), (r.right(), r.top(), -1, 1),
                         (r.left(), r.bottom(), 1, -1), (r.right(), r.bottom(), -1, -1)):
        path.moveTo(x + a * dx, y)
        path.lineTo(x, y)
        path.lineTo(x, y + a * dy)
    pen = QPen(FOCUS, 2)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawPath(path)


class FocusMark(QWidget):
    """FocusMark: the brackets 5 pt outside the chosen picture. One mark per row, so it slides from card to card
    (matchedGeometryEffect with DS.pick, snappy 0.32 s) instead of going out on one and coming on on the next.
    `follow(widget)`; the widget may say which part of it is the picture with `pic_rect()`."""

    def __init__(self, parent, margin=5, arm=11):
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.margin, self.arm = margin, arm
        self.target = None
        self.at = self._from = self._to = QRectF()
        self.slide = Tween(1, self._sliding, self, 320, QEasingCurve.Type.OutCubic)
        parent.installEventFilter(self)
        self.hide()

    def _goal(self):
        w = self.target
        if w is None or not w.isVisibleTo(self.parentWidget()):
            return None
        r = w.pic_rect() if hasattr(w, "pic_rect") else QRectF(w.rect())
        return r.translated(QPointF(w.mapTo(self.parentWidget(), QPoint(0, 0)))).adjusted(
            -self.margin, -self.margin, self.margin, self.margin)

    def follow(self, target, animate=True):
        if target is not self.target:
            for w, on in ((self.target, False), (target, True)):
                if w is not None:
                    (w.installEventFilter if on else w.removeEventFilter)(self)
            slide = animate and self.target is not None and target is not None and not self.at.isEmpty()
            self.target = target
        else:
            slide = False
        self.setGeometry(self.parentWidget().rect())
        self.raise_()
        veil = getattr(self.parentWidget(), "veil", None)
        if veil is not None:
            veil.raise_()
        goal = self._goal()
        if goal is None:
            self.hide()
            self.at = QRectF()
            return
        self.show()
        if slide:
            self._from, self._to = QRectF(self.at), goal
            self.slide.to(0, animate=False)
            self.slide.to(1)
        elif self.slide.value < 1:              # moved while sliding: keep sliding, to where it is now
            self._to = goal
        else:
            self.at = self._to = goal
            self.update()

    def _sliding(self):
        t = self.slide.value
        a, b = self._from, self._to
        self.at = QRectF(a.x() + (b.x() - a.x()) * t, a.y() + (b.y() - a.y()) * t,
                         a.width() + (b.width() - a.width()) * t, a.height() + (b.height() - a.height()) * t)
        self.update()

    def eventFilter(self, obj, e):
        if e.type() in (QEvent.Type.Move, QEvent.Type.Resize, QEvent.Type.Show, QEvent.Type.Hide):
            QTimer.singleShot(0, lambda: self.follow(self.target, animate=False))
        return False

    def paintEvent(self, _e):
        if not self.at.isEmpty():
            brackets(painter(self), self.at.adjusted(1, 1, -1, -1), self.arm)


MENU_SHEET = ("QMenu{background:rgb(38,38,42);color:white;border:1px solid rgba(255,255,255,30);border-radius:8px;"
              "padding:4px;font-size:13px}QMenu::item{padding:6px 16px;border-radius:5px}"
              "QMenu::item:selected{background:rgba(255,255,255,30)}")


class LookCard(Control):
    """LookCard: picture width x min(104, width*0.66), corner 9; title 13 (semibold and focus yellow when chosen),
    note 11; 7 apart; 78 % opacity unless chosen. The chosen one sits in the row's FocusMark. Hover grows an
    unchosen picture to 1.03 (easeOut 0.15); choosing animates over 0.3 s."""
    delete = Signal()

    def __init__(self):
        super().__init__()
        self.look = None
        self.selected = False
        self.mine = False
        self.card_w = 120
        self.sel = Tween(0, self.update, self, 300)
        self.grow = Tween(0, self.update, self, 150, QEasingCurve.Type.OutQuad)

    def set_look(self, look, selected, width, animate=True):
        self.look = look
        self.mine = look["id"].startswith("u") if look else False
        if width != self.card_w:
            self.card_w = width
        self.setFixedSize(width, 72 + 9 + 16 + 5 + 13)
        if selected != self.selected or self.sel.target != (1 if selected else 0):
            self.selected = selected
            self.sel.to(1 if selected else 0, animate=animate)
        self.grow.to(1 if self.hovering and not self.selected else 0, animate=animate)
        self.update()

    def pic_rect(self):
        return QRectF(0, 0, self.card_w, 72)

    def on_hover(self, inside):
        self.grow.to(1 if inside and not self.selected else 0)

    def contextMenuEvent(self, e):
        """One of the user's own looks: "Delete this style" in its context menu, as on the Mac (no hover-only x)."""
        if not self.mine:
            return
        menu = QMenu(self)
        menu.setStyleSheet(MENU_SHEET)
        menu.addAction(tr("look.delete"), self.delete.emit)
        menu.exec(e.globalPos())

    def paintEvent(self, _e):
        if not self.look:
            return
        p = painter(self)
        op(p, 0.78 + 0.22 * self.sel.value)
        r = self.pic_rect()
        g = 1 + 0.03 * self.grow.value
        p.save()
        p.translate(r.center())
        p.scale(g, g)
        p.translate(-r.center())
        p.save()
        p.setClipPath(rounded(r, 5))
        if not draw_cover(p, self.look.get("image"), r):
            p.fillRect(r, white(0.06))
        p.restore()
        p.restore()
        t = self.sel.value
        y = r.bottom() + 9
        p.setFont(font(12, SEMIBOLD if self.selected else REGULAR))
        p.setPen(mix(TEXT, FOCUS, t))
        p.drawText(QRectF(0, y, self.card_w, 16), LEFT, p.fontMetrics().elidedText(self.look["title"], Qt.TextElideMode.ElideRight, self.card_w))
        p.setFont(font(11))
        p.setPen(SOFT)
        p.drawText(QRectF(0, y + 16 + 5, self.card_w, 13), LEFT, p.fontMetrics().elidedText(self.look["note"], Qt.TextElideMode.ElideRight, self.card_w))


class AddLookCard(Control):
    """AddLookCard: a faint 72-high card (corner 5) with a plus (18, soft); "Save as my style" (12) and its note (11, soft);
    0.78 opacity like an unchosen look."""

    def __init__(self):
        super().__init__()
        self.card_w = 120

    def set_width(self, width):
        self.card_w = width
        self.setFixedSize(width, 72 + 9 + 16 + 5 + 13)

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 0.78 * (0.6 if self.pressed else 1) if self.isEnabled() else 0.3)
        r = QRectF(0, 0, self.card_w, 72)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(white(0.18 if self.hovering else 0.12))
        p.drawRoundedRect(r, 5, 5)
        c = r.center()
        icons.plus(p, QRectF(c.x() - 9, c.y() - 9, 18, 18), SOFT, 0.06)
        y = r.bottom() + 9
        for size, color, text, top in ((12, TEXT, tr("look.save"), y), (11, SOFT, tr("look.save_note"), y + 21)):
            f = font(size)
            w = text_width(f, text)
            if w > self.card_w:                     # .minimumScaleFactor(0.7)
                f.setStretch(max(70, int(100 * self.card_w / w)))
            p.setFont(f)
            p.setPen(color)
            p.drawText(QRectF(0, top, self.card_w, 16 if size == 12 else 13), LEFT, text)


class PhotoThumb(Control):
    """PhotoThumb: 60 x 60 in 5 all round, corner 9, the chosen one in the rail's FocusMark; 0.66 opacity unless chosen or
    loading; flags on a focus-yellow capsule (10 bold, black, 5 x 2 inside) 3 above the bottom."""
    FLAGS = {key: tr(f"flag.{key}") for key in ("eyes", "blur", "over", "dup")}

    def __init__(self):
        super().__init__()
        self.image = None
        self.selected = self.loading = False
        self.flags = []
        self.sel = Tween(0, self.update, self, 200)
        self.setFixedSize(70, 70)

    def pic_rect(self):
        return QRectF(5, 5, 60, 60)

    def set_state(self, image, selected, loading, flags):
        self.image, self.loading, self.flags = image, loading, list(flags)
        if selected != self.selected:
            self.selected = selected
            self.sel.to(1 if selected else 0)
        if loading:
            Ticker.join(self)
        else:
            Ticker.leave(self)
        self.update()

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 1 if self.selected or self.loading else 0.66 + 0.34 * self.sel.value)
        r = self.pic_rect()
        p.save()
        p.setClipPath(rounded(r, 9))
        if not draw_cover(p, self.image, r):
            p.fillRect(r, white(0.06))
        if self.loading:
            draw_petals(p, r.center(), 18)
        if self.flags:
            text = " ".join(self.FLAGS.get(f, f) for f in self.flags)
            f = font(10, BOLD)
            p.setFont(f)
            w = min(r.width() - 4, text_width(f, text) + 10)
            badge = QRectF(r.center().x() - w / 2, r.bottom() - 3 - 17, w, 17)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(FOCUS)
            p.drawRoundedRect(badge, 7.5, 7.5)
            p.setPen(black(0.85))
            p.drawText(badge, CENTER, text)
        p.restore()


class PersonChip(Control):
    """PersonChip: a 44 pt round face (faint 1 pt ring, or focus yellow 2 pt when set; "no retouch" is grey at 0.5) over its
    choice (11, soft / focus yellow semibold), 3 apart. 48 wide."""
    NAMES = {"follow": tr("person.follow"), "light": tr("person.light"), "natural": tr("level.natural"),
             "refined": tr("level.refined"), "off": tr("person.off")}

    def __init__(self, image, action):
        super().__init__()
        self.image = image
        self.choice = "follow"
        self.t = Tween(0, self.update, self, 200)
        self.setFixedSize(48, 44 + 3 + 14)
        self.clicked.connect(action)

    def set_choice(self, choice):
        if choice != self.choice:
            self.choice = choice
            self.t.to(0 if choice == "follow" else 1)

    def paintEvent(self, _e):
        p = painter(self)
        r = QRectF(2, 0, 44, 44)
        p.save()
        op(p, 0.5 if self.choice == "off" else 1)
        path = QPainterPath()
        path.addEllipse(r)
        p.setClipPath(path)
        image = self.image
        if self.choice == "off" and image is not None and not image.isNull():
            image = image.convertToFormat(QImage.Format.Format_Grayscale8)      # .saturation(0)
        if not draw_cover(p, image, r):
            p.fillRect(r, white(0.06))
        p.restore()
        t = self.t.value
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.setPen(QPen(mix(white(0.12), FOCUS, t), 1 + t))
        p.drawEllipse(r.adjusted(0.5 + t / 2, 0.5 + t / 2, -0.5 - t / 2, -0.5 - t / 2))
        name = self.NAMES.get(self.choice, self.NAMES["follow"])
        f = font(11, SEMIBOLD if self.choice != "follow" else REGULAR)
        w = text_width(f, name)
        if w > 48:                                          # .minimumScaleFactor(0.6)
            f.setStretch(max(60, int(100 * 48 / w)))
        p.setFont(f)
        p.setPen(mix(SOFT, FOCUS, t))
        p.drawText(QRectF(0, 47, 48, 14), CENTER, name)


# ---------------------------------------------------------------- zoom bar
class ZoomCapsule(QWidget):
    """− Fit window / 2.0× +: two 44 icon buttons and the words (12 medium, even digits, at least 64 wide, 6 a side) between
    them; a click on the words fits the picture. Bare: ZoomCluster is the glass."""
    fit = Signal()

    def __init__(self, minus, plus):
        super().__init__()
        self.text = tr("zoom.fit")
        self.f = font(12, MEDIUM, digits=True)
        self.roll = Roll(self, self.text)
        self.minus = IconButton("minus", minus, box=44, glyph=12)
        self.plus = IconButton("plus", plus, box=44, glyph=12)
        self.minus.setParent(self)
        self.plus.setParent(self)
        self._fit()

    def _words(self):
        return max(64, round(text_width(self.f, tr("zoom.fit"))) + 12)

    def _fit(self):
        mid = self._words()
        self.setFixedSize(44 + mid + 44, 44)
        self.minus.move(0, 0)
        self.plus.move(44 + mid, 0)

    def set_zoom(self, zoom):
        self.text = tr("zoom.fit") if zoom <= 1.01 else f"{zoom:.1f}×"
        self.roll.set(self.text, animate=self.isVisible())
        self.minus.setEnabled(zoom > 1)
        self.plus.setEnabled(zoom < 8)
        self.update()

    def mouseReleaseEvent(self, e):
        if QRectF(44, 0, self._words(), 44).contains(e.position()):
            self.fit.emit()

    def paintEvent(self, _e):
        p = painter(self)
        p.setFont(self.f)
        p.setPen(TEXT)
        self.roll.draw(p, QRectF(44, 0, self._words(), 44), CENTER)


class FaceButton(Control):
    """Label('Zoom to faces', systemImage: 'face.smiling') 12 medium, 14 a side, 44 high; bare inside ZoomCluster."""

    def __init__(self, action):
        super().__init__()
        self.text = FACE_TEXT
        self.f = font(12, MEDIUM)
        self.clicked.connect(action)
        self._fit()

    def _fit(self):
        self.setFixedSize(round(14 + 14 + 6 + text_width(self.f, self.text) + 14), 44)

    def set_text(self, text):
        if text != self.text:
            self.text = text
            self._fit()
            self.update()

    def paintEvent(self, _e):
        p = painter(self)
        op(p, 0.6 if self.pressed else 1)
        r = QRectF(self.rect())
        icons.face_smiling(p, QRectF(14, 15, 14, 14), TEXT, QColor(36, 36, 38))
        p.setFont(self.f)
        p.setPen(TEXT)
        p.drawText(QRectF(14 + 14 + 6, 0, r.width(), 44), LEFT, self.text)


# ---------------------------------------------------------------- text entry
class Field(QLineEdit):
    """TextField(.roundedBorder) in the dark appearance; `sheet`: SaveStyleSheet's plain field - 14, 44 high, 14 inside,
    on the faint fill with corner 12."""

    def __init__(self, placeholder, sheet=False):
        super().__init__()
        self.setPlaceholderText(placeholder)
        if sheet:
            self.setFont(font(14))
            self.setFixedHeight(44)
            self.setStyleSheet(
                "QLineEdit{background:rgba(255,255,255,31);color:rgb(255,255,255);border:0;"
                "border-radius:12px;padding:0 14px;selection-background-color:rgba(10,132,255,150);}")
            return
        self.setFont(font(13))
        self.setFixedHeight(24)
        self.setStyleSheet(
            "QLineEdit{background:rgba(255,255,255,10);color:rgb(239,239,243);border:1px solid rgba(255,255,255,24);"
            "border-radius:5px;padding:0 6px;selection-background-color:rgba(10,132,255,150);}")


class ScrollStyle:
    SHEET = ("QScrollArea{background:transparent;border:0;} QScrollArea>QWidget>QWidget{background:transparent;}"
             "QScrollBar:vertical{background:transparent;width:8px;margin:2px;}"
             "QScrollBar::handle:vertical{background:rgba(255,255,255,60);border-radius:3px;min-height:30px;}"
             "QScrollBar::add-line,QScrollBar::sub-line{height:0;} QScrollBar::add-page,QScrollBar::sub-page{background:none;}")
