"""Cast shadows on faces: shadows with an edge, thrown by something else - a hat brim, hair, a hand, leaves.
(The even-light step, lrcdf/relight.py, only knows the smooth shading of the face's own shape.)
A shadow multiplies the light, so it is taken out by multiplying: a small network (scripts/train_shadow.py) looks at
the face and gives, per pixel and colour, the factor that undoes the shadow. Pores inside the shadow are scaled with
it, as they were when the shadow fell; nothing is painted.
The network learns from shadows painted here onto real faces (after Zhang et al., "Portrait Shadow Manipulation",
2020: there are no photographs of the same face with and without a shadow)."""
import cv2, numpy as np


def _noise(rng, h, w, cells):
    g = rng.standard_normal((max(2, int(cells * h / max(h, w)) + 2), max(2, int(cells * w / max(h, w)) + 2))).astype(np.float32)
    return cv2.resize(g, (w, h), interpolation=cv2.INTER_CUBIC)


def outline(h, w, face, rng):
    """A shadow's shape, 0..1 with a soft rim: an edge across the picture (brim, wall), blobs (a hand, a head),
    strands (hair, twigs) or dappled light (leaves)."""
    kind = rng.choice(["edge", "edge", "blob", "strands", "leaves"])
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    if kind == "edge":
        px, py, t = rng.uniform(0.2, 0.8) * w, rng.uniform(0.2, 0.8) * h, rng.uniform(0, 2 * np.pi)
        along = (xx - px) * -np.sin(t) + (yy - py) * np.cos(t)
        d = (xx - px) * np.cos(t) + (yy - py) * np.sin(t) + rng.uniform(-0.6, 0.6) * along ** 2 / face + face * 0.03 * _noise(rng, h, w, 4)
        s = (d > 0).astype(np.float32)
    elif kind == "blob":
        n = _noise(rng, h, w, rng.uniform(2, 5) * max(h, w) / face)
        s = (n > rng.uniform(0.0, 0.8)).astype(np.float32)
    elif kind == "strands":
        s = np.zeros((h, w), np.float32)
        for _ in range(int(rng.integers(2, 9))):
            p = rng.uniform(-0.2, 1.2, (3, 2)) * (w, h)
            t = np.linspace(0, 1, 40)[:, None]
            curve = (1 - t) ** 2 * p[0] + 2 * t * (1 - t) * p[1] + t ** 2 * p[2]
            cv2.polylines(s, [np.round(curve).astype(np.int32)], False, 1.0, max(1, int(face * rng.uniform(0.01, 0.06))))
    else:
        n = _noise(rng, h, w, rng.uniform(6, 14) * max(h, w) / face)
        s = (n > rng.uniform(-0.3, 0.5)).astype(np.float32)
    rim = face * float(np.exp(rng.uniform(np.log(0.003), np.log(0.04))))
    s = cv2.GaussianBlur(s, (0, 0), max(0.5, rim))
    return s * (0.75 + 0.25 * np.clip(0.5 + 0.5 * _noise(rng, h, w, 3), 0, 1))       # not equally deep everywhere


def cast(img, face, rng):
    """img: float RGB 0..1. Returns (the picture with a shadow painted on, what to multiply by to undo it as a log
    factor h x w x 3 in linear light). The shadow is a little bluer than the light it blocks (sky fills it)."""
    h, w = img.shape[:2]
    s = outline(h, w, face, rng)
    depth = rng.uniform(0.35, 0.8)
    keep = np.clip(depth * np.float32([rng.uniform(0.90, 1.0), 1.0, rng.uniform(1.0, 1.12)]), 0.05, 0.95)
    factor = 1 - s[..., None] * (1 - keep)
    out = (np.clip(img, 0, 1) ** 2.2 * factor) ** (1 / 2.2)
    return out.astype(np.float32), (-np.log(factor)).astype(np.float32)


def guided(guide, src, radius, eps=1e-3):
    """Guided filter (He et al.): src smoothed, but with its edges where the guide (h x w, 0..1) has them. Used to
    carry a factor map made on a small copy of a face to the photo's own resolution without blurring the shadow's rim."""
    k = (2 * int(radius) + 1,) * 2
    box = lambda a: cv2.boxFilter(a, -1, k, borderType=cv2.BORDER_REFLECT)
    mg, mgg = box(guide), box(guide * guide)
    var = mgg - mg * mg
    out = np.empty_like(src)
    for c in range(src.shape[2]):
        ms = box(src[..., c])
        a = (box(guide * src[..., c]) - mg * ms) / (var + eps)
        out[..., c] = box(a) * guide + box(ms - a * mg)
    return out
