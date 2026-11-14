"""Experiment: learning a user's look from N of their edited photos (PPR10K, experts b and c play the user; the model's
style A is the base, as in predict.py --learn). Which way of turning N examples into settings for a new photo is best?
usage: exp_style.py <ppr10k_dir> <tone.pt>
  one     the difference on one example, used everywhere (what --learn did)
  mean    the average difference          median  the per-setting median
  near    differences weighted by how alike the photos are (cosine of the model's own features, softmax / t)
Examples are drawn from the validation shoots, either anywhere or from two shoots only (a user edits a session)."""
import os, sys
import numpy as np, torch, torch.nn.functional as F
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P
from lrcdf.model import ToneNet, SIZE, CACHE
root, ckpt = sys.argv[1], sys.argv[2]
L = np.load(f"{root}/labels.npz"); ids, ok = L["ids"], L["ok"]
group = np.array([int(s.split("_")[0]) for s in ids])
T = np.load(f"{root}/targets_rel.npy"); pred = np.load(f"{root}/pred_devval.npy")
idx = np.flatnonzero(group >= 1200); val = group[idx] >= 1356
cache = f"{root}/feats_tone_devval.npy"
if not os.path.exists(cache):
    imgs = np.load(f"{root}/cache_source_{CACHE}.npy", mmap_mode="r")
    ck = torch.load(ckpt, map_location="cpu", weights_only=False)
    m = ToneNet(3, pretrained=False); m.load_state_dict(ck["model"]); m.to("mps").eval()
    out = []
    with torch.no_grad():
        for s in range(0, len(idx), 128):
            x = torch.from_numpy(np.ascontiguousarray(imgs[idx[s:s + 128]])).to("mps").permute(0, 3, 1, 2).float() / 255
            out.append(m.features(F.interpolate(x, size=(SIZE, SIZE), mode="bilinear", antialias=True)).cpu().numpy())
    np.save(cache, np.concatenate(out))
feat = np.load(cache)[val]; feat = feat / np.linalg.norm(feat, axis=1, keepdims=True)
g = group[idx][val]; base = pred[0][val]
iE = 2 + P.SCALAR_NAMES.index("Exposure2012")
others = [k for k in range(2, 2 + P.N_SCALAR) if k != iE]


def errors(p, t):
    d = np.abs(p - t)
    return np.array([d[:, others].mean(), d[:, iE].mean(), d[:, 0].mean() * 100, d[:, 2 + P.N_SCALAR:].mean() * 255])


def near(delta, fe, ft, t):
    w = np.exp((ft @ fe.T - 1) / t); w /= w.sum(1, keepdims=True)
    return w @ delta


rng = np.random.default_rng(0)
for user in (1, 2):
    good = ok[user][idx][val] & ok[0][idx][val]
    target = T[user][idx][val]
    delta = target - base
    print(f"\nuser = expert {'abc'[user]}   columns: sliders | exposure EV | temperature % | curve levels")
    print("  style A untouched      ", np.round(errors(base[good], target[good]), 3))
    print("  model's own style      ", np.round(errors(pred[user][val][good], target[good]), 3))
    for how in ("anywhere", "two shoots"):
        for n in (1, 3, 6, 12, 25):
            res = {}
            for trial in range(30):
                if how == "anywhere":
                    ex = rng.choice(np.flatnonzero(good), n, replace=False)
                else:
                    pool = np.flatnonzero(good & np.isin(g, rng.choice(np.unique(g[good]), 2, replace=False)))
                    if len(pool) < n:
                        continue
                    ex = rng.choice(pool, n, replace=False)
                test = good & ~np.isin(g, g[ex])
                cand = {"one": np.repeat(delta[ex[:1]], test.sum(), 0), "mean": np.repeat(delta[ex].mean(0)[None], test.sum(), 0),
                        "median": np.repeat(np.median(delta[ex], 0)[None], test.sum(), 0)}
                for t in (0.02, 0.05, 0.1, 0.2):
                    cand[f"near {t}"] = near(delta[ex], feat[ex], feat[test], t)
                for k, d in cand.items():
                    res.setdefault(k, []).append(errors(base[test] + d, target[test]))
            print(f"  {how}, {n} examples")
            for k, v in res.items():
                print(f"     {k:10s}", np.round(np.mean(v, 0), 3))
