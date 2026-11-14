"""Train the dodge-and-burn retouching model: from a face it predicts (1) a smooth map that is ADDED to the picture -
what a retoucher does on the colour layer of a frequency separation, or with dodge and burn - and (2) a heal mask:
the few places where the texture layer itself belongs to a blemish and is to be toned down. The picture's own texture
is never predicted, so pores cannot be lost or invented, and the maps can be made on a reduced copy of a face of any
size and enlarged (the add map is produced at a quarter of the working resolution).
usage: train_dodge.py <out dir> [--parts 1,2,3 | all] [--steps 40000] [--bs 10] [--crop 384] [--width 32] [--resume]
Data: the FFHQ/FFHQR pairs of train_retouch.py, used two ways. Real pairs give the add map (colour layer of what the
retoucher changed, without their overall tone shift) and, weakly, the heal mask (compact places where texture was
removed; their broad smoothing is not learnt). On top, lrcdf/blemish.py paints synthetic blemishes whose answer is
exact; a share of the samples starts from the retouched picture, where the answer is "nothing but the paint"."""
import argparse, copy, json, os, random, sys, time
import cv2, numpy as np, torch, torch.nn as nn, torch.nn.functional as F
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from train_retouch import Tars, DATA, block
from lrcdf import blemish

SPLIT = 0.006           # the same colour/texture split as lrcdf.beauty.SPLIT (fraction of the face width)
REACH = 0.06            # the add map carries nothing broader than this (fraction of the face width): see targets()
FACE = 0.5              # face width as a fraction of an FFHQ-aligned picture


def texture(img, face):
    return img - cv2.GaussianBlur(img, (0, 0), face * SPLIT)


def targets(x, y, face, real=True):
    """x: what the model sees, y: the answer (float RGB 0..1). Returns (add map h x w x 3, heal mask h x w).
    Of a real retoucher's change only the local part is taken (spots, marks, lines, small patches of light and shade):
    what is broader than REACH is their taste in tone and contrast, which cannot be told from the picture and is
    Lightroom's part here."""
    add = cv2.GaussianBlur(y - x, (0, 0), face * SPLIT)
    if real:
        add -= cv2.GaussianBlur(add, (0, 0), face * REACH)
    e = cv2.GaussianBlur(np.abs(texture(x, face) - texture(y, face)).mean(2), (0, 0), max(0.7, face * 0.004))
    if real:                # retouchers also smooth whole areas: keep only compact places that stand out of that
        e = e - 1.5 * cv2.GaussianBlur(e, (0, 0), face * 0.03)
    return add, np.clip((e - 0.006) / 0.02, 0, 1)


class Faces(torch.utils.data.Dataset):
    def __init__(self, keys, crop, training, parts, seed=0):
        self.keys, self.crop, self.training, self.parts, self.seed = keys, crop, training, parts, seed
        self.orig = self.done = None

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
        rng = np.random.default_rng(None if self.training else self.seed + i)
        a, b = self.orig.read(self.keys[i]), self.done.read(self.keys[i])
        s = float(np.exp(rng.uniform(np.log(max(0.4, (self.crop + 2) / 1024)), 0))) if self.training else (0.5, 0.75, 1.0)[i % 3]
        if s < 0.98:
            n = int(round(1024 * s))
            a, b = cv2.resize(a, (n, n), interpolation=cv2.INTER_AREA), cv2.resize(b, (n, n), interpolation=cv2.INTER_AREA)
        n = a.shape[0]; face = n * FACE; c = min(self.crop, n) // 16 * 16
        if self.training:
            best = None
            for _ in range(3):      # of three places, the one where the retoucher did most
                y0, x0 = int(rng.integers(0, n - c + 1)), int(rng.integers(0, n - c + 1))
                dd = float(np.abs(a[y0:y0 + c, x0:x0 + c:4].astype(np.int16) - b[y0:y0 + c, x0:x0 + c:4]).mean())
                if best is None or dd > best[0]:
                    best = (dd, y0, x0)
            _, y0, x0 = best
        else:
            y0 = x0 = (n - c) // 2
        f = lambda im: np.ascontiguousarray(im[y0:y0 + c, x0:x0 + c, ::-1]).astype(np.float32) / 255
        a, b = f(a), f(b)
        kind = rng.random() if self.training else (0.0, 0.5, 0.9)[i % 3]
        if kind < 0.15:             # clean skin plus paint: the answer is exactly the paint
            x = blemish.paint(b.copy(), face, rng, amount=int(rng.integers(1, 4)))
            add, heal = targets(x, b, face, real=False)
        elif kind < 0.6:            # a real pair with paint on top
            x = blemish.paint(a.copy(), face, rng, amount=int(rng.integers(1, 4)))
            add, heal = targets(a, b, face)
            add2, heal2 = targets(x, a, face, real=False)
            add, heal = add + add2, np.maximum(heal, heal2)
        else:                       # a real pair as it is
            x = a
            add, heal = targets(a, b, face)
        if self.training and rng.random() < 0.5:
            x, add, heal = x[:, ::-1], add[:, ::-1], heal[:, ::-1]
        t = lambda im: torch.from_numpy(np.ascontiguousarray(im)).permute(2, 0, 1)
        return t(x), t(add), torch.from_numpy(np.ascontiguousarray(heal))[None], torch.tensor(float(kind >= 0.6))


class DodgeNet(nn.Module):
    """U-Net with two outputs: the add map at a quarter of the input size (enlarged smoothly by the caller) and the
    heal mask at input size (logits)."""
    def __init__(self, width=32):
        super().__init__()
        w = [width, width * 2, width * 4, width * 6, width * 6]
        self.down = nn.ModuleList([block(3, w[0])] + [block(w[k], w[k + 1]) for k in range(4)])
        self.up = nn.ModuleList([block(w[4] + w[3], w[3]), block(w[3] + w[2], w[2]), block(w[2] + w[1], w[1]), block(w[1] + w[0], w[0])])
        self.add = nn.Conv2d(w[2], 3, 3, padding=1)
        self.heal = nn.Conv2d(w[0], 1, 3, padding=1)
        nn.init.zeros_(self.add.weight); nn.init.zeros_(self.add.bias)
        nn.init.zeros_(self.heal.weight); nn.init.constant_(self.heal.bias, -4.0)

    def forward(self, x):
        skips, h = [], x
        for k, layer in enumerate(self.down):
            h = layer(h if k == 0 else F.avg_pool2d(h, 2))
            skips.append(h)
        add = None
        for k, (layer, skip) in enumerate(zip(self.up, reversed(skips[:-1]))):
            h = layer(torch.cat([F.interpolate(h, size=skip.shape[-2:], mode="bilinear", align_corners=False), skip], 1))
            if k == 1:
                add = self.add(h)
        return add, self.heal(h)


def apply(net, x):
    """x: 1 x 3 x h x w, 0..1, sides divisible by 16. Returns (add map at input size, heal mask 0..1)."""
    add, heal = net(x)
    return F.interpolate(add, size=x.shape[-2:], mode="bicubic", align_corners=False), torch.sigmoid(heal)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--parts", default="1"); ap.add_argument("--steps", type=int, default=40000)
    ap.add_argument("--bs", type=int, default=10); ap.add_argument("--crop", type=int, default=384)
    ap.add_argument("--lr", type=float, default=3e-4); ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--resume", action="store_true"); ap.add_argument("--width", type=int, default=32)
    ap.add_argument("--every", type=int, default=2000)
    ap.add_argument("--focus", type=float, default=6.0, help="extra weight where a change is wanted (10 in the first trial: more made, more drift)")
    ap.add_argument("--heal", type=float, default=6.0, help="extra weight of heal-mask pixels (12 in the first trial: mask too generous)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    setup = f"{a.out}/setup.json"
    if a.resume and os.path.exists(setup):
        kept = json.load(open(setup)); a.parts = kept["parts"]
    if a.parts == "all":            # every part of FFHQR that is there whole (a download in progress has another name)
        a.parts = ",".join(str(p) for p in range(1, 8) if os.path.exists(f"{DATA}/ffhqr/ffhqr.part{p}.tar")
                           and all(os.path.exists(f"{DATA}/ffhq1024/{k:02d}000.tar") for k in range((p - 1) * 10, p * 10)))
    parts = [int(p) for p in a.parts.split(",")]
    dev = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    probe = Faces([], a.crop, True, parts); probe.open()
    keys = sorted(k for k in probe.done.at if k in probe.orig.at)
    held, keys = keys[-300:], keys[:-300]
    if a.resume and os.path.exists(setup):
        held = kept["held"]; keys = [k for k in keys if k not in set(held)]
    else:
        json.dump(dict(parts=a.parts, held=held), open(setup, "w"))
    print(f"device {dev}; {len(keys)} training pairs, {len(held)} held out; parts {parts}", flush=True)
    loader = torch.utils.data.DataLoader(Faces(keys, a.crop, True, parts), batch_size=a.bs, shuffle=True, num_workers=a.workers,
                                         drop_last=True, persistent_workers=True, prefetch_factor=4)
    check = Faces(held[:90], 768, False, parts); check.open()

    model = DodgeNet(a.width).to(dev).to(memory_format=torch.channels_last)
    ema = copy.deepcopy(model).eval()
    opt = torch.optim.AdamW(model.parameters(), a.lr, weight_decay=1e-4)
    step = 0
    last = f"{a.out}/last.pt"
    if a.resume and os.path.exists(last):
        ck = torch.load(last, map_location="cpu", weights_only=False)
        model.load_state_dict(ck["model"]); ema.load_state_dict(ck["ema"]); opt.load_state_dict(ck["opt"]); step = ck["step"]
        print("resumed at step", step, flush=True)
    print("parameters: %.1fM" % (sum(p.numel() for p in model.parameters()) / 1e6), flush=True)

    def evaluate():
        """Held-out faces at 512, 768 and 1024 px, a third each of: paint on clean skin, paint on a real pair, real
        pair. add_*: share of the wanted colour-layer change that is made, where one is wanted (1 = all, 0 = nothing,
        below 0 = harm); drift_*: mean change, in 8-bit levels, where none is wanted; heal_*: overlap of the predicted
        heal mask with the wanted one (soft IoU)."""
        got = {}
        with torch.no_grad():
            for i in range(len(check)):
                x, add, heal, _ = check[i]
                x, add, heal = x[None].to(dev), add[None].to(dev), heal[None].to(dev)
                pa, ph = apply(ema, x)
                name = ("paint", "both", "real")[i % 3]
                g = got.setdefault(name, [0.0] * 7)
                on = (add.abs().amax(1, keepdim=True) > 2 / 255).float()
                g[0] += float(((pa - add).abs() * on).sum()); g[1] += float((add.abs() * on).sum())
                g[2] += float(torch.minimum(ph, heal).sum()); g[3] += float(torch.maximum(ph, heal).sum())
                g[4] += float((pa.abs() * (1 - on)).sum() / ((1 - on).sum() * 3 + 1) * 255); g[5] += 1
        rec = {}
        for name, g in got.items():
            rec["add_" + name] = round(1 - g[0] / max(g[1], 1e-9), 4); rec["heal_" + name] = round(g[2] / max(g[3], 1e-9), 4)
            rec["drift_" + name] = round(g[4] / g[5], 3)
        return rec

    t0, seen = time.time(), 0.0
    log = open(f"{a.out}/log.jsonl", "a")
    while step < a.steps:
        for x, add, heal, real in loader:
            x = x.to(dev).contiguous(memory_format=torch.channels_last); add = add.to(dev); heal = heal.to(dev); real = real.to(dev)
            for g in opt.param_groups:
                g["lr"] = a.lr * min(1.0, (step + 1) / 500) * 0.5 * (1 + np.cos(np.pi * step / a.steps))
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=dev == "cuda"):
                pa, ph = model(x)
            pa = F.interpolate(pa.float(), size=x.shape[-2:], mode="bicubic", align_corners=False); ph = ph.float()
            # The wanted map is zero almost everywhere. A plain absolute error then settles on "add nothing" (seen:
            # the output stayed at zero); a squared error for small misses, and more weight where something is wanted,
            # keeps the few places that matter in charge.
            weight = 1 + a.focus * (add.abs().amax(1, keepdim=True) > 2 / 255).float()
            bce = F.binary_cross_entropy_with_logits(ph, heal, reduction="none") * (1 + a.heal * heal)
            # heal masks derived from real pairs are rough: they count a third
            loss = 20 * (F.huber_loss(pa, add, reduction="none", delta=0.03) / 0.03 * weight).mean() + (bce.mean((1, 2, 3)) * (1 - 0.67 * real)).mean()
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
                torch.save(dict(model=ema.state_dict(), width=a.width, **rec), f"{a.out}/dodge.pt")
            if step >= a.steps:
                break


if __name__ == "__main__":
    main()
