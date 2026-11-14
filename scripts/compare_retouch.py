"""Blemish models side by side on a folder of portraits: original | RetouchFormer (512 px crops, in use) | the trained
RetouchNet with the face scaled to its training size | RetouchNet at the photo's own resolution.
usage: compare_retouch.py <image dir> <out dir> [--model runs/retouch/retouch.pt] [--only a,b] [--long 6000]
Writes <name>_f<k>.jpg (whole face) and <name>_z<k>.jpg (cheek at full resolution) per face; prints how much each changes."""
import argparse, glob, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import beautify
from train_retouch import RetouchNet

NATIVE = 1792   # largest crop the model is run on at once (memory); bigger faces are reduced to this
FACE = 520      # width of a face in the 1024 px training pictures, roughly


def run(net, rgb, box, device, native):
    """rgb: float32 0..1. The model's change around one face, feathered to nothing at the border of the crop."""
    H, W = rgb.shape[:2]
    x0, y0, x1, y1 = box; w = x1 - x0; m = 0.45 * max(w, y1 - y0)
    a, b, c, d = int(max(0, x0 - m)), int(max(0, y0 - m)), int(min(W, x1 + m)), int(min(H, y1 + m))
    crop = rgb[b:d, a:c]
    s = min(1.0, NATIVE / max(crop.shape[:2])) if native else min(1.0, FACE / w)
    small = cv2.resize(crop, None, fx=s, fy=s, interpolation=cv2.INTER_AREA) if s < 1 else crop
    h8, w8 = small.shape[0] // 8 * 8, small.shape[1] // 8 * 8
    x = torch.from_numpy(np.ascontiguousarray(small[:h8, :w8])).permute(2, 0, 1)[None].to(device)
    with torch.inference_mode():
        r = net(x)[0].permute(1, 2, 0).cpu().numpy()
    full = np.zeros_like(small); full[:h8, :w8] = r
    if s < 1:
        full = cv2.resize(full, (crop.shape[1], crop.shape[0]), interpolation=cv2.INTER_CUBIC)
    mask = np.zeros(crop.shape[:2], np.float32)
    cv2.ellipse(mask, (int((x0 + x1) / 2 - a), int((y0 + y1) / 2 - b)), (int(0.75 * w), int(0.8 * (y1 - y0))), 0, 0, 360, 1.0, -1)
    mask = cv2.GaussianBlur(mask, (0, 0), 0.08 * w)
    out = rgb.copy(); out[b:d, a:c] += full * mask[..., None]
    return np.clip(out, 0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("out"); ap.add_argument("--model", default="runs/retouch/retouch.pt")
    ap.add_argument("--only", default=""); ap.add_argument("--long", type=int, default=6000); ap.add_argument("--max-faces", type=int, default=1)
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    models = beautify.load_models(device)
    ck = torch.load(a.model, map_location="cpu", weights_only=False)
    net = RetouchNet(ck.get("width", 40)); net.load_state_dict(ck["model"]); net = net.to(device).eval()
    print("model step", ck.get("step"), "closer_edited", ck.get("closer_edited"), flush=True)
    only = set(filter(None, a.only.split(",")))
    plain = dict(blemish=1.0, hires=0, who=None, **{k: 0.0 for k in beautify.beauty.DEFAULTS})
    for path in sorted(glob.glob(os.path.join(a.src, "*"))):
        stem = os.path.splitext(os.path.basename(path))[0]
        bgr = cv2.imread(path)
        if bgr is None or (only and stem not in only):
            continue
        s = a.long / max(bgr.shape[:2])
        if s < 1:
            bgr = cv2.resize(bgr, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        src8 = np.ascontiguousarray(bgr[..., ::-1]); src = src8.astype(np.float32) / 255
        faces = [d for d in models[0].predict_jsons(src8) if d["bbox"] and d["score"] > 0.6]
        faces.sort(key=lambda d: d["bbox"][0] - d["bbox"][2])
        if not faces:
            continue
        # RetouchFormer alone: the blemish pass of the pipeline, everything else switched off
        detector, former, regions = models
        edits = []
        with torch.inference_mode():
            for d in faces:
                tf = beautify.legacy.face_transform(d["landmarks"])
                crop = cv2.warpAffine(src8, tf, (512, 512), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
                x = torch.from_numpy(crop.copy()).permute(2, 0, 1).float()[None].to(device) / 127.5 - 1
                pred = ((former(x)[0][0].cpu().permute(1, 2, 0).numpy() + 1) * 127.5).clip(0, 255)
                edits.append((pred - crop.astype(np.float32), beautify.legacy.feather(), tf))
        old, _ = beautify.legacy.blend_float(src * 255.0, edits, beautify.legacy.skin_weight(src8))
        old = np.clip(old / 255.0, 0, 1)
        fit, own = src, src
        for d in faces:
            fit = run(net, fit, d["bbox"], device, False); own = run(net, own, d["bbox"], device, True)
        H, W = src.shape[:2]
        for k, d in enumerate(faces[:a.max_faces]):
            x0, y0, x1, y1 = [int(v) for v in d["bbox"]]; w, h = x1 - x0, y1 - y0
            inner = (slice(y0 + h // 4, y1 - h // 6), slice(x0 + w // 6, x1 - w // 6))
            print(stem, f"face {k} width {w}:", "  ".join(f"{n} {float(np.abs(im[inner] - src[inner]).mean() * 255):.2f}" for n, im in (("former", old), ("fit", fit), ("native", own))), flush=True)
            a0, b0, a1, b1 = max(0, x0 - w // 4), max(0, y0 - h // 4), min(W, x1 + w // 4), min(H, y1 + h // 4)
            z = 760 / (b1 - b0)
            cells = [cv2.resize(im[b0:b1, a0:a1], None, fx=z, fy=z, interpolation=cv2.INTER_AREA if z < 1 else cv2.INTER_CUBIC) for im in (src, old, fit, own)]
            cv2.imwrite(os.path.join(a.out, f"{stem}_f{k}.jpg"), (np.concatenate(cells, 1)[..., ::-1] * 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, 92])
            q = min(480, w // 2)                      # a cheek, pixel for pixel
            cx, cy = x0 + int(w * 0.28), y0 + int(h * 0.62)
            a0, b0 = int(np.clip(cx - q // 2, 0, W - q)), int(np.clip(cy - q // 2, 0, H - q))
            cells = [im[b0:b0 + q, a0:a0 + q] for im in (src, old, fit, own)]
            cv2.imwrite(os.path.join(a.out, f"{stem}_z{k}.jpg"), (np.concatenate(cells, 1)[..., ::-1] * 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, 94])


if __name__ == "__main__":
    main()
