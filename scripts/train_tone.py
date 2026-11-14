"""Train ToneNet on PPR10K: source image -> each expert Lightroom parameters.
usage: train_tone.py <ppr10k_dir> <out_dir> [--epochs 12] [--bs 64] [--limit N] [--expaug 0.7] [--freeze]
Splits by shoot (group): train <1200, dev 1200..1355 (model selection), val >=1356 (official PPR10K val, report only)."""
import argparse, copy, json, os, sys, time
import numpy as np
import torch
import torch.nn.functional as F
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P
from lrcdf.model import ToneNet, SIZE, CACHE

ap = argparse.ArgumentParser()
ap.add_argument("root"); ap.add_argument("out")
ap.add_argument("--epochs", type=int, default=12); ap.add_argument("--bs", type=int, default=64)
ap.add_argument("--limit", type=int, default=0); ap.add_argument("--lr", type=float, default=2e-5)
ap.add_argument("--head_lr", type=float, default=1e-3); ap.add_argument("--expaug", type=float, default=0.0)
ap.add_argument("--freeze", action="store_true"); ap.add_argument("--all", action="store_true", help="train on train+dev")
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
torch.manual_seed(0); np.random.seed(0)
dev = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"

L = np.load(f"{a.root}/labels.npz")
imgs = np.load(f"{a.root}/cache_source_{CACHE}.npy", mmap_mode="r")
ids, ok = L["ids"], L["ok"]; N = len(ids)
group = np.array([int(s.split("_")[0]) for s in ids])
src_wb = np.load(f"{a.root}/src_wb.npy")     # as-shot temperature/tint of every photo (PPR10K xmp_source)
t_as, tint_as = src_wb[:, 0], src_wb[:, 1]


def targets(rel):
    T = np.zeros((3, N, P.DIM), np.float32)
    for e in range(3):
        for i in np.flatnonzero(ok[e]):
            r = (t_as[i], tint_as[i]) if rel else (P.T_DEFAULT, 0.0)
            T[e, i] = P.encode(L["temp"][e, i], L["tint"][e, i], L["scalars"][e, i], L["curves"][e, i], *r)
    return T


def cached(name, rel):
    f = f"{a.root}/{name}.npy"
    if not os.path.exists(f):
        np.save(f, targets(rel))
    return np.load(f)


T_rel, T_abs = cached("targets_rel", True), cached("targets_abs", False)
train = np.flatnonzero(group < (1356 if a.all else 1200))
dv = np.flatnonzero((group >= 1200) & (group < 1356)); val = np.flatnonzero(group >= 1356)
if a.limit:
    train, dv, val = train[:a.limit], dv[:128], val[:128]
flat = T_rel[:, train][ok[:, train]]
mean = flat.mean(0)
floor = np.concatenate([[0.02, 0.02], np.where(np.array(P.SCALAR_NAMES) == "Exposure2012", 0.05, 1.0),
                        np.full(P.N_CURVE, 0.004)])
std = np.maximum(flat.std(0), floor)
mean[:2] = 0  # WB dims are used both as-shot-relative and absolute; keep them zero-centred
iE = 2 + P.SCALAR_NAMES.index("Exposure2012")

model = ToneNet().to(dev)
model.t_mean.copy_(torch.tensor(mean)); model.t_std.copy_(torch.tensor(std))
ema = copy.deepcopy(model).eval()
head = [p for n, p in model.named_parameters() if not n.startswith("backbone")]
groups = [{"params": head, "lr": a.head_lr}]
if a.freeze:
    model.backbone.requires_grad_(False)
else:
    groups.append({"params": model.backbone.parameters(), "lr": a.lr})
opt = torch.optim.AdamW(groups, weight_decay=0.05)
steps = a.epochs * (len(train) // a.bs)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, [g["lr"] for g in groups], total_steps=steps, pct_start=0.15)
styles = torch.arange(3, device=dev)


def batch(idx, training):
    idx = np.sort(idx); n = len(idx)
    x = torch.from_numpy(np.ascontiguousarray(imgs[idx])).to(dev).permute(0, 3, 1, 2).float() / 255
    # the as-shot WB is given (and the WB target is relative to it); dropped 20% in training so the
    # model still works on photos whose as-shot value is unavailable
    use = (np.random.rand(n) > 0.2) if training else np.ones(n, bool)
    tgt = torch.tensor(np.where(use[None, :, None], T_rel[:, idx], T_abs[:, idx]), device=dev)
    if training:
        s = np.random.randint(int(CACHE * 0.75), CACHE + 1)           # random crop, then resize
        i, j = np.random.randint(0, CACHE - s + 1, 2)
        x = x[:, :, i:i + s, j:j + s]
        if np.random.rand() < 0.5:
            x = x.flip(3)
        if a.expaug:  # darken/brighten the input and move the Exposure label the opposite way
            d = (torch.rand(n, device=dev) * 2 - 1) * a.expaug * (torch.rand(n, device=dev) < 0.5)
            x = (x.clamp_min(1e-4) ** 2.2 * (2 ** d).view(-1, 1, 1, 1)).clamp(0, 1) ** (1 / 2.2)
            tgt[:, :, iE] -= d
    x = F.interpolate(x, size=(SIZE, SIZE), mode="bilinear", antialias=True, align_corners=False)
    wb = np.stack([np.log(t_as[idx] / P.T_DEFAULT), tint_as[idx] / P.TINT_SCALE, np.ones(n)], 1) * use[:, None]
    return x, torch.tensor(wb, dtype=torch.float32, device=dev), tgt, torch.tensor(ok[:, idx], device=dev)


def run(m, x, wb):
    feat = m.features(x)
    return torch.stack([m.heads(feat, styles[e].expand(len(x)), wb) for e in range(3)])


def evaluate(m, idx):
    err, msk = [], []
    with torch.no_grad():
        for s in range(0, len(idx), 128):
            x, wb, tgt, k = batch(idx[s:s + 128], False)
            err.append(((run(m, x, wb) * m.t_std + m.t_mean) - tgt).abs().cpu().numpy()); msk.append(k.cpu().numpy())
    err, msk = np.concatenate(err, 1), np.concatenate(msk, 1)
    return np.array([err[e][msk[e]].mean(0) for e in range(3)])  # [3,DIM] in encoded units


def summary(mae):
    return dict(norm=round(float((mae / std).mean()), 4), key=round(float((mae / std)[:, [0, 1, iE]].mean()), 4),
                exposure=[round(float(v), 3) for v in mae[:, iE]],
                temp_pct=[round(float(np.expm1(v) * 100), 1) for v in mae[:, 0]],
                tint=[round(float(v * P.TINT_SCALE), 1) for v in mae[:, 1]])


def baseline(idx):  # always predict the expert mean edit (as-shot WB + mean shift)
    return np.array([np.abs(T_rel[e][idx][ok[e][idx]] - T_rel[e][train][ok[e][train]].mean(0)).mean(0) for e in range(3)])


base = {"dev": summary(baseline(dv)), "val": summary(baseline(val))}
log = open(f"{a.out}/log.jsonl", "a")
print(f"device {dev} train {len(train)} dev {len(dv)} val {len(val)} steps {steps}", flush=True)
print("baseline", json.dumps(base), flush=True)
best, t0, step = 1e9, time.time(), 0
for ep in range(a.epochs):
    model.train(); tot = 0
    if a.freeze:
        model.backbone.eval()
    perm = np.random.permutation(train)
    for s in range(0, len(perm) - a.bs + 1, a.bs):
        x, wb, tgt, m = batch(perm[s:s + a.bs], True)
        loss = F.smooth_l1_loss(run(model, x, wb), (tgt - model.t_mean) / model.t_std, reduction="none").mean(2)
        loss = (loss * m).sum() / m.sum()
        opt.zero_grad(set_to_none=True); loss.backward(); opt.step(); sched.step()
        tot += loss.item(); step += 1
        decay = min(0.998, (1 + step) / (10 + step))
        with torch.no_grad():
            for pe, pm in zip(ema.parameters(), model.parameters()):
                pe.lerp_(pm, 1 - decay)
            for be, bm in zip(ema.buffers(), model.buffers()):
                be.copy_(bm)
    d, v = evaluate(ema, dv), evaluate(ema, val)
    rec = dict(epoch=ep + 1, loss=round(tot / max(1, len(perm) // a.bs), 4), minutes=round((time.time() - t0) / 60, 1),
               dev=summary(d), val=summary(v))
    print(json.dumps(rec), flush=True); log.write(json.dumps(rec) + "\n"); log.flush()
    score = rec["val" if a.all else "dev"]["norm"] + rec["val" if a.all else "dev"]["key"]
    if score < best or a.all:
        best = score
        torch.save({"model": ema.state_dict(), "styles": ["a", "b", "c"], "val": rec, "base": base,
                    "mae": v.tolist(), "args": vars(a)}, f"{a.out}/tone.pt")
