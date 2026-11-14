"""One-click beautification for the Lightroom plug-in: blemish removal (RetouchFormer) + skin evening,
under-eye, eyes and teeth (lrcdf.beauty). Works on full-size 16-bit TIFFs and keeps their colour profile:
sRGB in -> sRGB out (8 or 16 bit); ProPhoto RGB in with --bits 16 -> 16-bit ProPhoto out, untouched pixels identical.
usage: beautify.py --job job.tsv [--blemish 1 --smooth .6 --undereye .5 --eyes .4 --teeth .4] [--bits 8|16]
job.tsv lines: input.tif <TAB> output.tif     Prints one JSON line per photo."""
import argparse, json, os, sys, time
import cv2, numpy as np, tifffile, torch
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..")); sys.path.insert(0, os.path.dirname(__file__))
from lrcdf import beauty, people, shape

LEGACY = os.path.expanduser("~/LRCDF/legacy/mac_project")
HIRES_FROM = 900     # face crops covering at least this many pixels of the photo are retouched at 1024 instead of 512
sys.path.insert(0, f"{LEGACY}/scripts")
import train_dodge
import retouch_photo as legacy  # face_transform, feather, blend_float, skin_weight


def load_models(device):
    base = f"{LEGACY}/external_models/modelscope_skin_v1_0_4"
    sys.path.insert(0, f"{base}/source")
    from modelscope.models.cv.skin_retouching.retinaface.predict_single import Model
    detector = Model(max_size=960, device="cpu")
    detector.load_state_dict(torch.load(f"{base}/retinaface_resnet50_2020-07-20_old_torch.pth", map_location="cpu", weights_only=True))
    detector.eval()
    # RetouchFormer (blemish pass on small faces) is loaded when it is installed; without it small faces get the
    # classical steps only.
    net = None
    if os.path.exists(f"{LEGACY}/gen_best.pth") and os.path.isdir(f"{LEGACY}/external_models/RetouchFormer_AAAI_24"):
        sys.path.insert(0, f"{LEGACY}/external_models/RetouchFormer_AAAI_24")
        from model.RetouchFormer import InpaintGenerator
        net = InpaintGenerator()
        net.load_state_dict(torch.load(f"{LEGACY}/gen_best.pth", map_location="cpu", weights_only=True), strict=True)
        net = net.to(device).eval()
    return detector, net, beauty.Models()


RETOUCHER = os.path.join(os.path.dirname(__file__), "..", "runs", "retouch_model.pt")
_RETOUCHER = None


def retoucher(device):
    """The retouching model trained on FFHQR (scripts/train_retouch.py), or None when it is not installed."""
    global _RETOUCHER
    if _RETOUCHER is None and os.path.exists(RETOUCHER):
        from train_retouch import RetouchNet
        ck = torch.load(RETOUCHER, map_location="cpu", weights_only=False)
        net = RetouchNet(ck.get("width", 40)); net.load_state_dict(ck["model"])
        _RETOUCHER = net.to(device).eval()
    return _RETOUCHER


DODGER = os.path.join(os.path.dirname(__file__), "..", "runs", "dodge_model.pt")
_DODGER = None


def dodger(device):
    """The dodge-and-burn model (scripts/train_dodge.py), or None when it is not installed."""
    global _DODGER
    if _DODGER is None and os.path.exists(DODGER):
        from train_dodge import DodgeNet
        ck = torch.load(DODGER, map_location="cpu", weights_only=False)
        net = DodgeNet(ck.get("width", 32)); net.load_state_dict(ck["model"])
        _DODGER = net.to(device).eval()
    return _DODGER


def heal(out, heals, skin, amount=beauty.HEAL):
    """Tone down the texture layer where the dodge model marked a blemish. out: float picture 0..255, changed in place.
    heals: (mask in crop space, feather, transform, face width in the photo, strength) per face."""
    H, W = out.shape[:2]
    for mask, feather, tf, face, strength in heals:
        inv = cv2.invertAffineTransform(tf); n = mask.shape[0]
        corners = np.float32([[0, 0], [n, 0], [0, n], [n, n]]) @ inv[:, :2].T + inv[:, 2]
        x0, y0 = np.floor(corners.min(0)).astype(int); x1, y1 = np.ceil(corners.max(0)).astype(int)
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, W), min(y1, H)
        if x1 - x0 < 8 or y1 - y0 < 8:
            continue
        move = inv.copy(); move[:, 2] -= (x0, y0)
        m = cv2.warpAffine(mask * feather, move, (int(x1 - x0), int(y1 - y0)), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        m *= skin[y0:y1, x0:x1]
        if m.max() < 0.05:
            continue
        part = out[y0:y1, x0:x1]
        part -= (amount * strength * m)[..., None] * (part - cv2.GaussianBlur(part, (0, 0), face * beauty.SPLIT))


SHADOW = os.path.join(os.path.dirname(__file__), "..", "runs", "shadow_model.pt")
_SHADOW = None


def deshadow(rgb, faces, amount, device, note=None):
    """Cast shadows on the faces taken out (lrcdf/shadow.py, scripts/train_shadow.py), or rgb itself when there is
    nothing to do. rgb: float 0..255. The model sees each face at up to 768 px and answers with a factor per pixel
    and colour; the factor is brought to the photo's resolution with the photo's own edges as a guide, so the rim of
    a shadow is undone where it really is, and applied in linear light. It only ever lightens."""
    global _SHADOW
    if amount <= 0 or not os.path.exists(SHADOW) or not faces:
        return rgb
    from lrcdf import shadow
    if _SHADOW is None:
        from train_retouch import RetouchNet
        ck = torch.load(SHADOW, map_location="cpu", weights_only=False)
        _SHADOW = RetouchNet(ck.get("width", 32)); _SHADOW.load_state_dict(ck["model"]); _SHADOW = _SHADOW.to(device).eval()
    H, W = rgb.shape[:2]
    total = None
    for d in faces:
        tf = legacy.face_transform(d["landmarks"])
        side = 512 / float(np.hypot(tf[0, 0], tf[0, 1]))
        if side < 300:              # a small face in the photo: too few pixels to tell a shadow from a feature
            continue
        n = int(np.clip(side, 256, 768)) // 16 * 16
        crop = cv2.warpAffine(rgb, tf * (n / 512), (n, n), flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REFLECT_101) / 255.0
        with torch.inference_mode():
            x = torch.from_numpy(np.clip(crop, 0, 1).astype(np.float32)).permute(2, 0, 1)[None].to(device)
            L = _SHADOW(x)[0].permute(1, 2, 0).cpu().numpy()
        L = np.clip(L - 0.03, 0, 1.4)                     # only real shadows, only lightening, at most four times
        if note is not None:
            note.append(round(float((L.max(2) > 0.1).mean()), 3))      # share of the crop found to be in shadow
        if L.max() < 0.08:
            continue
        m = int(np.clip(side, n, 1536)) // 2 * 2
        tfm = tf * (m / 512)
        if m > n:
            big = cv2.warpAffine(rgb, tfm, (m, m), flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REFLECT_101) / 255.0
            L = cv2.resize(L, (m, m), interpolation=cv2.INTER_LINEAR)
            L = np.clip(shadow.guided(np.ascontiguousarray(big @ np.float32([0.299, 0.587, 0.114])), L, max(2, int(round(1.5 * m / n)))), 0, 1.4)
        L = L * (amount * cv2.resize(legacy.feather(), (m, m), interpolation=cv2.INTER_LINEAR))[..., None]
        back = cv2.warpAffine(L, cv2.invertAffineTransform(tfm), (W, H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
        total = back if total is None else np.maximum(total, back)
    if total is None:
        return rgb
    lit = np.where(total.max(2) > 1e-3)
    if not len(lit[0]):
        return rgb
    y0, y1, x0, x1 = lit[0].min(), lit[0].max() + 1, lit[1].min(), lit[1].max() + 1
    out = rgb.copy()
    part = np.clip(out[y0:y1, x0:x1] / 255.0, 0, 1) ** 2.2 * np.exp(total[y0:y1, x0:x1])
    out[y0:y1, x0:x1] = np.clip(part, 0, 1) ** (1 / 2.2) * 255.0
    return out


CRITIC = os.path.join(os.path.dirname(__file__), "..", "runs", "critic_model.pt")
_CRITIC = None
TEXTURE_LIMIT = 1.4     # x the critic's 90th percentile: professionals go beyond this on about 3 faces in 100
COLOUR_LIMIT = (2.0, 2.1)   # limit = (a + b * smooth) x the 90th percentile: what our own levels reach on 9 faces in 10


def judge(rgb, out, faces, each, device):
    """Per face: None (not judged: left alone, too small, hardly any skin in view) or a dict with `over` (1 = at the
    limit), what was measured and what is needed to take the face back. See guard."""
    global _CRITIC
    found = [None] * len(faces)
    if not os.path.exists(CRITIC):
        return found
    import train_critic
    if _CRITIC is None:
        ck = torch.load(CRITIC, map_location="cpu", weights_only=False)
        _CRITIC = train_critic.Critic(pretrained=False); _CRITIC.load_state_dict(ck["model"]); _CRITIC = _CRITIC.to(device).eval()
    n = train_critic.SIDE
    for k, (d, f) in enumerate(zip(faces, each)):
        if not f:
            continue
        tf = legacy.face_transform(d["landmarks"]) * (n / 512)
        if 512 / float(np.hypot(tf[0, 0], tf[0, 1])) * (512 / n) < 200:      # too small in the photo to measure texture
            continue
        warp = lambda im: cv2.warpAffine(im, tf, (n, n), flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REFLECT_101) / 255.0
        x, y = warp(rgb), warp(out)
        w = train_critic.skin_of(x)
        if w.mean() < 0.03:
            continue
        marks = train_critic.corrected(x, y)       # blemishes are not smoothing: judged and taken back without them
        w = w * (1 - marks)
        if w.mean() < 0.02:
            continue
        colour, texture = train_critic.measure(x, y, w)
        view = cv2.resize(x, (train_critic.VIEW, train_critic.VIEW), interpolation=cv2.INTER_AREA)
        with torch.inference_mode():
            q = train_critic.decode(_CRITIC(torch.from_numpy(view).permute(2, 0, 1)[None].float().to(device)).cpu())[0.9]
        over = max(colour / ((COLOUR_LIMIT[0] + COLOUR_LIMIT[1] * f["smooth"]) * max(q[0], 0.3)),
                   texture / (TEXTURE_LIMIT * max(q[1], 0.03)))
        found[k] = dict(colour=round(colour, 2), texture=round(texture, 3), expected=[round(q[0], 2), round(q[1], 3)],
                        over=round(float(over), 2), _tf=tf, _marks=marks)
    return found


def guard(rgb, out, faces, each, device, note=None):
    """The "retouched too much" check (scripts/train_critic.py). For every retouched face, how much was changed is
    measured the way professionals' work was measured, and compared with what the critic expects professionals to do
    on this very face. Texture: more taken away than they almost ever take is overdone. Colour: our levels even colour
    about three times as much as FFHQR's retouchers on purpose, so there the limit is what the chosen level itself
    reaches on nine faces in ten - only the unusual face is caught. Places where a blemish was corrected are left out of both the
    measuring and the taking back: removing acne is not smoothing. An overdone face is taken back towards the
    original until it is at the limit (never by more than half). rgb, out: float 0..255; out is changed in place."""
    n = 512
    for j in judge(rgb, out, faces, each, device):
        if j is None:
            continue
        keep = 1.0 if j["over"] <= 1 else max(0.5, 1 / j["over"])
        if note is not None:
            note.append(dict({k: v for k, v in j.items() if not k.startswith("_")}, kept=round(keep, 2)))
        if keep < 1:
            inv = cv2.invertAffineTransform(j["_tf"])
            m = cv2.warpAffine(cv2.resize(legacy.feather(), (n, n), interpolation=cv2.INTER_LINEAR) * (1 - j["_marks"]), inv, (out.shape[1], out.shape[0]),
                               flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
            out -= (m * (1 - keep))[..., None] * (out - rgb)


AUTO = ("refined", "natural", "light")      # tried in this order: the strongest level that is not overdone
AUTO_ROOM = dict(refined=0.7)               # 精致 only with room to spare: it is the level "for close-ups", not the default


def choose(rgb, models, opt, device):
    """Automatic level. For every face nobody chose a level for: the strongest of 精致 / 自然 / 轻 that the critic does
    not find overdone on this face (judge). Decided on a copy of at most 2600 px, with the levels' values from
    opt["who"].table. Returns [(x, y, width, level name)], positions as fractions of the picture."""
    table = getattr(opt.get("who"), "table", None) or {}
    if not all(name in table for name in AUTO):
        return []
    h, w = rgb.shape[:2]
    s = min(1.0, 2600 / max(h, w))
    small = rgb if s == 1 else cv2.resize(rgb, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    memo = opt.get("_memo") if s == 1 and opt.get("_memo") is not None else {}
    picked = {}
    for name in AUTO:
        o = dict(opt, **table[name]); o.update(auto=0, guard=0, _memo=memo, _judge=[]); o.pop("_auto", None)
        retouch(small, models, o, device)
        for k, j in enumerate(o["_judge"]):
            if j is not None and k not in picked and (j["over"] <= AUTO_ROOM.get(name, 1.0) or name == AUTO[-1]):
                picked[k] = name
            elif j is None:
                picked.setdefault(k, None)
    out = []
    for k, d in enumerate(memo.get("faces", [])):
        if picked.get(k):
            x0, y0, x1, y1 = d["bbox"]
            out.append(((x0 + x1) / 2 / small.shape[1], (y0 + y1) / 2 / small.shape[0], (x1 - x0) / small.shape[1], picked[k]))
    return out


def read(path):
    with tifffile.TiffFile(path) as t:
        page = t.pages[0]; img = page.asarray()
        icc = page.tags["InterColorProfile"].value if "InterColorProfile" in page.tags else None
    if img.ndim == 2:
        img = np.stack([img] * 3, -1)
    return img[..., :3], icc


def kept(memo, key, make):
    """make() once per picture: memo is the dict a caller keeps for ONE picture (see retouch), or None."""
    if memo is None:
        return make()
    if key not in memo:
        memo[key] = make()
    return memo[key]


def retouch(rgb, models, opt, device):
    """rgb: float32 sRGB picture, 0..255. Returns (retouched picture in the same scale, number of faces).
    opt["_memo"]: a dict the caller keeps for this one picture. The faces found, the skin map and what the blemish
    model proposes do not depend on the chosen strengths and are taken from it the second time (the preview server
    asks for several levels of one picture)."""
    detector, net, regions = models
    memo = opt.get("_memo")
    rgb8 = np.rint(np.clip(rgb, 0, 255)).astype(np.uint8)
    faces = kept(memo, "faces", lambda: [d for d in detector.predict_jsons(rgb8) if d["bbox"] and d["score"] > 0.6])
    if opt.get("light", 0) > 0:         # 匀光 also takes out shadows cast onto the faces; everything after works on that picture
        if memo is not None:
            memo = memo.setdefault("lit", {"faces": faces})
        opt["_shadow"] = []
        rgb = kept(memo, "deshadow", lambda: deshadow(rgb, faces, min(1.0, opt["light"] / 0.7), device, opt["_shadow"]))
        rgb8 = np.rint(np.clip(rgb, 0, 255)).astype(np.uint8)
    out = rgb
    # What each face gets: the chosen level, or what was chosen for that person (None = leave them alone).
    who = opt.get("who")
    own = who.of(rgb8, faces) if who else [{} for _ in faces]
    if opt.get("auto"):           # automatic level for the faces nobody chose one for (choose); the others keep theirs
        if "_auto" not in opt:
            opt["_auto"] = kept(memo, "auto", lambda: choose(rgb, models, opt, device))
        H, W = rgb.shape[:2]
        for k, d in enumerate(faces):
            if own[k] == {}:
                cx, cy = (d["bbox"][0] + d["bbox"][2]) / 2 / W, (d["bbox"][1] + d["bbox"][3]) / 2 / H
                near = [a for a in opt["_auto"] if abs(a[0] - cx) < 0.5 * a[2] and abs(a[1] - cy) * H / W < 0.5 * a[2]]
                if near:
                    own[k] = dict(who.table[near[0][3]], _level=near[0][3])
    each = []
    for o in own:
        if o is None:
            each.append(None); continue
        f = dict(opt, **o)
        f["shine"] = opt["shine"] * min(1.6, f["smooth"] / beauty.DEFAULTS["smooth"])      # follows the level
        f["spots"] = opt["spots"] * f["blemish"]
        each.append({k: f[k] for k in list(beauty.DEFAULTS) + ["blemish"]})
    opt["_levels"] = [o.get("_level") if o else None for o in own]
    followers = [o is not None and "_level" not in o and not (set(o) - {"_level"}) for o in own]     # nobody chose for them
    if any(f and f["blemish"] > 0 for f in each):
        edits, heals = [], []
        with torch.inference_mode():
            for index, (d, f) in enumerate(zip(faces, each)):
                if not f or f["blemish"] <= 0:
                    continue
                amount = min(1.0, f["blemish"])
                ready = memo.get(("edit", index, opt.get("model", "new"))) if memo is not None else None
                if ready is not None:
                    edits.append((ready[0] * amount, ready[1], ready[2]))
                    if ready[3] is not None:
                        heals.append(ready[3] + (amount,))
                    continue
                tf = legacy.face_transform(d["landmarks"])
                # The model was trained on 512 px faces. On a big face it is run at 1024 px instead (it accepts that),
                # so that its corrections are not a 512 px patch blown up: side = pixels of the photo the crop covers.
                side = 512 / float(np.hypot(tf[0, 0], tf[0, 1]))
                size = 1024 if side >= HIRES_FROM and opt.get("hires", 0) else 512
                # small faces (crop under 300 px of the photo) stay with RetouchFormer: enlarged to 1024 they lost texture
                dodge = dodger(device) if opt.get("model", "new") == "dodge" else None
                if dodge is not None:
                    # Dodge-and-burn model: a smooth map to add (made at a quarter of the working size and enlarged, so
                    # it cannot touch texture) and a heal mask. The face is worked on at its own size up to 1024 px.
                    n = int(np.clip(side, 256, 1024)) // 16 * 16
                    tf = tf * (n / 512)
                    crop = cv2.warpAffine(rgb8, tf, (n, n), flags=cv2.INTER_AREA if side > n else cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
                    x = torch.from_numpy(crop.copy()).permute(2, 0, 1).float()[None].to(device) / 255
                    add, mark = train_dodge.apply(dodge, x)
                    mask = cv2.resize(legacy.feather(), (n, n), interpolation=cv2.INTER_LINEAR)
                    ready = (add[0].permute(1, 2, 0).cpu().numpy() * 255, mask, tf, (mark[0, 0].cpu().numpy(), mask, tf, side * train_dodge.FACE))
                    if memo is not None:
                        memo[("edit", index, "dodge")] = ready
                    edits.append((ready[0] * amount, mask, tf)); heals.append(ready[3] + (amount,))
                    continue
                own = retoucher(device) if opt.get("model", "new") == "new" and side >= 300 else None
                if own is not None:
                    # The crop is the one the model was trained on (FFHQ's alignment at 1024 px). What it adds is taken
                    # as local corrections only: its overall colour shift (the retouchers' taste in tone) is dropped,
                    # tone being Lightroom's part. On faces larger than the crop the correction is enlarged, which
                    # leaves pores (finer than it) exactly as they are.
                    tf = tf * 2
                    crop = cv2.warpAffine(rgb8, tf, (1024, 1024), flags=cv2.INTER_AREA if side > 1024 else cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
                    x = torch.from_numpy(crop.copy()).permute(2, 0, 1).float()[None].to(device) / 255
                    delta = own(x)[0].permute(1, 2, 0).cpu().numpy() * 255
                    mask = cv2.resize(legacy.feather(), (1024, 1024), interpolation=cv2.INTER_LINEAR)
                    delta -= np.median(delta[mask > 0.5], 0)
                    # 高低频: only the colour layer of its correction is used (same split as lrcdf.beauty: the face is
                    # about half the crop wide). What it would take out of the texture layer stays in the photo; the
                    # raised texture of a blemish is toned down later, on the marks only (beauty.HEAL).
                    delta = cv2.GaussianBlur(delta, (0, 0), 512 * beauty.SPLIT * opt.get("split", 1.0))
                    if memo is not None:
                        memo[("edit", index, opt.get("model", "new"))] = (delta, mask, tf, None)
                    edits.append((delta * amount, mask, tf))
                    continue
                if net is None:             # no RetouchFormer installed: this face goes without a blemish model
                    continue
                tf = tf * (size / 512)
                crop = cv2.warpAffine(rgb8, tf, (size, size), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
                x = torch.from_numpy(crop.copy()).permute(2, 0, 1).float()[None].to(device) / 127.5 - 1
                pred = ((net(x)[0][0].cpu().permute(1, 2, 0).numpy() + 1) * 127.5).clip(0, 255)
                mask = legacy.feather() if size == 512 else cv2.resize(legacy.feather(), (size, size), interpolation=cv2.INTER_LINEAR)
                delta = pred - crop.astype(np.float32)
                if memo is not None:
                    memo[("edit", index, opt.get("model", "new"))] = (delta, mask, tf, None)
                edits.append((delta * amount, mask, tf))
        skin = kept(memo, "skin", lambda: legacy.skin_weight(rgb8))
        out, _ = legacy.blend_float(rgb, edits, skin)
        heal(out, heals, skin)
    meshes = []
    alone = [d["bbox"] for d, f in zip(faces, each) if f is None]
    if faces:
        out = beauty.beautify(out / 255.0, [d["bbox"] for d in faces], regions, [d["landmarks"] for d in faces], meshes,
                              each=each, **{k: opt[k] for k in beauty.DEFAULTS}) * 255.0
    if "_judge" in opt:
        opt["_judge"] = judge(rgb, out, faces, [f if free else None for f, free in zip(each, followers)], device)
    if faces and opt.get("guard", 1):
        if out is rgb:
            out = rgb.copy()
        opt["_guard"] = []
        guard(rgb, out, faces, each, device, opt["_guard"])
    opt["_men"] = list(who.men) if who else []
    return out, len(faces), meshes, alone


SHAPES = ("slim", "bigeyes", "chest", "waist", "legs")
_POSES = None


def geometry(srgb, meshes, opt, alone=()):
    """What reshaping does to the picture (lrcdf.shape.plan), or None. srgb: float32 0..1, as shot."""
    global _POSES
    want = {k: float(opt.get(k) or 0) for k in SHAPES}
    if not any(v > 0 for v in want.values()):
        return None
    if want["chest"] > 0 or want["waist"] > 0 or want["legs"] > 0:
        _POSES = _POSES or shape.Poses()
    return shape.plan(srgb, meshes, _POSES, slim=want["slim"], eyes=want["bigeyes"], chest=want["chest"],
                      waist=want["waist"], legs=want["legs"], alone=alone, men=opt.get("_men", ()))


# ProPhoto RGB (ROMM, D50) <-> sRGB. Checked against Lightroom's own two exports of one photo: 0.003 levels apart on average.
_PROPHOTO_TO_XYZ = np.array([[0.7976749, 0.1351917, 0.0313534], [0.2880402, 0.7118741, 0.0000857], [0.0, 0.0, 0.8252100]])
_XYZ_TO_SRGB = np.array([[3.1338561, -1.6168667, -0.4906146], [-0.9787684, 1.9161415, 0.0334540], [0.0719453, -0.2289914, 1.4052427]])
_TO_SRGB = (_XYZ_TO_SRGB @ _PROPHOTO_TO_XYZ).astype(np.float32)
_TO_PROPHOTO = np.linalg.inv(_XYZ_TO_SRGB @ _PROPHOTO_TO_XYZ).astype(np.float32)


def prophoto_to_srgb(x):
    """ProPhoto-encoded 0..1 -> sRGB-encoded, NOT clipped: colours outside sRGB come out below 0 or above 1."""
    lin = np.where(x < 16 / 512, x / 16, np.power(x, 1.8, dtype=np.float32)) @ _TO_SRGB.T
    mag = np.abs(lin)
    return np.sign(lin) * np.where(mag <= 0.0031308, 12.92 * mag, 1.055 * np.power(mag, 1 / 2.4, dtype=np.float32) - 0.055)


def srgb_to_prophoto(s):
    mag = np.abs(s)
    lin = np.sign(s) * np.where(mag <= 0.04045, mag / 12.92, np.power((mag + 0.055) / 1.055, 2.4, dtype=np.float32))
    p = np.clip(lin @ _TO_PROPHOTO.T, 0, 1)
    return np.where(p < 1 / 512, p * 16, np.power(p, 1 / 1.8, dtype=np.float32))


def process(src, models, opt, device, icc=None):
    """src: uint8/uint16 RGB. Returns (result, faces).
    Colour and skin are retouched on an sRGB picture. With a ProPhoto profile and 16-bit output the picture stays in
    ProPhoto: only what retouching changed is carried over to the original pixels, so those it did not touch come out
    exactly as they went in. Reshaping is done last and on the real pixels, whatever their colour space."""
    opt.pop("_auto", None)       # what was chosen for the last picture
    scale = 65535.0 if src.dtype == np.uint16 else 255.0
    wide = icc is not None and b"ProPhoto" in icc and src.dtype == np.uint16 and opt.get("bits") != 8
    if not wide:
        srgb = src.astype(np.float32) * (1.0 / scale)
        out, n, meshes, alone = retouch(srgb * 255.0, models, opt, device)
        if opt.get("bits") == 8:                                           # 8-bit result: about a third of the file size
            res = np.rint(np.clip(out, 0, 255)).astype(np.uint8)
        else:
            res = np.rint(np.clip(out, 0, 255) * (scale / 255.0)).astype(src.dtype)
        return shape.apply(res, geometry(srgb, meshes, opt, alone)), n
    unclipped = prophoto_to_srgb(src.astype(np.float32) / 65535.0).astype(np.float32)
    clipped = np.clip(unclipped, 0, 1)
    out, n, meshes, alone = retouch(clipped * 255.0, models, opt, device)
    change = out / 255.0 - clipped
    touched = np.abs(change).max(2) > 0.5 / 65535
    res = src.copy()
    if touched.any():
        ys, xs = np.where(touched)                                        # convert back only where something happened
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        back = srgb_to_prophoto(unclipped[y0:y1, x0:x1] + change[y0:y1, x0:x1])
        part = res[y0:y1, x0:x1]
        m = touched[y0:y1, x0:x1]
        part[m] = np.rint(back[m] * 65535.0).astype(np.uint16)
    return shape.apply(res, geometry(clipped, meshes, opt, alone)), n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--job", required=True); ap.add_argument("--blemish", type=float, default=1.0)
    for k, v in beauty.DEFAULTS.items():
        ap.add_argument("--" + k, type=float, default=v)
    for name, text in (("slim", "slimmer face"), ("bigeyes", "larger eyes"), ("chest", "fuller chest"), ("waist", "slimmer waist"), ("legs", "longer legs")):
        ap.add_argument("--" + name, type=float, default=0.0, help=text + ", 0..1.5 (skipped where it cannot be done safely)")
    ap.add_argument("--hires", type=int, default=0, help="1: run the blemish model at 1024 px on big faces (tried: no gain, 4x slower)")
    ap.add_argument("--bits", type=int, default=8, choices=(8, 16), help="bit depth of the result (16 only if the input is 16-bit)")
    ap.add_argument("--auto", type=int, default=0, help="1: every face gets the strongest of the levels 精致/自然/轻 that is not overdone on it (see choose); needs --levels. The strengths given are used where no level could be chosen")
    ap.add_argument("--guard", type=int, default=1, help="1: faces retouched more than professionals would are taken back to the limit (see guard); 0: off")
    ap.add_argument("--model", default="new", choices=("new", "old", "dodge"), help="blemish model: the one trained on FFHQR (if installed), RetouchFormer, or the dodge-and-burn model (experimental)")
    ap.add_argument("--people", help="people.json of the shoot (cull.py)"); ap.add_argument("--choices", help="e.g. 3:off,5:refined")
    ap.add_argument("--levels", help="what the level names mean: natural=1,0.6,0.5,0.4,0.4/refined=...")
    a = ap.parse_args(); opt = vars(a)
    opt["who"] = people.Choices(a.people, a.choices, a.levels)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    models = load_models(device)
    for line in open(a.job, encoding="utf-8"):
        if not line.strip():
            continue
        inp, outp = line.rstrip("\n").split("\t")
        t0 = time.time()
        try:
            src, icc = read(inp)
            res, n = process(src, models, opt, device, icc)
            if res.dtype == np.uint8 and icc is not None and b"ProPhoto" in icc:
                raise ValueError("8-bit output needs an sRGB input")
            tags = [(34675, "B", len(icc), icc, True)] if icc else []
            tifffile.imwrite(outp + ".tmp", res, photometric="rgb", compression="zlib", predictor=True, extratags=tags)
            os.replace(outp + ".tmp", outp)
            print(json.dumps({"input": inp, "output": outp, "faces": n, "seconds": round(time.time() - t0, 1),
                              "levels": opt.get("_levels") if opt.get("auto") else None,
                              "toned_down": [g["kept"] for g in opt.get("_guard") or [] if g["kept"] < 1]}), flush=True)
        except Exception as ex:  # one bad file must not stop a batch
            print(json.dumps({"input": inp, "error": repr(ex)}), flush=True)


if __name__ == "__main__":
    main()
