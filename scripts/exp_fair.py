"""Is retouching even-handed across skin tones? Faces are put into six groups by ITA (individual typology angle, from
Lab on a patch of cheek and nose; the usual dermatology scale: very light > 55, light > 41, intermediate > 28, tan > 10,
brown > -30, dark below). Per group: what professionals did (FFHQR), how well the critic predicts it, how much of the
face our skin detection finds, and what our pipeline and its guard do.
usage: exp_fair.py <critic run dir> <out.json> [--per 40]     (--per: faces per group put through the pipeline)"""
import argparse, json, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import train_critic as C

GROUPS = [("very light", 55), ("light", 41), ("intermediate", 28), ("tan", 10), ("brown", -30), ("dark", -999)]


def ita(view):
    """view: uint8 RGB, FFHQ-aligned. Typology angle of the median colour of the cheeks-and-nose patch."""
    n = view.shape[0]
    patch = view[int(n * 0.50):int(n * 0.66), int(n * 0.33):int(n * 0.67)]
    lab = cv2.cvtColor(patch, cv2.COLOR_RGB2Lab).reshape(-1, 3).astype(np.float32)
    L, b = np.median(lab[:, 0]) * 100 / 255, np.median(lab[:, 2]) - 128
    return float(np.degrees(np.arctan2(L - 50, b)))


def group_of(angle):
    return next(k for k, (_, lo) in enumerate(GROUPS) if angle > lo)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("run"); ap.add_argument("out"); ap.add_argument("--per", type=int, default=40)
    a = ap.parse_args()
    keys = json.load(open(f"{a.run}/keys.json")); views = np.load(f"{a.run}/views.npy", mmap_mode="r"); am = np.load(f"{a.run}/amounts.npy")
    g = np.array([group_of(ita(views[i])) for i in range(len(keys))])
    use = np.flatnonzero(am[:, 2] > 0.03); held = use[-600:]
    dev = "mps"
    ck = torch.load(f"{a.run}/critic.pt", map_location="cpu", weights_only=False)
    critic = C.Critic(False); critic.load_state_dict(ck["model"]); critic = critic.to(dev).eval()
    with torch.no_grad():
        P = torch.cat([critic(torch.from_numpy(np.stack([views[i] for i in held[s:s + 100]])).to(dev).permute(0, 3, 1, 2).float() / 255).cpu()
                       for s in range(0, len(held), 100)]).reshape(-1, 2, 2)
    q90 = np.stack([np.exp(P[:, 0, 1].numpy()) - 0.1, P[:, 1, 1].numpy()], 1)
    rep = {}
    print("group          faces  skin found  too little skin | professionals: colour  texture | critic q90 holds (held-out n): colour texture")
    for k, (name, _) in enumerate(GROUPS):
        m = g == k; h = g[held] == k
        row = dict(faces=int(m.sum()), skin=float(am[m, 2].mean()), no_skin=float((am[m, 2] <= 0.03).mean()),
                   pro_colour=float(np.median(am[m & (am[:, 2] > 0.03), 0])), pro_texture=float(np.median(am[m & (am[:, 2] > 0.03), 1])),
                   held=int(h.sum()), cover_colour=float((am[held][h, 0] <= q90[h, 0]).mean()) if h.any() else None,
                   cover_texture=float((am[held][h, 1] <= q90[h, 1]).mean()) if h.any() else None)
        rep[name] = row
        print(f"{name:13s} {row['faces']:6d}  {row['skin']:.3f}      {100 * row['no_skin']:5.1f}%         | {row['pro_colour']:.2f}    {row['pro_texture']:.3f}  |"
              f" ({row['held']:3d})  {row['cover_colour'] if row['cover_colour'] is None else round(row['cover_colour'], 2)}  {row['cover_texture'] if row['cover_texture'] is None else round(row['cover_texture'], 2)}", flush=True)
    if a.per:
        import beautify
        from lrcdf import beauty
        pairs = C.Pairs([], [1, 2, 3]); pairs.open()
        models = beautify.load_models(dev)
        small = lambda im: cv2.resize(im, (C.SIDE, C.SIDE), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
        print("\nour pipeline, level natural:  faces | found by the face detector | colour | texture removed | toned down by the guard")
        for k, (name, _) in enumerate(GROUPS):
            pick = np.flatnonzero(g == k)[-a.per:]
            got = []; found = 0; guarded = 0
            for i in pick:
                src = np.ascontiguousarray(pairs.orig.read(keys[i])[..., ::-1])
                opt = dict(blemish=1.0, smooth=.6, undereye=.5, eyes=.4, teeth=.4)
                for kk, d in beauty.DEFAULTS.items():
                    opt.setdefault(kk, d)
                res, n = beautify.process(src, models, opt, dev)
                found += n > 0
                guarded += any(x["kept"] < 1 for x in opt.get("_guard") or [])
                x = small(src); w = C.skin_of(x)
                if w.mean() > 0.03:
                    got.append(C.measure(x, small(res), w))
            got = np.array(got) if got else np.zeros((1, 2))
            rep[name].update(tested=len(pick), detected=found, ours_colour=float(np.median(got[:, 0])), ours_texture=float(np.median(got[:, 1])), guarded=guarded)
            print(f"{name:13s} {len(pick):4d} | {found:4d} | {np.median(got[:, 0]):.2f} | {np.median(got[:, 1]):.3f} | {guarded}", flush=True)
    json.dump(rep, open(a.out, "w"), indent=1)


if __name__ == "__main__":
    main()
