"""Synthetic skin blemishes painted onto real skin, for training (scripts/train_dodge.py): the picture before painting
is the exact answer, at any resolution, and no retoucher's taste comes with it.
Kinds: inflamed spots (red, darker, often raised: lit on one side, shaded on the other, sometimes a glint or a white
head), flat brownish marks left by old spots, and small dark-red scabs. Single or in clusters, as acne is."""
import cv2, numpy as np


def skin_like(rgb):
    """Rough 0..1 map of skin-coloured pixels (float RGB 0..1): only decides where blemishes may be painted."""
    ycc = cv2.cvtColor(rgb, cv2.COLOR_RGB2YCrCb)
    cr, cb = ycc[..., 1] * 255, ycc[..., 2] * 255
    # Limits checked per skin-tone group (scripts/exp_fair.py, six ITA groups, cheek patch counted as skin): with the
    # first, narrower limits (Cr 132-180, Cb 75-132, Y from 0.2) dark skin was found on 60 % of the patch against
    # 82-95 % for the others; with these it is 88-98 % for every group.
    m = np.clip((cr - 128) / 8, 0, 1) * np.clip((185 - cr) / 8, 0, 1) * np.clip((cb - 70) / 8, 0, 1) * np.clip((134 - cb) / 8, 0, 1)
    return m * np.clip((ycc[..., 0] - 0.06) / 0.1, 0, 1)


def _noise(rng, n, cells):
    """Smooth random field n x n, zero mean, about unit range."""
    g = rng.standard_normal((cells, cells)).astype(np.float32)
    return cv2.resize(g, (n, n), interpolation=cv2.INTER_CUBIC)


def paint(img, face, rng, amount=None):
    """img: float32 RGB 0..1 (changed in place and returned); face: face width in pixels (sets blemish sizes).
    amount: None = random (a quarter of the pictures get none, some get a few, some a breakout)."""
    h, w = img.shape[:2]
    area = h * w / float(face * face)
    if amount is None:
        amount = rng.choice([0, 0, 1, 1, 1, 2, 2, 3])
    if amount == 0:
        return img
    lam = {1: 6, 2: 25, 3: 70}[int(amount)] * area
    n = int(rng.poisson(lam))
    if n == 0:
        return img
    skin = skin_like(img)
    centres = []
    if amount >= 2:                     # breakouts gather: on a cheek, the forehead, the chin
        for _ in range(int(rng.integers(1, 4))):
            centres.append((rng.uniform(0, w), rng.uniform(0, h), face * rng.uniform(0.08, 0.25)))
    light = rng.uniform(0, 2 * np.pi)   # one light for the whole face
    for _ in range(n):
        if centres and rng.random() < 0.8:
            cx, cy, spread = centres[int(rng.integers(len(centres)))]
            x, y = rng.normal(cx, spread), rng.normal(cy, spread)
        else:
            x, y = rng.uniform(0, w), rng.uniform(0, h)
        if not (0 <= x < w and 0 <= y < h) or skin[int(y), int(x)] < 0.5:
            continue
        kind = rng.choice(["red", "red", "red", "red", "red", "red", "red", "mark", "mark", "scab"])
        r = face * float(np.exp(rng.uniform(np.log(0.004), np.log(0.012 if kind == "scab" else 0.024))))
        r = max(r, 1.2)
        R = int(np.ceil(r * 3.5)) + 2
        x0, y0, x1, y1 = int(x) - R, int(y) - R, int(x) + R + 1, int(y) + R + 1
        if x0 < 0 or y0 < 0 or x1 > w or y1 > h:
            continue
        n_px = x1 - x0
        yy, xx = np.mgrid[0:n_px, 0:n_px].astype(np.float32)
        dx, dy = xx - (x - x0), yy - (y - y0)
        ang = rng.uniform(0, np.pi); ca, sa = np.cos(ang), np.sin(ang); asp = rng.uniform(0.7, 1.0)
        u, v = (dx * ca + dy * sa) / r, (-dx * sa + dy * ca) / (r * asp)
        d = np.sqrt(u * u + v * v) * (1 + 0.22 * _noise(rng, n_px, 4))           # irregular outline
        if kind == "red":
            p = np.exp(-1.2 * d * d)
            dl, da, db = -rng.uniform(1, 9), rng.uniform(6, 22), rng.uniform(-3, 5)
        elif kind == "mark":
            p = np.exp(-(d ** 4) * 0.8)
            dl, da, db = -rng.uniform(3, 10), rng.uniform(1, 7), rng.uniform(1, 8)
        else:
            p = 1 / (1 + np.exp((d - 0.9) * 6))
            dl, da, db = -rng.uniform(8, 20), rng.uniform(6, 15), rng.uniform(0, 6)
        strength = rng.uniform(0.45, 1.0) * skin[int(y), int(x)]
        p = p * strength * np.clip(skin[y0:y1, x0:x1] * 2, 0, 1)
        lab = cv2.cvtColor(img[y0:y1, x0:x1], cv2.COLOR_RGB2Lab)
        tex = 1 + 0.3 * _noise(rng, n_px, max(4, n_px // 3))                        # uneven inside
        lab[..., 0] += dl * p * tex; lab[..., 1] += da * p * tex; lab[..., 2] += db * p
        if kind == "red" and r > 2 and rng.random() < 0.6:                          # raised: lit and shaded sides
            gy, gx = np.gradient(np.exp(-1.2 * d * d))
            k = rng.uniform(3, 11) * r * strength
            lab[..., 0] += k * (gx * np.cos(light) + gy * np.sin(light))
            if rng.random() < 0.4:                                                  # glint towards the light
                ox, oy = -0.35 * r * np.cos(light), -0.35 * r * np.sin(light)
                lab[..., 0] += rng.uniform(5, 18) * strength * np.exp(-((dx - ox) ** 2 + (dy - oy) ** 2) / (2 * (0.28 * r) ** 2))
            if rng.random() < 0.2:                                                  # white head
                head = np.exp(-(dx * dx + dy * dy) / (2 * (0.3 * r) ** 2)) * strength
                lab[..., 0] += rng.uniform(8, 18) * head; lab[..., 1] -= 0.6 * da * head; lab[..., 2] += rng.uniform(4, 10) * head
        img[y0:y1, x0:x1] = np.clip(cv2.cvtColor(lab, cv2.COLOR_Lab2RGB), 0, 1)
    return img
