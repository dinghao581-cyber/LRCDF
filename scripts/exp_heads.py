"""Fast head experiments on frozen features. dev = train groups 1200..1355 (model selection), val = official."""
import os, sys, json
import numpy as np, torch, torch.nn as nn, torch.nn.functional as Fn
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P
root = sys.argv[1]
L = np.load(f"{root}/labels.npz"); ids, ok = L["ids"], L["ok"]; N = len(ids)
wb = np.load(f"{root}/src_wb.npy")
group = np.array([int(s.split("_")[0]) for s in ids])
cache = f"{root}/targets_rel.npy"
if os.path.exists(cache): T = np.load(cache)
else:
    T = np.zeros((3, N, P.DIM), np.float32)
    for e in range(3):
        for i in np.flatnonzero(ok[e]):
            T[e, i] = P.encode(L["temp"][e, i], L["tint"][e, i], L["scalars"][e, i], L["curves"][e, i], wb[i, 0], wb[i, 1])
    np.save(cache, T)
tr = np.flatnonzero(group < 1200); dv = np.flatnonzero((group >= 1200) & (group < 1356)); va = np.flatnonzero(group >= 1356)
flat = T[:, tr][ok[:, tr]]
floor = np.concatenate([[0.02, 0.02], np.where(np.array(P.SCALAR_NAMES) == "Exposure2012", 0.05, 1.0), np.full(P.N_CURVE, 0.004)])
std = np.maximum(flat.std(0), floor)
mean_e = np.stack([T[e][tr][ok[e][tr]].mean(0) for e in range(3)])
wbf = np.stack([np.log(wb[:, 0] / P.T_DEFAULT), wb[:, 1] / P.TINT_SCALE], 1)
FC = np.load(f"{root}/feats_convnext.npy"); FS = np.load(f"{root}/feats_stats.npy")
iE = 2 + P.SCALAR_NAMES.index("Exposure2012")

def report(name, pred):  # pred [3,N,DIM] encoded units
    out = {}
    for tag, idx in (("dev", dv), ("val", va)):
        mae = np.stack([np.abs(pred[e][idx] - T[e][idx])[ok[e][idx]].mean(0) for e in range(3)])
        out[tag] = dict(norm=round(float((mae / std).mean()), 4), exp=[round(float(v), 3) for v in mae[:, iE]],
                        temp=[round(float(np.expm1(v) * 100), 1) for v in mae[:, 0]], tint=[round(float(v * 50), 1) for v in mae[:, 1]])
    print(name, json.dumps(out), flush=True); return out

report("baseline-mean", np.broadcast_to(mean_e[:, None], T.shape))
# oracle: other photos of the same group by the same expert (how consistent is a group?)
pg = np.zeros_like(T)
for e in range(3):
    for g in np.unique(group[np.concatenate([dv, va])]):
        i = np.flatnonzero((group == g) & ok[e])
        if len(i) > 1: pg[e, i] = (T[e, i].sum(0, keepdims=True) - T[e, i]) / (len(i) - 1)
        else: pg[e, i] = mean_e[e]
report("oracle-same-group", pg)

def feats(kind):
    parts = {"c": FC, "s": FS, "w": wbf}
    X = np.concatenate([parts[k] for k in kind], 1).astype(np.float32)
    return (X - X[tr].mean(0)) / (X[tr].std(0) + 1e-6)

def ridge(kind, lam):
    X = feats(kind); X1 = np.concatenate([X, np.ones((N, 1), np.float32)], 1); pred = np.zeros_like(T)
    for e in range(3):
        i = tr[ok[e][tr]]; A = X1[i].astype(np.float64); Y = ((T[e][i] - mean_e[e]) / std).astype(np.float64)
        R = lam * np.eye(A.shape[1]); R[-1, -1] = 0
        W = np.linalg.solve(A.T @ A + R, A.T @ Y); pred[e] = (X1 @ W) * std + mean_e[e]
    return report(f"ridge[{kind}] lam={lam}", pred)

def mlp(kind, hidden=512, drop=0.3, wd=0.05, epochs=40, lr=1e-3, seed=0):
    torch.manual_seed(seed); X = torch.tensor(feats(kind)); d = X.shape[1]
    net = nn.Sequential(nn.Dropout(0.1), nn.Linear(d, hidden), nn.GELU(), nn.Dropout(drop), nn.Linear(hidden, hidden), nn.GELU(), nn.Dropout(drop), nn.Linear(hidden, 3 * P.DIM))
    opt = torch.optim.AdamW(net.parameters(), lr=lr, weight_decay=wd)
    Y = torch.tensor((T - mean_e[:, None]) / std).permute(1, 0, 2); M = torch.tensor(ok.T)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, lr, total_steps=epochs * (len(tr) // 128 + 1))
    best, bp = 1e9, None
    for ep in range(epochs):
        net.train(); perm = torch.tensor(np.random.RandomState(ep + seed).permutation(tr))
        for s in range(0, len(perm), 128):
            i = perm[s:s + 128]; p = net(X[i]).view(-1, 3, P.DIM)
            l = (Fn.smooth_l1_loss(p, Y[i], reduction="none").mean(2) * M[i]).sum() / M[i].sum()
            opt.zero_grad(); l.backward(); opt.step(); sched.step()
        net.eval()
        with torch.no_grad(): p = net(X).view(-1, 3, P.DIM).permute(1, 0, 2).numpy() * std + mean_e[:, None]
        sc = np.mean([(np.abs(p[e][dv] - T[e][dv])[ok[e][dv]].mean(0) / std).mean() for e in range(3)])
        if sc < best: best, bp, be = sc, p.copy(), ep + 1
    return report(f"mlp[{kind}] h={hidden} drop={drop} wd={wd} best_ep={be}", bp)

for k in ("w", "sw", "cw", "csw"):
    for lam in (100, 1000, 10000): ridge(k, lam)
for k in ("sw", "csw"):
    mlp(k); mlp(k, drop=0.5)
mlp("csw", hidden=1024, drop=0.5, wd=0.2)
