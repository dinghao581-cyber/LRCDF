"""Relighting in the colour layer: the light on a face is estimated from the picture and the face's shape, and made
more even - the side in shadow is lifted, the lit side comes down a little - without touching the texture layer.
The method is the classic "ratio image": skin brightness = reflectance x shading, where the shading of a matte
surface under distant light is a low-order function of the surface direction (9 spherical-harmonic terms). The face
mesh (MediaPipe, 478 points with depth) gives the surface directions; a robust least-squares fit on skin gives the
light; the picture is multiplied by new shading / old shading, which is smooth. Nothing is learnt and no outside
model is used.
What it cannot do: cast shadows with an edge (nose, hat brim, hair) are not part of this model and stay; the neck
and ears are outside the mesh and keep their light (the change fades out towards the outline of the face)."""
import cv2, numpy as np
from scipy.interpolate import LinearNDInterpolator

WORK = 160          # the light is estimated on a copy where the face is about this many pixels wide
LIMIT = (0.72, 1.45)    # the shading ratio never leaves this range


def directions(shape, pts, z, f):
    """Surface directions over the face. shape: (h, w) of the crop; pts [478,2] in crop pixels, z [478] depth in the
    same unit (smaller = nearer); f: face width in pixels. Returns (normals [hs,ws,3], inside-the-mesh mask [hs,ws],
    scale of the small grid)."""
    g = min(1.0, WORK / f)
    hs, ws = max(8, int(shape[0] * g)), max(8, int(shape[1] * g))
    yy, xx = np.mgrid[0:hs, 0:ws].astype(np.float32)
    depth = LinearNDInterpolator(pts * g, z * g)(xx, yy).astype(np.float32)
    inside = np.isfinite(depth).astype(np.float32)
    depth = np.nan_to_num(depth)
    s = max(1.0, f * g * 0.035)                  # the mesh is faceted and jitters: smooth it (normalised, so the rim holds)
    depth = cv2.GaussianBlur(depth * inside, (0, 0), s) / np.maximum(cv2.GaussianBlur(inside, (0, 0), s), 1e-3)
    gy, gx = np.gradient(depth)
    n = np.dstack([gx, gy, np.ones_like(gx)])
    return n / np.linalg.norm(n, axis=2, keepdims=True), inside, g


def basis(n):
    x, y, z = n[..., 0], n[..., 1], n[..., 2]
    return np.stack([np.ones_like(x), x, y, z, x * y, x * z, y * z, x * x - y * y, 3 * z * z - 1], -1)


SIDE_TERMS = (1, 4, 5)      # change sign when the light moves to the other side
UP_TERMS = (2, 6)           # change sign when the light moves from above to below


def even(low, pts, z, f, skin, amount, debug=None, where=None):
    """low: float RGB 0..1 colour layer of a face crop (h,w,3); skin: 0..1 where the fit may look (skin without eyes,
    brows, lips). amount 0..1: how much of the sideways unevenness of the light is taken out (and 40 % of that much of
    the up-down unevenness: light from above is what faces are expected to have). Returns the ratio map (h,w) to
    multiply `low` by (in linear light: use ratio ** (1 / 2.2) on the encoded values). where: 0..1, the only places
    that may change (all skin of the face: on a turned head the mesh reaches over the background)."""
    h, w = low.shape[:2]
    n, inside, g = directions((h, w), pts, z, f)
    hs, ws = inside.shape
    lum = cv2.resize(low, (ws, hs), interpolation=cv2.INTER_AREA) @ np.float32([0.2126, 0.7152, 0.0722])
    lum = np.clip(lum, 1e-3, 1) ** 2.2
    wt = cv2.resize(skin, (ws, hs), interpolation=cv2.INTER_AREA) * (cv2.erode(inside, np.ones((5, 5), np.uint8)))
    B = basis(n)
    use = wt > 0.3
    if use.sum() < 200:
        return np.ones((h, w), np.float32)
    A, b, wgt = B[use], lum[use], wt[use].copy()
    for _ in range(3):          # robust: glints and cast shadows are not shading
        sw = np.sqrt(wgt)[:, None]
        coef = np.linalg.lstsq(np.vstack([A * sw, 0.02 * np.sqrt(len(b)) * np.eye(9)[4:]]), np.concatenate([b * sw[:, 0], np.zeros(5)]), rcond=None)[0]
        r = b - A @ coef
        wgt = wt[use] / (1 + (r / (1.5 * np.median(np.abs(r)) + 1e-4)) ** 2)
    shade = B @ coef
    floor = 0.25 * float(np.median(shade[use]))
    target = coef.copy()
    target[list(SIDE_TERMS)] *= 1 - amount
    target[list(UP_TERMS)] *= 1 - 0.4 * amount
    new = B @ target
    new *= float((shade[use] * wt[use]).sum() / max((new[use] * wt[use]).sum(), 1e-6))       # same brightness overall
    ratio = np.clip(np.maximum(new, floor) / np.maximum(shade, floor), *LIMIT)
    ratio = 1 + (ratio - 1) * cv2.GaussianBlur(cv2.erode(inside, np.ones((3, 3), np.uint8)), (0, 0), max(1.5, f * g * 0.06))
    ratio = cv2.GaussianBlur(ratio.astype(np.float32), (0, 0), max(1.0, f * g * 0.02))
    if debug is not None:
        side = float(np.abs(coef[list(SIDE_TERMS)]).sum() / (abs(coef[0]) + abs(coef[3]) + 1e-6))
        debug.update(light=coef, uneven=side, shade=shade, ratio=ratio)
    ratio = cv2.resize(ratio, (w, h), interpolation=cv2.INTER_CUBIC)
    return ratio if where is None else 1 + (ratio - 1) * where
