"""Parse the three experts' XMP folders into one labels file.
usage: build_labels.py <ppr10k_dir> <out.npz>

Expert a's XMP names match the image names. For experts b/c the XMP files of some
groups carry a different group number, so each b/c group is mapped to the image
group whose photos share its EXIF fingerprints (majority vote, checked below)."""
import sys, glob, os, re, collections
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import params as P

root, out = sys.argv[1], sys.argv[2]
order = lambda s: tuple(map(int, s.split("_")))


def fingerprint(t):
    g = lambda k: (re.search(k + r'="([^"]*)"', t) or [None, None])[1]
    return (g("exif:DateTimeOriginal"), g("tiff:Model"), g("exif:ExposureTime"), g("exif:FNumber"))


texts = {e: {os.path.basename(f)[:-4]: open(f, errors="ignore").read()
             for f in glob.glob(f"{root}/xmp_target_{e}/*.xmp")} for e in "abc"}
ids = sorted(texts["a"], key=order)
index = {pid: i for i, pid in enumerate(ids)}
fp_a = collections.defaultdict(set)
for pid, t in texts["a"].items():
    fp_a[fingerprint(t)].add(pid)

N = len(ids)
temp = np.full((3, N), np.nan, np.float32); tint = temp.copy()
scal = np.zeros((3, N, P.N_SCALAR), np.float32)
curv = np.zeros((3, N, len(P.CURVES), len(P.CURVE_X)), np.float32)
asshot = np.zeros((3, N), bool); ok = np.zeros((3, N), bool)
for e, name in enumerate("abc"):
    votes = collections.defaultdict(collections.Counter)
    for pid, t in texts[name].items():
        g, k = pid.split("_")
        for cand in fp_a.get(fingerprint(t), ()):
            cg, ck = cand.split("_")
            if ck == k:
                votes[g][cg] += 1
    gmap, weak = {}, 0
    sizes = collections.Counter(p.split("_")[0] for p in texts[name])
    for g in sizes:
        if votes[g]:
            (best, n), = votes[g].most_common(1)
            if name == "a" or votes[g][g] >= n:  # own name is at least as good: keep it
                best = g
            gmap[g] = best
            weak += n < 0.5 * sizes[g]
        else:
            gmap[g] = g
    renamed = sum(g != v for g, v in gmap.items())
    targets = collections.Counter(gmap.values())
    seen = set()
    for pid, t in texts[name].items():
        g, k = pid.split("_")
        i = index.get(f"{gmap[g]}_{k}")
        if i is None or i in seen:
            continue
        seen.add(i)
        d = P.parse_xmp(t)
        temp[e, i], tint[e, i], scal[e, i], curv[e, i] = d["temp"], d["tint"], d["scalars"], d["curves"]
        asshot[e, i] = d["wb_mode"] == "As Shot"
        ok[e, i] = np.isfinite(d["temp"]) and np.isfinite(d["tint"])
    print(f"expert {name}: groups renamed {renamed}, weak votes {weak}, "
          f"target collisions {sum(v > 1 for v in targets.values())}, labelled {ok[e].sum()}/{N}")
np.savez_compressed(out, ids=np.array(ids), temp=temp, tint=tint, scalars=scal, curves=curv,
                    wb_asshot=asshot, ok=ok, scalar_names=np.array(P.SCALAR_NAMES))
print("as-shot per expert", asshot.sum(1), "any as-shot", asshot.any(0).sum())
for x, y in ((0, 1), (0, 2), (1, 2)):
    both = asshot[x] & asshot[y]
    if both.any():
        d = np.abs(temp[x, both] - temp[y, both])
        print(f"as-shot temp {'abc'[x]} vs {'abc'[y]}: n {both.sum()} identical {(d == 0).mean():.3f}")
