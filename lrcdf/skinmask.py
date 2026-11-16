"""Where the skin is, as brush strokes Lightroom can take: the look's skin corrections (orange / yellow saturation and
luminance, which the model sets for every photo) then touch the skin only, and wood, warm clothes and warm light keep
their colour (docs/colorchart/REPORT.md). Lightroom's own AI skin mask would do the same, but a plug-in cannot make
Lightroom compute it; a brush mask needs no computing.

strokes(rgb8) -> None, or { "brushes": [ { "r": radius, "dabs": [x, y, x, y, ...] }, ... ] }: circles inside the skin
found by MediaPipe's selfie segmenter (body skin + face skin; see region), largest first. x, y: 0..1 of the picture's width and
height; r: in parts of the picture's long edge. The plug-in maps them into the uncropped photo (Tone.lua)."""
import numpy as np, cv2
from . import skinkeep
from .blemish import skin_like
from .beauty import LIPS_OUT, EYE_L, EYE_R

AREA_MIN = 0.004        # skin below this share of the picture: no mask, the look stays as the model gives it
COVER = 0.97            # stop when this much of the skin is inside a circle
MOST = 400              # circles at most
SMALLEST = 0.003        # smallest circle, in parts of the long edge
WORK = 512              # the circles are placed on a copy with this long edge
STEP = 0.75             # a circle takes this much of its radius out of what is left to cover
PATCH_SKIN = 0.3        # a patch of the segmenter's skin is kept when this share of it has a skin colour
HOLE = 9                # a hole enclosed by skin is filled when it has at most this many pixels of the working copy:
                        # specks only - with larger ones the beads of a necklace lying on the skin were filled in
GROW = 1.15             # brush radius over the circle's: the brush fades towards its rim (CenterWeight in Tone.lua)


def skin(rgb8, device="cpu"):
    """Share of skin per pixel, 0..1 (body and face)."""
    mp, _, _, _, segmenter = skinkeep._load(device)
    masks = segmenter.segment(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb8))).confidence_masks
    H, W = rgb8.shape[:2]
    return np.maximum(masks[2].numpy_view().reshape(H, W), masks[3].numpy_view().reshape(H, W))


def pack(mask):
    """Circles inside a boolean mask, largest first: [(x, y, r)] in pixels."""
    dist = cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    left, total, out = mask.copy(), int(mask.sum()), []
    yy, xx = np.mgrid[:mask.shape[0], :mask.shape[1]]
    smallest = SMALLEST * max(mask.shape)
    while len(out) < MOST and left.sum() > (1 - COVER) * total:
        d = np.where(left, dist, 0)
        y, x = divmod(int(d.argmax()), mask.shape[1])
        r = float(d[y, x])
        if r < smallest:
            break
        out.append((x + 0.5, y + 0.5, r))
        left &= (xx - x) ** 2 + (yy - y) ** 2 > (STEP * r) ** 2
    return out


def region(small, device="cpu"):
    """Where the skin is in a small picture (bool). Three rules on top of the segmenter:
    - a patch the segmenter calls skin counts as a whole when enough of it has a skin colour (blemish.skin_like):
      judged pixel by pixel, skin in shadow dropped out (a band under the chin stayed brown in a Windows test);
      a patch with hardly any skin colour is a plain surface the segmenter took for skin and is dropped;
    - specks enclosed by skin are filled (catchlights, moles);
    - lips, the mouth's inside (teeth) and the eyes are taken out with the face mesh: the correction is meant for
      skin, and they were thinned and lifted with it."""
    mp, _, _, landmarker, _ = skinkeep._load(device)
    h, w = small.shape[:2]
    seg = (skin(small, device) > 0.5).astype(np.uint8)
    soft = cv2.GaussianBlur(small, (0, 0), 2).astype(np.float32) / 255
    like = skin_like(soft) > 0.25
    count, labels = cv2.connectedComponents(seg, connectivity=8)
    mask = np.zeros((h, w), bool)
    for k in range(1, count):
        patch = labels == k
        if patch.sum() >= 12 and like[patch].mean() >= PATCH_SKIN:
            mask |= patch
    holes = (~mask).astype(np.uint8)        # background that does not reach the picture's edge = a hole in the skin
    count, labels, stats, _ = cv2.connectedComponentsWithStats(holes, connectivity=4)
    for k in range(1, count):
        x, y, bw, bh, area = stats[k]
        inside = x > 0 and y > 0 and x + bw < w and y + bh < h
        if inside and area <= HOLE:
            mask |= labels == k
    out = np.zeros((h, w), np.uint8)
    try:
        faces = landmarker.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(small))).face_landmarks
    except Exception:
        faces = []
    for face in faces:
        pts = np.array([(p.x * w, p.y * h) for p in face], np.float32)
        for ring in (LIPS_OUT, EYE_L, EYE_R):
            cv2.fillPoly(out, [np.round(pts[ring]).astype(np.int32)], 1)
    if out.any():
        mask &= cv2.dilate(out, np.ones((3, 3), np.uint8)) == 0
    return mask


def strokes(rgb8, device="cpu"):
    H, W = rgb8.shape[:2]
    f = WORK / max(H, W)
    small = cv2.resize(rgb8, (max(1, round(W * f)), max(1, round(H * f))), interpolation=cv2.INTER_AREA) if f < 1 else rgb8
    mask = region(small, device)
    if mask.mean() < AREA_MIN:
        return None
    h, w = mask.shape
    groups = {}
    for x, y, r in pack(mask):          # a brush has one radius: circles of about the same size share a brush
        groups.setdefault(round(float(np.log2(r)) * 3), []).append((x, y, r))
    brushes = []
    for key in sorted(groups, reverse=True):
        g = groups[key]
        brushes.append({"r": round(float(np.mean([c[2] for c in g])) * GROW / max(h, w), 5),
                        "dabs": [round(float(v), 4) for x, y, _ in g for v in (x / w, y / h)]})
    return {"brushes": brushes} if brushes else None
