"""The "retouched too much" critic: from a face as shot it predicts how much a professional retoucher would change it,
as a range (median and 90th percentile). A result that changes the face more than professionals almost ever do on such
a face is overdone, and the pipeline takes it back to that limit (beautify.guard).
There are no public ratings of "too much"; what there is, is what retouchers decided on 30,000+ faces (FFHQR).
usage: train_critic.py prepare <out dir> [--parts 1,2,3]     measures and small pictures of every pair (once)
       train_critic.py train <out dir> [--epochs 8]          -> <out dir>/critic.pt
Two measures of a change (measure()), both on skin only and relative to the face size:
  colour   mean local change of the colour layer, in 8-bit levels (spots, marks, patches; not overall tone)
  texture  share of the texture layer's amplitude that was taken away (0 = all pores kept, 1 = none left)"""
import argparse, json, os, sys
import cv2, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from train_retouch import Tars, DATA
from train_dodge import SPLIT, REACH, FACE
from lrcdf import blemish

SIDE = 512          # pairs are measured at this size (face about 256 px wide)
VIEW = 224          # what the critic looks at
QUANTILES = (0.5, 0.9)


def skin_of(x):
    """Where a change counts: skin-coloured pixels inside the face oval of an FFHQ-aligned picture (float RGB 0..1)."""
    n = x.shape[0]
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32) / n
    oval = np.clip(1.6 - 1.6 * np.sqrt(((xx - 0.5) / 0.30) ** 2 + ((yy - 0.56) / 0.40) ** 2), 0, 1)
    return blemish.skin_like(x) * oval


def corrected(x, y):
    """0..1 map of the places where a blemish was corrected: strong local changes of the colour layer and what is
    right next to them. A guard against smoothing too much must not undo these."""
    face = x.shape[0] * FACE
    low = cv2.GaussianBlur(y - x, (0, 0), face * SPLIT)
    local = np.abs(low - cv2.GaussianBlur(low, (0, 0), face * REACH)).mean(2) * 255
    k = max(3, int(face * 0.03)) | 1
    return cv2.GaussianBlur(cv2.dilate(np.clip((local - 3) / 3, 0, 1), np.ones((k, k), np.uint8)), (0, 0), face * 0.01)


def measure(x, y, w=None):
    """x: before, y: after (float RGB 0..1, FFHQ-aligned, same size). Returns (colour, texture) as described above."""
    face = x.shape[0] * FACE
    w = skin_of(x) if w is None else w
    total = float(w.sum()) + 1e-6
    low = cv2.GaussianBlur(y - x, (0, 0), face * SPLIT)
    local = low - cv2.GaussianBlur(low, (0, 0), face * REACH)
    colour = float((np.abs(local).mean(2) * w).sum() / total * 255)
    hx = x - cv2.GaussianBlur(x, (0, 0), face * SPLIT); hy = y - cv2.GaussianBlur(y, (0, 0), face * SPLIT)
    ex, ey = float(((hx ** 2).mean(2) * w).sum()), float(((hy ** 2).mean(2) * w).sum())
    return colour, 1 - (ey / (ex + 1e-9)) ** 0.5


class Pairs(torch.utils.data.Dataset):
    def __init__(self, keys, parts):
        self.keys, self.parts, self.orig = keys, parts, None

    def open(self):
        self.orig, self.done = Tars(), Tars()
        for p in self.parts:
            self.done.add(f"{DATA}/ffhqr/ffhqr.part{p}.tar")
            for k in range((p - 1) * 10, p * 10):
                if os.path.exists(f"{DATA}/ffhq1024/{k:02d}000.tar"):
                    self.orig.add(f"{DATA}/ffhq1024/{k:02d}000.tar")

    def __len__(self):
        return len(self.keys)

    def __getitem__(self, i):
        if self.orig is None:
            self.open()
        a, b = self.orig.read(self.keys[i]), self.done.read(self.keys[i])
        f = lambda im: np.ascontiguousarray(cv2.resize(im, (SIDE, SIDE), interpolation=cv2.INTER_AREA)[..., ::-1]).astype(np.float32) / 255
        x, y = f(a), f(b)
        w = skin_of(x)
        c, t = measure(x, y, w)
        small = cv2.resize(a, (VIEW, VIEW), interpolation=cv2.INTER_AREA)[..., ::-1]
        return torch.from_numpy(np.ascontiguousarray(small)), torch.tensor([c, t, float(w.mean())], dtype=torch.float32)


def encode(m):
    """(colour, texture) -> what the critic predicts: colour on a log scale, texture as it is."""
    return torch.stack([torch.log(m[:, 0] + 0.1), m[:, 1]], 1)


def decode(v):
    """Critic output [.., 2 measures x quantiles] -> dict of (colour, texture) per quantile."""
    v = v.reshape(-1, 2, len(QUANTILES))
    return {q: (float(torch.exp(v[0, 0, k]) - 0.1), float(v[0, 1, k])) for k, q in enumerate(QUANTILES)}


class Critic(nn.Module):
    def __init__(self, pretrained=True):
        super().__init__()
        import torchvision
        self.net = torchvision.models.resnet18(weights="IMAGENET1K_V1" if pretrained else None)
        self.net.fc = nn.Linear(512, 2 * len(QUANTILES))

    def forward(self, x):       # x: B x 3 x VIEW x VIEW, 0..1
        mean = torch.tensor([0.485, 0.456, 0.406], device=x.device).view(1, 3, 1, 1)
        std = torch.tensor([0.229, 0.224, 0.225], device=x.device).view(1, 3, 1, 1)
        return self.net((x - mean) / std)


def pinball(pred, target):
    pred = pred.reshape(-1, 2, len(QUANTILES)); loss = 0
    for k, q in enumerate(QUANTILES):
        d = target - pred[:, :, k]
        loss = loss + torch.maximum(q * d, (q - 1) * d).mean()
    return loss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=("prepare", "train")); ap.add_argument("out")
    ap.add_argument("--parts", default="1,2,3"); ap.add_argument("--epochs", type=int, default=8)
    ap.add_argument("--workers", type=int, default=10); ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if a.what == "prepare":
        parts = [int(p) for p in a.parts.split(",")]
        probe = Pairs([], parts); probe.open()
        keys = sorted(k for k in probe.done.at if k in probe.orig.at)
        if a.limit:
            keys = keys[:a.limit]
        views = np.lib.format.open_memmap(f"{a.out}/views.npy", "w+", np.uint8, (len(keys), VIEW, VIEW, 3))
        amounts = np.zeros((len(keys), 3), np.float32)
        loader = torch.utils.data.DataLoader(Pairs(keys, parts), batch_size=32, num_workers=a.workers)
        n = 0
        for v, m in loader:
            views[n:n + len(v)] = v.numpy(); amounts[n:n + len(v)] = m.numpy(); n += len(v)
            if n % 3200 == 0:
                print(n, "of", len(keys), flush=True)
        views.flush(); np.save(f"{a.out}/amounts.npy", amounts); json.dump(keys, open(f"{a.out}/keys.json", "w"))
        return
    views = np.load(f"{a.out}/views.npy", mmap_mode="r"); amounts = np.load(f"{a.out}/amounts.npy")
    use = np.flatnonzero(amounts[:, 2] > 0.03)          # faces with too little skin in view say nothing
    held, rest = use[-600:], use[:-600]
    dev = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    model = Critic().to(dev)
    opt = torch.optim.AdamW(model.parameters(), 3e-4, weight_decay=1e-4)
    steps = a.epochs * (len(rest) // 64); step = 0
    rng = np.random.default_rng(0)

    def batch(ix, flip):
        x = torch.from_numpy(np.stack([views[i] for i in sorted(ix)])).to(dev).permute(0, 3, 1, 2).float() / 255
        if flip:
            x = torch.flip(x, [3])
        return x, encode(torch.from_numpy(amounts[sorted(ix)]).to(dev))

    def check():
        model.eval(); P, T = [], []
        with torch.no_grad():
            for s in range(0, len(held), 100):
                x, t = batch(held[s:s + 100], False)
                P.append(model(x).reshape(-1, 2, len(QUANTILES)).cpu()); T.append(t.cpu())
        model.train(); P, T = torch.cat(P), torch.cat(T)
        rec = {}
        for j, name in enumerate(("colour", "texture")):
            rec[name + "_corr"] = round(float(np.corrcoef(P[:, j, 0], T[:, j])[0, 1]), 3)      # does the face tell the amount?
            rec[name + "_under_q90"] = round(float((T[:, j] <= P[:, j, 1]).float().mean()), 3)   # should be about 0.9
        return rec

    for epoch in range(a.epochs):
        order = rng.permutation(rest)
        for s in range(0, len(order) - 63, 64):
            for g in opt.param_groups:
                g["lr"] = 3e-4 * min(1.0, (step + 1) / 200) * 0.5 * (1 + np.cos(np.pi * step / steps))
            x, t = batch(order[s:s + 64], rng.random() < 0.5)
            loss = pinball(model(x), t)
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step(); step += 1
        rec = dict(epoch=epoch + 1, loss=round(loss.item(), 4), **check())
        print(json.dumps(rec), flush=True)
        torch.save(dict(model=model.state_dict(), quantiles=QUANTILES, **rec), f"{a.out}/critic.pt")


if __name__ == "__main__":
    main()
