"""Tone model accuracy on the official val split, by as-shot colour temperature (night/tungsten .. shade).
usage: eval_bins.py <ppr10k_dir> <tone.pt> [more.pt ...]   Report only: never choose settings from these numbers."""
import os, sys
import numpy as np, torch, torch.nn.functional as F
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P
from lrcdf.model import ToneNet, SIZE, CACHE
root = sys.argv[1]; dev = "mps" if torch.backends.mps.is_available() else "cpu"
L = np.load(f"{root}/labels.npz"); ids, ok = L["ids"], L["ok"]
group = np.array([int(s.split("_")[0]) for s in ids]); wb = np.load(f"{root}/src_wb.npy")
T = np.load(f"{root}/targets_rel.npy"); imgs = np.load(f"{root}/cache_source_{CACHE}.npy", mmap_mode="r")
idx = np.flatnonzero(group >= 1356); iE = 2 + P.SCALAR_NAMES.index("Exposure2012")
for ckpt in sys.argv[2:]:
    ck = torch.load(ckpt, map_location="cpu", weights_only=False)
    m = ToneNet(3, pretrained=False); m.load_state_dict(ck["model"]); m.to(dev).eval()
    pred = np.zeros((3, len(idx), P.DIM), np.float32)
    with torch.no_grad():
        for s in range(0, len(idx), 128):
            i = idx[s:s + 128]
            x = torch.from_numpy(np.ascontiguousarray(imgs[i])).to(dev).permute(0, 3, 1, 2).float() / 255
            x = F.interpolate(x, size=(SIZE, SIZE), mode="bilinear", antialias=True)
            w = torch.tensor(np.stack([np.log(wb[i, 0] / P.T_DEFAULT), wb[i, 1] / P.TINT_SCALE, np.ones(len(i))], 1), dtype=torch.float32, device=dev)
            f = m.features(x)
            for e in range(3):
                pred[e, s:s + 128] = (m.heads(f, torch.full((len(i),), e, device=dev), w) * m.t_std + m.t_mean).cpu().numpy()
    print(ckpt)
    for lo, hi in ((0, 3600), (3600, 4500), (4500, 6500), (6500, 8000), (8000, 99999), (0, 99999)):
        row = []
        for e in range(3):
            k = ok[e, idx] & (wb[idx, 0] >= lo) & (wb[idx, 0] < hi)
            d = pred[e, k, 0] - T[e, idx][k, 0]; x = pred[e, k, iE] - T[e, idx][k, iE]
            row.append("n=%4d temp bias %+5.1f%% mae %4.1f%% | exp bias %+.2f mae %.2f" % (k.sum(), np.expm1(d.mean()) * 100, np.expm1(np.abs(d).mean()) * 100, x.mean(), np.abs(x).mean()))
        print("  %5d-%5d K  " % (lo, hi) + "  ||  ".join(row))
