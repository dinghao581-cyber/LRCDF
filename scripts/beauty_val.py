"""Check beautification on a folder of photos: before/after close-up of every face, to be looked at.
usage: beauty_val.py <image dir> <out dir> [--max-faces 4] [--long 6000] [beautify options, e.g. --smooth .6]
Images of any common format; long edge is reduced to --long first. Writes <out>/<name>_f<k>.jpg (before | after) per face and <name>_b<k>.jpg for the body skin that changed most."""
import argparse, glob, os, sys
import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import beautify
from lrcdf import beauty


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("out"); ap.add_argument("--max-faces", type=int, default=4)
    ap.add_argument("--long", type=int, default=6000); ap.add_argument("--blemish", type=float, default=1.0)
    ap.add_argument("--only", default="", help="comma list of file stems"); ap.add_argument("--model", default="new"); ap.add_argument("--hires", type=int, default=0); ap.add_argument("--guard", type=int, default=1)
    ap.add_argument("--fixed", default="", help="x,y,size: one extra close-up at this place, written as <name>_x.jpg")
    for k, v in beauty.DEFAULTS.items():
        ap.add_argument("--" + k, type=float, default=v)
    a = ap.parse_args(); opt = vars(a); os.makedirs(a.out, exist_ok=True)
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    models = beautify.load_models(device)
    only = set(filter(None, a.only.split(",")))
    for path in sorted(glob.glob(os.path.join(a.src, "*"))):
        stem = os.path.splitext(os.path.basename(path))[0]
        if only and stem not in only:
            continue
        bgr = cv2.imread(path, cv2.IMREAD_COLOR)
        if bgr is None:
            continue
        s = a.long / max(bgr.shape[:2])
        if s < 1:
            bgr = cv2.resize(bgr, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
        src = np.ascontiguousarray(bgr[..., ::-1])
        res, n = beautify.process(src, models, opt, device)
        boxes = [d["bbox"] for d in models[0].predict_jsons(src) if d["bbox"] and d["score"] > 0.6]
        boxes.sort(key=lambda b: -(b[2] - b[0]))
        for g in opt.get("_guard") or []:
            print("   guard", g, flush=True)
        print(stem, src.shape[1], "x", src.shape[0], "faces", n, "widths", [int(b[2] - b[0]) for b in boxes[:8]], flush=True)
        H, W = src.shape[:2]
        if a.fixed:
            fx, fy, fq = [int(t) for t in a.fixed.split(",")]
            cells = [im[fy:fy + fq, fx:fx + fq] for im in (src, res)]
            cv2.imwrite(os.path.join(a.out, f"{stem}_x.jpg"), np.concatenate(cells, 1)[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, 93])
        # where skin outside the faces changed most: two close-ups of body skin
        diff = np.abs(res.astype(np.int16) - src).max(2).astype(np.float32)
        for x0, y0, x1, y1 in boxes:
            m = 0.6 * max(x1 - x0, y1 - y0)
            diff[int(max(0, y0 - m)):int(y1 + m), int(max(0, x0 - m)):int(x1 + m)] = 0
        q = int(min(H, W, 1.2 * (boxes[0][2] - boxes[0][0]))) if boxes else 0
        for k in range(2 if q > 64 else 0):
            heat = cv2.boxFilter(diff, -1, (q, q), normalize=False)
            cy, cx = np.unravel_index(int(heat.argmax()), heat.shape)
            if heat[cy, cx] < q * q * 0.05:
                break
            x0, y0 = int(np.clip(cx - q // 2, 0, W - q)), int(np.clip(cy - q // 2, 0, H - q))
            z = 900 / q
            cells = [cv2.resize(im[y0:y0 + q, x0:x0 + q], None, fx=z, fy=z, interpolation=cv2.INTER_AREA if z < 1 else cv2.INTER_CUBIC) for im in (src, res)]
            cv2.imwrite(os.path.join(a.out, f"{stem}_b{k}.jpg"), np.concatenate(cells, 1)[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, 92])
            diff[y0:y0 + q, x0:x0 + q] = 0
        for k, (x0, y0, x1, y1) in enumerate(boxes[:a.max_faces]):
            w, h = x1 - x0, y1 - y0
            # texture check on the cheeks-and-nose part of the face: energy of the high layer after / before
            cx0, cx1, cy0, cy1 = int(x0 + w * 0.25), int(x1 - w * 0.25), int(y0 + h * 0.4), int(y1 - h * 0.3)
            hi = [beauty.split(im[cy0:cy1, cx0:cx1].astype(np.float32) / 255, w)[1].std() for im in (src, res)]
            print(f"   face {k}: texture kept {100 * hi[1] / max(hi[0], 1e-6):.0f}%", flush=True)
            x0, x1 = int(max(0, x0 - w * 0.35)), int(min(W, x1 + w * 0.35)); y0, y1 = int(max(0, y0 - h * 0.3)), int(min(H, y1 + h * 0.45))
            z = 900 / (y1 - y0)
            cells = [cv2.resize(im[y0:y1, x0:x1], None, fx=z, fy=z, interpolation=cv2.INTER_AREA if z < 1 else cv2.INTER_CUBIC) for im in (src, res)]
            cv2.imwrite(os.path.join(a.out, f"{stem}_f{k}.jpg"), np.concatenate(cells, 1)[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, 92])


if __name__ == "__main__":
    main()
