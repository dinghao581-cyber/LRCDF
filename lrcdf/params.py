"""Lightroom develop-parameter space shared by labels, model and plugin.

A photo's global edit is a fixed-length vector:
  [wb(2)] + [scalars(S)] + [curves(4*9)]
wb     = (log(T/T_ref), (Tint-Tint_ref)/50). T_ref is the as-shot value when
         known, else 5500/0 (flagged by `has_asshot`).
curves = ToneCurvePV2012 {master,R,G,B} sampled at CURVE_X, stored as (y-x)/255.
"""
import math
import re
import numpy as np

# (crs name, default). All are global sliders that LrC accepts in applyDevelopSettings.
SCALARS = [
    ("Exposure2012", 0), ("Contrast2012", 0), ("Highlights2012", 0), ("Shadows2012", 0),
    ("Whites2012", 0), ("Blacks2012", 0), ("Texture", 0), ("Clarity2012", 0), ("Dehaze", 0),
    ("Vibrance", 0), ("Saturation", 0),
    ("ParametricShadows", 0), ("ParametricDarks", 0), ("ParametricLights", 0), ("ParametricHighlights", 0),
    *[(f"{k}Adjustment{c}", 0) for k in ("Hue", "Saturation", "Luminance")
      for c in ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta")],
    ("ShadowTint", 0), ("RedHue", 0), ("RedSaturation", 0), ("GreenHue", 0),
    ("GreenSaturation", 0), ("BlueHue", 0), ("BlueSaturation", 0),
    ("Sharpness", 40), ("LuminanceSmoothing", 0), ("PostCropVignetteAmount", 0),
]
SCALAR_NAMES = [n for n, _ in SCALARS]
SCALAR_DEFAULTS = np.array([d for _, d in SCALARS], np.float32)
# slider limits used to clamp predictions before writing to Lightroom
LIMITS = {"Exposure2012": (-5, 5), "Sharpness": (0, 150), "LuminanceSmoothing": (0, 100),
          "Texture": (-100, 100)}
CURVES = ["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"]
CURVE_X = np.array([0, 32, 64, 96, 128, 160, 192, 224, 255], np.float32)
N_WB, N_SCALAR, N_CURVE = 2, len(SCALARS), len(CURVES) * len(CURVE_X)
DIM = N_WB + N_SCALAR + N_CURVE
T_DEFAULT, TINT_SCALE = 5500.0, 50.0
# Look settings the model does not predict (colour grading, grain). Derived styles may set them (styles.json "extra"),
# reference-photo mode copies them, and every other run resets them to these neutral values.
EXTRA = {"SplitToningHighlightHue": 0, "SplitToningHighlightSaturation": 0, "SplitToningShadowHue": 0,
         "SplitToningShadowSaturation": 0, "SplitToningBalance": 0, "ColorGradeMidtoneHue": 0, "ColorGradeMidtoneSat": 0,
         "ColorGradeBlending": 50, "GrainAmount": 0, "GrainSize": 25, "GrainFrequency": 50}
EXTRA_HUES = ("SplitToningHighlightHue", "SplitToningShadowHue", "ColorGradeMidtoneHue")
EXTRA_SCALED = ("SplitToningHighlightSaturation", "SplitToningShadowSaturation", "ColorGradeMidtoneSat", "GrainAmount")


def extras(values=None, strength=1.0):
    """Complete EXTRA dict from a partial one; saturations and grain amount follow the style strength."""
    out = dict(EXTRA)
    for k, v in (values or {}).items():
        if k in EXTRA:
            out[k] = int(round(float(v) * (min(strength, 1.5) if k in EXTRA_SCALED else 1)))
    return out

_ATTR = re.compile(r'crs:([A-Za-z0-9]+)="([^"]*)"')
_LI = re.compile(r"<rdf:li>\s*(-?\d+)\s*,\s*(-?\d+)\s*</rdf:li>")


def _spline(px, py, x):
    """Natural cubic spline through control points (what ACR uses), clipped to 0..255."""
    px, py = np.asarray(px, float), np.asarray(py, float)
    n = len(px)
    if n == 2:
        return np.clip(np.interp(x, px, py), 0, 255)
    h = np.diff(px)
    A = np.zeros((n, n)); r = np.zeros(n)
    A[0, 0] = A[-1, -1] = 1
    for i in range(1, n - 1):
        A[i, i - 1], A[i, i], A[i, i + 1] = h[i - 1], 2 * (h[i - 1] + h[i]), h[i]
        r[i] = 6 * ((py[i + 1] - py[i]) / h[i] - (py[i] - py[i - 1]) / h[i - 1])
    m = np.linalg.solve(A, r)
    x = np.clip(np.asarray(x, float), px[0], px[-1])
    i = np.clip(np.searchsorted(px, x, side="right") - 1, 0, n - 2)
    t0, t1 = px[i + 1] - x, x - px[i]
    y = (m[i] * t0**3 + m[i + 1] * t1**3) / (6 * h[i]) \
        + (py[i] / h[i] - m[i] * h[i] / 6) * t0 + (py[i + 1] / h[i] - m[i + 1] * h[i] / 6) * t1
    return np.clip(y, 0, 255)


def parse_xmp(text):
    """-> dict(temp, tint, wb_mode, scalars[S], curves[4,9] as y values 0..255)."""
    a = dict(_ATTR.findall(text))

    def num(k, d):
        try:
            return float(a[k])
        except (KeyError, ValueError):
            return float(d)

    scal = np.array([num(n, d) for n, d in SCALARS], np.float32)
    curves = np.zeros((len(CURVES), len(CURVE_X)), np.float32)
    for ci, tag in enumerate(CURVES):
        m = re.search(rf"<crs:{tag}>\s*<rdf:Seq>(.*?)</rdf:Seq>", text, re.S)
        pts = [(int(x), int(y)) for x, y in _LI.findall(m.group(1))] if m else []
        pts = sorted(dict(pts).items())
        if len(pts) < 2:
            pts = [(0, 0), (255, 255)]
        curves[ci] = _spline([p[0] for p in pts], [p[1] for p in pts], CURVE_X)
    return dict(temp=num("Temperature", float("nan")), tint=num("Tint", float("nan")),
                wb_mode=a.get("WhiteBalance", ""), scalars=scal, curves=curves)


def encode(temp, tint, scalars, curves, t_ref=T_DEFAULT, tint_ref=0.0):
    wb = [math.log(temp / t_ref), (tint - tint_ref) / TINT_SCALE]
    return np.concatenate([wb, scalars, ((curves - CURVE_X) / 255.0).ravel()]).astype(np.float32)


def decode(vec, t_ref=T_DEFAULT, tint_ref=0.0, strength=1.0):
    """Vector -> Lightroom develop-settings dict. `strength` scales the edit toward neutral."""
    vec = np.asarray(vec, np.float64)
    neutral = np.concatenate([[0, 0], SCALAR_DEFAULTS, np.zeros(N_CURVE)])
    vec = neutral + strength * (vec - neutral)
    out = {"WhiteBalance": "Custom",
           "Temperature": int(round(min(50000, max(2000, t_ref * math.exp(vec[0]))))),
           "Tint": int(round(min(150, max(-150, tint_ref + vec[1] * TINT_SCALE))))}
    for name, v in zip(SCALAR_NAMES, vec[N_WB:N_WB + N_SCALAR]):
        lo, hi = LIMITS.get(name, (-100, 100))
        v = min(hi, max(lo, v))
        out[name] = round(float(v), 2) if name == "Exposure2012" else int(round(v))
    cur = vec[N_WB + N_SCALAR:].reshape(len(CURVES), -1) * 255.0 + CURVE_X
    for tag, ys in zip(CURVES, cur):
        ys = np.maximum.accumulate(np.clip(np.round(ys), 0, 255))  # keep monotone
        out[tag] = [int(v) for xy in zip(CURVE_X, ys) for v in xy]
    return out
