"""usage: beauty.py <image> <faces.run.json from retouch_photo.py> <out.png> [--smooth .6 --undereye .5 --eyes .4 --teeth .4]"""
import argparse, json, os, sys
import cv2, numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import beauty

ap = argparse.ArgumentParser()
ap.add_argument("image"); ap.add_argument("faces"); ap.add_argument("out")
for k, v in beauty.DEFAULTS.items():
    ap.add_argument("--" + k, type=float, default=v)
a = ap.parse_args()
img = cv2.imread(a.image, cv2.IMREAD_UNCHANGED)[..., :3][..., ::-1]
scale = 65535.0 if img.dtype == np.uint16 else 255.0
rgb = img.astype(np.float32) / scale
boxes = [f["detection"]["bbox"] for f in json.load(open(a.faces))["faces"]]
out = beauty.beautify(rgb, boxes, **{k: getattr(a, k) for k in beauty.DEFAULTS})
cv2.imwrite(a.out, np.rint(out[..., ::-1] * scale).astype(img.dtype))
print("faces", len(boxes), "changed", float((np.abs(out - rgb).max(2) > 1 / 255).mean()))
