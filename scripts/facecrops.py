"""Before/after close-ups of every face. usage: facecrops.py <faces.run.json> <out prefix> <img1> <img2> [...]"""
import json, sys, cv2, numpy as np
faces = json.load(open(sys.argv[1]))["faces"]; ims = [cv2.imread(p) for p in sys.argv[3:]]
for k, f in enumerate(faces):
    x0, y0, x1, y1 = [int(v) for v in f["detection"]["bbox"]]; w, h = x1 - x0, y1 - y0
    x0 = max(0, x0 - w // 5); x1 = min(ims[0].shape[1], x1 + w // 5); y0 = max(0, y0 - h // 6); y1 = min(ims[0].shape[0], y1 + h // 8)
    cells = []
    for im in ims:
        c = im[y0:y1, x0:x1]; s = 1000 / c.shape[0]
        cells.append(cv2.resize(c, None, fx=s, fy=s, interpolation=cv2.INTER_AREA if s < 1 else cv2.INTER_CUBIC))
    cv2.imwrite(f"{sys.argv[2]}{k}.jpg", np.concatenate(cells, 1), [cv2.IMWRITE_JPEG_QUALITY, 93])
