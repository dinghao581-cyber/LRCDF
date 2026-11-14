"""Reshaping on pixels (liquify): slimmer face, larger eyes, slimmer waist, fuller chest, longer legs.
Everything here is geometry only: plan() works out where each pixel of the result comes from, on a small sRGB copy,
and apply() resamples the real picture once, in whatever colour space and bit depth it has. Pixels that do not move
are not resampled. All of it is off by default, and each step is skipped when it cannot be done safely (body turned
away, something in front of it, legs not visible)."""
import os
import cv2
import numpy as np

MODELS = os.path.expanduser("~/LRCDF/models/mediapipe")
SLIM = 0.05      # face: at amount 1 the jaw angle moves in by this fraction of the face width, each side
EYES = 0.10      # eyes: at amount 1 they are magnified by this much at their centre
WAIST = 0.055    # waist: at amount 1 each side moves in by this fraction of the shoulder width
CHEST = 0.16     # chest: at amount 1 it is magnified by this much at its centre
LEGS = 0.07      # legs: at amount 1 they get this much longer
JAW_L = [234, 93, 132, 58, 172, 136, 150, 149, 176, 148]      # face outline from the ear down to the chin
JAW_R = [454, 323, 361, 288, 397, 365, 379, 378, 400, 377]
JAW_PULL = [0.15, 0.45, 0.8, 1.0, 1.0, 0.9, 0.7, 0.5, 0.3, 0.15]   # strongest at the jaw angle, fading to ear and chin
EYE_L = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
EYE_R = [263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466]
NOSE, L_SHOULDER, R_SHOULDER, L_ELBOW, R_ELBOW, L_WRIST, R_WRIST = 0, 11, 12, 13, 14, 15, 16
L_HIP, R_HIP, L_KNEE, R_KNEE, L_ANKLE, R_ANKLE = 23, 24, 25, 26, 27, 28
ARMS = [(L_SHOULDER, L_ELBOW), (L_ELBOW, L_WRIST), (R_SHOULDER, R_ELBOW), (R_ELBOW, R_WRIST)]


class Poses:
    def __init__(self):
        import mediapipe as mp
        from mediapipe.tasks import python as mpp
        from mediapipe.tasks.python import vision
        self.mp = mp
        self.pose = vision.PoseLandmarker.create_from_options(vision.PoseLandmarkerOptions(
            base_options=mpp.BaseOptions(model_asset_path=f"{MODELS}/pose_landmarker_heavy.task"), num_poses=4,
            min_pose_detection_confidence=0.5, output_segmentation_masks=True))

    def find(self, rgb8):
        """-> list of (points [33,2] in pixels, visibility [33], person mask [H,W] 0..1)."""
        res = self.pose.detect(self.mp.Image(image_format=self.mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb8)))
        h, w = rgb8.shape[:2]
        out = []
        for k, lm in enumerate(res.pose_landmarks):
            pts = np.array([[p.x * w, p.y * h] for p in lm], np.float32)
            vis = np.array([p.visibility for p in lm], np.float32)
            mask = np.squeeze(res.segmentation_masks[k].numpy_view()).astype(np.float32) if res.segmentation_masks else None
            out.append((pts, vis, mask))
        return out


def _segment_distance(p, a, b):
    ab = b - a
    t = float(np.clip(np.dot(p - a, ab) / (np.dot(ab, ab) + 1e-6), 0, 1))
    return float(np.linalg.norm(p - (a + t * ab)))


def _arm_near(pts, vis, p, reach):
    """Is an upper arm, forearm or hand within `reach` of point p? Unsure counts as yes."""
    for a, b in ARMS:
        if min(vis[a], vis[b]) < 0.3:
            continue                                   # that arm is out of sight
        if _segment_distance(p, pts[a], pts[b]) < reach:
            return True
    return any(vis[k] > 0.3 and np.linalg.norm(pts[k] - p) < reach for k in range(17, 23))


def torso(pts, vis):
    """The frame of a torso seen from the front: (mid shoulders, down, across, shoulder width, torso length), or None
    when shoulders/hips are hidden, the body is turned sideways, or the person has their back to the camera."""
    if min(vis[L_SHOULDER], vis[R_SHOULDER], vis[L_HIP], vis[R_HIP]) < 0.6 or vis[NOSE] < 0.5:
        return None
    ms, mh = (pts[L_SHOULDER] + pts[R_SHOULDER]) / 2, (pts[L_HIP] + pts[R_HIP]) / 2
    length = float(np.linalg.norm(mh - ms)); width = float(np.linalg.norm(pts[L_SHOULDER] - pts[R_SHOULDER]))
    if length < 20 or not 0.5 <= width / length <= 1.15:      # turned sideways (narrow) or foreshortened (wide)
        return None
    down = (mh - ms) / length
    r_to_l = pts[L_SHOULDER] - pts[R_SHOULDER]
    if r_to_l[0] * down[1] - r_to_l[1] * down[0] <= 0:        # from the front, the person's left is on our right
        return None
    across = np.array([-down[1], down[0]], np.float32)
    return ms, down, across, width, length


def _face(field, xs, ys, pts, f, slim, eyes):
    top, chin = pts[168], pts[152]
    axis = (chin - top) / (np.linalg.norm(chin - top) + 1e-6)
    if slim > 0:
        total = np.zeros(xs.shape, np.float32); part = np.zeros(xs.shape + (2,), np.float32)
        sigma = f * 0.1
        for side in (JAW_L, JAW_R):
            for i, pull in zip(side, JAW_PULL):
                p = pts[i]
                foot = top + np.dot(p - top, axis) * axis            # nearest point of the midline
                away = np.linalg.norm(foot - p)
                if away < 1:
                    continue
                # the far side of a turned face is close to the midline: move it less
                move = (foot - p) / away * slim * SLIM * f * pull * min(1.0, away / (0.25 * f))
                g = np.exp(-((xs - p[0]) ** 2 + (ys - p[1]) ** 2) / (2 * sigma ** 2))
                part += g[..., None] * move; total += g
        field -= part / np.maximum(total, 1.0)[..., None]
    if eyes > 0:
        for eye in (EYE_L, EYE_R):
            c = pts[eye].mean(0); width = float(np.linalg.norm(pts[eye[0]] - pts[eye[8]]))
            if width < f * 0.08:                       # an eye this narrow is turned away from the camera
                continue
            radius = width * 1.05
            dx, dy = xs - c[0], ys - c[1]
            inside = np.clip(1 - (dx * dx + dy * dy) / (radius * radius), 0, 1) ** 2
            field[..., 0] -= dx * eyes * EYES * inside; field[..., 1] -= dy * eyes * EYES * inside


def _body(field, xs, ys, person, chest, waist, note):
    pts, vis, mask = person
    frame = torso(pts, vis)
    if frame is None:
        return
    ms, down, across, width, length = frame
    h, w = xs.shape
    if waist > 0 and mask is not None:
        # the outline at waist height: walk out from the body's middle along the waist line until the person ends
        centre = ms + down * 0.68 * length
        for side in (-1.0, 1.0):
            edge = None
            for step in np.arange(0.12, 0.75, 0.01) * width:
                p = centre + across * side * step
                x, y = int(round(p[0])), int(round(p[1]))
                if not (0 <= x < w and 0 <= y < h) or mask[y, x] < 0.5:
                    edge = p
                    break
            # an arm hanging at the side is part of the silhouette: then the "outline" is the arm, not the waist
            if edge is None or np.linalg.norm(edge - centre) > 0.62 * width or _arm_near(pts, vis, edge, 0.14 * width):
                continue
            move = -across * side * waist * WAIST * width            # towards the middle
            # a tall, narrow patch around the outline: the waist line is pulled in, shoulders and hips stay
            along = (xs - edge[0]) * down[0] + (ys - edge[1]) * down[1]
            beside = (xs - edge[0]) * across[0] + (ys - edge[1]) * across[1]
            g = np.exp(-(along / (0.20 * length)) ** 2 - (beside / (0.16 * width)) ** 2)
            field[..., 0] -= g * move[0]; field[..., 1] -= g * move[1]
            note.append("waist")
    if chest > 0:
        for side in (-1.0, 1.0):
            c = ms + down * 0.30 * length + across * side * 0.20 * width
            radius = 0.21 * width
            if _arm_near(pts, vis, c, radius * 1.3):      # an arm or hand in front would be blown up instead
                continue
            dx, dy = xs - c[0], ys - c[1]
            inside = np.clip(1 - (dx * dx + dy * dy) / (radius * radius), 0, 1) ** 2
            field[..., 0] -= dx * chest * CHEST * inside; field[..., 1] -= dy * chest * CHEST * inside
            note.append("chest")


def _legs(people, h, amount):
    """Row map for longer legs: result row -> source row (length h), or None. The picture keeps its size: the legs are
    stretched upwards and the rows that pushes out at the top are dropped, so there must be room above the heads."""
    standing = []
    for pts, vis, mask in people:
        if min(vis[[L_HIP, R_HIP, L_KNEE, R_KNEE, L_ANKLE, R_ANKLE]]) < 0.6:
            continue
        hip, ankle = (pts[L_HIP] + pts[R_HIP]) / 2, (pts[L_ANKLE] + pts[R_ANKLE]) / 2
        leg = ankle - hip
        if leg[1] < 0.12 * h or abs(leg[0]) > 0.35 * leg[1]:          # sitting, lying, or legs far from upright
            continue
        if min(pts[L_KNEE][1], pts[R_KNEE][1]) < hip[1] or max(pts[L_KNEE][1], pts[R_KNEE][1]) > ankle[1]:
            continue
        top = float(np.where(mask.max(1) > 0.5)[0].min()) if mask is not None and (mask > 0.5).any() else float(pts[:, 1].min())
        standing.append((hip[1], ankle[1], top))
    if not standing or len(standing) != len(people):                  # someone would be stretched in the wrong place
        return None
    y0 = float(np.mean([s[0] for s in standing])); y1 = float(np.mean([s[1] for s in standing]))
    if max(abs(s[0] - y0) for s in standing) > 0.06 * h or max(abs(s[1] - y1) for s in standing) > 0.06 * h:
        return None                                                   # people standing at different heights
    y0 += 0.12 * (y1 - y0)                                            # from the upper thigh down
    headroom = min(s[2] for s in standing) * 0.8
    k = 1 + amount * LEGS
    added = min((k - 1) * (y1 - y0), headroom)
    if added < 0.004 * h:
        return None
    k = 1 + added / (y1 - y0)
    src = np.arange(h, dtype=np.float32)
    soft = max(2.0, 0.03 * (y1 - y0))
    ramp = lambda v: 1 / (1 + np.exp(-v))
    scale = 1 + (k - 1) * ramp((src - y0) / soft) * ramp((y1 - src) / soft)   # how much each source row is stretched
    position = np.cumsum(scale) - scale[0]
    position -= position[-1] - (h - 1)                                # the bottom row stays where it is
    return np.interp(src, position, src).astype(np.float32)


def plan(rgb, meshes, poses, slim=0.0, eyes=0.0, chest=0.0, waist=0.0, legs=0.0, note=None, alone=(), men=()):
    """rgb: float32 sRGB 0..1, the picture as shot. meshes: [(face landmarks [478,2] in pixels, face width)].
    Returns None when nothing is to be done, else (field, scale, rows): on a copy `scale` times the size, the result at
    (x, y) comes from (x + field[y, x, 0], rows[y] + field[y, x, 1]) (field or rows may be None)."""
    note = note if note is not None else []
    H, W = rgb.shape[:2]
    s = min(1.0, 1536 / max(H, W))
    h, w = int(round(H * s)), int(round(W * s))
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    field = np.zeros((h, w, 2), np.float32)
    if slim > 0 or eyes > 0:
        for pts, f in meshes:
            _face(field, xs, ys, pts * s, f * s, slim, eyes)
    rows = None
    if chest > 0 or waist > 0 or legs > 0:
        small = cv2.resize(rgb, (w, h), interpolation=cv2.INTER_AREA)
        people = poses.find(np.rint(np.clip(small, 0, 1) * 255).astype(np.uint8))
        # People who are left alone (their face boxes are in `alone`, picture pixels): the body under such a face is
        # not reshaped, and legs are not lengthened at all, because that stretches whole rows of the picture.
        def spared(person, boxes=None):
            x, y = person[0][NOSE] / s
            return any(x0 - 0.3 * (x1 - x0) < x < x1 + 0.3 * (x1 - x0) and y0 - 0.3 * (y1 - y0) < y < y1 + 0.3 * (y1 - y0)
                       for x0, y0, x1, y1 in (alone if boxes is None else boxes))
        for person in people:
            if not spared(person):
                _body(field, xs, ys, person, 0.0 if spared(person, men) else chest, waist, note)     # no fuller chest for men
        if legs > 0 and not alone:
            rows = _legs(people, h, legs)
            if rows is not None:
                note.append("legs")
    if float(np.hypot(field[..., 0], field[..., 1]).max()) < 0.05:
        field = None
    return None if field is None and rows is None else (field, s, rows)


def apply(img, geometry):
    """Resample img (uint8/uint16/float, any colour space) according to plan()'s result."""
    if geometry is None:
        return img
    field, s, rows = geometry
    H, W = img.shape[:2]
    gy, gx = np.mgrid[0:H, 0:W].astype(np.float32)
    if rows is not None:
        full = np.interp(np.arange(H, dtype=np.float32) * s, np.arange(len(rows), dtype=np.float32), rows) / s
        if field is not None:      # the field is in result coordinates; bring it along with the rows
            ry, rx = np.mgrid[0:field.shape[0], 0:field.shape[1]].astype(np.float32)
            field = cv2.remap(field, rx, np.repeat(rows[:, None], field.shape[1], 1), cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        my = np.repeat(full[:, None].astype(np.float32), W, 1)
    else:
        my = gy
    mx = gx
    still = None
    if field is not None:
        big = cv2.resize(field, (W, H), interpolation=cv2.INTER_LINEAR) / s
        mx = gx + big[..., 0]; my = my + big[..., 1]
        if rows is None:
            still = np.hypot(big[..., 0], big[..., 1]) < 0.03
    top = 65535.0 if img.dtype == np.uint16 else 255.0 if img.dtype == np.uint8 else 1.0
    out = cv2.remap(img.astype(np.float32), mx, my, cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REFLECT_101)
    out = np.clip(out, 0, top)
    out = out if img.dtype.kind == "f" else np.rint(out).astype(img.dtype)
    if still is not None:
        out[still] = img[still]                    # where nothing moves, nothing is resampled
    return out
