"""Frozen-backbone features + hand-made colour statistics for fast head experiments.
usage: exp_features.py <ppr10k_dir>  -> feats_convnext.npy [N,1440], feats_stats.npy [N,S]"""
import os, sys
import numpy as np, torch, torchvision
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf.model import SIZE, MEAN, STD

root = sys.argv[1]
dev = "mps" if torch.backends.mps.is_available() else "cpu"
imgs = np.load(f"{root}/cache_source_{SIZE}.npy", mmap_mode="r")
net = torchvision.models.convnext_tiny(weights=torchvision.models.ConvNeXt_Tiny_Weights.DEFAULT).features.to(dev).eval()


def stats(x):
    """x [B,3,H,W] sRGB 0..1 -> global tone/colour statistics."""
    lin = x.clamp(1e-4, 1) ** 2.2
    lum = (lin * torch.tensor([0.2126, 0.7152, 0.0722], device=x.device).view(1, 3, 1, 1)).sum(1)
    out = []
    q = torch.tensor([.01, .05, .25, .5, .75, .95, .99], device=x.device)
    c = SIZE // 4
    for region in (slice(None), slice(c, -c)):
        l = lum[:, region, region].flatten(1); r = lin[:, :, region, region].flatten(2)
        out.append(torch.log2(torch.quantile(l, q, dim=1).T + 1e-4))
        out.append(torch.log2(l.mean(1, keepdim=True) + 1e-4))
        m = r.mean(2)
        out.append(torch.log2(m[:, [0, 2]] / m[:, [1]]))
        out.append((x[:, :, region, region].flatten(2) > 0.98).float().mean(2))
        out.append((x[:, :, region, region].flatten(2) < 0.02).float().mean(2))
    sat = (x.max(1).values - x.min(1).values).flatten(1)
    out.append(torch.stack([sat.mean(1), sat.std(1)], 1))
    for ch in range(3):
        out.append(torch.stack([torch.histc(v, 16, 0, 1) for v in x[:, ch].flatten(1).cpu()]).to(x.device) / SIZE ** 2)
    return torch.cat(out, 1)


F, S = [], []
with torch.no_grad():
    for s in range(0, len(imgs), 128):
        x = torch.from_numpy(np.ascontiguousarray(imgs[s:s + 128])).to(dev).permute(0, 3, 1, 2).float() / 255
        S.append(stats(x).cpu().numpy())
        h = (x - MEAN.to(dev)) / STD.to(dev); f = []
        for i, m in enumerate(net):
            h = m(h)
            if i in (1, 3, 5, 7):
                f.append(h.mean((2, 3)))
        F.append(torch.cat(f, 1).cpu().numpy())
        if s % 2560 == 0: print(s, flush=True)
np.save(f"{root}/feats_convnext.npy", np.concatenate(F)); np.save(f"{root}/feats_stats.npy", np.concatenate(S))
print(np.concatenate(F).shape, np.concatenate(S).shape)
