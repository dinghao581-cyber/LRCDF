"""Keep the person's own skin: correct a look's settings from a render of it (called by the Lightroom plug-in, twice).
usage: skin_keep.py --skin BASE --state state.json --job job.tsv --out changes.lua
BASE.skin.npz: the skin samples predict.py stored for the photos with dark skin (lrcdf/skinkeep.py).
job.tsv lines: id <TAB> render of the photo as it is now <TAB> Exposure2012 <TAB> LuminanceAdjustmentOrange <TAB>
SaturationAdjustmentOrange (the settings of that render).
A photo seen for the first time (not in the state file) is rendered with the look's own settings: one_shot. The second
time the render shows the corrected settings: refine. After that nothing more is changed.
The result is a Lua table of the settings to change: return { ["id"] = { Exposure2012 = 0.1 }, ... }; photos with
nothing to change are not in it. No networks are loaded here."""
import argparse, json, os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf import skinkeep
from lrcdf.image_io import imread


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--skin", required=True); ap.add_argument("--state", required=True)
    ap.add_argument("--job", required=True); ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    skin = skinkeep.load(a.skin)
    state = json.load(open(a.state, encoding="utf-8")) if os.path.exists(a.state) else {}
    out = {}
    for line in open(a.job, encoding="utf-8"):
        pid, path, *values = line.rstrip("\n").split("\t")
        if pid not in skin or state.get(pid, {}).get("passes", 0) >= 2:
            continue
        try:
            now = dict(zip(skinkeep.KEYS, map(float, values)))
            im = imread(path)
            pixels = skinkeep.sample(im[..., ::-1], skin[pid]["xy"])
            if pid not in state:
                changes, state[pid] = skinkeep.one_shot(skin[pid]["rgb"].astype(np.float64), pixels, skin[pid]["s"], now, skin[pid]["score"])
                state[pid]["passes"] = 1
            else:
                changes = skinkeep.refine(skin[pid]["rgb"].astype(np.float64), pixels, state[pid], now)
                state[pid]["passes"] = 2
            L, C = skinkeep.mean(pixels)
            print(pid, "pass", state[pid]["passes"], "skin L %.1f C %.1f, goal L %.1f" % (L, C, state[pid]["Lg"]), changes, flush=True)
            if changes:
                out[pid] = changes
        except Exception as ex:     # a photo that cannot be measured keeps the look as it is
            print(pid, "not corrected:", ex, flush=True)
    json.dump(state, open(a.state, "w", encoding="utf-8"))
    tmp = a.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("return {" + ",".join('["%s"]={%s}' % (pid, ",".join(f"{k}={v!r}" for k, v in c.items())) for pid, c in out.items()) + "}\n")
    os.replace(tmp, a.out)


if __name__ == "__main__":
    main()
