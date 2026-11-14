"""How much does making a shoot consistent help? Blend each photo prediction with its group mean.
usage: eval_group.py <ppr10k_dir> <tone.pt>"""
import os, sys, json
import numpy as np, torch, torch.nn.functional as F
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P
from lrcdf.model import ToneNet, SIZE, CACHE
root, ckpt = sys.argv[1], sys.argv[2]
dev = "mps"
L = np.load(f"{root}/labels.npz"); ids, ok = L["ids"], L["ok"]
group = np.array([int(s.split("_")[0]) for s in ids]); wb = np.load(f"{root}/src_wb.npy")
T = np.load(f"{root}/targets_rel.npy"); imgs = np.load(f"{root}/cache_source_{CACHE}.npy", mmap_mode="r")
ck = torch.load(ckpt, map_location="cpu", weights_only=False)
m = ToneNet(3, pretrained=False); m.load_state_dict(ck["model"]); m.to(dev).eval()
idx = np.flatnonzero(group >= 1200); pred = np.zeros((3, len(idx), P.DIM), np.float32)
with torch.no_grad():
    for s in range(0, len(idx), 128):
        i = idx[s:s + 128]
        x = torch.from_numpy(np.ascontiguousarray(imgs[i])).to(dev).permute(0, 3, 1, 2).float() / 255
        x = F.interpolate(x, size=(SIZE, SIZE), mode="bilinear", antialias=True)
        w = torch.tensor(np.stack([np.log(wb[i, 0] / P.T_DEFAULT), wb[i, 1] / P.TINT_SCALE, np.ones(len(i))], 1), dtype=torch.float32, device=dev)
        f = m.features(x)
        for e in range(3):
            pred[e, s:s + 128] = (m.heads(f, torch.full((len(i),), e, device=dev), w) * m.t_std + m.t_mean).cpu().numpy()
np.save(f"{root}/pred_devval.npy", pred)
g = group[idx]; Tt = T[:, idx]; okk = ok[:, idx]; std = m.t_std.cpu().numpy()
iE = 2 + P.SCALAR_NAMES.index("Exposure2012")
ref = np.stack([np.log(wb[idx, 0]), wb[idx, 1] / P.TINT_SCALE], 1)            # as-shot per photo
gi = np.unique(g, return_inverse=True)[1]; cnt = np.bincount(gi)[:, None]
gm = lambda a: (np.stack([np.bincount(gi, a[:, k]) for k in range(a.shape[1])], 1) / cnt)[gi]
cls = {"exp": [iE], "temp": [0], "tint": [1], "rest": [k for k in range(P.DIM) if k not in (0, 1, iE)]}

def blended(alpha, absolute):
    out = pred.copy()
    for e in range(3):
        p = pred[e]; mean_rel = gm(p)
        mean_abs = gm(p[:, :2] + ref) - ref                                  # same final temp/tint for the group
        for c, dims in cls.items():
            a = alpha[c]
            tgt = mean_abs[:, dims] if (absolute and c in ("temp", "tint")) else mean_rel[:, dims]
            out[e][:, dims] = (1 - a) * p[:, dims] + a * tgt
    return out

def score(o, part):
    sel = (g < 1356) if part == "dev" else (g >= 1356)
    mae = np.stack([np.abs(o[e] - Tt[e])[okk[e] & sel].mean(0) for e in range(3)])
    return {c: float((mae / std)[:, d].mean()) for c, d in cls.items()}, mae

for absolute in (False, True):
    best = {}
    for c in cls:
        if absolute and c not in ("temp", "tint"): continue
        row = []
        for a in (0, .25, .5, .75, 1):
            al = {k: 0 for k in cls}; al[c] = a
            row.append(round(score(blended(al, absolute), "dev")[0][c], 4))
        best[c] = (0, .25, .5, .75, 1)[int(np.argmin(row))]
        print("abs" if absolute else "rel", c, "dev norm-mae at alpha 0,.25,.5,.75,1:", row, flush=True)
    print("best", best)
for name, al, ab in (("per-photo", dict(exp=0, temp=0, tint=0, rest=0), False), ("all-rel-1", dict(exp=1, temp=1, tint=1, rest=1), False)):
    s, mae = score(blended(al, ab), "val")
    print(name, "val", {k: round(v, 4) for k, v in s.items()}, "exp", mae[:, iE].round(3), "temp%", (np.expm1(mae[:, 0]) * 100).round(1), "tint", (mae[:, 1] * 50).round(1))
