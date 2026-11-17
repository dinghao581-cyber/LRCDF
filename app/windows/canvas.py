"""CompareView of Views.swift: the original left of a draggable divider, the result right of it; zoom by wheel,
pinch, buttons and double click, drag a zoomed picture to move it."""
from PySide6.QtCore import QEasingCurve, QEvent, QPointF, QRectF, QSize, Qt, QTimer, QVariantAnimation, Signal
import math
import time

from PySide6.QtGui import QColor, QCursor, QFontMetricsF, QImage, QLinearGradient, QPainter, QPen, QRadialGradient
from PySide6.QtWidgets import QWidget

from . import icons
from .i18n import tr
from .theme import LINE, SEMIBOLD, TEXT, Tween, black, font, paint_shadow, rounded
from .widgets import Ticker, brackets, draw_petals, smooth, text_width


class CompareCanvas(QWidget):
    changed = Signal()

    def __init__(self):
        super().__init__()
        self.setMinimumSize(200, 160)
        self.setMouseTracking(True)
        self.grabGesture(Qt.GestureType.PinchGesture)
        self.before = self.after = None
        self.title = ""
        self.plain = self.pending = False
        self.split = 0.5
        self.sweep = None                # while Lightroom works: how far it has got; the line shows it
        self.swept = Tween(0.5, self.update, self, 400, QEasingCurve.Type.Linear)
        self.zoom = 1.0
        self.centre = QPointF(0.5, 0.5)
        self.face = None
        self.faces = ()
        self.marked = Tween(0, self.update, self, 300)    # focus brackets on the face just jumped to
        self.photo_key = None
        self._drag = None
        self._old = None                 # the picture being faded out (or wiped / opened over)
        self.reveal = "settle"           # how the new picture comes in: "settle", "wipe-left", "wipe-right", "iris"
        self.context = None              # (look index, level, retouched) of the picture on show
        self.origin = QPointF(0.5, 0.5)  # where an iris opens from: the first face, as a fraction of the picture
        self.kept = 0.5                  # @AppStorage("divider"): the divider stays where it was left
        self.on_kept = lambda value: None  # the page keeps it in the settings (window.keep_divider)
        self.grabbed = Tween(0, self.update, self, 200, QEasingCurve.Type.OutCubic)   # line 1.5 -> 2.5, handle x 1.14
        self.settle = Tween(0.5, self._settling, self, 420)
        curve = QEasingCurve(QEasingCurve.Type.OutBack)
        curve.setOvershoot(0.9)          # spring(response: 0.42, dampingFraction: 0.74)
        self.settle._anim.setEasingCurve(curve)
        self.pull = Tween(0, self.update, self, 400)
        pull_curve = QEasingCurve(QEasingCurve.Type.OutBack)
        pull_curve.setOvershoot(1.2)     # spring(duration: 0.4, bounce: 0.25)
        self.pull._anim.setEasingCurve(pull_curve)
        self.arrive = Tween(1, self.update, self, 300, QEasingCurve.Type.OutCubic)   # a new photo: fade in, 0.985 -> 1
        self._samples = []               # (time, x) while the divider is dragged: its speed when let go
        self._swiped = 0.0               # two-finger sideways scrolling on a picture that fits
        self.can_step = lambda d: False  # set by the page: is there a photo that way?
        self.on_step = lambda d: None
        self.fade = Tween(1, self.update, self, 250, QEasingCurve.Type.InOutQuad)
        self.left_tag = Tween(1, self.update, self, 150, QEasingCurve.Type.OutQuad)
        self.right_tag = Tween(1, self.update, self, 150, QEasingCurve.Type.OutQuad)
        self._move = QVariantAnimation(self)
        self._move.valueChanged.connect(self._moving)
        self._from = self._to = None

    # ------------------------------------------------------------ state
    def set_context(self, look_index, level, retouched):
        """What the next picture is (RevealImage): its look's place in the row, the beauty level, retouched or not."""
        self._next_context = (look_index, level, retouched)

    def set_picture(self, key, before, after, title, plain, pending, faces=()):
        context = getattr(self, "_next_context", None)
        if key != self.photo_key:
            photo_changed = self.photo_key is not None and key[1:] != self.photo_key[1:]
            self.photo_key = key
            self.split = self.kept
            self._move.stop()
            self.zoom, self.centre, self.face = 1.0, QPointF(0.5, 0.5), None
            self._old = None
            self.fade.to(1, animate=False)
            self.pull.to(0, animate=False)
            if photo_changed:            # .transition(.opacity.combined(with: .scale(scale: 0.985)))
                self.arrive.to(0, animate=False)
                self.arrive.to(1, 300)
        elif after is not self.after and self.after is not None and after is not None:
            # a new picture of the same photo: from the side of its card, from the face, or (a more exact render of
            # the same look) a 0.25 s settle
            before_ctx = self.context or context
            if context is None or before_ctx is None:
                self.reveal = "settle"
            elif context[0] != before_ctx[0]:
                self.reveal = "wipe-left" if context[0] < before_ctx[0] else "wipe-right"
            elif context[1:] != before_ctx[1:]:
                self.reveal = "iris"
            else:
                self.reveal = "settle"
            self._old = self.after if self.fade.value >= 1 or self._old is None else self.after
            time_ms = {"iris": 600, "settle": 250}.get(self.reveal, 420)
            self.fade._anim.setEasingCurve(QEasingCurve.Type.InOutQuad if self.reveal == "settle" else QEasingCurve.Type.InOutSine)
            self.fade.to(0, animate=False)
            self.fade.to(1, time_ms)
        if context is not None:
            self.context = context
        if faces:
            x, y, w, h = faces[0]
            self.origin = QPointF(x + w / 2, y + h / 2)
        else:
            self.origin = QPointF(0.5, 0.5)
        self.before, self.after, self.title = before, after, title
        self.plain, self.faces = plain, faces
        if pending != self.pending:
            self.pending = pending
            (Ticker.join if pending else Ticker.leave)(self)
        self.update()

    def set_sweep(self, fraction):
        """Compare.swift `sweep`: while Lightroom works the result spreads across the picture from the right as far
        as the work has got (the line at 1 - fraction, linear 0.4 s); no handle, no labels, nothing to drag."""
        if fraction is None:
            if self.sweep is not None:
                self.sweep = None
                self.update()
            return
        if self.sweep is None:
            self._drag = None
            self.swept.to(self.split, animate=False)
        self.sweep = min(1.0, max(0.0, fraction))
        self.swept.to(1 - self.sweep)

    def shown_split(self):
        return self.swept.value if self.sweep is not None else self.split

    def picture_rect(self):
        if self.before is None or self.before.isNull():
            return QRectF()
        size = self.before.size().scaled(self.size(), Qt.AspectRatioMode.KeepAspectRatio)
        return QRectF((self.width() - size.width()) / 2, (self.height() - size.height()) / 2, size.width(), size.height())

    def shadow(self):
        box = self.picture_rect()
        if box.isEmpty():
            return None
        return box, 14, 30, black(0.55), 16

    def _bounded(self, point, zoom):
        half = 0.5 / zoom
        return QPointF(max(half, min(1 - half, point.x())), max(half, min(1 - half, point.y())))

    def _look(self, point):
        self.centre = self._bounded(point, self.zoom)

    def _refresh(self):
        self.changed.emit()
        self.update()

    def _animate(self, zoom, centre, duration, curve=QEasingCurve.Type.OutCubic):
        self._move.stop()
        self._from = (self.zoom, QPointF(self.centre))
        self._to = (zoom, self._bounded(centre, zoom))
        self._move.setDuration(duration)
        self._move.setEasingCurve(curve)
        self._move.setStartValue(0.0)
        self._move.setEndValue(1.0)
        self._move.start()
        self.changed.emit()

    def _moving(self, t):
        (z0, c0), (z1, c1) = self._from, self._to
        # interpolate the visible window, not the raw numbers, so the move looks straight
        self.zoom = z0 * (z1 / z0) ** t
        self.centre = c0 + (c1 - c0) * t
        self.centre = self._bounded(self.centre, self.zoom)
        self._refresh()

    @property
    def target_zoom(self):
        return self._to[0] if self._move.state() == QVariantAnimation.State.Running else self.zoom

    def fit(self):
        self.face = None
        self._animate(1.0, QPointF(0.5, 0.5), 400)            # spring(duration: 0.4)

    def magnify(self, factor, anchor=None, animate=True, duration=200):
        anchor = anchor or QPointF(0.5, 0.5)
        zoom0 = self.target_zoom
        centre0 = self._to[1] if self._move.state() == QVariantAnimation.State.Running else self.centre
        offset = anchor - QPointF(0.5, 0.5)
        point = centre0 + offset / zoom0
        zoom = max(1.0, min(8.0, zoom0 * factor))
        if zoom == 1:
            self.face = None
        centre = point - offset / zoom
        if animate:
            self._animate(zoom, centre, duration)             # easeOut(duration: 0.2)
        else:
            self._move.stop()
            self.zoom = zoom
            self._look(centre)
            self._refresh()

    def next_face(self):
        if not self.faces:
            return
        i = 0 if self.face is None else self.face + 1
        if i >= min(len(self.faces), 4):
            self.fit()
            return
        x, y, w, h = self.faces[i]
        self.face = i
        self._animate(max(1.6, min(7.0, 0.55 / max(h, 0.02))), QPointF(x + w / 2, y + h / 2), 450)
        # Compare.swift `marked`: the brackets come on (from 1.5 times the size), and go 1.1 s later
        self.marked.to(1)
        QTimer.singleShot(1100, lambda: self.marked.to(0, 300) if self.face == i else None)

    # ------------------------------------------------------------ mouse
    @classmethod
    def _clamped(cls, point, box):
        n = cls._normal(point, box)
        return QPointF(max(0.0, min(1.0, n.x())), max(0.0, min(1.0, n.y())))

    @staticmethod
    def _normal(point, box):
        return QPointF((point.x() - box.left()) / box.width(), (point.y() - box.top()) / box.height())

    def _on_line(self, point, box):
        """The divider is taken by its line or its handle: a 44 pt column, and nowhere else."""
        return not self.plain and abs(point.x() - (box.left() + box.width() * self.split)) <= 22

    def _settling(self):
        self.split = self.settle.value
        self.update()

    def mousePressEvent(self, event):
        if self.sweep is not None:
            return
        box = self.picture_rect()
        if event.button() != Qt.MouseButton.LeftButton or not box.contains(event.position()):
            return
        p = event.position()
        self._move.stop()
        if self._on_line(p, box):
            self.settle._anim.stop()
            self._drag = "split", p, self.centre
            self._samples = [(time.monotonic(), p.x())]
            self.grabbed.to(1)
        elif self.zoom > 1.01:
            self._drag = "pan", p, self.centre
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
        else:
            self._drag = "swipe", p, self.centre

    def mouseMoveEvent(self, event):
        box = self.picture_rect()
        if box.isEmpty() or self.sweep is not None:
            return
        p = event.position()
        if self._drag:
            kind, start, centre = self._drag
            if kind == "split":
                self.split = max(0.0, min(1.0, self._normal(p, box).x()))
                self._samples = (self._samples + [(time.monotonic(), p.x())])[-6:]
            elif kind == "swipe":
                dx = p.x() - start.x()
                if abs(dx) >= 10:                      # DragGesture(minimumDistance: 10)
                    can = self.can_step(1 if dx < 0 else -1)
                    self.pull.to(dx * (0.45 if can else 0.1), animate=False)   # stiff when there is nothing that way
                    self._samples = (self._samples + [(time.monotonic(), p.x())])[-6:]
            else:
                delta = p - start
                self._look(centre - QPointF(delta.x() / (box.width() * self.zoom), delta.y() / (box.height() * self.zoom)))
                self.changed.emit()
            self.update()
        elif box.contains(p) and self._on_line(p, box):
            self.setCursor(Qt.CursorShape.SizeHorCursor)
        elif box.contains(p) and self.zoom > 1.01:
            self.setCursor(Qt.CursorShape.OpenHandCursor)
        else:
            self.unsetCursor()

    def _speed(self):
        s = self._samples
        if len(s) < 2 or s[-1][0] - s[0][0] <= 0:
            return 0.0
        return (s[-1][1] - s[0][1]) / (s[-1][0] - s[0][0])

    def mouseReleaseEvent(self, event):
        drag, self._drag = self._drag, None
        if not drag:
            return
        kind, start, _ = drag
        if kind == "pan":
            self.setCursor(Qt.CursorShape.OpenHandCursor)
        elif kind == "split":
            box = self.picture_rect()
            # let go: it carries on a little (predictedEndLocation) and settles; thrown at an edge it goes all the way
            rest = self.split + self._speed() * 0.25 / max(box.width(), 1)
            rest = 0.0 if rest < 0.07 else 1.0 if rest > 0.93 else max(0.0, min(1.0, rest))
            self.settle.to(self.split, animate=False)
            self.settle.to(rest)
            self.kept = rest
            self.on_kept(rest)
            self.grabbed.to(0)
        elif kind == "swipe":
            flung = event.position().x() - start.x() + self._speed() * 0.25
            if abs(flung) > 160 and self.can_step(1 if flung < 0 else -1):
                self.on_step(1 if flung < 0 else -1)
            self.pull.to(0)
        self._samples = []

    def mouseDoubleClickEvent(self, event):
        if self.sweep is not None:
            return
        box = self.picture_rect()
        if box.contains(event.position()) and event.button() == Qt.MouseButton.LeftButton:
            self._drag = None
            if self._on_line(event.position(), box):     # a double tap on the divider: back to the middle
                self.grabbed.to(0)
                self.settle.to(self.split, animate=False)
                self.settle.to(0.5)
                self.kept = 0.5
                self.on_kept(0.5)
                return
            if self.zoom > 1.01:
                self.fit()
            else:
                self.magnify(3, self._normal(event.position(), box), duration=400)

    def wheelEvent(self, event):
        if self.sweep is not None:
            return
        box = self.picture_rect()
        if not box.contains(event.position()):
            return super().wheelEvent(event)
        if event.phase() in (Qt.ScrollPhase.ScrollBegin, Qt.ScrollPhase.ScrollEnd):
            self._swiped = 0.0
        if (event.pixelDelta().manhattanLength() and self.zoom <= 1.01
                and abs(event.pixelDelta().x()) > abs(event.pixelDelta().y())):
            if math.isfinite(self._swiped):
                self._swiped += event.pixelDelta().x()
                if abs(self._swiped) > 110:
                    d = 1 if self._swiped < 0 else -1
                    if self.can_step(d):
                        self.on_step(d)
                    self._swiped = math.inf          # one photo per swipe
            event.accept()
            return
        if event.pixelDelta().manhattanLength() and not event.angleDelta().y() % 120 == 0 and self.zoom > 1.01:
            # a precision touchpad's two-finger scroll moves a zoomed picture, like on the Mac
            d = event.pixelDelta()
            self._look(self.centre - QPointF(d.x() / (box.width() * self.zoom), d.y() / (box.height() * self.zoom)))
            self._refresh()
            event.accept()
            return
        delta = event.angleDelta().y() or event.pixelDelta().y()
        if delta:
            self.magnify(1.18 if delta > 0 else 1 / 1.18, self._normal(event.position(), box), animate=False)
            event.accept()

    def event(self, event):
        if getattr(self, "sweep", None) is not None and event.type() in (QEvent.Type.Gesture, QEvent.Type.NativeGesture):
            return True
        if event.type() == QEvent.Type.Gesture:
            pinch = event.gesture(Qt.GestureType.PinchGesture)
            box = self.picture_rect()
            if pinch and not box.isEmpty() and pinch.lastScaleFactor() > 0:
                point = self.mapFromGlobal(QCursor.pos())
                self.magnify(pinch.scaleFactor() / pinch.lastScaleFactor(), self._clamped(QPointF(point), box), animate=False)
                event.accept(pinch)
                return True
        if event.type() == QEvent.Type.NativeGesture and event.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            box = self.picture_rect()
            if not box.isEmpty():
                self.magnify(1 + event.value(), self._clamped(event.position(), box), animate=False)
                return True
        return super().event(event)

    # ------------------------------------------------------------ painting
    def _target(self, box):
        w, h = box.width() * self.zoom, box.height() * self.zoom
        return QRectF(box.center().x() - self.centre.x() * w, box.center().y() - self.centre.y() * h, w, h)

    def paintEvent(self, _event):
        box = self.picture_rect()
        if box.isEmpty():
            return
        p = QPainter(self)
        p.setRenderHints(QPainter.RenderHint.Antialiasing | QPainter.RenderHint.SmoothPixmapTransform)
        a = self.arrive.value
        if a < 1 or self.pull.value:
            p.setOpacity(a)
            s = 0.985 + 0.015 * a
            p.translate(box.center().x() + self.pull.value, box.center().y())
            p.scale(s, s)
            p.translate(-box.center().x(), -box.center().y())
        p.save()
        p.setClipPath(rounded(box, 8))
        target = self._target(box)
        after = self.after or self.before
        ratio = self.devicePixelRatioF()

        def pic(img):
            # whole picture shown: a properly scaled copy; zoomed in: the full-size one
            return smooth(img, target.width(), target.height(), ratio) if self.zoom < 1.5 else img
        if self._old is not None and self.fade.value < 1:
            p.drawImage(target, pic(self._old))
            if self.reveal == "settle":
                p.setOpacity(self.fade.value)
                p.drawImage(target, pic(after))
                p.setOpacity(1)
            else:
                p.drawImage(target, self._revealed(pic(after), target, box))
        else:
            p.drawImage(target, pic(after))
        split = self.shown_split()
        split_x = box.left() + box.width() * split
        if not self.plain:
            p.save()
            p.setClipRect(QRectF(box.left(), box.top(), box.width() * split, box.height()), Qt.ClipOperation.IntersectClip)
            p.drawImage(target, pic(self.before))
            p.restore()
        if self.face is not None and self.marked.value > 0.01 and self.face < len(self.faces):
            x, y, w, h = self.faces[self.face]
            face = QRectF(target.left() + x * target.width(), target.top() + y * target.height(),
                          w * target.width(), h * target.height())
            s = 1.5 - 0.5 * self.marked.value
            p.save()
            p.setOpacity(self.marked.value)
            p.translate(face.center())
            p.scale(s, s)
            p.translate(-face.center())
            brackets(p, face, 14)
            p.restore()
        p.restore()
        p.setPen(QPen(LINE, 1))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(box.adjusted(0.5, 0.5, -0.5, -0.5), 8, 8)
        if not self.plain:
            lw = 1.5 + 1.0 * self.grabbed.value
            line = QRectF(split_x - lw / 2, box.top(), lw, box.height())
            paint_shadow(p, line, 0, 3, black(0.45))
            p.fillRect(line, QColor(255, 255, 255))
            if self.sweep is not None:
                return
            cy = self._knob_y(box)
            k = 22 * (1 + 0.14 * self.grabbed.value)
            knob = QRectF(split_x - k, cy - k, 2 * k, 2 * k)
            paint_shadow(p, knob, 22, 6, black(0.35), 2)
            self._material(p, box, knob)                              # .glass(Circle(), smoked: false)
            p.setPen(QPen(QColor(255, 255, 255, 40), 0.8))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawEllipse(knob.adjusted(0.4, 0.4, -0.4, -0.4))
            icons.chevrons(p, QRectF(knob.center().x() - 7, knob.center().y() - 7, 14, 14), QColor(255, 255, 255), 0.16)
            # the labels go when the line is within 84 of the left edge or 150 of the right one (Compare.swift)
            at = box.width() * self.split
            self.left_tag.to(1 if at > 84 else 0)
            self.right_tag.to(1 if at < box.width() - 150 else 0)
            left = None
            if self.left_tag.value > 0.01:
                p.setOpacity(self.left_tag.value)
                left = self._tag(p, box, tr("look.none.title"), False, False)
            if self.right_tag.value > 0.01:
                # the title never covers "Original": a long one is cut short with "..." (every language)
                p.setOpacity(self.right_tag.value)
                self._tag(p, box, self.title, True, self.pending, left.right() + 8 if left is not None else None)
            p.setOpacity(1)
        elif self.sweep is None:
            self._tag(p, box, tr("look.none.title"), False, False)

    def _revealed(self, image, target, box):
        """RevealMask: the new picture cut by a wipe from one side or a circle from the face, its edge feathered
        (.blur(radius: 18): about 36 wide)."""
        out = QImage(image.size(), QImage.Format.Format_ARGB32_Premultiplied)
        out.fill(0)
        q = QPainter(out)
        q.drawImage(0, 0, image)
        q.setCompositionMode(QPainter.CompositionMode.CompositionMode_DestinationIn)
        sx, sy = image.width() / target.width(), image.height() / target.height()
        t = self.fade.value
        feather = 36 * sx
        if self.reveal == "iris":
            cx = (box.left() + box.width() * self.origin.x() - target.left()) * sx
            cy = (box.top() + box.height() * self.origin.y() - target.top()) * sy
            far = max(math.hypot(x - cx, y - cy) for x in (0, image.width()) for y in (0, image.height()))
            r = (far + 40 * sx + feather) * t
            g = QRadialGradient(QPointF(cx, cy), max(1.0, r))
            inner = max(0.0, (r - feather) / max(r, 1))
            g.setColorAt(0, QColor(0, 0, 0, 255))
            g.setColorAt(inner, QColor(0, 0, 0, 255))
            g.setColorAt(1, QColor(0, 0, 0, 0))
        else:
            span = (image.width() + 60 * sx + feather) * t
            if self.reveal == "wipe-left":
                edge = -30 * sx + span
                g = QLinearGradient(QPointF(edge - feather, 0), QPointF(edge, 0))
                g.setColorAt(0, QColor(0, 0, 0, 255))
                g.setColorAt(1, QColor(0, 0, 0, 0))
            else:
                edge = image.width() + 30 * sx - span
                g = QLinearGradient(QPointF(edge, 0), QPointF(edge + feather, 0))
                g.setColorAt(0, QColor(0, 0, 0, 0))
                g.setColorAt(1, QColor(0, 0, 0, 255))
        q.fillRect(out.rect(), g)
        q.end()
        return out

    def _material(self, p, box, rect):
        """.ultraThinMaterial: the picture under the capsule, blurred, pulled towards a mid grey
        (measured on the Mac shot: about 0.34 x picture + 44)."""
        src = rect.intersected(box)
        if src.isEmpty():
            return
        target = self._target(box)
        img = QImage(max(1, round(src.width() / 6)), max(1, round(src.height() / 6)), QImage.Format.Format_RGB32)
        img.fill(QColor(30, 30, 34))
        q = QPainter(img)
        q.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        q.scale(img.width() / src.width(), img.height() / src.height())
        q.translate(-src.left(), -src.top())
        q.drawImage(target, self.after or self.before)
        if not self.plain:
            q.setClipRect(QRectF(box.left(), box.top(), box.width() * self.shown_split(), box.height()))
            q.drawImage(target, self.before)
        q.end()
        img = img.scaled(max(1, img.width() // 2), max(1, img.height() // 2), Qt.AspectRatioMode.IgnoreAspectRatio,
                         Qt.TransformationMode.SmoothTransformation)
        p.save()
        p.setClipPath(rounded(rect, rect.height() / 2))
        p.drawImage(rect, img)
        p.fillRect(rect, QColor(67, 67, 71, 168))
        p.restore()

    @staticmethod
    def _knob_y(box):
        return box.bottom() - 54 if box.height() > 108 else box.center().y()

    def _tag(self, p, box, text, right, pending, start=None):
        """Tag / the title capsule (clear glass): 12 semibold white, 26 high, 11 a side, 12 from the corner. A right
        one starts no further left than `start` (or 12 from the left edge): longer text ends in "...". Returns it."""
        f = font(12, SEMIBOLD)
        extra = 22 + (17 if pending else 0)
        room = box.right() - 12 - (start if start is not None else box.left() + 12) if right else box.width() - 24
        width = text_width(f, text) + extra
        if width > room:
            text = QFontMetricsF(f).elidedText(text, Qt.TextElideMode.ElideRight, max(0.0, room - extra))
            width = text_width(f, text) + extra
        height = 26
        x = box.right() - width - 12 if right else box.left() + 12
        rect = QRectF(x, box.top() + 12, width, height)
        self._material(p, box, rect)
        p.setPen(QPen(QColor(255, 255, 255, 18), 0.8))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(rect.adjusted(0.4, 0.4, -0.4, -0.4), height / 2, height / 2)
        tx = rect.left() + 11
        if pending:
            draw_petals(p, QPointF(tx + 5, rect.center().y()), 11)
            tx += 17
        p.setFont(f)
        p.setPen(TEXT)
        p.drawText(QRectF(tx, rect.top(), rect.right() - tx - 11, height), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, text)
        return rect
