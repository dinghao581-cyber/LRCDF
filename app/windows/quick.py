"""An immediate, approximate picture of a tweak and the colour wheels, shown until Lightroom's own render arrives
(that one takes about ten seconds). A line-by-line translation of the Mac app's Quick.swift (second version,
DESIGN.md 7 "instant approximation", the same numbers on all three): gains in linear light, then green-pink as a 3 x 3 table in
linear light, saturation around the luminance, contrast around mid-grey, then split toning as one curve per channel
on the encoded value."""
import colorsys
from collections import OrderedDict

import numpy as np
from PySide6.QtGui import QColorSpace, QImage


_SRGB = QColorSpace(QColorSpace.NamedColorSpace.SRgb)
_F = np.float32

# The same linear-light and output tables, and the same gains as Quick.swift.
_s = np.arange(256, dtype=np.float32) / _F(255)
_TO_LINEAR = np.where(_s <= _F(.04045), _s / _F(12.92), ((_s + _F(.055)) / _F(1.055)) ** _F(2.4))
_l = np.arange(4097, dtype=np.float32) / _F(4096)
_TO_SRGB = np.where(_l <= _F(.0031308), _F(12.92) * _l, _F(1.055) * _l ** _F(1 / 2.4) - _F(.055))

# Split toning: a shape over the channel's own encoded value (25 points, 0 ... 1, straight lines between) times a
# factor per channel = table x the pure colour of the hue x amount / 100. Green-pink: out = in + T x (table x in)
# on linear sRGB. All numbers copied from Quick.swift (DESIGN.md 7).
SHADOW_SHAPE = np.array([0.673, 0.775, 0.908, 0.999, 0.983, 1.0, 0.972, 0.898, 0.793, 0.694, 0.59, 0.501, 0.426,
                         0.365, 0.315, 0.275, 0.24, 0.204, 0.17, 0.135, 0.104, 0.076, 0.051, 0.025, 0.01], dtype=np.float32)
HIGH_SHAPE = np.array([0.01, 0.011, 0.014, 0.022, 0.03, 0.051, 0.081, 0.111, 0.139, 0.177, 0.221, 0.258, 0.306,
                       0.377, 0.457, 0.551, 0.649, 0.759, 0.856, 0.953, 1.0, 0.972, 0.867, 0.611, 0.403], dtype=np.float32)
SHADOW_TABLE = np.array([[0.1148, -0.1184, -0.0127], [-0.0529, 0.049, -0.0017], [-0.029, -0.0831, 0.0996]], dtype=np.float32)
HIGH_TABLE = np.array([[0.106, -0.1039, -0.0093], [-0.0554, 0.0542, -0.0008], [-0.0278, -0.0866, 0.1183]], dtype=np.float32)
TINT_TABLE = np.array([[0.0569, -0.0633, 0.0079], [-0.0236, 0.0646, -0.0435], [-0.0019, 0.0684, -0.0492]], dtype=np.float32)

NO_WHEELS = (0.0, None, None)
NO_OWN = ((0, 0), (0, 0))


def factors(zone, table):
    """The factor of each channel's curve for a (hue, amount) point (Quick.swift `factors`)."""
    hue, amount = zone
    if amount <= 0:
        return np.zeros(3, dtype=np.float32)
    rgb = np.array(colorsys.hsv_to_rgb((hue % 360) / 360, 1, 1), dtype=np.float32)
    return (table @ rgb) * _F(amount / 100)


def wash(zone, own, table):
    """A wheel that was set replaces what the look has there: the difference between the two (`wash`)."""
    change = factors(zone, table) - factors(own, table)
    return None if not change.any() else change


def shape(table, values):
    """The curve at each value: 0 ... 1 mapped onto 24 steps, straight lines between (`shape`)."""
    at = np.clip(values, 0, 1) * _F(24)
    i = np.minimum(at.astype(np.int32), 23)
    return table[i] + (table[i + 1] - table[i]) * (at - i)


class Quick:
    def __init__(self):
        self._images = OrderedDict()

    def forget(self):
        self._images.clear()

    def picture(self, source: QImage, key, tweak, wheels=NO_WHEELS, own=NO_OWN) -> QImage:
        """`tweak` (bright, warm, rich) -2 ... 2; `wheels` (tint -2 ... 2, shadow (hue, amount) or None, high ...);
        `own` the look's own (shadow, high) split toning, which a set wheel replaces."""
        cache_key = (key, tuple(tweak), tuple(wheels), tuple(own), source.cacheKey())
        if cache_key in self._images:
            return self._images[cache_key]
        # This interim image is displayed at screen size. The actual Lightroom
        # preview replaces it and retains the full rendered resolution.
        result = self._apply(source, tweak, wheels, own)
        self._images[cache_key] = result
        if len(self._images) > 8:
            self._images.popitem(last=False)
        return result

    @staticmethod
    def rgb(source):
        if source.colorSpace().isValid() and source.colorSpace() != _SRGB:
            source = source.convertedToColorSpace(_SRGB)
        source = source.convertToFormat(QImage.Format.Format_RGB888)
        w, h = source.width(), source.height()
        return np.ndarray((h, w, 3), dtype=np.uint8, buffer=source.constBits(), strides=(source.bytesPerLine(), 3, 1)).copy()

    @staticmethod
    def apply_array(rgb, tweak, wheels=NO_WHEELS, own=NO_OWN):
        """The approximation on an 8-bit RGB array (also used to compare with the Mac numbers)."""
        bright, warm, rich = map(_F, tweak)
        tint, shadow_zone, high_zone = wheels
        tint = _F(tint)
        gains = np.exp2(np.array([
            _F(.162) * bright + _F(.070) * warm - _F(.012) * rich,
            _F(.158) * bright + _F(.026) * warm - _F(.012) * rich,
            _F(.150) * bright - _F(.025) * warm - _F(.013) * rich,
        ], dtype=np.float32))
        shadow = wash(shadow_zone, own[0], SHADOW_TABLE) if shadow_zone is not None else None
        high = wash(high_zone, own[1], HIGH_TABLE) if high_zone is not None else None
        saturation = _F(1) + _F(.095) * rich
        contrast = _F(1) - _F(.055) * bright + _F(.016) * rich
        r, g, b = [(_TO_LINEAR * gain)[rgb[:, :, channel]] for channel, gain in enumerate(gains)]
        if tint != 0:        # tint moves the channels into one another: a table, not three gains
            m = TINT_TABLE * tint
            r, g, b = (r + m[0, 0] * r + m[0, 1] * g + m[0, 2] * b,
                       g + m[1, 0] * r + m[1, 1] * g + m[1, 2] * b,
                       b + m[2, 0] * r + m[2, 1] * g + m[2, 2] * b)
        luma = r * _F(.2126) + g * _F(.7152) + b * _F(.0722)
        output = np.empty(rgb.shape, dtype=np.uint8)
        for channel, plane in enumerate((r, g, b)):
            plane = luma + saturation * (plane - luma)
            index = (np.clip(plane, 0, 1) * _F(4096)).astype(np.int32)
            values = _F(.5) + contrast * (_TO_SRGB[index] - _F(.5))
            if shadow is not None:
                values = values + shape(SHADOW_SHAPE, values) * shadow[channel]
            if high is not None:
                values = values + shape(HIGH_SHAPE, values) * high[channel]
            output[:, :, channel] = np.clip(values * _F(255) + _F(.5), 0, 255).astype(np.uint8)
        return output

    @staticmethod
    def _apply(source, tweak, wheels=NO_WHEELS, own=NO_OWN):
        output = Quick.apply_array(Quick.rgb(source), tweak, wheels, own)
        h, w = output.shape[:2]
        picture = QImage(output.data, w, h, output.strides[0], QImage.Format.Format_RGB888).copy()
        picture.setColorSpace(_SRGB)
        return picture
