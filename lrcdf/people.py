"""Who is who: one vector per face (OpenCV's SFace, Apache 2.0), so that the same person is found again in the other
photos of a shoot and can be given their own retouching ("leave the groom natural, the bride refined, the child alone").
Also a guess at age and sex per face (ViT trained on UTKFace, Apache 2.0), for a lighter default on men and children."""
import json, os, sys
import cv2, numpy as np
from lrcdf import paths

MODEL = paths.models("sface", "face_recognition_sface_2021dec.onnx")
ABOUT = paths.models("agegender", "model.onnx")
SAME = 0.40      # cosine similarity from which a face is taken for a known person (the model's own threshold is 0.363; at 0.36 two strangers merged)
TWICE = 0.60     # two faces in ONE photo are the same person only from here (a mirror: 0.63-0.70 measured); relatives
                 # reach 0.55, the same person in different photos 0.34-0.70 - which is why one photo's faces are told
                 # apart by exclusion and not by the threshold


class Reader:
    def __init__(self):
        if sys.platform == "win32" and not MODEL.isascii():
            self.net = cv2.FaceRecognizerSF.create("onnx", np.fromfile(MODEL, dtype=np.uint8),
                                                   np.empty(0, dtype=np.uint8))
        else:
            self.net = cv2.FaceRecognizerSF.create(MODEL, "")
        self.guess = None

    def vector(self, rgb8, box, points):
        """box: x0, y0, x1, y1; points: the detector's five (eyes, nose, mouth corners), all in picture pixels."""
        x0, y0, x1, y1 = box
        row = np.float32([x0, y0, x1 - x0, y1 - y0] + [v for p in points for v in p] + [1.0])
        v = self.net.feature(self.net.alignCrop(np.ascontiguousarray(rgb8[..., ::-1]), row))[0].astype(np.float32)
        return v / (np.linalg.norm(v) + 1e-9)

    def about(self, rgb8, box):
        """-> (age in years, probability of female) for the face in the box."""
        if self.guess is None:
            import onnxruntime as ort
            self.guess = ort.InferenceSession(ABOUT, providers=["CPUExecutionProvider"])
        x0, y0, x1, y1 = box
        m = 0.25 * max(x1 - x0, y1 - y0); H, W = rgb8.shape[:2]
        crop = rgb8[int(max(0, y0 - m)):int(min(H, y1 + m)), int(max(0, x0 - m)):int(min(W, x1 + m))]
        x = cv2.resize(crop, (224, 224), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        x = ((x - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]).astype(np.float32).transpose(2, 0, 1)[None]
        age, female = self.guess.run(None, {self.guess.get_inputs()[0].name: x})[0].ravel()[:2]
        return float(np.clip(age, 0, 100)), float(np.clip(female, 0, 1))


def whole(box, points):
    """Is this a whole face (both eyes and the mouth apart from each other), not a cheek or a strong profile?"""
    w = box[2] - box[0]
    (ax, ay), (bx, by), _, (cx, cy), (dx, dy) = points
    eyes = np.hypot(bx - ax, by - ay)
    drop = np.hypot((cx + dx) / 2 - (ax + bx) / 2, (cy + dy) / 2 - (ay + by) / 2)
    return eyes > 0.22 * w and drop > 0.5 * eyes


def assign(vectors, known):
    """Which known person each face of ONE photo is: list of indices into `known` (unit vectors) or None.
    Best matches first; a person already given to a face of this photo is given to another one only if the two faces
    are near-identical (a mirror)."""
    out = [None] * len(vectors)
    if not len(vectors) or not len(known):
        return out
    V = np.asarray(vectors, np.float32); S = V @ np.asarray(known, np.float32).T
    taken = {}
    for flat in np.argsort(-S, axis=None):
        f, p = divmod(int(flat), S.shape[1])
        if S[f, p] < SAME:
            break
        if out[f] is not None:
            continue
        if p in taken and float(V[f] @ V[taken[p]]) < TWICE:
            continue
        out[f] = p; taken.setdefault(p, f)
    return out


class Choices:
    """The people of a shoot (people.json written by cull.py) and what was chosen for some of them.
    choices: "3:off,5:refined" (person id : level); levels: "natural=1,0.6,0.5,0.4,0.4/refined=..." in the order of KEYS."""
    KEYS = ("blemish", "smooth", "undereye", "eyes", "teeth")

    def __init__(self, path, choices, levels):
        self.reader, self.vectors, self.wanted, self.male, self.men = None, [], [], [], []
        table = {}
        for part in filter(None, (levels or "").split("/")):
            name, values = part.split("=")
            table[name] = dict(zip(self.KEYS, map(float, values.split(","))))
        self.table = table
        want = dict(p.split(":") for p in filter(None, (choices or "").split(",")))
        if path and os.path.exists(path):
            for person in json.load(open(path))["people"]:       # everyone, so that a relative is not taken for the chosen one
                level = want.get(str(person["id"]))
                self.vectors.append(np.float32(person["vec"]))
                self.wanted.append(None if level == "off" else table[level] if level in table else {})
                self.male.append(person.get("guesses", 0) > 0 and person.get("female", 0.5) < 0.5)      # likely a man: no fuller chest (a miss costs a woman little)
            self.reader = Reader() if self.vectors else None

    def of(self, rgb8, faces):
        """faces: the detector's results for one photo. Per face: {} (nothing chosen), None (leave this person alone)
        or the options chosen for them. Afterwards self.men holds the face boxes of the men among them."""
        self.men = []
        if not self.reader:
            return [{} for _ in faces]
        good = [k for k, d in enumerate(faces) if whole(d["bbox"], d["landmarks"])]
        who = assign([self.reader.vector(rgb8, faces[k]["bbox"], faces[k]["landmarks"]) for k in good], self.vectors)
        out = [{} for _ in faces]
        for k, p in zip(good, who):
            if p is not None:
                out[k] = self.wanted[p]
                if self.male[p]:
                    self.men.append(faces[k]["bbox"])
        return out
