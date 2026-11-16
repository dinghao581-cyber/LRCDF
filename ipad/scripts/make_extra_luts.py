"""iPad-only looks, made on top of look a (明亮通透) as 17^3 colour cubes (same format as fit_style_lut.py):
j 日系清新, v 胶片复古, m 电影感 (user 2026-11-15). Designed by recipe, then judged on the Mac app's renders of look a.

usage: make_extra_luts.py <out folder> [--sheet <jpg>]
"""
import os, sys, glob, argparse, numpy as np, cv2

N = 17
ap = argparse.ArgumentParser(); ap.add_argument("out"); ap.add_argument("--sheet", default="")
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)


def lum(c):
    return c[..., 0] * 0.299 + c[..., 1] * 0.587 + c[..., 2] * 0.114


def sat(c, k, keep_skin=0.0):
    """Saturation times k; skin tones (orange hues) move only (1 - keep_skin) of the way."""
    y = lum(c)[..., None]
    out = y + (c - y) * k
    if keep_skin:
        r, g, b = c[..., 0], c[..., 1], c[..., 2]
        skin = np.clip((r - g) * 6, 0, 1) * np.clip((g - b) * 6, 0, 1) * np.clip(1 - np.abs(r - g - (g - b)) * 3, 0, 1)
        out = out + (c - out) * (keep_skin * skin)[..., None]
    return out


def smooth(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


def japanese(c):        # 日系清新: airy, low contrast, lifted shadows, a cool cyan-green cast, gentle colour, skin kept fair
    y = lum(c)[..., None]
    c = 0.07 + 0.90 * np.power(np.clip(c, 0, 1), 0.88)                    # lifted blacks, brighter mids, soft top
    c = c + (0.5 - y) * 0.10                                               # less contrast
    sh = (1 - smooth(lum(c) / 0.6))[..., None]
    c = c + sh * np.array([-0.020, 0.012, 0.020])                          # cyan in the shadows
    c = c + np.array([-0.006, 0.004, 0.012])                               # a cool cast overall
    return sat(c, 0.80, keep_skin=0.4)


def vintage(c):         # 胶片复古: warm, faded, gently compressed highlights, greenish shadows (grain added in the app)
    c = np.clip(c, 0, 1)
    c = 0.075 + 0.86 * (c - 0.5 * c * c * 0.25)                            # faded black, rolled-off white
    y = lum(c)[..., None]
    sh = (1 - smooth(y / 0.5))
    c = c + sh * np.array([-0.010, 0.012, -0.012])                         # green-olive shadows
    hi = smooth((y - 0.45) / 0.55)
    c = c + hi * np.array([0.030, 0.012, -0.035])                          # warm yellow highlights
    c = c + np.array([0.010, 0.002, -0.020])
    return sat(c, 0.82)


def cinema(c):          # 电影感: teal shadows, warm skin and highlights, a firmer S-curve
    c = np.clip(c, 0, 1)
    c = c + (smooth(c) - c) * 0.35                                         # S-curve
    y = lum(c)[..., None]
    sh = 1 - smooth(y / 0.55)
    c = c + sh * np.array([-0.045, 0.012, 0.040])                          # teal shadows
    hi = smooth((y - 0.35) / 0.65)
    c = c + hi * np.array([0.035, 0.010, -0.035])                          # orange highlights / skin
    return sat(c, 0.95, keep_skin=0.2)


grid = np.stack(np.meshgrid(np.linspace(0, 1, N), np.linspace(0, 1, N), np.linspace(0, 1, N), indexing="ij"), -1)[..., ::-1]
grid = grid.reshape(-1, 3)      # r fastest
looks = {"j": japanese, "v": vintage, "m": cinema}
for name, fn in looks.items():
    out = np.clip(fn(grid.copy()), 0, 1).astype(np.float32)
    np.concatenate([out, np.ones((N ** 3, 1), np.float32)], 1).tofile(f"{a.out}/{name}.cube.bin")
    print("wrote", name)

if a.sheet:
    from PIL import Image, ImageDraw, ImageFont
    P = os.path.expanduser("~/Library/Application Support/LRCDF/previews")
    F = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 26); T = 300
    folders = sorted(d for d in glob.glob(f"{P}/*_2600") if os.path.exists(f"{d}/a.jpg"))[:4]
    rows = []
    for d in folders:
        x = cv2.imread(f"{d}/a.jpg")[..., ::-1].astype(np.float32) / 255
        tiles = [x] + [np.clip(fn(x.copy()), 0, 1) for fn in looks.values()]
        rows.append(np.hstack([cv2.resize((t * 255).astype(np.uint8), (T, T), interpolation=cv2.INTER_AREA) for t in tiles]))
    img = Image.new("RGB", (T * 4, len(rows) * T + 50), (24, 24, 24)); dr = ImageDraw.Draw(img)
    for i, t in enumerate(["明亮通透", "日系清新", "胶片复古", "电影感"]): dr.text((i * T + 10, 10), t, font=F, fill=(255, 214, 0))
    for k, r in enumerate(rows): img.paste(Image.fromarray(r), (0, 50 + k * T))
    img.save(a.sheet, quality=88); print("sheet", a.sheet)
