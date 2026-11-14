"""Score retouching models on the held-out faces of a train_dodge.py run, on that run's own measures.
usage: eval_dodge.py <dodge run dir> [--retouch runs/retouch_model.pt] [--n 90]
Prints, per kind of sample (paint on clean skin / paint on a real pair / real pair): the share of the wanted
colour-layer change that is made by the dodge model and, for comparison, by the pixel model (train_retouch.py) used
the way the pipeline uses it (its change minus its median, colour layer only)."""
import argparse, json, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import train_dodge
from train_retouch import RetouchNet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run"); ap.add_argument("--retouch", default="runs/retouch_model.pt"); ap.add_argument("--n", type=int, default=90)
    a = ap.parse_args()
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    setup = json.load(open(f"{a.run}/setup.json"))
    check = train_dodge.Faces(setup["held"][:a.n], 768, False, [int(p) for p in setup["parts"].split(",")]); check.open()
    ck = torch.load(f"{a.run}/dodge.pt", map_location="cpu", weights_only=False)
    dodge = train_dodge.DodgeNet(ck.get("width", 32)); dodge.load_state_dict(ck["model"]); dodge = dodge.to(dev).eval()
    ck = torch.load(a.retouch, map_location="cpu", weights_only=False)
    pixel = RetouchNet(ck.get("width", 40)); pixel.load_state_dict(ck["model"]); pixel = pixel.to(dev).eval()
    got = {}
    with torch.no_grad():
        for i in range(len(check)):
            x, add, heal, _ = check[i]
            face = x.shape[-1] * train_dodge.FACE
            xd = x[None].to(dev)
            pa, _ = train_dodge.apply(dodge, xd)
            pa = pa[0].permute(1, 2, 0).cpu().numpy()
            d = pixel(xd)[0].permute(1, 2, 0).cpu().numpy()
            d = cv2.GaussianBlur(d, (0, 0), face * train_dodge.SPLIT)
            d -= cv2.GaussianBlur(d, (0, 0), face * train_dodge.REACH)      # judged on local corrections only, like the target
            want = add.permute(1, 2, 0).numpy()
            on = (np.abs(want).max(2, keepdims=True) > 2 / 255).astype(np.float32)
            g = got.setdefault(("paint", "both", "real")[i % 3], [0.0] * 6)
            g[0] += float((np.abs(pa - want) * on).sum()); g[1] += float((np.abs(d - want) * on).sum()); g[2] += float((np.abs(want) * on).sum())
            g[3] += float((np.abs(pa) * (1 - on)).mean() * 255); g[4] += float((np.abs(d) * (1 - on)).mean() * 255); g[5] += 1
    for name, g in got.items():
        print(f"{name}: made where wanted: dodge {1 - g[0] / g[2]:.3f}  pixel model {1 - g[1] / g[2]:.3f}   drift elsewhere: dodge {g[3] / g[5]:.3f}  pixel {g[4] / g[5]:.3f}")


if __name__ == "__main__":
    main()
