"""The few SF Symbols the Mac app uses, drawn as vector paths so they stay sharp at any scale.

Each function paints into `rect` (a square) with `brush` (a colour); `weight` follows the
symbol weights in Views.swift (light, medium, bold).
"""
import math

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QBrush, QPainterPath, QPen

LIGHT, REGULAR, MEDIUM, BOLD = 0.055, 0.075, 0.09, 0.12   # stroke width as a share of the symbol size


def _pen(brush, width):
    pen = QPen(QBrush(brush), width)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    return pen


def _star(cx, cy, r, waist=0.16):
    """The four-pointed sparkle: concave sides like the SF 'sparkles' glyph."""
    path = QPainterPath(QPointF(cx, cy - r))
    for i in range(4):
        a0 = -math.pi / 2 + i * math.pi / 2
        a1 = a0 + math.pi / 2
        tip = QPointF(cx + r * math.cos(a1), cy + r * math.sin(a1))
        ctrl = QPointF(cx + r * waist * math.cos(a0 + math.pi / 4) * 1.4, cy + r * waist * math.sin(a0 + math.pi / 4) * 1.4)
        path.quadTo(ctrl, tip)
    path.closeSubpath()
    return path


def sparkles(p, rect, brush, weight=LIGHT):
    s = rect.width()
    x, y = rect.left(), rect.top()
    path = _star(x + s * 0.40, y + s * 0.58, s * 0.40)
    path.addPath(_star(x + s * 0.80, y + s * 0.22, s * 0.17))
    path.addPath(_star(x + s * 0.80, y + s * 0.84, s * 0.12))
    p.setPen(_pen(brush, s * weight * 0.9))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawPath(path)


def circle(p, rect, brush, weight=LIGHT):
    s = rect.width()
    w = s * weight
    p.setPen(_pen(brush, w))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawEllipse(rect.adjusted(w / 2 + s * 0.02, w / 2 + s * 0.02, -w / 2 - s * 0.02, -w / 2 - s * 0.02))


def check_circle_fill(p, rect, brush, background):
    s = rect.width()
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(brush))
    p.drawEllipse(rect.adjusted(s * 0.02, s * 0.02, -s * 0.02, -s * 0.02))
    p.setPen(_pen(background, s * 0.085))
    path = QPainterPath(QPointF(rect.left() + s * 0.30, rect.top() + s * 0.52))
    path.lineTo(rect.left() + s * 0.44, rect.top() + s * 0.66)
    path.lineTo(rect.left() + s * 0.71, rect.top() + s * 0.36)
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawPath(path)


def pause_circle(p, rect, brush, weight=LIGHT):
    circle(p, rect, brush, weight)
    s = rect.width()
    p.setPen(_pen(brush, s * weight * 1.1))
    for dx in (-0.09, 0.09):
        x = rect.center().x() + s * dx
        p.drawLine(QPointF(x, rect.top() + s * 0.34), QPointF(x, rect.top() + s * 0.66))


def undo_circle(p, rect, brush, weight=LIGHT):
    circle(p, rect, brush, weight)
    s = rect.width()
    x, y = rect.left(), rect.top()
    p.setPen(_pen(brush, s * weight * 1.1))
    path = QPainterPath(QPointF(x + s * 0.36, y + s * 0.42))
    path.lineTo(x + s * 0.58, y + s * 0.42)
    path.arcTo(QRectF(x + s * 0.44, y + s * 0.42, s * 0.26, s * 0.26), 90, -180)
    path.lineTo(x + s * 0.42, y + s * 0.68)
    p.drawPath(path)
    head = QPainterPath(QPointF(x + s * 0.44, y + s * 0.33))
    head.lineTo(x + s * 0.35, y + s * 0.42)
    head.lineTo(x + s * 0.44, y + s * 0.51)
    p.drawPath(head)


def warning(p, rect, brush, weight=LIGHT):
    s = rect.width()
    x, y = rect.left(), rect.top()
    p.setPen(_pen(brush, s * weight))
    p.setBrush(Qt.BrushStyle.NoBrush)
    path = QPainterPath(QPointF(x + s * 0.5, y + s * 0.08))
    path.lineTo(x + s * 0.96, y + s * 0.90)
    path.lineTo(x + s * 0.04, y + s * 0.90)
    path.closeSubpath()
    p.drawPath(path)
    p.drawLine(QPointF(x + s * 0.5, y + s * 0.38), QPointF(x + s * 0.5, y + s * 0.62))
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(brush))
    p.drawEllipse(QPointF(x + s * 0.5, y + s * 0.76), s * weight * 0.8, s * weight * 0.8)


def exclamation_circle(p, rect, brush, weight=REGULAR):
    circle(p, rect, brush, weight)
    s = rect.width()
    c = rect.center()
    p.setPen(_pen(brush, s * weight * 1.1))
    p.drawLine(QPointF(c.x(), rect.top() + s * 0.27), QPointF(c.x(), rect.top() + s * 0.57))
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(brush))
    p.drawEllipse(QPointF(c.x(), rect.top() + s * 0.73), s * 0.06, s * 0.06)


def face_smiling(p, rect, brush, background):
    """SF 'face.smiling' in a medium weight: a filled disc with the eyes and mouth cut out of it."""
    s = rect.width()
    x, y = rect.left(), rect.top()
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(brush))
    p.drawEllipse(rect.adjusted(s * 0.04, s * 0.04, -s * 0.04, -s * 0.04))
    p.setBrush(QBrush(background))
    for ex in (0.36, 0.64):
        p.drawEllipse(QRectF(x + s * (ex - 0.055), y + s * 0.30, s * 0.11, s * 0.16))
    pen = _pen(background, s * 0.085)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawArc(QRectF(x + s * 0.29, y + s * 0.38, s * 0.42, s * 0.30), 200 * 16, 140 * 16)


def minus(p, rect, brush, weight=BOLD):
    s = rect.width()
    c = rect.center()
    p.setPen(_pen(brush, s * weight))
    p.drawLine(QPointF(c.x() - s * 0.36, c.y()), QPointF(c.x() + s * 0.36, c.y()))


def plus(p, rect, brush, weight=BOLD):
    minus(p, rect, brush, weight)
    s = rect.width()
    c = rect.center()
    p.drawLine(QPointF(c.x(), c.y() - s * 0.36), QPointF(c.x(), c.y() + s * 0.36))


def xmark(p, rect, brush, weight=BOLD):
    s = rect.width()
    c = rect.center()
    d = s * 0.32
    p.setPen(_pen(brush, s * weight))
    p.drawLine(QPointF(c.x() - d, c.y() - d), QPointF(c.x() + d, c.y() + d))
    p.drawLine(QPointF(c.x() - d, c.y() + d), QPointF(c.x() + d, c.y() - d))


def chevrons(p, rect, brush, weight=BOLD):
    """'chevron.left.chevron.right'."""
    s = rect.width()
    c = rect.center()
    p.setPen(_pen(brush, s * weight))
    p.setBrush(Qt.BrushStyle.NoBrush)
    for d in (-1, 1):
        path = QPainterPath(QPointF(c.x() + d * s * 0.12, c.y() - s * 0.26))
        path.lineTo(c.x() + d * s * 0.40, c.y())
        path.lineTo(c.x() + d * s * 0.12, c.y() + s * 0.26)
        p.drawPath(path)


def cup(p, rect, brush, weight=REGULAR):
    s = rect.width()
    x, y = rect.left(), rect.top()
    p.setPen(_pen(brush, s * weight))
    p.setBrush(Qt.BrushStyle.NoBrush)
    body = QPainterPath(QPointF(x + s * 0.14, y + s * 0.30))
    body.lineTo(x + s * 0.70, y + s * 0.30)
    body.lineTo(x + s * 0.66, y + s * 0.66)
    body.quadTo(x + s * 0.64, y + s * 0.74, x + s * 0.56, y + s * 0.74)
    body.lineTo(x + s * 0.28, y + s * 0.74)
    body.quadTo(x + s * 0.20, y + s * 0.74, x + s * 0.18, y + s * 0.66)
    body.closeSubpath()
    p.drawPath(body)
    p.drawArc(QRectF(x + s * 0.60, y + s * 0.36, s * 0.24, s * 0.20), -90 * 16, 180 * 16)
    p.drawLine(QPointF(x + s * 0.06, y + s * 0.86), QPointF(x + s * 0.80, y + s * 0.86))


def question(p, rect, brush, weight=REGULAR):
    circle(p, rect, brush, weight)
    s = rect.width()
    x, y = rect.left(), rect.top()
    p.setPen(_pen(brush, s * weight * 1.1))
    path = QPainterPath(QPointF(x + s * 0.37, y + s * 0.38))
    path.arcTo(QRectF(x + s * 0.37, y + s * 0.24, s * 0.26, s * 0.24), 180, -230)
    path.quadTo(x + s * 0.50, y + s * 0.52, x + s * 0.50, y + s * 0.60)
    p.drawPath(path)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QBrush(brush))
    p.drawEllipse(QPointF(x + s * 0.5, y + s * 0.74), s * 0.05, s * 0.05)


def gear(p, rect, brush, weight=REGULAR):
    """SF 'gearshape': eight square-ish teeth round a ring, a hole in the middle; outlined."""
    s = rect.width()
    c = rect.center()
    outer, inner, hole = s * 0.48, s * 0.36, s * 0.15
    path = QPainterPath()
    teeth = 8
    for i in range(teeth * 4):
        a = (i / (teeth * 4)) * 2 * math.pi - math.pi / 2 - math.pi / (teeth * 4)
        r = outer if i % 4 in (1, 2) else inner
        point = QPointF(c.x() + r * math.cos(a), c.y() + r * math.sin(a))
        if i == 0:
            path.moveTo(point)
        else:
            path.lineTo(point)
    path.closeSubpath()
    p.setPen(_pen(brush, s * weight))
    p.setBrush(Qt.BrushStyle.NoBrush)
    p.drawPath(path)
    p.drawEllipse(c, hole, hole)

