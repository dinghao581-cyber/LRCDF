"""The Mac's extra looks d (Soft & Fresh), e (Korean Style) and f (Hong Kong Film) for the iPad, as colour cubes.

On the Mac they are look a plus a fixed set of Lightroom slider changes (styles.json), rendered by Lightroom. Those
changes are global colour operations (temperature, tone, HSL, split toning), so a 3D colour table from a's rendering to
d/e/f's reproduces them. It is fitted on the Mac app's own previews of the same photos (a.jpg -> d.jpg ...), by least
squares on trilinear weights with a smoothness term, which fills the colours the photos do not contain.

usage: fit_style_lut.py <out folder> [--hold <preview folder name>]   -> <out>/<look>.cube.bin (float32 N*N*N*4, r fastest)
"""
import sys, os, glob, argparse, numpy as np, cv2
from scipy.sparse import coo_matrix, vstack, identity, diags
from scipy.sparse.linalg import lsqr

N = 17
P = os.path.expanduser("~/Library/Application Support/LRCDF/previews")
ap = argparse.ArgumentParser(); ap.add_argument("out"); ap.add_argument("--hold", default=""); ap.add_argument("--smooth", type=float, default=3.0)
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
rng = np.random.default_rng(0)


def read(f):
    return cv2.imread(f)[..., ::-1].astype(np.float32) / 255


def weights(x):
    """Trilinear weights of colours x (n,3) in 0..1 over the N^3 grid, as a sparse matrix (n, N^3)."""
    g = np.clip(x, 0, 1) * (N - 1); i0 = np.minimum(g.astype(int), N - 2); f = g - i0
    rows, cols, vals = [], [], []
    n = len(x)
    for dr in (0, 1):
        for dg in (0, 1):
            for db in (0, 1):
                w = (f[:, 0] if dr else 1 - f[:, 0]) * (f[:, 1] if dg else 1 - f[:, 1]) * (f[:, 2] if db else 1 - f[:, 2])
                idx = (i0[:, 0] + dr) + N * (i0[:, 1] + dg) + N * N * (i0[:, 2] + db)
                rows.append(np.arange(n)); cols.append(idx); vals.append(w)
    return coo_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(n, N ** 3)).tocsr()


def laplacian():
    """Second differences along r, g and b on the grid."""
    mats = []
    idx = np.arange(N ** 3).reshape(N, N, N)       # [b][g][r]
    for axis in range(3):
        a0 = np.moveaxis(idx, axis, 0)
        lo, mid, hi = a0[:-2].ravel(), a0[1:-1].ravel(), a0[2:].ravel()
        m = len(mid)
        r = np.repeat(np.arange(m), 3)
        c = np.stack([lo, mid, hi], 1).ravel()
        v = np.tile([1.0, -2.0, 1.0], m)
        mats.append(coo_matrix((v, (r, c)), shape=(m, N ** 3)))
    return vstack(mats).tocsr()


folders = sorted(d for d in glob.glob(f"{P}/*_2600") if all(os.path.exists(f"{d}/{s}.jpg") for s in "adef"))
print(len(folders), "photos:", [os.path.basename(d) for d in folders])
L = laplacian()
for look in "def":
    xs, ys = [], []
    for d in folders:
        if a.hold and os.path.basename(d) == a.hold:
            continue
        x, y = read(f"{d}/a.jpg"), read(f"{d}/{look}.jpg")
        if look == "f":     # film grain: fit the colour under it
            y = cv2.GaussianBlur(y, (0, 0), 1.5); x = cv2.GaussianBlur(x, (0, 0), 1.5)
        k = rng.choice(x.shape[0] * x.shape[1], 120000, replace=False)
        xs.append(x.reshape(-1, 3)[k]); ys.append(y.reshape(-1, 3)[k])
    x, y = np.concatenate(xs), np.concatenate(ys)
    W = weights(x)
    # smoothness, plus a weak pull towards the identity where no colour was seen
    grid = np.stack(np.meshgrid(np.linspace(0, 1, N), np.linspace(0, 1, N), np.linspace(0, 1, N), indexing="ij"), -1)  # [b][g][r] -> (b, g, r)
    ident = grid[..., ::-1].reshape(-1, 3)                                     # r, g, b at each node
    seen = np.asarray(W.sum(0)).ravel()
    A = vstack([W, a.smooth * L, diags(0.02 * (seen < 1e-3).astype(float) + 0.002)]).tocsr()
    lut = np.zeros((N ** 3, 3), np.float32)
    for c in range(3):
        # solve for the change from the identity (smoothness then keeps unseen colours close to "same change")
        b = np.concatenate([y[:, c] - W @ ident[:, c], np.zeros(L.shape[0]), np.zeros(N ** 3)])
        lut[:, c] = ident[:, c] + lsqr(A, b, atol=1e-7, btol=1e-7, iter_lim=4000)[0]
    lut = np.clip(lut, 0, 1)
    rgba = np.concatenate([lut, np.ones((N ** 3, 1), np.float32)], 1)
    rgba.astype(np.float32).tofile(f"{a.out}/{look}.cube.bin")
    fit = W @ lut
    print(look, "fit error (8-bit levels): mean %.2f, 99%% %.1f" % (np.abs(fit - y).mean() * 255, np.percentile(np.abs(fit - y).max(1), 99) * 255))
    if a.hold:
        d = f"{P}/{a.hold}"
        x, y = read(f"{d}/a.jpg"), read(f"{d}/{look}.jpg")
        if look == "f":
            y = cv2.GaussianBlur(y, (0, 0), 1.5); x = cv2.GaussianBlur(x, (0, 0), 1.5)
        p = (weights(x.reshape(-1, 3)) @ lut).reshape(x.shape)
        print("   held-out", a.hold, "error mean %.2f, 99%% %.1f (a vs %s itself: %.2f)" % (np.abs(p - y).mean() * 255, np.percentile(np.abs(p - y).max(2), 99) * 255, look, np.abs(x - y).mean() * 255))
