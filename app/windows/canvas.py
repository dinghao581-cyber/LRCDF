"""CompareView of Views.swift: the original left of a draggable divider, the result right of it; zoom by wheel,
pinch, buttons and double click, drag a zoomed picture to move it."""
from PySide6.QtCore import QEasingCurve, QEvent, QPointF, QRectF, QSize, Qt, QTimer, QVariantAnimation, Signal
from PySide6.QtGui import QColor, QCursor, QFontMetricsF, QImage, QPainter, QPen
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
        self._old = None                 # the picture being faded out
        self.fade = Tween(1, self.update, self, 300, QEasingCurve.Type.InOutQuad)
        self._move = QVariantAnimation(self)
        self._move.valueChanged.connect(self._moving)
        self._from = self._to = None

    # ------------------------------------------------------------ state
    def set_picture(self, key, before, after, title, plain, pending, faces=()):
        if key != self.photo_key:
            self.photo_key = key
            self.split = 0.5
            self._move.stop()
            self.zoom, self.centre, self.face = 1.0, QPointF(0.5, 0.5), None
            self._old = None
            self.fade.to(1, animate=False)
        elif after is not self.after and self.after is not None and after is not None:
            # a new render of the same photo: easeInOut 0.3 crossfade, as `pictures[key] = image` does
            self._old = self.after
            self.fade.to(0, animate=False)
            self.fade.to(1, 300)
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
    @staticmethod
    def _normal(point, box):
        return QPointF((point.x() - box.left()) / box.width(), (point.y() - box.top()) / box.height())

    def _on_line(self, point, box):
        return not self.plain and abs(point.x() - (box.left() + box.width() * self.split)) < 26

    def mousePressEvent(self, event):
        if self.sweep is not None:
            return
        box = self.picture_rect()
        if event.button() != Qt.MouseButton.LeftButton or not box.contains(event.position()):
            return
        p = event.position()
        self._move.stop()
        if self._on_line(p, box) or (not self.plain and self.zoom <= 1.01):
            self._drag = "split", p, self.centre
        elif self.zoom > 1.01:
            self._drag = "pan", p, self.centre
            self.setCursor(Qt.CursorShape.ClosedHandCursor)

    def mouseMoveEvent(self, event):
        box = self.picture_rect()
        if box.isEmpty() or self.sweep is not None:
            return
        p = event.position()
        if self._drag:
            kind, start, centre = self._drag
            if kind == "split":
                self.split = max(0.0, min(1.0, self._normal(p, box).x()))
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

    def mouseReleaseEvent(self, event):
        if self._drag and self._drag[0] == "pan":
            self.setCursor(Qt.CursorShape.OpenHandCursor)
        self._drag = None

    def mouseDoubleClickEvent(self, event):
        if self.sweep is not None:
            return
        box = self.picture_rect()
        if box.contains(event.position()) and event.button() == Qt.MouseButton.LeftButton:
            self._drag = None
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
                if box.contains(QPointF(point)):
                    self.magnify(pinch.scaleFactor() / pinch.lastScaleFactor(), self._normal(QPointF(point), box), animate=False)
                    event.accept(pinch)
                    return True
        if event.type() == QEvent.Type.NativeGesture and event.gestureType() == Qt.NativeGestureType.ZoomNativeGesture:
            box = self.picture_rect()
            if box.contains(event.position()):
                self.magnify(1 + event.value(), self._normal(event.position(), box), animate=False)
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
        p.save()
        p.setClipPath(rounded(box, 14))
        target = self._target(box)
        after = self.after or self.before
        ratio = self.devicePixelRatioF()

        def pic(img):
            # whole picture shown: a properly scaled copy; zoomed in: the full-size one
            return smooth(img, target.width(), target.height(), ratio) if self.zoom < 1.5 else img
        if self._old is not None and self.fade.value < 1:
            p.drawImage(target, pic(self._old))
            p.setOpacity(self.fade.value)
        p.drawImage(target, pic(after))
        p.setOpacity(1)
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
        p.drawRoundedRect(box.adjusted(0.5, 0.5, -0.5, -0.5), 14, 14)
        if not self.plain:
            line = QRectF(split_x - 0.75, box.top(), 1.5, box.height())
            paint_shadow(p, line, 0, 3, black(0.5))
            p.fillRect(line, QColor(255, 255, 255))
            if self.sweep is not None:
                return
            knob = QRectF(split_x - 17, box.center().y() - 17, 34, 34)
            paint_shadow(p, knob, 17, 6, black(0.45), 2)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 255, 255))
            p.drawEllipse(knob)
            icons.chevrons(p, QRectF(knob.center().x() - 6, knob.center().y() - 6, 12, 12), black(0.75), 0.15)
            left = self._tag(p, box, tr("look.none.title"), False, False) if self.split > 0.14 else None
            if self.split < 0.86:
                # the title never covers "Original": a long one is cut short with "..." (every language)
                self._tag(p, box, self.title, True, self.pending, left.right() + 8 if left is not None else None)
        elif self.sweep is None:
            self._tag(p, box, tr("look.none.title"), False, False)

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

    def _tag(self, p, box, text, right, pending, start=None):
        """Tag / the title capsule: 12 semibold, 10 x 5 padding, 14 from the corner. A right one starts no further
        left than `start` (or 14 from the left edge): longer text ends in "...". Returns the capsule."""
        f = font(12, SEMIBOLD)
        extra = 20 + (16 if pending else 0)
        room = box.right() - 14 - (start if start is not None else box.left() + 14) if right else box.width() - 28
        width = text_width(f, text) + extra
        if width > room:
            text = QFontMetricsF(f).elidedText(text, Qt.TextElideMode.ElideRight, max(0.0, room - extra))
            width = text_width(f, text) + extra
        height = 25
        x = box.right() - width - 14 if right else box.left() + 14
        rect = QRectF(x, box.top() + 14, width, height)
        self._material(p, box, rect)
        p.setPen(QPen(QColor(255, 255, 255, 18), 0.8))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(rect.adjusted(0.4, 0.4, -0.4, -0.4), height / 2, height / 2)
        tx = rect.left() + 10
        if pending:
            draw_petals(p, QPointF(tx + 5, rect.center().y()), 11)
            tx += 16
        p.setFont(f)
        p.setPen(TEXT)
        p.drawText(QRectF(tx, rect.top(), rect.right() - tx - 10, height), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft, text)
        return rect
