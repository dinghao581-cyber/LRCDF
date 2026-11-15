"""Train the cast-shadow model: face -> log factor per pixel and colour that undoes shadows thrown onto it by other
things (see lrcdf/shadow.py). Trained on FFHQ faces with painted shadows; three pictures in ten get none, so that
beards, brows and the face's own shading are learnt as "leave it".
usage: train_shadow.py <out dir> [--parts 1,2,3] [--steps 16000] [--bs 16] [--crop 256] [--width 32] [--resume]
The model works on a SMALL copy of the face (about 130-260 px wide) and sees all of it at once (six scales and a
summary of the whole crop at the bottom). The first attempt used the retouch model's four scales on 400-1000 px
crops: after 11,000 steps it undid a quarter of a painted shadow - the inside of a large shadow, far from its rim,
looks like a darker photo to a network that sees 100 px around each pixel. The factor map is brought to the photo's
resolution afterwards, with the photo's edges as a guide (lrcdf.shadow.guided), so nothing is lost by working small."""
import argparse, copy, json, os, sys, time
import cv2, numpy as np, torch, torch.nn.functional as F
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import torch.nn as nn
from train_retouch import Tars, DATA, block
from lrcdf import shadow

FACE = 0.5
WORK = 384          # the model is given an FFHQ-aligned crop of this size (face about 190 px wide)


class ShadowNet(nn.Module):
    """U-Net over six scales; the coarsest also gets the average of the whole crop, so every pixel knows how bright
    the face is elsewhere. Output: log factor per pixel and colour, at input size."""
    def __init__(self, width=32):
        super().__init__()
        w = [width, width * 3 // 2, width * 2, width * 3, width * 4, width * 5]
        self.down = nn.ModuleList([block(3, w[0])] + [block(w[k], w[k + 1]) for k in range(5)])
        self.mid = block(w[5] * 2, w[5])
        self.up = nn.ModuleList([block(w[k + 1] + w[k], w[k]) for k in range(4, -1, -1)])
        self.out = nn.Conv2d(w[0], 3, 3, padding=1)
        nn.init.zeros_(self.out.weight); nn.init.zeros_(self.out.bias)

    def forward(self, x):
        skips, h = [], x
        for k, layer in enumerate(self.down):
            h = layer(h if k == 0 else F.avg_pool2d(h, 2))
            skips.append(h)
        h = self.mid(torch.cat([h, h.mean((2, 3), keepdim=True).expand_as(h)], 1))
        for layer, skip in zip(self.up, reversed(skips[:-1])):
            h = layer(torch.cat([F.interpolate(h, size=skip.shape[-2:], mode="bilinear", align_corners=False), skip], 1))
        return self.out(h)


class Faces(torch.utils.data.Dataset):
    def __init__(self, keys, crop, training, parts):
        self.keys, self.crop, self.training, self.parts, self.orig = keys, crop, training, parts, None

    def open(self):
        self.orig = Tars()
        for p in self.parts:
            for k in range((p - 1) * 10, p * 10):
                if os.path.exists(f"{DATA}/ffhq1024/{k:02d}000.tar"):
                    self.orig.add(f"{DATA}/ffhq1024/{k:02d}000.tar")

    def __len__(self):
        return len(self.keys)

    def __getitem__(self, i):
        if self.orig is None:
            self.open()
        rng = np.random.default_rng(None if self.training else 1000 + i)
        a = self.orig.read(self.keys[i])
        s = float(np.exp(rng.uniform(np.log(max(0.26, (self.crop + 2) / 1024)), np.log(0.52)))) if self.training else WORK / 1024
        n = int(round(1024 * s))
        a = cv2.resize(a, (n, n), interpolation=cv2.INTER_AREA)
        c = min(self.crop, n) // 32 * 32
        y0, x0 = (int(rng.integers(0, n - c + 1)), int(rng.integers(0, n - c + 1))) if self.training else ((n - c) // 2,) * 2
        x = np.ascontiguousarray(a[y0:y0 + c, x0:x0 + c, ::-1]).astype(np.float32) / 255
        if self.training and rng.random() < 0.5:
            x = np.ascontiguousarray(x[:, ::-1])
        if (rng.random() if self.training else (i % 3) / 3) < 0.3:
            target = np.zeros_like(x)
        else:
            x, target = shadow.cast(x, n * FACE, rng)
        t = lambda im: torch.from_numpy(np.ascontiguousarray(im)).permute(2, 0, 1)
        return t(x), t(target)


def grad(v):
    return v[..., :, 1:] - v[..., :, :-1], v[..., 1:, :] - v[..., :-1, :]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--parts", default="1,2,3"); ap.add_argument("--steps", type=int, default=16000)
    ap.add_argument("--bs", type=int, default=16); ap.add_argument("--crop", type=int, default=256)
    ap.add_argument("--lr", type=float, default=1e-3); ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--resume", action="store_true"); ap.add_argument("--width", type=int, default=32)
    ap.add_argument("--every", type=int, default=1000)
    ap.add_argument("--rim", type=float, default=0.0, help="weight of the slope term (20 in the second attempt, which stayed at a constant answer)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    parts = [int(p) for p in a.parts.split(",")]
    dev = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    probe = Faces([], a.crop, True, parts); probe.open()
    keys = sorted(probe.orig.at)
    held, keys = keys[-300:], keys[:-300]
    print(f"device {dev}; {len(keys)} faces, {len(held)} held out", flush=True)
    loader = torch.utils.data.DataLoader(Faces(keys, a.crop, True, parts), batch_size=a.bs, shuffle=True, num_workers=a.workers,
                                         drop_last=True, persistent_workers=True, prefetch_factor=4)
    check = Faces(held[:90], WORK, False, parts); check.open()
    model = ShadowNet(a.width).to(dev).to(memory_format=torch.channels_last)
    ema = copy.deepcopy(model).eval()
    opt = torch.optim.AdamW(model.parameters(), a.lr, weight_decay=1e-4)
    step, last = 0, f"{a.out}/last.pt"
    if a.resume and os.path.exists(last):
        ck = torch.load(last, map_location="cpu", weights_only=False)
        model.load_state_dict(ck["model"]); ema.load_state_dict(ck["ema"]); opt.load_state_dict(ck["opt"]); step = ck["step"]
    print("parameters: %.1fM" % (sum(p.numel() for p in model.parameters()) / 1e6), flush=True)

    def evaluate():
        """Held-out faces: share of the painted shadow that is undone where there is one (1 = all); mean factor
        predicted on faces without a painted shadow, as a change in per cent (should be near 0)."""
        num = den = clean = 0.0; n_clean = 0
        with torch.no_grad():
            for i in range(len(check)):
                x, t = check[i]
                x, t = x[None].to(dev), t[None].to(dev)
                p = ema(x)
                if float(t.abs().max()) == 0:
                    clean += float(torch.expm1(p.abs()).mean()) * 100; n_clean += 1
                else:
                    on = (t.amax(1, keepdim=True) > 0.05).float()
                    num += float(((p - t).abs() * on).sum()); den += float((t.abs() * on).sum())
        return dict(undone=round(1 - num / max(den, 1e-9), 4), change_on_clean=round(clean / max(n_clean, 1), 3))

    t0, seen = time.time(), 0.0
    log = open(f"{a.out}/log.jsonl", "a")
    while step < a.steps:
        for x, t in loader:
            x = x.to(dev).contiguous(memory_format=torch.channels_last); t = t.to(dev)
            for g in opt.param_groups:
                g["lr"] = a.lr * min(1.0, (step + 1) / 500) * 0.5 * (1 + np.cos(np.pi * step / a.steps))
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=dev == "cuda"):
                p = model(x).float()
            (px, py), (tx, ty) = grad(p), grad(t)
            # Squared errors: with absolute ones the safest answer to "shadow or dark thing?" is no factor at all, and
            # the model stayed near it (the same trap as in train_dodge.py). More weight where there is a shadow;
            # the rim must sit exactly, so the slopes are compared too.
            weight = 1 + 4 * (t.amax(1, keepdim=True) > 0.02).float()
            loss = 10 * (weight * (p - t) ** 2).mean() + a.rim * (((px - tx) ** 2).mean() + ((py - ty) ** 2).mean())
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
            with torch.no_grad():
                decay = min(0.999, (1 + step) / (10 + step))
                for pe, pm in zip(ema.parameters(), model.parameters()):
                    pe.lerp_(pm, 1 - decay)
            step += 1; seen += loss.item()
            if step % 100 == 0:
                print(f"step {step} loss {seen / 100:.5f} {(time.time() - t0) / 100:.2f}s/step", flush=True)
                seen, t0 = 0.0, time.time()
            if step % a.every == 0 or step == a.steps:
                rec = dict(step=step, **evaluate())
                print(json.dumps(rec), flush=True); log.write(json.dumps(rec) + "\n"); log.flush()
                torch.save(dict(model=model.state_dict(), ema=ema.state_dict(), opt=opt.state_dict(), step=step, args=vars(a)), last + ".tmp")
                os.replace(last + ".tmp", last)
                torch.save(dict(model=ema.state_dict(), width=a.width, **rec), f"{a.out}/shadow.pt")
            if step >= a.steps:
                break


if __name__ == "__main__":
    main()
