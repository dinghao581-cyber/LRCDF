"""Where does our retouching stand next to professionals? On FFHQ faces: the two measures of train_critic.measure for
the retoucher's version (FFHQR) and for our pipeline at the three levels.
usage: exp_amount.py <out.npy> [--n 150] [--part 3]"""
import argparse, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import beautify, train_critic
from lrcdf import beauty

LEVELS = dict(light=(1.0, .35, .30, .25, .30), natural=(1.0, .60, .50, .40, .40), refined=(1.2, .85, .70, .55, .55))


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("out"); ap.add_argument("--n", type=int, default=150); ap.add_argument("--part", type=int, default=3)
    a = ap.parse_args()
    pairs = train_critic.Pairs([], [a.part]); pairs.open()
    keys = sorted(k for k in pairs.done.at if k in pairs.orig.at)[-a.n:]
    models = beautify.load_models("mps")
    side = train_critic.SIDE
    small = lambda im: cv2.resize(im, (side, side), interpolation=cv2.INTER_AREA).astype(np.float32) / 255
    rows = []
    for k in keys:
        src = np.ascontiguousarray(pairs.orig.read(k)[..., ::-1]); pro = np.ascontiguousarray(pairs.done.read(k)[..., ::-1])
        x = small(src); w = train_critic.skin_of(x)
        if w.mean() < 0.03:
            continue
        row = list(train_critic.measure(x, small(pro), w))
        for name, v in LEVELS.items():
            opt = dict(zip(("blemish", "smooth", "undereye", "eyes", "teeth"), v))
            for kk, d in beauty.DEFAULTS.items():
                opt.setdefault(kk, d)
            res, n = beautify.process(src, models, opt, "mps")
            row += list(train_critic.measure(x, small(res), w))
        rows.append(row); print(k, np.round(row, 3), flush=True)
    rows = np.array(rows); np.save(a.out, rows)
    names = ["professional"] + list(LEVELS)
    for j, what in enumerate(("colour (levels)", "texture removed")):
        print("\n" + what + ": percentiles 10 / 50 / 90")
        for i, name in enumerate(names):
            print(f"  {name:13s}", np.round(np.percentile(rows[:, 2 * i + j], [10, 50, 90]), 3))
    for i, name in enumerate(names[1:], 1):
        print(f"{name}: more colour change than the professional on {100 * (rows[:, 2 * i] > rows[:, 0]).mean():.0f}% of faces, "
              f"more texture removed on {100 * (rows[:, 2 * i + 1] > rows[:, 1]).mean():.0f}%")


if __name__ == "__main__":
    main()
