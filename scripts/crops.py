"""Face-area crops side by side. usage: crops.py <dir> <out.jpg> <tags,comma> <id:x0,y0,x1,y1 as fractions> ..."""
import sys, cv2, numpy as np
d, out, tags = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
rows = []
for spec in sys.argv[4:]:
    i, box = spec.split(":"); x0, y0, x1, y1 = map(float, box.split(","))
    cells = []
    for t in tags:
        im = cv2.imread(f"{d}/{i}_{t}.jpg"); h, w = im.shape[:2]
        c = im[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)]
        c = cv2.resize(c, (480, int(c.shape[0] * 480 / c.shape[1])), interpolation=cv2.INTER_CUBIC)
        cv2.putText(c, t, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4); cv2.putText(c, t, (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cells.append(c)
    hh = min(c.shape[0] for c in cells); rows.append(np.concatenate([c[:hh] for c in cells], 1))
cv2.imwrite(out, np.concatenate(rows, 0), [cv2.IMWRITE_JPEG_QUALITY, 92])
