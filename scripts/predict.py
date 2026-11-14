"""Predict Lightroom develop settings for photos (called by the Lightroom plugin).
usage: predict.py --ckpt tone.pt --job job.tsv --out result.lua --style a --strength 1.0
job.tsv lines: id <TAB> image path <TAB> as-shot temp <TAB> as-shot tint <TAB> 1|0 (WB is as-shot) [<TAB> capture time, seconds]
When the as-shot values are missing (0 or negative) they are read from the develop settings embedded in the preview.
--group time: photos shot within --gap minutes of each other form a shoot; --group all: one shoot; none: off.
Inside a shoot the style sliders are made identical and white balance is pulled half-way to a common value;
exposure stays per photo (measured on PPR10K: this is where per-photo prediction is better than the shoot average).
--reference ID --refsettings FILE: reference-photo mode. One photo of the job already has an approved edit (its develop
settings in FILE, lines "name <TAB> value", curves as comma lists). Every other photo gets its style sliders and its final
temperature/tint; exposure is the model's own estimate shifted by 0.75 of the model's error on the reference. Measured on
PPR10K with a random reference per shoot (val): sliders 2.49 -> 0.37, temperature 9.5% -> 3.4%, exposure 0.31 -> 0.24 EV.
The reference itself is not in the result.
--mystyles FILE adds the user's own styles (made with --learn KEY --name TITLE from the edited --reference photo, plus
--examples ID,ID,... for more edited photos of the job: the look is their average; --forget KEY deletes one).
--style all: every style at once; the result is then { style = { id = settings } } (used for the style previews).
The result is a Lua table: return { ["id"] = { Temperature = 5200, ... }, ... }"""
import argparse, json, os, sys
import math
import numpy as np
import torch
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P
from lrcdf.model import ToneNet, load_image, wb_feature


def lua(v):
    if isinstance(v, dict):
        return "{" + ",".join(f'["{k}"]={lua(x)}' for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'
    return repr(v)


BRIGHT = -0.22      # exposure added to every built-in look: PPR10K's experts retouch brighter than our users want
                    # (2026-11-14: the default look was "a little too bright"; -0.14 still was, -0.28 began to look flat)


def restyle(v, recipe):
    """Add a derived style's fixed offsets to the model's prediction (slider units; curve in 0..255 levels)."""
    for name, d in recipe.get("delta", {}).items():
        if name == "TemperaturePct":
            v[0] += math.log(1 + d / 100)
        elif name == "Tint":
            v[1] += d / P.TINT_SCALE
        else:
            v[2 + P.SCALAR_NAMES.index(name)] += d
    if "curve" in recipe:
        v[2 + P.N_SCALAR:2 + P.N_SCALAR + len(P.CURVE_X)] += np.array(recipe["curve"]) / 255.0
    if "curves" in recipe:      # all four curves (master, red, green, blue): what a learned style stores
        v[2 + P.N_SCALAR:] += np.array(recipe["curves"]) / 255.0
    return v


def my_styles(path):
    return json.load(open(path, encoding="utf-8")) if path and os.path.exists(path) else {}


def save_my_styles(path, styles):
    """The user's own styles: JSON for this script, and a Lua list of the cards for the plug-in."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(styles, open(path + ".tmp", "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    cards = ",".join("{value=%s,title=%s,note=%s}" % (lua(k), lua(v.get("title", k)), lua(v.get("note", "我的风格")))
                     for k, v in styles.items())
    open(os.path.splitext(path)[0] + ".lua", "w", encoding="utf-8").write("return {" + cards + "}\n")


def learn(examples, title):
    """A style from the user's edited photos: what they did beyond the model's style A, averaged over the photos.
    examples: [(style A's vector for the photo, its as-shot (temperature, tint), file with its develop settings)],
    the photo on screen first. Returns a recipe for restyle().
    Measured on PPR10K with experts b and c as the user (scripts/exp_style.py; error on photos of other shoots):
    1 example: sliders 5.5, exposure 0.43 EV, temperature 14.7 %; 6: 4.7 / 0.35 / 11.7; 12: 4.6 / 0.35 / 11.5 - as
    good as the model's own trained style. Weighting the examples by how alike the photos are was no better than the
    plain average (a look is the same on every photo; what differs is already in style A), and the median was better
    for sliders but worse when the examples come from one or two shoots, which is the usual case.
    Colour grading and grain are taken from the first photo. The single differences are kept ("samples")."""
    ds, extra = [], {}
    for k, (base, ref, settings) in enumerate(examples):
        temp, tint, scal, curves, more = read_settings(settings)
        temp = temp or ref[0]; tint = ref[1] if tint is None else tint
        ds.append(P.encode(temp, tint, scal, curves, *ref).astype(np.float64) - base)
        if k == 0:
            extra = more
    d = np.mean(ds, 0)
    note = "我的风格" if len(ds) == 1 else f"我的风格 · 学自 {len(ds)} 张照片"
    delta = {"TemperaturePct": round((math.exp(d[0]) - 1) * 100, 2), "Tint": round(d[1] * P.TINT_SCALE, 1)}
    for name, value in zip(P.SCALAR_NAMES, d[2:2 + P.N_SCALAR]):
        if abs(value) >= (0.02 if name == "Exposure2012" else 0.5):
            delta[name] = round(float(value), 2)
    return {"base": "a", "title": title, "note": note, "delta": delta,
            "curves": [round(float(x) * 255, 1) for x in d[2 + P.N_SCALAR:]], "extra": extra,
            "samples": [[round(float(x), 4) for x in one] for one in ds]}


def shoots(vecs, mode, gap):
    """Split predictions into shoots. Photos without a capture time are left alone in time mode."""
    if mode == "none":
        return []
    if mode == "all":
        return [vecs]
    out, cur = [], []
    for item in sorted((v for v in vecs if v[3] > 0), key=lambda v: v[3]):
        if cur and item[3] - cur[-1][3] > gap * 60:
            out.append(cur); cur = []
        cur.append(item)
    return out + [cur]


def harmonise(shoot, wb_pull=0.5):
    if len(shoot) < 2:
        return
    V = np.stack([v for _, v, _, _ in shoot])
    refs = np.array([[math.log(t), tint / P.TINT_SCALE] for _, _, (t, tint), _ in shoot])
    exposure = 2 + P.SCALAR_NAMES.index("Exposure2012")
    common = V.mean(0)
    wb_abs = (V[:, :2] + refs).mean(0)            # the shoot shares one final temperature/tint target
    for k, (_, v, _, _) in enumerate(shoot):
        keep = v[exposure]
        v[2:] = common[2:]; v[exposure] = keep
        v[:2] = (1 - wb_pull) * v[:2] + wb_pull * (wb_abs - refs[k])


def read_settings(path):
    """Develop settings written by the plug-in -> (temperature or None, tint or None, scalars, curves)."""
    raw = dict(line.rstrip("\n").split("\t", 1) for line in open(path, encoding="utf-8") if "\t" in line)
    scal = np.array([float(raw.get(n, d)) for n, d in P.SCALARS], np.float64)
    curves = np.zeros((len(P.CURVES), len(P.CURVE_X)))
    for k, tag in enumerate(P.CURVES):
        flat = [float(x) for x in raw[tag].split(",")] if raw.get(tag) else [0, 0, 255, 255]
        pts = sorted(dict(zip(flat[0::2], flat[1::2])).items())
        curves[k] = P._spline([p[0] for p in pts], [p[1] for p in pts], P.CURVE_X)
    num = lambda k: float(raw[k]) if raw.get(k) not in (None, "", "nil") else None
    extra = {k: float(raw[k]) for k in P.EXTRA if raw.get(k) not in (None, "", "nil")}
    return num("Temperature"), num("Tint"), scal, curves, extra


def follow_reference(vecs, ref_id, settings, exposure_trust=0.75):
    """Give every photo the reference's look. vecs: [id, vector, (as-shot temp, tint), time].
    Returns (vecs without the reference, the reference's colour-grading and grain settings)."""
    found = [v for v in vecs if v[0] == ref_id]
    if not found:
        raise SystemExit("the reference photo could not be analysed")
    _, model_ref, (t0, tint0), _ = found[0]
    temp, tint, scal, curves, extra = read_settings(settings)
    temp = temp or t0; tint = tint0 if tint is None else tint       # reference left on as-shot white balance
    target = P.encode(temp, tint, scal, curves).astype(np.float64)   # only [2:] is used; white balance is absolute
    exposure = 2 + P.SCALAR_NAMES.index("Exposure2012")
    shift = exposure_trust * (target[exposure] - model_ref[exposure])
    out = []
    for item in vecs:
        if item[0] == ref_id:
            continue
        v, (t, ti) = item[1], item[2]
        own = v[exposure] + shift
        v[2:] = target[2:]; v[exposure] = own
        v[0] = math.log(temp / t); v[1] = (tint - ti) / P.TINT_SCALE
        out.append(item)
    return out, extra


def embedded_wb(path):
    """As-shot temperature and tint from the develop settings Lightroom embeds in an exported preview, or None.
    The SDK itself returns nil or -999999 for photos that were never opened in Develop."""
    import re
    try:
        head = open(path, "rb").read(400000).decode("latin-1")
    except OSError:
        return None
    t = re.search(r'crs:Temperature="(\d+)"', head); ti = re.search(r'crs:Tint="([-+]?\d+)"', head)
    mode = re.search(r'crs:WhiteBalance="([^"]*)"', head)
    if t and ti and mode and mode.group(1) == "As Shot" and float(t.group(1)) > 0:
        return float(t.group(1)), float(ti.group(1))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True); ap.add_argument("--job", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--style", default="a")
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--group", default="none", choices=["none", "time", "all"])
    ap.add_argument("--gap", type=float, default=20.0, help="minutes between shots that starts a new shoot")
    ap.add_argument("--reference", help="id of the photo whose edit the others follow"); ap.add_argument("--refsettings")
    ap.add_argument("--mystyles", help="JSON file with the user's own styles")
    ap.add_argument("--learn", help="store the edit of --reference (settings in --refsettings) as the style with this key")
    ap.add_argument("--examples", help="with --learn: ids of more edited photos (settings in reference_<id>.tsv next to --refsettings)")
    ap.add_argument("--name", default="我的风格"); ap.add_argument("--forget", help="delete the user's style with this key")
    a = ap.parse_args()
    if a.forget:
        styles = my_styles(a.mystyles); styles.pop(a.forget, None); save_my_styles(a.mystyles, styles)
        open(a.out, "w").write("return {}\n")
        return
    ck = torch.load(a.ckpt, map_location="cpu", weights_only=False)
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    model = ToneNet(len(ck["styles"]), pretrained=False)
    model.load_state_dict(ck["model"]); model.to(dev).eval()
    recipes = json.load(open(os.path.join(os.path.dirname(__file__), "..", "styles.json"), encoding="utf-8"))
    builtin = set(ck["styles"]) | set(recipes)      # not the user's own looks (learnt against the model as it is)
    recipes.update(my_styles(a.mystyles))
    names = list(ck["styles"]) + list(recipes) if a.style == "all" else [a.style]
    photos, failed = [], {}
    with torch.no_grad():
        for line in open(a.job, encoding="utf-8"):
            pid, path, temp, tint, asshot, *rest = line.rstrip("\n").split("\t")
            try:
                temp, tint = float(temp), float(tint)
                known = asshot == "1" and temp > 0
                if not known:                       # ask the preview itself (see embedded_wb)
                    found = embedded_wb(path)
                    if found:
                        (temp, tint), known = found, True
                x = torch.from_numpy(load_image(path))[None].to(dev)
                wb = torch.tensor([wb_feature(temp, tint, known)], device=dev)
                feat = model.features(x)
                base = {s: (model.heads(feat, torch.tensor([k], device=dev), wb)[0] * model.t_std + model.t_mean).cpu().numpy().astype(np.float64)
                        for k, s in enumerate(ck["styles"]) if any(recipes.get(n, {}).get("base", n) == s for n in names)}
                ref = (temp, tint) if known else (P.T_DEFAULT, 0.0)
                when = float(rest[0]) if rest and rest[0] else 0.0
                photos.append((pid, base, ref, when))
            except Exception as ex:  # one bad file must not stop a batch
                failed[pid] = {"error": str(ex)}
    if a.learn:
        found = [p for p in photos if p[0] == a.reference]
        if not found:
            raise SystemExit("the photo could not be analysed")
        styles = my_styles(a.mystyles)
        examples = [(found[0][1]["a"], found[0][2], a.refsettings)]
        for pid in filter(None, (a.examples or "").split(",")):
            path = os.path.join(os.path.dirname(a.refsettings), f"reference_{pid}.tsv")
            more = [p for p in photos if p[0] == pid and pid != a.reference]
            if more and os.path.exists(path):
                examples.append((more[0][1]["a"], more[0][2], path))
        styles[a.learn] = learn(examples, a.name)
        print("examples", len(examples), flush=True)
        save_my_styles(a.mystyles, styles)
        open(a.out, "w").write("return {}\n")
        return
    out = {}
    for name in names:
        recipe = recipes.get(name, {})
        res = dict(failed)
        vecs = [[pid, restyle(base[recipe.get("base", name)].copy(), recipe), ref, when] for pid, base, ref, when in photos]
        if name in builtin and not a.reference:
            for item in vecs:
                item[1][2 + P.SCALAR_NAMES.index("Exposure2012")] += BRIGHT
        extra = P.extras(recipe.get("extra"), a.strength)
        if a.reference:
            vecs, extra = follow_reference(vecs, a.reference, a.refsettings)
            extra = P.extras(extra)
        else:
            for shoot in shoots(vecs, a.group, a.gap):
                harmonise(shoot)
        for pid, v, ref, _ in vecs:
            res[pid] = dict(P.decode(v, *ref, strength=1.0 if a.reference else a.strength), **extra)
        out[name] = res
    tmp = a.out + ".tmp"
    open(tmp, "w", encoding="utf-8").write("return " + lua(out if a.style == "all" else out[a.style]) + "\n")
    os.replace(tmp, a.out)


if __name__ == "__main__":
    main()
