"""Look at what the cast-shadow model does (scripts/train_shadow.py).
usage: exp_shadow.py <shadow.pt> <out dir> [--scan 300]
  synth.jpg   held-out faces with painted shadows: with shadow | undone by the model | the face as it was
  real_*.jpg  held-out FFHQ faces as they are, the ones where the model finds most shadow: before | after | factor
  clean.txt   how much it changes faces overall (most real faces have no cast shadow: should be little)"""
import argparse, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import train_shadow
from lrcdf import shadow


def undo(net, x, dev):
    """x: float RGB 0..1, sides divisible by 16 -> (picture without the shadow, log factor)."""
    with torch.inference_mode():
        L = net(torch.from_numpy(x).permute(2, 0, 1)[None].to(dev))[0].permute(1, 2, 0).cpu().numpy()
    L = np.clip(L - 0.03, 0, 1.4)
    return np.clip(np.clip(x, 0, 1) ** 2.2 * np.exp(L), 0, 1) ** (1 / 2.2), L


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("ckpt"); ap.add_argument("out"); ap.add_argument("--scan", type=int, default=300)
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    dev = "mps"
    ck = torch.load(a.ckpt, map_location="cpu", weights_only=False)
    net = train_shadow.ShadowNet(ck.get("width", 32)); net.load_state_dict(ck["model"]); net = net.to(dev).eval()
    W = train_shadow.WORK
    probe = train_shadow.Faces([], W, False, [1, 2, 3]); probe.open()
    held = sorted(probe.orig.at)[-300:]
    read = lambda k: np.ascontiguousarray(cv2.resize(probe.orig.read(k), (W, W), interpolation=cv2.INTER_AREA)[..., ::-1]).astype(np.float32) / 255
    save = lambda name, cells: cv2.imwrite(f"{a.out}/{name}", (np.concatenate(cells, 1)[..., ::-1] * 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, 90])
    rng = np.random.default_rng(11); rows = []; left = []
    for k in held[:8]:
        face = read(k); x, L = shadow.cast(face.copy(), W * train_shadow.FACE, rng)
        y, _ = undo(net, x, dev)
        rows.append(np.concatenate([x, y, face], 1))
        on = L.max(2) > 0.05
        if on.any():
            left.append(float(np.abs(y - face)[on].mean() / max(np.abs(x - face)[on].mean(), 1e-6)))
    cv2.imwrite(f"{a.out}/synth.jpg", (np.concatenate(rows[:4], 0)[..., ::-1] * 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, 88])
    found = []
    for k in held[:a.scan]:
        x = read(k); y, L = undo(net, x, dev)
        found.append((float((L.max(2) > 0.1).mean()), float(np.abs(y - x).mean() * 255), k))
    found.sort(reverse=True)
    for n, (area, change, k) in enumerate(found[:8]):
        x = read(k); y, L = undo(net, x, dev)
        save(f"real_{n}.jpg", [x, y, np.repeat(np.clip(L.max(2) / 0.8, 0, 1)[..., None], 3, 2)])
    areas = np.array([f[0] for f in found]); changes = np.array([f[1] for f in found])
    text = (f"step {ck.get('step')}  painted shadows: {100 * (1 - np.mean(left)):.0f}% of the darkening undone (8 faces)\n"
            f"real faces ({len(found)}): share of the face found in shadow - median {100 * np.median(areas):.2f}%, 90th percentile {100 * np.percentile(areas, 90):.1f}%, "
            f"faces with more than 2% in shadow: {100 * (areas > 0.02).mean():.0f}%; mean change {np.mean(changes):.2f} levels, median {np.median(changes):.2f}\n"
            f"most shadow found on: {[k for _, _, k in found[:8]]}")
    print(text); open(f"{a.out}/clean.txt", "w").write(text + "\n")


if __name__ == "__main__":
    main()
