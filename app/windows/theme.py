"""Colours, fonts, soft shadows and small animation helpers, copied from Views.swift (Palette)."""
import os
from pathlib import Path

# FreeType draws text the Mac way (grey-scale anti-aliasing, no hinting); the default DirectWrite engine uses
# ClearType's coloured fringes. Must be set before the QApplication exists, i.e. on import.
os.environ.setdefault("QT_QPA_PLATFORM", "windows:fontengine=freetype")

import numpy as np
from PySide6.QtCore import QEasingCurve, QObject, QPointF, QRectF, Qt, QVariantAnimation
from PySide6.QtGui import QColor, QFont, QFontDatabase, QImage, QPainter, QPainterPath

from .i18n import LANGUAGE

INK = QColor(14, 14, 17)                 # Palette.ink   0.055 0.055 0.065
PANEL = QColor(24, 24, 28)               # Palette.panel 0.095 0.095 0.11
FOCUS = QColor(255, 214, 10)             # DS.focus #FFD60A (1.0 0.84 0.04): the one colour, only for "chosen" / "look here"
TEXT = QColor(239, 239, 243)             # .primary on the dark window (measured on the Mac shot)
LINK = QColor(65, 156, 255)              # macOS link colour, dark appearance


def white(alpha):
    return QColor(255, 255, 255, round(255 * alpha))


def black(alpha):
    return QColor(0, 0, 0, round(255 * alpha))


LINE = white(0.08)                       # Palette.line
SOFT = white(0.55)                       # Palette.soft


def css(color):
    return f"rgba({color.red()},{color.green()},{color.blue()},{color.alpha()})"


# ---------------------------------------------------------------- fonts
# PingFang SC (the Mac font) is closest to Noto Sans SC / Source Han Sans; Windows 11 ships it as a variable font,
# so every weight of the Mac design can be matched. A copy next to the app covers machines without it.
_FAMILY = None
REGULAR, MEDIUM, SEMIBOLD, BOLD, LIGHT = 400, 500, 600, 700, 300


# The Noto Sans of the UI language, so Han characters take that language's shapes (Japanese and Traditional
# Chinese differ from Simplified); Windows 11 ships SC and KR, fonts/ brings the rest. Without it: the system font.
_NOTO = {"ja": ("Noto Sans JP", "NotoSansJP-VF.ttf", "Yu Gothic UI"),
         "zh-TW": ("Noto Sans TC", "NotoSansTC-VF.ttf", "Microsoft JhengHei UI"),
         "ko": ("Noto Sans KR", "NotoSansKR-VF.ttf", "Malgun Gothic")}


def family():
    global _FAMILY
    if _FAMILY is None:
        name, file, fallback = _NOTO.get(LANGUAGE, ("Noto Sans SC", "NotoSansSC-VF.ttf", "Microsoft YaHei UI"))
        families = set(QFontDatabase.families())
        if name not in families:
            bundled = Path(__file__).with_name("fonts") / file
            if bundled.exists():
                QFontDatabase.addApplicationFont(str(bundled))
                families = set(QFontDatabase.families())
        _FAMILY = name if name in families else fallback
    return _FAMILY


CJK = LANGUAGE in ("zh-CN", "zh-TW", "ja", "ko")


_SERIF = None


def serif_family():
    """The face of the few words that name things (DS.display: Songti SC bold on the Mac): Noto Serif SC, which
    Windows 11 ships (Noto Serif KR for Korean when it is there). "" when the system has neither (Windows 10)."""
    global _SERIF
    if _SERIF is None:
        families = set(QFontDatabase.families())
        wanted = ["Noto Serif KR", "Noto Serif SC"] if LANGUAGE == "ko" else ["Noto Serif SC"]
        _SERIF = next((name for name in wanted if name in families), "")
    return _SERIF


def display(size):
    """DS.display(size): the serif at 600 (Songti SC's bold looks this weight); the UI face in bold without it."""
    family_name = serif_family()
    if not family_name:
        return font(size, BOLD)
    f = QFont(family_name)
    f.setPixelSize(round(size))
    f.setHintingPreference(QFont.HintingPreference.PreferNoHinting)
    f.setStyleStrategy(QFont.StyleStrategy(QFont.StyleStrategy.PreferAntialias | QFont.StyleStrategy.NoSubpixelAntialias))
    f.setVariableAxis(QFont.Tag("wght"), 600)
    f.setWeight(QFont.Weight.DemiBold)
    return f


def font(size, weight=REGULAR, *, digits=False):
    f = QFont(family())
    f.setPixelSize(round(size))
    f.setHintingPreference(QFont.HintingPreference.PreferNoHinting)
    f.setStyleStrategy(QFont.StyleStrategy(QFont.StyleStrategy.PreferAntialias | QFont.StyleStrategy.NoSubpixelAntialias))
    if family().startswith("Noto Sans"):
        # macOS thickens strokes when it renders; a little more weight gives the same colour of text
        f.setVariableAxis(QFont.Tag("wght"), weight + (60 if weight <= 500 else 30 if weight < 700 else 0))
    else:
        f.setWeight(QFont.Weight(weight))
    if digits:
        f.setFeature(QFont.Tag("tnum"), 1)
    if not CJK:
        # Noto Sans SC sets quotes and "·" a full em wide (Chinese style); other languages want them narrow
        f.setFeature(QFont.Tag("pwid"), 1)
    return f


# ---------------------------------------------------------------- shadows
_SHADOWS = {}


def _blur(alpha, sigma):
    if sigma <= 0:
        return alpha
    r = int(sigma * 3)
    x = np.arange(-r, r + 1, dtype=np.float32)
    k = np.exp(-x * x / (2 * sigma * sigma))
    k /= k.sum()
    pad = np.pad(alpha, r, mode="constant")
    rows = np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), 1, pad)
    return np.apply_along_axis(lambda m: np.convolve(m, k, mode="valid"), 0, rows)


def shadow_image(w, h, corner, radius, color):
    """A SwiftUI .shadow(color, radius): the shape blurred (radius ~ 2 sigma), returned with its margin."""
    key = (round(w), round(h), corner, radius, color.rgba())
    hit = _SHADOWS.get(key)
    if hit is not None:
        return hit
    sigma = radius / 2
    m = int(radius * 1.6) + 2
    scale = 0.5 if max(w, h) > 120 else 1.0          # blur a half-size copy of big shapes; looks the same
    W, H = int((w + 2 * m) * scale), int((h + 2 * m) * scale)
    mask = QImage(W, H, QImage.Format.Format_Grayscale8)
    mask.fill(0)
    p = QPainter(mask)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(QColor(255, 255, 255))
    p.drawRoundedRect(QRectF(m * scale, m * scale, w * scale, h * scale), corner * scale, corner * scale)
    p.end()
    ptr = mask.constBits()
    a = np.frombuffer(ptr, np.uint8, mask.bytesPerLine() * H).reshape(H, mask.bytesPerLine())[:, :W].astype(np.float32) / 255
    a = _blur(a, sigma * scale) * color.alphaF()
    out = np.zeros((H, W, 4), np.uint8)
    out[..., 0], out[..., 1], out[..., 2] = color.blue(), color.green(), color.red()
    out[..., 3] = np.clip(a * 255, 0, 255).astype(np.uint8)
    img = QImage(out.data, W, H, W * 4, QImage.Format.Format_ARGB32).copy()
    if scale != 1:
        img = img.scaled(int(w + 2 * m), int(h + 2 * m), Qt.AspectRatioMode.IgnoreAspectRatio,
                         Qt.TransformationMode.SmoothTransformation)
    _SHADOWS[key] = (img, m)
    if len(_SHADOWS) > 200:
        _SHADOWS.pop(next(iter(_SHADOWS)))
    return img, m


def paint_shadow(p, rect, corner, radius, color, dy=0.0):
    img, m = shadow_image(rect.width(), rect.height(), corner, radius, color)
    p.drawImage(QPointF(rect.left() - m, rect.top() - m + dy), img)


def rounded(rect, r):
    path = QPainterPath()
    path.addRoundedRect(rect, r, r)
    return path


# ---------------------------------------------------------------- animation
class Tween(QObject):
    """One animated number. `value` follows `to(...)`; `step` is called on every frame."""

    def __init__(self, value, step, parent=None, duration=200, curve=QEasingCurve.Type.OutCubic):
        super().__init__(parent)
        self.value = float(value)
        self.target = float(value)
        self._step = step
        self._anim = QVariantAnimation(self)
        self._anim.setDuration(duration)
        self._anim.setEasingCurve(curve)
        self._anim.valueChanged.connect(self._changed)

    def _changed(self, v):
        self.value = float(v)
        self._step()

    def to(self, target, duration=None, animate=True):
        target = float(target)
        if target == self.target and (self._anim.state() == QVariantAnimation.State.Running or self.value == target):
            return
        self.target = target
        self._anim.stop()
        if not animate:
            self.value = target
            self._step()
            return
        if duration is not None:
            self._anim.setDuration(duration)
        self._anim.setStartValue(self.value)
        self._anim.setEndValue(target)
        self._anim.start()


def mix(a, b, t):
    return QColor(round(a.red() + (b.red() - a.red()) * t), round(a.green() + (b.green() - a.green()) * t),
                  round(a.blue() + (b.blue() - a.blue()) * t), round(a.alpha() + (b.alpha() - a.alpha()) * t))
