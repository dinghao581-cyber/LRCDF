"""Selection help: which photos have closed eyes, are out of focus, have a burnt-out face, or repeat another one.
usage: cull.py --job job.tsv --out result.tsv        job.tsv lines: id <TAB> picture (about 1400 px long edge)
result lines: id <TAB> flags <TAB> sharpness <TAB> blink <TAB> faces     flags: comma list of "blur", "eyes", "over", "dup" (may be empty)
Judged on faces only: the sharpest face decides focus (a blurred second person or a mirror image does not count);
"eyes" when any of the main people (faces at least 60% as wide as the widest) has both eyes closed; "over" when a main
face is burnt out. "dup": the photo is nearly the same picture as its neighbour in the job and the neighbour is the
better one (no other flag, then sharper). Photos without a face get no flags except "dup"."""
import argparse, json, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import beauty, people, paths
from lrcdf.device import pick
from lrcdf.image_io import imread, imwrite
from lrcdf.mediapipe_io import base_options

LEGACY = paths.legacy("mac_project")
BLUR = 0.065   # sharpness below this: clearly out of focus (Gaussian blur of 4 px on a 1400 px picture gives 0.05-0.07, sharp faces 0.11+)
FACE = 30       # faces from this width (on the 1400 px picture) are told apart as people (at 26 px all 17 test faces still matched)
ABOUT = 60      # ... and from this width their age and sex are guessed
MAN = 0.10      # probability of female below this: a man (lighter retouching by default)
CHILD = 11      # guessed age below this: a child (lighter retouching by default)
MAIN = 0.6     # people who count: faces at least this wide relative to the widest
OVER = 0.25    # this share of a face at the top of the scale: burnt out
SAME = 0.965   # correlation of two small grey copies from here: the same picture again
BLINK = 0.68    # both eyes above this: closed. On 1600 PPR10K photos scores from 0.67 up were closed eyes; 0.55-0.66 mixed with looking down


_models = {}


def _cached(name, make):
    """The models are made once per process: the preview service runs main() for many requests."""
    if name not in _models:
        _models[name] = make()
    return _models[name]


def detector():
    if sys.platform == "win32":
        os.environ["NO_ALBUMENTATIONS_UPDATE"] = "1"
    base = f"{LEGACY}/external_models/modelscope_skin_v1_0_4"
    sys.path.insert(0, f"{base}/source")
    from modelscope.models.cv.skin_retouching.retinaface.predict_single import Model
    d = Model(max_size=960, device=pick() if sys.platform == "win32" else "cpu")
    d.load_state_dict(torch.load(f"{base}/retinaface_resnet50_2020-07-20_old_torch.pth", map_location="cpu", weights_only=True))
    d.eval()
    return d


def blink_reader():
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision
    lm = vision.FaceLandmarker.create_from_options(vision.FaceLandmarkerOptions(
        base_options=base_options(mpp.BaseOptions, f"{beauty.MODELS}/face_landmarker.task"), num_faces=1,
        output_face_blendshapes=True, min_face_detection_confidence=0.3, min_face_presence_confidence=0.3))

    def read(rgb8):
        """-> (blink of the less closed eye 0..1, looking down 0..1), or None when the face is not found."""
        res = lm.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb8)))
        if not res.face_blendshapes:
            return None
        s = {c.category_name: c.score for c in res.face_blendshapes[0]}
        return min(s.get("eyeBlinkLeft", 0), s.get("eyeBlinkRight", 0)), min(s.get("eyeLookDownLeft", 0), s.get("eyeLookDownRight", 0))
    return read


def sharpness(grey_face):
    """How steep the steepest edges in a face are, 0..1: the strongest brightness steps per pixel (after a slight blur
    against noise) relative to the face's contrast. In focus, lashes and lid edges change over one or two pixels of the
    1400 px picture; out of focus the same change is spread over many. Measured at the picture's own scale, because
    shrinking a face hides blur."""
    g = cv2.GaussianBlur(grey_face.astype(np.float32), (0, 0), 0.7)
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3) / 8; gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3) / 8
    contrast = float(np.percentile(g, 95) - np.percentile(g, 5)) + 8.0
    return float(np.percentile(np.hypot(gx, gy), 99.5) / contrast)


def judge(bgr, det, read, seen=None):
    rgb = np.ascontiguousarray(bgr[..., ::-1]); H, W = rgb.shape[:2]
    faces, points = [], {}
    for d in det.predict_jsons(rgb):
        if not d["bbox"] or d["score"] <= 0.7:
            continue
        x0, y0, x1, y1 = [int(v) for v in d["bbox"]]
        if x1 - x0 >= 24:
            faces.append((x0, y0, x1, y1)); points[(x0, y0, x1, y1)] = d["landmarks"]
    if not faces:
        return [], 0.0, 0.0, 0
    if seen is not None:
        seen.extend((f, points[f]) for f in faces if f[2] - f[0] >= FACE)
    widest = max(x1 - x0 for x0, y0, x1, y1 in faces)
    main = sorted((f for f in faces if f[2] - f[0] >= MAIN * widest), key=lambda f: f[0] - f[2])[:8]
    grey = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    s = max(sharpness(grey[max(0, y0):y1, max(0, x0):x1]) for x0, y0, x1, y1 in main)
    blink, over = 0.0, 0.0
    for x0, y0, x1, y1 in main:
        w, h = x1 - x0, y1 - y0; m = 0.4 * max(w, h)
        eyes = read(rgb[int(max(0, y0 - m)):int(min(H, y1 + m)), int(max(0, x0 - m)):int(min(W, x1 + m))])
        if eyes:
            blink = max(blink, eyes[0])
        inner = rgb[max(0, y0 + h // 6):y1 - h // 6, max(0, x0 + w // 6):x1 - w // 6]       # skin, not hair or background
        if inner.size:
            over = max(over, float((inner.max(2) >= 250).mean()))
    flags = []
    if s < BLUR:
        flags.append("blur")
    if blink > BLINK:
        flags.append("eyes")
    if over > OVER:
        flags.append("over")
    return flags, s, blink, len(faces)


def tiny(bgr):
    """Small grey copy without its mean, for comparing pictures: 32 x 32, slightly blurred so that a small shift counts little."""
    g = cv2.resize(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY), (32, 32), interpolation=cv2.INTER_AREA).astype(np.float32)
    g = cv2.GaussianBlur(g, (0, 0), 1.0); g -= g.mean()
    return g / (np.linalg.norm(g) + 1e-6)


def repeats(rows):
    """rows: [id, flags, sharpness, blink, faces, tiny] in job order. Runs of neighbours that are the same picture keep
    their best one; the others get "dup"."""
    k = 0
    while k < len(rows):
        run = [k]
        while run[-1] + 1 < len(rows) and rows[run[-1] + 1][5] is not None and rows[run[-1]][5] is not None \
                and float((rows[run[-1]][5] * rows[run[-1] + 1][5]).sum()) >= SAME:
            run.append(run[-1] + 1)
        if len(run) > 1:
            best = min(run, key=lambda r: (len(rows[r][1]), -rows[r][2]))
            for r in run:
                if r != best:
                    rows[r][1].append("dup")
        k = run[-1] + 1


class Album:
    """The people of the shoot, kept in people.json across calls:
    {"people": [{id, n, photos, thumb, vec, width, age, female, auto}]}.
    The faces of one photo are shared out among the known people (people.assign); the rest are new people. vec is the
    mean of the person's faces; thumb is their largest face so far (person_<id>.jpg next to the file); age and female
    are averages of the guesses; auto is "light" for men and children when the guesses are clear, else ""."""
    def __init__(self, path, fresh):
        self.path, self.reader = path, _cached("reader", people.Reader)
        self.list = [] if fresh or not os.path.exists(path) else json.load(open(path))["people"]

    def add(self, pid, bgr, seen):
        rgb = np.ascontiguousarray(bgr[..., ::-1]); H, W = rgb.shape[:2]
        seen = [(box, pts) for box, pts in seen if people.whole(box, pts)]
        vectors = [self.reader.vector(rgb, box, pts) for box, pts in seen]
        who = people.assign(vectors, [p["vec"] for p in self.list])
        fresh = {}                                   # new people of this photo; a mirror image joins its original
        for k, ((x0, y0, x1, y1), pts) in enumerate(seen):
            v = vectors[k]
            if who[k] is None:
                twin = next((n for n, u in fresh.items() if float(u @ v) >= people.TWICE), None)
                if twin is None:
                    self.list.append(dict(id=1 + max([p["id"] for p in self.list], default=0), n=0, photos=[], thumb="",
                                          vec=v.tolist(), width=0, age=0.0, female=0.5, auto=""))
                    twin = len(self.list) - 1; fresh[twin] = v
                who[k] = twin
            p = self.list[who[k]]
            mean = np.float32(p["vec"]) * p["n"] + v
            p["vec"] = (mean / (np.linalg.norm(mean) + 1e-9)).tolist()
            if x1 - x0 >= ABOUT:
                age, female = self.reader.about(rgb, (x0, y0, x1, y1))
                m = p.get("guesses", 0)
                p["age"] = (p["age"] * m + age) / (m + 1); p["female"] = (p["female"] * m + female) / (m + 1); p["guesses"] = m + 1
                p["auto"] = "light" if p["female"] < MAN or p["age"] < CHILD else ""
            p["n"] += 1
            if pid not in p["photos"]:
                p["photos"].append(pid)
            if x1 - x0 > p["width"]:
                w = x1 - x0; cx, cy = (x0 + x1) // 2, (y0 + y1) // 2; r = int(w * 0.8)
                crop = bgr[max(0, cy - r):min(H, cy + r), max(0, cx - r):min(W, cx + r)]
                p["thumb"] = os.path.join(os.path.dirname(self.path), f"person_{p['id']}.jpg"); p["width"] = int(w)
                imwrite(p["thumb"], cv2.resize(crop, (160, 160), interpolation=cv2.INTER_AREA))

    def save(self):
        json.dump({"people": self.list}, open(self.path + ".tmp", "w"))
        os.replace(self.path + ".tmp", self.path)


def main(argv=None):
    ap = argparse.ArgumentParser(); ap.add_argument("--job", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--people", help="people.json: the people of the shoot are added to it"); ap.add_argument("--fresh", type=int, default=0)
    a = ap.parse_args(argv)
    det, read = _cached("detector", detector), _cached("blink", blink_reader)
    album = Album(a.people, a.fresh) if a.people else None
    rows = []
    for line in open(a.job, encoding="utf-8"):
        if "\t" not in line:
            continue
        pid, path = line.rstrip("\n").split("\t")
        try:
            bgr = imread(path)
            seen = []
            flags, s, blink, n = judge(bgr, det, read, seen)
            if album:
                album.add(pid, bgr, seen)
            rows.append([pid, flags, s, blink, n, tiny(bgr)])
        except Exception as ex:
            rows.append([pid, [], 0.0, 0.0, 0, None]); print(pid, repr(ex), flush=True)
    repeats(rows)
    if album:
        album.save()
    lines = [f"{pid}\t{','.join(flags)}\t{s:.3f}\t{blink:.2f}\t{n}" for pid, flags, s, blink, n, _ in rows]
    print("\n".join(lines), flush=True)
    open(a.out + ".tmp", "w", encoding="utf-8").write("\n".join(lines) + "\n")
    os.replace(a.out + ".tmp", a.out)


if __name__ == "__main__":
    main()
