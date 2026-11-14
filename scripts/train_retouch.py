"""Train the high-resolution retouching model on FFHQR: original 1024 px face -> what a professional retoucher changed.
usage: train_retouch.py <out dir> [--parts 1,2,3] [--steps 40000] [--bs 12] [--crop 384] [--resume]
Data (scripts/fetch_ffhq.sh): ~/LRCDF/data/ffhqr/ffhqr.part<N>.tar (retouched PNG) and ~/LRCDF/data/ffhq1024/<NN000>.tar
(originals, lossless WebP). Pictures are read straight out of the tars.
The model is small and fully convolutional and learns the residual on random crops, so it works on any size of face at
the photo's own resolution (the 512 px model it is meant to replace cannot be trained on this Mac: 156M parameters).
The last 300 pairs of the highest part are held out; the log reports how much of the retoucher's change is reproduced."""
import argparse, copy, io, json, os, random, sys, tarfile, time
import cv2, numpy as np, torch, torch.nn as nn, torch.nn.functional as F

DATA = os.environ.get("LRCDF_DATA") or os.path.expanduser("~/LRCDF/data")


class Tars:
    """Random access to the files inside tar archives: name -> (archive, offset, size)."""
    def __init__(self):
        self.at = {}

    def add(self, path, key=lambda name: os.path.basename(name)[:5]):
        index = path + ".index.json"
        if os.path.exists(index):
            entries = json.load(open(index))
        else:
            entries = {}
            with tarfile.open(path) as t:
                for m in t:
                    if m.isfile():
                        entries[key(m.name)] = (m.offset_data, m.size)
            json.dump(entries, open(index, "w"))
        for k, (offset, size) in entries.items():
            self.at[k] = (path, offset, size)

    def read(self, key):
        path, offset, size = self.at[key]
        with open(path, "rb") as f:
            f.seek(offset)
            return cv2.imdecode(np.frombuffer(f.read(size), np.uint8), cv2.IMREAD_COLOR)


class Pairs(torch.utils.data.Dataset):
    def __init__(self, keys, crop, training, parts):
        self.keys, self.crop, self.training, self.parts = keys, crop, training, parts
        self.orig = self.done = None      # opened in each loader process

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
        if self.training:
            c = self.crop
            best = None
            for _ in range(3):      # of three places, take the one where the retoucher did most
                y, x = random.randint(0, 1024 - c), random.randint(0, 1024 - c)
                d = float(np.abs(a[y:y + c, x:x + c].astype(np.int16) - b[y:y + c, x:x + c]).mean())
                if best is None or d > best[0]:
                    best = (d, y, x)
            _, y, x = best
            a, b = a[y:y + c, x:x + c], b[y:y + c, x:x + c]
            if random.random() < 0.5:
                a, b = a[:, ::-1], b[:, ::-1]
        f = lambda im: torch.from_numpy(np.ascontiguousarray(im[..., ::-1])).permute(2, 0, 1).float() / 255
        return f(a), f(b)


def block(cin, cout):
    return nn.Sequential(nn.Conv2d(cin, cout, 3, padding=1), nn.GELU(), nn.Conv2d(cout, cout, 3, padding=1), nn.GELU())


class RetouchNet(nn.Module):
    """U-Net that predicts what to add to the picture. Four scales, so it sees about 200 px around every pixel."""
    def __init__(self, width=40):
        super().__init__()
        w = [width, width * 2, width * 4, width * 6]
        self.down = nn.ModuleList([block(3, w[0]), block(w[0], w[1]), block(w[1], w[2]), block(w[2], w[3])])
        self.mid = block(w[3], w[3])
        self.up = nn.ModuleList([block(w[3] + w[2], w[2]), block(w[2] + w[1], w[1]), block(w[1] + w[0], w[0])])
        self.out = nn.Conv2d(w[0], 3, 3, padding=1)
        nn.init.zeros_(self.out.weight); nn.init.zeros_(self.out.bias)       # starts as "change nothing"

    def forward(self, x):
        skips, h = [], x
        for k, layer in enumerate(self.down):
            h = layer(h if k == 0 else F.avg_pool2d(h, 2))
            skips.append(h)
        h = self.mid(h)
        for layer, skip in zip(self.up, reversed(skips[:-1])):
            h = layer(torch.cat([F.interpolate(h, size=skip.shape[-2:], mode="bilinear", align_corners=False), skip], 1))
        return self.out(h)


def highpass(x):
    return x - F.avg_pool2d(x, 5, stride=1, padding=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--parts", default="1"); ap.add_argument("--steps", type=int, default=40000)
    ap.add_argument("--bs", type=int, default=12); ap.add_argument("--crop", type=int, default=384)
    ap.add_argument("--lr", type=float, default=2e-4); ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--resume", action="store_true"); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--width", type=int, default=40, help="channels of the first stage (40 = 3.4M parameters; 80 on a 24 GB NVIDIA card)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    setup = f"{a.out}/setup.json"       # the data a run was started with stays with it: resuming cannot change it
    if a.resume and os.path.exists(setup):
        kept = json.load(open(setup)); a.parts = kept["parts"]
    parts = [int(p) for p in a.parts.split(",")]
    dev = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    probe = Pairs([], a.crop, True, parts); probe.open()
    keys = sorted(k for k in probe.done.at if k in probe.orig.at)
    held, keys = keys[-300:], keys[:-300]
    if a.resume and os.path.exists(setup):
        held = kept["held"]; keys = [k for k in keys if k not in set(held)]
    else:
        json.dump(dict(parts=a.parts, held=held), open(setup, "w"))
    if a.limit:
        keys = keys[:a.limit]
    if len(keys) < a.bs:
        raise SystemExit("fewer training pairs than one batch")
    print(f"device {dev}; {len(keys)} training pairs, {len(held)} held out; parts {parts}", flush=True)
    loader = torch.utils.data.DataLoader(Pairs(keys, a.crop, True, parts), batch_size=a.bs, shuffle=True, num_workers=a.workers,
                                         drop_last=True, persistent_workers=True, prefetch_factor=4)
    check = Pairs(held[:60], a.crop, False, parts); check.open()

    model = RetouchNet(a.width).to(dev).to(memory_format=torch.channels_last)
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
        """On held-out pairs: how much closer to the retoucher the model gets than doing nothing (1 = identical),
        over the whole picture and only where the retoucher changed something; and how much it disturbs what the
        retoucher left alone (mean change there, in 8-bit levels)."""
        num = den = enum = eden = drift = 0.0
        with torch.no_grad():
            for i in range(len(check)):
                x, y = check[i]
                x, y = x[None].to(dev), y[None].to(dev)
                p = x + ema(x)
                edited = ((x - y).abs().amax(1, keepdim=True) > 4 / 255).float()
                num += float((p - y).abs().mean()); den += float((x - y).abs().mean())
                enum += float(((p - y).abs() * edited).sum()); eden += float(((x - y).abs() * edited).sum())
                drift += float(((p - x).abs() * (1 - edited)).sum() / ((1 - edited).sum() * 3 + 1) * 255)
        return dict(closer_all=round(1 - num / den, 4), closer_edited=round(1 - enum / max(eden, 1e-9), 4),
                    drift_untouched=round(drift / len(check), 3))

    t0, seen = time.time(), 0.0
    log = open(f"{a.out}/log.jsonl", "a")
    while step < a.steps:
        for x, y in loader:
            x = x.to(dev).contiguous(memory_format=torch.channels_last); y = y.to(dev)
            for g in opt.param_groups:
                g["lr"] = a.lr * min(1.0, (step + 1) / 500) * 0.5 * (1 + np.cos(np.pi * step / a.steps))
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=dev == "cuda"):     # about twice as fast on NVIDIA
                pred = x + model(x).float()
            weight = 1 + 6 * ((x - y).abs().amax(1, keepdim=True) > 4 / 255).float()        # where the retoucher worked
            loss = ((pred - y).abs() * weight).mean() + 0.5 * (highpass(pred) - highpass(y)).abs().mean()
            opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
            with torch.no_grad():
                decay = min(0.999, (1 + step) / (10 + step))
                for pe, pm in zip(ema.parameters(), model.parameters()):
                    pe.lerp_(pm, 1 - decay)
            step += 1; seen += loss.item()
            if step % 100 == 0:
                print(f"step {step} loss {seen / 100:.5f} {(time.time() - t0) / 100:.2f}s/step", flush=True)
                seen, t0 = 0.0, time.time()
            if step % 2000 == 0 or step == a.steps:
                rec = dict(step=step, **evaluate())
                print(json.dumps(rec), flush=True); log.write(json.dumps(rec) + "\n"); log.flush()
                torch.save(dict(model=model.state_dict(), ema=ema.state_dict(), opt=opt.state_dict(), step=step, args=vars(a)), last + ".tmp")
                os.replace(last + ".tmp", last)
                torch.save(dict(model=ema.state_dict(), width=a.width, **rec), f"{a.out}/retouch.pt")
            if step >= a.steps:
                break


if __name__ == "__main__":
    main()
