"""Contact sheet: one row per photo, one column per tag. usage: sheet.py <dir> <out.jpg> <tags,comma> <ids,comma> [cell width]"""
import sys, os, cv2, numpy as np
d, out, tags, ids = sys.argv[1], sys.argv[2], sys.argv[3].split(","), sys.argv[4].split(",")
w = int(sys.argv[5]) if len(sys.argv) > 5 else 480
rows = []
for i in ids:
    cells = []
    for t in tags:
        im = cv2.imread(f"{d}/{i}_{t}.jpg"); h = int(im.shape[0] * w / im.shape[1])
        im = cv2.resize(im, (w, h), interpolation=cv2.INTER_AREA)
        cv2.putText(im, t, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4); cv2.putText(im, t, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cells.append(im)
    hh = min(c.shape[0] for c in cells); rows.append(np.concatenate([c[:hh] for c in cells], 1))
ww = min(r.shape[1] for r in rows)
cv2.imwrite(out, np.concatenate([r[:, :ww] for r in rows], 0), [cv2.IMWRITE_JPEG_QUALITY, 88])
