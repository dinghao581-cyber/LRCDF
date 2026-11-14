"""Portrait beautification on pixels by frequency separation (高低频), the way a retoucher works by hand.

Skin is split into two layers that add up to the photo exactly:
  low  = colour and light (Gaussian blur, radius SPLIT x face width)
  high = texture: pores, fine hair, lines (photo - low)
The low layer is where skin is evened: blotches, redness, uneven shading, red marks, dark under-eyes.
The high layer is left as it is, except on blemishes, where the raised texture is toned down.
So skin keeps its real texture and never turns to plastic. Eyes and teeth are finished on the recombined image.
Faces are handled in their own crops; body skin (arms, hands, chest, legs) gets the same low-layer evening."""
import os
import cv2
import numpy as np

MODELS = os.path.expanduser("~/LRCDF/models/mediapipe")
LIPS_OUT = [61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185]
LIPS_IN = [78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191]
EYE_L = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
EYE_R = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
BROW_L = [70, 63, 105, 66, 107, 55, 65, 52, 53, 46]
BROW_R = [300, 293, 334, 296, 336, 285, 295, 282, 283, 276]
NOSTRILS = [[98, 97, 2, 326, 327, 294, 278, 344, 440, 275, 4, 45, 220, 115, 48, 64]]

SPLIT = 0.006   # low/high split radius as a fraction of the face width (about 8 px on a 1300 px face)
ACNE_HUE = (0.15, 0.35)   # yellow shift per unit of red shift (Lab): up to here inflamed skin .. from here blush or warm light
SPOT_WIDTH = 0.06   # widest red mark that is corrected at default strength, as a fraction of the face width
BODY = 0.75    # body skin is evened this much of the face's amount
HAIR = (0.012, 0.03)   # line contrast (darker than surrounding skin, averaged along the hair): from .. fully protected
HAIR_SCALE = 400       # hair detection works on a copy where the face is this many pixels wide
RELIEF = 0.8        # how much of a blemish's highlight and shadow is taken out
RELIEF_REACH = 3.0   # how far around a red mark that applies (larger = further)
HEAL = 0.7      # how much of the high layer is removed on a blemish at full strength
DEFAULTS = dict(smooth=0.6, spots=1.0, shine=0.5, unify=0.5, wrinkles=0.5, undereye=0.5, eyes=0.4, teeth=0.4, light=0.0)
LIGHT_FROM = 150    # faces narrower than this many pixels are not relit (the mesh is too coarse to trust its shape)
LINES = (0.012, 0.03, 0.11, 0.17)   # depth of a line relative to the skin beside it: from .. fully softened; from .. left alone (hair, frames)
LINE_SCALE = 360      # lines are looked for on a copy where the face is this many pixels wide
LINE_WIDTH = 0.035    # widest line, as a fraction of the face width
SHINE = (5.0, 14.0)   # skin this much lighter (Lab L) than its surroundings, and paler: from a hint of shine .. full glare


class Models:
    def __init__(self):
        import mediapipe as mp
        from mediapipe.tasks import python as mpp
        from mediapipe.tasks.python import vision
        self.mp = mp
        self.landmarker = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
            base_options=mpp.BaseOptions(model_asset_path=f"{MODELS}/face_landmarker.task"), num_faces=1,
            min_face_detection_confidence=0.3, min_face_presence_confidence=0.3))
        self.segmenter = vision.ImageSegmenter.create_from_options(vision.ImageSegmenterOptions(
            base_options=mpp.BaseOptions(model_asset_path=f"{MODELS}/selfie_multiclass_256x256.tflite"),
            output_confidence_masks=True, output_category_mask=False))

    def analyse(self, rgb8):
        """uint8 RGB crop -> (landmarks [478,2] in pixels or None, skin confidence [H,W] 0..1)."""
        image = self.mp.Image(image_format=self.mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb8))
        found = self.landmarker.detect(image).face_landmarks
        h, w = rgb8.shape[:2]
        pts = np.array([[p.x * w, p.y * h] for p in found[0]], np.float32) if found else None
        self.depth = np.array([p.z * w for p in found[0]], np.float32) if found else None      # of the last face (lrcdf.relight)
        conf = self.segmenter.segment(image).confidence_masks
        skin = conf[3].numpy_view() + conf[2].numpy_view()      # face skin + body skin (neck)
        self.skin_all = np.clip(skin, 0, 1).astype(np.float32)       # of the last crop, features included (lrcdf.relight)
        return pts, self.skin_all


def poly(shape, pts, idx, grow=0.0, blur=0.0):
    """Soft mask of a landmark polygon, optionally grown and feathered (pixels)."""
    m = np.zeros(shape[:2], np.float32)
    cv2.fillPoly(m, [np.round(pts[idx]).astype(np.int32)], 1.0)
    if grow >= 1:
        k = int(grow) * 2 + 1
        m = cv2.dilate(m, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    if blur > 0.3:
        m = cv2.GaussianBlur(m, (0, 0), blur)
    return m


def ellipse(shape, centre, axes, angle, blur):
    m = np.zeros(shape[:2], np.float32)
    cv2.ellipse(m, (int(centre[0]), int(centre[1])), (max(1, int(axes[0])), max(1, int(axes[1]))), angle, 0, 360, 1.0, -1)
    return cv2.GaussianBlur(m, (0, 0), max(0.5, blur))


def beautify_face(crop, face, models, opt, debug=None, box=None, mouth=None, eyes=None, mesh=None):
    """crop: float32 RGB 0..1 around one face; face: face width in pixels; box: the face box inside the crop;
    mouth, eyes: the two mouth corners and the two eye centres from the face detector, in crop pixels. They protect
    lips when the face mesh is off (profiles), and when the mesh finds no face at all (strong profile, lying down,
    close-up of a cheek) they stand in for it: skin is still evened and marks corrected, with eyes and mouth left
    alone; only the under-eye, eye and teeth steps need the mesh. Returns the edited crop."""
    h, w = crop.shape[:2]
    s = min(1.0, 1280 / max(h, w))
    small = cv2.resize(crop, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    pts, skin = models.analyse(np.rint(small * 255).astype(np.uint8))
    if pts is None and (mouth is None or eyes is None):
        return crop
    if pts is not None and mesh is not None:
        mesh.append(pts / s)                      # the face's landmarks in crop pixels, for whoever reshapes it
    skin = cv2.resize(skin, (w, h), interpolation=cv2.INTER_LINEAR)
    f = float(face)

    features = np.zeros((h, w), np.float32)
    if pts is not None:
        pts = pts / s
        for idx in (EYE_L, EYE_R, BROW_L, BROW_R, LIPS_OUT):
            features = np.maximum(features, poly(crop.shape, pts, idx, grow=f * 0.02, blur=f * 0.012))
    else:                       # no mesh: generous ovals over each eye with its brow, and over the mouth
        for ex, ey in eyes:
            features = np.maximum(features, ellipse(crop.shape, (ex, ey - f * 0.04), (f * 0.17, f * 0.15), 0, f * 0.02))
        (mx0, my0), (mx1, my1) = mouth
        features = np.maximum(features, ellipse(crop.shape, ((mx0 + mx1) / 2, (my0 + my1) / 2),
                                                (max(np.hypot(mx1 - mx0, my1 - my0) * 0.7, f * 0.14), f * 0.12), 0, f * 0.02))
        features = np.clip(features * 1.5, 0, 1)
    skin = cv2.GaussianBlur(np.clip(skin * 1.5 - 0.25, 0, 1), (0, 0), f * 0.012) * (1 - features)
    low, high = split(crop, f)

    # --- low layer: even colour and light (blotches, redness, soft uneven shading)
    small, base, d = smooth_low(low, f)
    low += opt["smooth"] * skin[..., None] * (base - low)

    # --- red spots (acne, marks): where skin is redder than the skin around it, pull colour and lightness back to
    # the surrounding skin in the low layer, and tone down the blemish's raised texture in the high layer.
    if opt.get("spots", 0) > 0 or opt.get("shine", 0) > 0:
        sm = cv2.resize(low, (small.shape[1], small.shape[0]), interpolation=cv2.INTER_AREA)
        wt = cv2.resize(skin, (small.shape[1], small.shape[0]), interpolation=cv2.INTER_AREA)
        lab = cv2.cvtColor(sm, cv2.COLOR_RGB2Lab)
        sigma = f * d * 0.06
        keep = wt.copy()
        for _ in range(4):   # surrounding skin = average of skin that is not itself a spot
            norm = cv2.GaussianBlur(keep, (0, 0), sigma) + 1e-3
            around = cv2.GaussianBlur(lab * keep[..., None], (0, 0), sigma) / norm[..., None]
            red = lab[..., 1] - around[..., 1]
            keep = wt * np.clip(1 - (red - 1.5) / 3.0, 0.05, 1)
        spot = np.clip((red - 1.5) / 3.0, 0, 1) * wt
        # not deep shadows (nostrils, mouth corners) ...
        spot *= np.clip(1 - (around[..., 0] - lab[..., 0] - 10) / 8, 0, 1)
        # ... compact marks always (up to SPOT_WIDTH of the face; wider with strength above the default).
        k = max(3, int(f * d * SPOT_WIDTH * max(1.0, opt["spots"] / DEFAULTS["spots"]) ** 2)) | 1
        wide = cv2.morphologyEx(spot, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
        # Wide red areas are either merged acne or something to keep: blush, lips, a ruddy cheek, a warm shadow.
        # What tells them apart is the colour of the redness: inflamed skin is redder without being yellower
        # (Lab b stays, a rises) and darker; blush, warm light and ruddy skin shift towards orange (b rises with a).
        # (Patchiness, crowding of small marks and surface texture were measured too and do not separate them.)
        blur = f * d * 0.02
        more_yellow = cv2.GaussianBlur(lab[..., 2] - around[..., 2], (0, 0), blur) / (cv2.GaussianBlur(np.maximum(red, 0), (0, 0), blur) + 0.5)
        darker = cv2.GaussianBlur(around[..., 0] - lab[..., 0], (0, 0), blur)
        inflamed = np.clip((ACNE_HUE[1] - more_yellow) / (ACNE_HUE[1] - ACNE_HUE[0]), 0, 1) * np.clip(darker / 2.0, 0, 1)
        if debug is not None:
            debug.update(red=red.copy(), wide=wide.copy(), inflamed=inflamed, more_yellow=more_yellow, darker=darker)
        spot = spot - wide + wide * inflamed
        if box is not None:  # stay on the face: the skin mask also catches skin-coloured things further away
            bx0, by0, bx1, by1 = [v * d for v in box]
            spot *= ellipse(spot.shape, ((bx0 + bx1) / 2, (by0 + by1) / 2), ((bx1 - bx0) * 0.62, (by1 - by0) * 0.7), 0, f * d * 0.05)
        if mouth is not None:
            (mx0, my0), (mx1, my1) = [(x * d, y * d) for x, y in mouth]
            half = max(np.hypot(mx1 - mx0, my1 - my0) * 0.65, f * d * 0.12)
            spot *= 1 - ellipse(spot.shape, ((mx0 + mx1) / 2, (my0 + my1) / 2), (half, f * d * 0.11),
                                float(np.degrees(np.arctan2(my1 - my0, mx1 - mx0))) if half > f * d * 0.12 else 0, f * d * 0.02)
        spot = cv2.GaussianBlur(spot, (0, 0), max(0.6, f * d * 0.004))
        fixed = lab + min(1.0, opt["spots"]) * spot[..., None] * (around - lab)
        # Relief: a raised blemish also has a highlight and a shadow that are not red. Right around the marks, lightness
        # that departs from the surrounding skin in small patches is pulled back as well.
        near = np.clip(cv2.GaussianBlur(spot, (0, 0), f * d * 0.02) * RELIEF_REACH, 0, 1)
        off = np.abs(lab[..., 0] - around[..., 0])
        bump = np.clip((off - 2.0) / 4.0, 0, 1) * near * wt
        bump -= cv2.morphologyEx(bump, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))   # small only
        bump = np.maximum(cv2.GaussianBlur(bump, (0, 0), max(0.6, f * d * 0.004)) - spot, 0)
        fixed[..., 0] += RELIEF * min(1.0, opt["spots"]) * bump * (around[..., 0] - lab[..., 0])
        # Shine (oily forehead, nose, cheeks): skin that is clearly lighter and paler than the skin around it. Its
        # lightness and colour are taken part of the way back; the catch-light keeps its place, only weaker.
        if opt.get("shine", 0) > 0:
            chroma = np.hypot(lab[..., 1], lab[..., 2]); chroma_around = np.hypot(around[..., 1], around[..., 2])
            glare = np.clip((lab[..., 0] - around[..., 0] - SHINE[0]) / (SHINE[1] - SHINE[0]), 0, 1) \
                * np.clip((chroma_around - chroma) / 3.0, 0, 1) * wt
            glare = cv2.GaussianBlur(glare, (0, 0), max(0.8, f * d * 0.008))
            fixed += min(1.0, opt["shine"]) * 0.7 * glare[..., None] * (around - fixed)
            if debug is not None:
                debug["shine"] = glare
        delta = cv2.cvtColor(fixed, cv2.COLOR_Lab2RGB) - sm
        on_skin = np.clip(skin * 1.5, 0, 1)[..., None]
        low += cv2.resize(delta, (w, h), interpolation=cv2.INTER_LINEAR) * on_skin
        marks = cv2.resize(np.clip(spot + RELIEF * bump, 0, 1), (w, h), interpolation=cv2.INTER_LINEAR)[..., None] * on_skin
        high *= 1 - HEAL * min(1.0, opt["spots"]) * marks
        if debug is not None:
            debug["spot"] = marks[..., 0]

    # Shine also sits in the high layer, as small white glints on oily skin (nose, forehead). Only the bright, colourless
    # peaks are lowered; pores and hairs, which are dark detail, are not touched.
    if opt.get("shine", 0) > 0:
        peak = high.mean(2)
        top, bottom = crop.max(2), crop.min(2)
        pale = np.clip((0.40 - (top - bottom) / (top + 1e-4)) / 0.2, 0, 1)
        glint = np.clip((peak - 0.04) / 0.06, 0, 1) * pale * np.clip(skin * 1.5, 0, 1)
        high -= min(1.0, opt["shine"]) * 0.75 * glint[..., None] * np.clip(high, 0, None)

    if pts is None:
        return np.clip(low + high, 0, 1)

    # --- light: side light made more even, in the colour layer only (lrcdf.relight; off unless asked for)
    if opt.get("light", 0) > 0 and f >= LIGHT_FROM and getattr(models, "depth", None) is not None:
        from lrcdf import relight
        ratio = relight.even(low, pts, models.depth / s, f, skin, min(1.0, opt["light"]), debug,
                             where=cv2.GaussianBlur(np.clip(cv2.resize(models.skin_all, (w, h), interpolation=cv2.INTER_LINEAR) * 1.5 - 0.25, 0, 1), (0, 0), f * 0.012))
        low *= ratio[..., None] ** (1 / 2.2)

    # --- under-eye: pull the low-frequency colour towards the cheek below it
    down = pts[LIPS_OUT].mean(0) - (pts[EYE_L].mean(0) + pts[EYE_R].mean(0)) / 2
    down /= np.linalg.norm(down) + 1e-6
    angle = float(np.degrees(np.arctan2(down[1], down[0])) - 90)
    for eye in (EYE_L, EYE_R):
        c = pts[eye].mean(0); ew = float(np.linalg.norm(pts[eye[0]] - pts[eye[8]]))
        under = ellipse(crop.shape, c + down * ew * 0.62, (ew * 0.72, ew * 0.36), angle, ew * 0.12)
        under *= (1 - poly(crop.shape, pts, eye, grow=ew * 0.12, blur=ew * 0.06)) * np.clip(skin * 2, 0, 1)
        cheek = ellipse(crop.shape, c + down * ew * 1.45, (ew * 0.6, ew * 0.35), angle, ew * 0.1) * skin
        if under.sum() > 10 and cheek.sum() > 10:
            delta = (base * cheek[..., None]).sum((0, 1)) / cheek.sum() - (base * under[..., None]).sum((0, 1)) / under.sum()
            low += opt["undereye"] * under[..., None] * delta
        if debug is not None:
            debug["under"] = np.maximum(debug.get("under", 0), under)

    out = low + high
    if debug is not None:
        debug.update(low=low, high=high)

    # --- wrinkles: fine dark lines are filled part of the way (more with stronger smoothing); texture stays
    amount = opt.get("wrinkles", 0) * min(1.5, opt["smooth"] / DEFAULTS["smooth"])
    if amount > 0 and f >= 200:
        keep = features.copy()
        for eye, brow in ((EYE_L, BROW_L), (EYE_R, BROW_R)):       # the lid crease belongs to the eye
            hull = cv2.convexHull(np.round(pts[eye + brow]).astype(np.int32))
            lid = np.zeros((h, w), np.float32); cv2.fillConvexPoly(lid, hull, 1.0)
            keep = np.maximum(keep, cv2.GaussianBlur(lid, (0, 0), f * 0.015))
        keep = np.maximum(keep, poly(crop.shape, pts, NOSTRILS[0], grow=f * 0.02, blur=f * 0.012))
        out *= soften_lines(out, np.clip(skin * 1.5, 0, 1) * (1 - np.clip(keep * 1.5, 0, 1)), f, amount, debug)[..., None]

    # --- eyes: a little clarity and brightness inside the eye opening
    eyes = np.maximum(poly(crop.shape, pts, EYE_L, blur=f * 0.006), poly(crop.shape, pts, EYE_R, blur=f * 0.006))
    detail = crop - cv2.GaussianBlur(crop, (0, 0), f * 0.02)
    out += opt["eyes"] * eyes[..., None] * (0.6 * detail + 0.03)

    # --- teeth: only bright, low-saturation pixels inside the lips
    mouth = poly(crop.shape, pts, LIPS_IN, blur=f * 0.004)
    mx, mn = crop.max(2), crop.min(2)
    sat = (mx - mn) / (mx + 1e-4)
    teeth = mouth * np.clip((mx - 0.35) * 5, 0, 1) * np.clip((0.45 - sat) * 6, 0, 1)
    grey = out.mean(2, keepdims=True)
    out += opt["teeth"] * teeth[..., None] * (0.5 * (grey - out) + 0.05)

    if debug is not None:
        debug.update(skin=skin, teeth=teeth, eyes=eyes)
    return np.clip(out, 0, 1)


def soften_lines(img, where, f, amount, debug=None):
    """Gain map (h x w, >= 1) that fills thin dark lines in skin: wrinkles on the forehead, beside and under the eyes,
    around the mouth, on the neck. A line is a narrow valley in brightness that is long rather than round (pores and
    moles are round) and shallow (hair, lashes and spectacle frames are deep and stay). The gain is smooth at the
    picture's own resolution, so pores inside a softened line remain."""
    h, w = img.shape[:2]
    g = min(1.0, LINE_SCALE / f); n = f * g
    lum = cv2.resize(img @ np.float32([0.299, 0.587, 0.114]), None, fx=g, fy=g, interpolation=cv2.INTER_AREA)
    fine = cv2.GaussianBlur(lum, (0, 0), n * 0.004)
    k = max(3, int(n * LINE_WIDTH)) | 1
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    filled = cv2.morphologyEx(fine, cv2.MORPH_CLOSE, kernel)
    depth = (filled - fine) / (filled + 0.05)
    b = cv2.GaussianBlur(lum, (0, 0), n * 0.006)
    xx = cv2.Sobel(b, cv2.CV_32F, 2, 0, ksize=3); yy = cv2.Sobel(b, cv2.CV_32F, 0, 2, ksize=3); xy = cv2.Sobel(b, cv2.CV_32F, 1, 1, ksize=3)
    root = np.sqrt(((xx - yy) / 2) ** 2 + xy ** 2)
    across, along = (xx + yy) / 2 + root, (xx + yy) / 2 - root        # curvature across the valley and along it
    long = np.clip(1 - np.abs(along) / (np.maximum(across, 0) + 1e-4), 0, 1) * (across > 0)
    long = cv2.GaussianBlur(long.astype(np.float32), (0, 0), n * 0.006)
    deepest = cv2.dilate(depth, kernel)                                # a deep line is left alone across its whole width
    line = np.clip((depth - LINES[0]) / (LINES[1] - LINES[0]), 0, 1) * np.clip(long * 1.6 - 0.3, 0, 1) \
        * np.clip(1 - (deepest - LINES[2]) / (LINES[3] - LINES[2]), 0, 1)
    line = cv2.GaussianBlur(line, (0, 0), max(0.6, n * 0.004)) * cv2.resize(where, (lum.shape[1], lum.shape[0]), interpolation=cv2.INTER_AREA)
    if debug is not None:
        debug["lines"] = line
    gain = 1 + min(1.0, amount) * line * (filled - fine) / (fine + 0.02)
    return cv2.resize(gain, (w, h), interpolation=cv2.INTER_LINEAR)


def split(img, f):
    """Frequency separation: (low, high) with low + high == img. f: face width in pixels."""
    low = cv2.GaussianBlur(img, (0, 0), f * SPLIT)
    return low, img - low


def smooth_low(low, f):
    """Edge-aware smoothing of the low layer: light and colour flow evenly, real edges and shading stay.
    Returns (small smoothed copy, the same at full size, scale of the small copy)."""
    h, w = low.shape[:2]
    d = min(1.0, 320 / f)
    small = cv2.resize(low, None, fx=d, fy=d, interpolation=cv2.INTER_AREA)
    for _ in range(2):
        small = cv2.bilateralFilter(small, -1, 0.07, f * d * 0.045)
    return small, cv2.resize(small, (w, h), interpolation=cv2.INTER_LINEAR), d


def _line_response(high, n):
    """Strongest dark line through each pixel: the high layer averaged along segments of n pixels in 12 directions."""
    c = (n - 1) / 2
    dark = np.zeros_like(high)
    for t in range(12):
        k = np.zeros((n, n), np.float32)
        dx, dy = c * np.cos(np.pi * t / 12), c * np.sin(np.pi * t / 12)
        cv2.line(k, (int(round(c - dx)), int(round(c - dy))), (int(round(c + dx)), int(round(c + dy))), 1.0, 1, cv2.LINE_AA)
        dark = np.maximum(dark, -cv2.filter2D(high, -1, k / k.sum()))
    return dark


_NOISE_RESPONSE = {}


def _noise_response(n, sigma_blur):
    """What pure noise of standard deviation 1 gives in _line_response: (99th, 99.9th percentile). Simulated once."""
    key = (n, round(sigma_blur, 1))
    if key not in _NOISE_RESPONSE:
        noise = np.random.default_rng(0).standard_normal((512, 512)).astype(np.float32)
        r = _line_response(noise - cv2.GaussianBlur(noise, (0, 0), sigma_blur), n)[n:-n, n:-n]
        _NOISE_RESPONSE[key] = tuple(float(v) for v in np.percentile(r, [99, 99.9]))
    return _NOISE_RESPONSE[key]


def hair_lines(img, f, skin=None):
    """Where thin dark lines (hair) run, 0..1, widened by the split radius. img: float RGB; f: face width in pixels.
    A matched filter: the high layer is averaged along short segments in 12 directions; a hair gives a clear dark
    response in its own direction, while noise and pores average out. The threshold is what the photo's own noise
    could produce by chance (noise measured from pixel-to-pixel differences on `skin`, its line response simulated),
    so a noisy high-ISO photo is not mistaken for hairy skin. (Texture strength, a finer split, a black top-hat and
    thresholds relative to the skin's typical response were tried and fail: the first three on noise, the last on
    densely hairy skin, where hair is the typical response.)"""
    h, w = img.shape[:2]
    z = min(1.0, HAIR_SCALE / f)
    grey = cv2.resize(img, None, fx=z, fy=z, interpolation=cv2.INTER_AREA).mean(2)
    fz = f * z
    soft = cv2.GaussianBlur(grey, (0, 0), fz * SPLIT)
    n = max(7, int(fz * 0.03)) | 1
    dark = _line_response(grey - soft, n)
    second = grey[:, 2:] - 2 * grey[:, 1:-1] + grey[:, :-2]          # noise level: robust, hairs are too few to move it
    if skin is not None:
        on = cv2.resize(skin, (grey.shape[1], grey.shape[0]))[:, 1:-1] > 0.5
        second = second[on] if on.sum() > 100 else second
    sigma = 1.4826 * float(np.median(np.abs(second))) / np.sqrt(6) + 1e-6
    q99, q999 = _noise_response(n, fz * SPLIT)
    lo = np.maximum(sigma * q999, HAIR[0] * (soft + 0.1))             # above noise and visibly darker than the skin
    lines = np.clip((dark - lo) / (lo * (HAIR[1] / HAIR[0] - 1)), 0, 1)
    if os.environ.get("LRCDF_DEBUG"):
        print("hair: noise sigma %.4f, noise threshold %.4f, contrast floor ~%.4f" % (sigma, sigma * q999, HAIR[0] * (float(soft.mean()) + 0.1)), flush=True)
    lines = cv2.GaussianBlur(lines, (0, 0), max(0.8, fz * SPLIT))
    return cv2.resize(np.clip(lines * 2, 0, 1), (w, h), interpolation=cv2.INTER_LINEAR)


def beautify_body(out, boxes, models, opt, alone=()):
    """Even the skin outside the face crops (arms, hands, chest, legs), at the scale of the faces in the photo."""
    H, W = out.shape[:2]
    f = float(np.median([x1 - x0 for x0, y0, x1, y1 in boxes]))
    s = min(1.0, 1536 / max(H, W))
    small = cv2.resize(out, (int(W * s), int(H * s)), interpolation=cv2.INTER_AREA)
    image = models.mp.Image(image_format=models.mp.ImageFormat.SRGB, data=np.ascontiguousarray(np.rint(small * 255).astype(np.uint8)))
    conf = models.segmenter.segment(image).confidence_masks
    skin = np.clip((np.squeeze(conf[2].numpy_view()) + np.squeeze(conf[3].numpy_view())) * 2 - 0.6, 0, 1).astype(np.float32)
    whole = skin.copy()
    face = np.zeros_like(skin)
    for x0, y0, x1, y1 in boxes:                       # the face crops are already done
        m = 0.6 * max(x1 - x0, y1 - y0)
        skin[int(max(0, y0 - m) * s):int(min(H, y1 + m) * s), int(max(0, x0 - m) * s):int(min(W, x1 + m) * s)] = 0
    for x0, y0, x1, y1 in alone:                       # a person who is left alone: nothing below their face either
        w = x1 - x0
        skin[int(max(0, y0 - w) * s):, int(max(0, x0 - 1.5 * w) * s):int(min(W, x1 + 1.5 * w) * s)] = 0
        whole[int(max(0, y0 - w) * s):, int(max(0, x0 - 1.5 * w) * s):int(min(W, x1 + 1.5 * w) * s)] = 0
        w, h = x1 - x0, y1 - y0                        # cheeks and nose: the colour the rest of the skin is matched to
        face[int((y0 + 0.4 * h) * s):int((y0 + 0.75 * h) * s), int((x0 + 0.2 * w) * s):int((x1 - 0.2 * w) * s)] = 1
    # One skin colour from face to hands: the body's skin colour (not its lightness, which is the light) is moved most of
    # the way to the face's, when they differ visibly but not wildly (then it is tanned skin or coloured light).
    lab = cv2.cvtColor(small, cv2.COLOR_RGB2Lab)
    on_face, on_body = (face * whole) > 0.5, skin > 0.5
    if opt.get("unify", 0) > 0 and len(boxes) == 1 and not alone and on_face.sum() > 80 and on_body.sum() > 200:
        shift = np.median(lab[on_face][:, 1:], 0) - np.median(lab[on_body][:, 1:], 0)
        size = float(np.linalg.norm(shift))
        if 1.5 < size < 8:
            shift = shift * min(1.0, 3.0 / size)      # at most 3 Lab units: a nudge; the face is often redder for good reasons
            # everywhere on skin except the face itself, fading in softly below it (no edge on the neck)
            x0, y0, x1, y1 = [v * s for v in boxes[0]]
            keep = np.zeros_like(skin)
            keep[int(max(0, y0)):int(y1), int(max(0, x0)):int(x1)] = 1
            keep = cv2.GaussianBlur(keep, (0, 0), max(1.0, 0.3 * (x1 - x0)))
            where = cv2.GaussianBlur(whole * np.clip(1 - 1.6 * keep, 0, 1), (0, 0), max(1.0, f * s * 0.012))
            ty, tx = np.where(where > 0.02)
            if len(ty) > 50:
                ta, tb, tc, te = int(tx.min() / s), int(ty.min() / s), min(W, int(tx.max() / s) + 2), min(H, int(ty.max() / s) + 2)
                mask = cv2.resize(where, (W, H), interpolation=cv2.INTER_LINEAR)[tb:te, ta:tc]
                moved = cv2.cvtColor(out[tb:te, ta:tc], cv2.COLOR_RGB2Lab)
                moved[..., 1:] += mask[..., None] * (shift * min(1.0, opt["unify"])).astype(np.float32)
                out[tb:te, ta:tc] = cv2.cvtColor(moved, cv2.COLOR_Lab2RGB)
    ys, xs = np.where(skin > 0.05)
    if len(ys) < 50:
        return
    pad = int(f * 0.1)
    a, b = max(0, int(xs.min() / s) - pad), max(0, int(ys.min() / s) - pad)
    c, e = min(W, int(xs.max() / s) + pad), min(H, int(ys.max() / s) + pad)
    part = cv2.resize(skin, (W, H), interpolation=cv2.INTER_LINEAR)[b:e, a:c]
    part = cv2.GaussianBlur(part, (0, 0), f * 0.012)
    region = out[b:e, a:c]
    # Body hair: a hair is high-layer detail, but its soft shadow sits in the low layer, and evening would fade it.
    # So evening is switched off on the hairs themselves (and a split radius around them) and stays on between them.
    low, _ = split(region, f)
    keep = 1 - hair_lines(region, f, part)
    if os.environ.get("LRCDF_DEBUG") and (part > 0.5).sum():
        print("hair cover on body skin: %.3f" % float((1 - keep)[part > 0.5].mean()), flush=True)
    region += BODY * opt["smooth"] * (part * keep)[..., None] * (smooth_low(low, f)[1] - low)   # the high layer is not touched


def beautify(rgb, boxes, models=None, points=None, meshes=None, each=None, **options):
    """rgb: float32 RGB 0..1 full image; boxes: [(x0,y0,x1,y1)] face boxes. each: per face, options that replace the
    general ones, or None for a person who is left alone (face, and the skin below it). Returns edited image."""
    opt = dict(DEFAULTS, **options)
    models = models or Models()
    out = rgb.copy()
    H, W = rgb.shape[:2]
    alone = []
    for n, (x0, y0, x1, y1) in enumerate(boxes):
        fw, fh = x1 - x0, y1 - y0
        own = dict(opt, **{k: v for k, v in each[n].items() if k in opt}) if each and each[n] else opt
        if each and each[n] is None:
            alone.append((x0, y0, x1, y1)); continue
        m = 0.6 * max(fw, fh)
        a, b = int(max(0, x0 - m)), int(max(0, y0 - m))
        c, d = int(min(W, x1 + m)), int(min(H, y1 + m))
        five = [(x - a, y - b) for x, y in points[n]] if points else None      # detector: eyes, nose, mouth corners
        got = []
        done = beautify_face(out[b:d, a:c], fw, models, own, box=(x0 - a, y0 - b, x1 - a, y1 - b),
                             mouth=five[3:5] if five else None, eyes=five[0:2] if five else None, mesh=got)
        # The crop fades in at its sides (not where the picture ends): a neighbour's skin inside it must not end in an edge.
        fade = np.ones((d - b, c - a), np.float32); r = max(2, int(0.15 * fw))
        ramp = np.linspace(0, 1, r, dtype=np.float32)
        if a > 0: fade[:, :r] *= ramp[None]
        if c < W: fade[:, -r:] *= ramp[::-1][None]
        if b > 0: fade[:r] *= ramp[:, None]
        if d < H: fade[-r:] *= ramp[::-1][:, None]
        for k, (u0, v0, u1, v1) in enumerate(boxes):     # other people's faces inside this crop are theirs: each face is done once
            if k != n and u1 > a and u0 < c and v1 > b and v0 < d:
                fade *= 1 - ellipse(fade.shape, ((u0 + u1) / 2 - a, (v0 + v1) / 2 - b - 0.05 * (v1 - v0)),
                                    (0.62 * (u1 - u0), 0.75 * (v1 - v0)), 0, 0.06 * (u1 - u0))
        out[b:d, a:c] += fade[..., None] * (done - out[b:d, a:c])
        if got and meshes is not None:
            meshes.append((got[0] + np.array([a, b], np.float32), float(fw)))   # (landmarks in picture pixels, face width)
    if len(boxes) and (opt["smooth"] > 0 or opt.get("unify", 0) > 0):
        beautify_body(out, boxes, models, opt, alone)
    for x0, y0, x1, y1 in alone:                       # their face as it was, also where a neighbour's crop reached it
        w, h = x1 - x0, y1 - y0
        a, b, c, d = int(max(0, x0 - w)), int(max(0, y0 - h)), int(min(W, x1 + w)), int(min(H, y1 + h))
        m = ellipse((d - b, c - a), ((x0 + x1) / 2 - a, (y0 + y1) / 2 - b - 0.08 * h), (0.68 * w, 0.82 * h), 0, 0.08 * w)[..., None]
        out[b:d, a:c] += m * (rgb[b:d, a:c] - out[b:d, a:c])
    return out
