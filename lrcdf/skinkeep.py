"""Keep the person's own skin ("fix R") in the tone step, as Lightroom develop settings.

The tone model was trained on PPR10K, whose retouchers bring every face to about the same lightness: dark skin comes
out 7-10 L lighter than it is (docs/skin_mac/REPORT.md, measured on Lightroom renders). The rule is the iPad app's
(docs/ipad/skin/FIX_R_RULES.md, the same constants P0); here it changes four develop settings instead of pixels:

  read()      from the neutral render: skin depth s (0 light .. 1 dark) of the largest face, read by the make-up
              network's second output, and a sample of the face skin (where it is, and what it looks like unedited).
              Photos the rule cannot change (see `takes_part`) keep exactly what the model gave.
  one_shot()  from a render of the look: the lift the look added to the skin is taken back by s, down to the natural
              level for that depth (goal_L). First the look's own orange luminance (it lifts skin and nothing else),
              then Exposure2012 for what is left; and the skin chroma the look took is given back (goal_C) with the
              look's own orange saturation, never beyond 0.
              Since 2026-11-16 (the user: "也收一些") a face that is not dark but sits below the look's level in
              ordinary light - medium-brown skin, light skin away from the light - is held back too, mildly: of the
              lift beyond EASE_ALLOW L, EASE of it is taken back (`ease`). The depth score cannot tell such skin from
              a dim photo of a light face, so the weight comes from the face's own lightness: none for a face in the
              dark (under L 38, the user's own under-exposed RAWs), full from L 48; or from a score that is not light.
  refine()    from a render of those settings: what is still off is corrected once.

Slider constants measured in Lightroom 16 on 31 photos (docs/skin_mac, probes.py): 1 EV of Exposure2012 moves rendered
skin 1/0.82 as much as the same factor in linear light on the finished picture, about 19 L; skin chroma falls about
10 % per EV taken away; +1 SaturationAdjustmentOrange = +1.05 % skin chroma;
+1 LuminanceAdjustmentOrange = +0.145 L on skin (less on very dark skin, which is why there is a second pass)."""
import math
import os

import cv2
import numpy as np
from lrcdf import paths

P0 = dict(L_REF=62.0, L_SLOPE=20.0, ALLOW=2.0, D0=3.0, R_BASE=0.5, C_CAP=28.0, S_LO=0.5, S_HI=3.5, CAST_LO=28.0, CAST_HI=36.0)
K_EXP, C_EXP, K_SO, K_LO, L_PER_EV = 0.82, 0.10, 0.0105, 0.145, 19.0
S_MIN = 0.05            # below this the dark-skin rule would move the skin by less than half an L
EASE, EASE_ALLOW = 0.4, 4.0     # the mild rule: this part of the lift beyond this many L is taken back
EASE_L, EASE_SCORE = (38.0, 48.0), (-1.5, 1.0)     # its weight: unedited skin lightness from .. to, or depth score from .. to
EASE_TOP = 60.0         # unedited skin this light is lifted by less than EASE_ALLOW anyway: such photos do not take part
FACE_MIN = 0.08         # the face must be this wide, as a fraction of the picture's long edge
SAMPLE = 20000
KEYS = ("Exposure2012", "LuminanceAdjustmentOrange", "SaturationAdjustmentOrange")
MODELS = paths.models()


def sstep(x, a, b):
    t = float(np.clip((x - a) / (b - a), 0, 1))
    return t * t * (3 - 2 * t)


def lin(s):
    s = np.clip(s, 0, 1)
    return np.where(s <= 0.04045, s / 12.92, ((s + 0.055) / 1.055) ** 2.4)


def enc(l):
    l = np.clip(l, 0, None)
    return np.where(l <= 0.0031308, l * 12.92, 1.055 * np.power(np.maximum(l, 1e-12), 1 / 2.4) - 0.055)


def lab(pixels):
    """Linear-light skin pixels [N,3] -> Lab [N,3] (OpenCV's sRGB D65)."""
    return cv2.cvtColor(np.clip(enc(pixels), 0, 1)[None].astype(np.float32), cv2.COLOR_RGB2Lab)[0]


def mean(pixels):
    """Mean L and the chroma of the mean (a, b)."""
    x = lab(pixels)
    return float(x[:, 0].mean()), float(math.hypot(x[:, 1].mean(), x[:, 2].mean()))


def gain_to(pixels, L):
    """The factor in linear light that brings the pixels' mean L to L."""
    lo, hi = 0.02, 50.0
    for _ in range(34):
        g = (lo * hi) ** 0.5
        if lab(pixels * g)[:, 0].mean() < L:
            lo = g
        else:
            hi = g
    return g


def ease(L0, score):
    """Weight 0..1 of the mild rule for a face at L0 unedited with this depth score."""
    return max(sstep(L0, *EASE_L), sstep(score, *EASE_SCORE))


def takes_part(s, L0, score):
    return s >= S_MIN or (L0 < EASE_TOP and ease(L0, score) >= 0.05)


def goal_L(L0, Lt, s, w=0.0, P=P0):
    """Skin at L0 unedited and Lt after the look: where it should be. s: depth, w: weight of the mild rule."""
    dark = Lt - s * max(0.0, Lt - max(P["L_REF"] - P["L_SLOPE"] * s, L0 + P["ALLOW"]))
    return min(dark, Lt - EASE * w * max(0.0, Lt - L0 - EASE_ALLOW))


def goal_C(neutral, C0, L1, C1, s, P=P0):
    """Chroma for skin that sits at (L1, C1): part of what a pure exposure change would have kept is given back."""
    Cref = mean(neutral * gain_to(neutral, L1))[1]
    r = P["R_BASE"] * (1 - sstep(C0, P["CAST_LO"], P["CAST_HI"])) + (1 - P["R_BASE"]) * s
    return min(C1 + r * max(0.0, Cref - C1 - P["D0"] * (1 - s)), max(P["C_CAP"], C1))


def _chroma(now, look, C1, Cg):
    """Move skin chroma from C1 to Cg with the look's own orange saturation, between the look's value and 0.
    (Saturation would do it too, but for the whole picture: a pale look would stop being pale.)"""
    name = "SaturationAdjustmentOrange"
    if abs(Cg - C1) <= 0.3 or C1 <= 0 or look.get(name, 0) >= 0:
        return {}
    new = int(max(look[name], min(0, now[name] + round((Cg / C1 - 1) / K_SO))))
    return {name: new} if new != now[name] else {}


def one_shot(neutral, toned, s, settings, score=-9.0):
    """neutral, toned: the skin sample before and after the look (linear light); settings: the look's KEYS.
    Returns (changed settings, state for refine)."""
    L0, C0 = mean(neutral)
    Lt, Ct = mean(toned)
    w = ease(L0, score)
    Lg = goal_L(L0, Lt, s, w)
    out, ev = {}, 0.0
    if Lg < Lt - 0.3:
        orange = settings["LuminanceAdjustmentOrange"]
        back = int(max(0, min(round(orange * max(s, EASE * w)), (Lt - Lg) // K_LO))) if orange > 0 else 0
        if back:
            out["LuminanceAdjustmentOrange"] = orange - back
        if Lt - K_LO * back - Lg > 0.3:
            ev = round(K_EXP * math.log2(gain_to(toned, Lg + K_LO * back)), 2)
            out["Exposure2012"] = round(settings["Exposure2012"] + ev, 2)
    else:
        Lg = Lt
    C1 = Ct * (1 + C_EXP * ev)
    state = dict(s=s, L0=L0, C0=C0, Lt=Lt, Ct=Ct, Lg=Lg, C1=C1, look={k: settings[k] for k in KEYS})
    out.update(_chroma(settings, settings, C1, goal_C(neutral, C0, Lg, C1, s)))
    return out, state


def refine(neutral, fixed, state, now):
    """fixed: the skin sample in a render of the settings `now` (the look's with one_shot's changes). Returns changes."""
    L1, C1 = mean(fixed)
    out = {}
    if state["Lg"] < state["Lt"] and abs(L1 - state["Lg"]) > 0.3:
        ev = round((state["Lg"] - L1) / L_PER_EV, 2)
        out["Exposure2012"] = round(now["Exposure2012"] + ev, 2)
        C1 *= 1 + C_EXP * ev
    # the goal is set from the state before any colour was given back
    Cg = goal_C(neutral, state["C0"], state["Lg"], state["C1"], state["s"])
    out.update(_chroma(now, state["look"], C1, Cg))
    return out


# --- reading the photo -------------------------------------------------------------------------------------------

_models = None


def _load(device):
    global _models
    if _models is None:
        import mediapipe as mp
        import torch
        from mediapipe.tasks import python as mpp
        from mediapipe.tasks.python import vision
        from lrcdf.mediapipe_io import base_options
        path = f"{MODELS}/makeup/makeup_s2.pt"
        scorer = None
        if os.path.exists(path):
            with open(path, "rb") as f:     # a file object: see scripts/beautify.makeup_of
                scorer = torch.jit.load(f, map_location="cpu").float().to(device).eval()
        landmarker = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
            base_options=base_options(mpp.BaseOptions, f"{MODELS}/mediapipe/face_landmarker.task"), num_faces=4,
            min_face_detection_confidence=0.3, min_face_presence_confidence=0.3))
        segmenter = vision.ImageSegmenter.create_from_options(vision.ImageSegmenterOptions(
            base_options=base_options(mpp.BaseOptions, f"{MODELS}/mediapipe/selfie_multiclass_256x256.tflite"),
            output_confidence_masks=True, output_category_mask=False))
        _models = mp, torch, scorer, landmarker, segmenter
    return _models


def read(rgb8, device="cpu"):
    """The neutral render (uint8 RGB) -> None, or dict(s, score, xy [N,2] in 0..1, rgb [N,3] linear light).
    None: no face large enough, a face the rule leaves alone (takes_part), or a model file from before the fix."""
    mp, torch, scorer, landmarker, segmenter = _load(device)
    if scorer is None:
        return None
    H, W = rgb8.shape[:2]
    image = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb8))
    boxes = []
    for face in landmarker.detect(image).face_landmarks:
        xs, ys = [p.x * W for p in face], [p.y * H for p in face]
        boxes.append((min(xs), min(ys), max(xs), max(ys)))
    boxes = [b for b in boxes if b[2] - b[0] >= FACE_MIN * max(H, W)]
    if not boxes:
        return None
    x0, y0, x1, y1 = max(boxes, key=lambda b: b[2] - b[0])
    side, cx, cy = max(x1 - x0, y1 - y0) * 1.3, (x0 + x1) / 2, (y0 + y1) / 2
    a, b, c, e = int(max(0, cx - side / 2)), int(max(0, cy - side / 2)), int(min(W, cx + side / 2)), int(min(H, cy + side / 2))
    if c - a < 8 or e - b < 8:
        return None
    crop = cv2.resize(rgb8[b:e, a:c], (256, 256), interpolation=cv2.INTER_AREA if c - a > 256 else cv2.INTER_LINEAR)
    with torch.no_grad():
        scores = scorer(torch.from_numpy(crop).permute(2, 0, 1).float()[None].to(device) / 255).flatten().tolist()
    if len(scores) < 2:
        return None
    s = sstep(scores[1], P0["S_LO"], P0["S_HI"])
    skin = segmenter.segment(image).confidence_masks[3].numpy_view().reshape(H, W)      # class 3: face skin
    L = cv2.cvtColor(rgb8.astype(np.float32) / 255, cv2.COLOR_RGB2Lab)[..., 0]
    idx = np.flatnonzero(((skin > 0.5) & (L > 8) & (L < 97)).ravel())      # without beard shadow, nostrils, glare
    if len(idx) < 200:
        return None
    if len(idx) > SAMPLE:
        idx = idx[np.linspace(0, len(idx) - 1, SAMPLE).astype(int)]
    ys, xs = np.divmod(idx, W)
    if not takes_part(s, mean(lin(rgb8.reshape(-1, 3)[idx].astype(np.float32) / 255))[0], scores[1]):
        return None
    return dict(s=s, score=scores[1], xy=np.stack([(xs + 0.5) / W, (ys + 0.5) / H], 1).astype(np.float32),
                rgb=lin(rgb8.reshape(-1, 3)[idx].astype(np.float32) / 255).astype(np.float32))


def sample(rgb8, xy):
    """The same places of another render of the photo (any size), linear light."""
    H, W = rgb8.shape[:2]
    xs = np.clip((xy[:, 0] * W).astype(int), 0, W - 1)
    ys = np.clip((xy[:, 1] * H).astype(int), 0, H - 1)
    return lin(rgb8[ys, xs].astype(np.float32) / 255)


def save(base, found):
    """found: {photo id: read()'s result}. -> base.skin.lua (id -> s, read by the plug-in) and base.skin.npz."""
    arrays = {}
    for pid, f in found.items():
        arrays[f"{pid}_xy"], arrays[f"{pid}_rgb"], arrays[f"{pid}_s"] = f["xy"], f["rgb"], np.float32([f["s"], f["score"]])
    for end in (".skin.npz", ".skin.lua"):
        if os.path.exists(base + end):
            os.remove(base + end)
    if arrays:
        with open(base + ".skin.npz", "wb") as f:
            np.savez_compressed(f, **arrays)
    with open(base + ".skin.lua", "w", encoding="utf-8") as f:
        f.write("return {" + ",".join(f'["{pid}"]={v["s"]:.3f}' for pid, v in found.items()) + "}\n")


def load(base):
    path = base + ".skin.npz"
    if not os.path.exists(path):
        return {}
    with open(path, "rb") as f:
        z = np.load(f)
        return {k[:-3]: dict(xy=z[k], rgb=z[k[:-3] + "_rgb"], s=float(z[k[:-3] + "_s"][0]), score=float(z[k[:-3] + "_s"][1])) for k in z.files if k.endswith("_xy")}
