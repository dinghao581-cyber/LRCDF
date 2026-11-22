"""Beautified versions of preview pictures, for the desktop app's before/after view.
usage: preview_beauty.py --job job.tsv --original none.jpg --faces faces.json
job.tsv lines ('auto' as an extra last column = automatic level per face): input.jpg <TAB> output.jpg <TAB> blemish <TAB> smooth <TAB> undereye <TAB> eyes <TAB> teeth <TAB> slim <TAB> bigeyes <TAB> chest <TAB> waist <TAB> legs [<TAB> light]
faces.json gets the face boxes of the original as fractions of width/height, largest first (the app zooms in on them).
The same pipeline as the full-size run (beautify.process), on a smaller picture: a preview, not the final pixels.

preview_beauty.py --serve <folder> keeps the models loaded and answers requests put into the folder, because starting
Python and loading them takes longer than the preview itself: a file <name>.req holds the arguments above as one
command line; when the pictures are written, <name>.done appears (with what would have been printed). `alive` is
written every second from the moment Python starts - while the models load and while a picture is being made too -
by a thread of its own: a file older than a few seconds means the process is gone, and the plug-in starts a new one
instead of waiting (Beauty.preview). The server leaves after `preview_idle` idle seconds of the machine's plan (lrcdf/device.py:
ten minutes from 32 GB, five on 16-24 GB, two on 8 GB) or when a file `quit` appears (the full-size run asks for that:
two sets of models do not fit comfortably in 16 GB)."""
import argparse, glob, json, os, shlex, sys, threading, time

_BEATING = threading.Event()


def _heartbeat(folder):
    alive = os.path.join(folder, "alive")
    while not _BEATING.wait(1.0):
        try:
            with open(alive, "w") as f:
                f.write(str(os.getpid()))
        except OSError:
            pass


if "--serve" in sys.argv[1:-1]:         # before the heavy imports: loading takes seconds, and the sign of life must not wait for it
    _folder = sys.argv[sys.argv.index("--serve") + 1]
    os.makedirs(_folder, exist_ok=True)
    threading.Thread(target=_heartbeat, args=(_folder,), daemon=True).start()

import cv2, numpy as np, torch
sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import beautify
from lrcdf import beauty
from lrcdf.device import pick
from lrcdf.image_io import imread, imwrite


_MEMO = {}      # per picture (path, time written): what beautify.retouch can reuse; the last few pictures only


def memo_of(path):
    key = (path, os.path.getmtime(path))
    if key not in _MEMO:
        while len(_MEMO) >= 3:
            _MEMO.pop(next(iter(_MEMO)))
        _MEMO[key] = {}
    return _MEMO[key]


def arguments(line=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--job"); ap.add_argument("--original"); ap.add_argument("--faces")
    ap.add_argument("--people"); ap.add_argument("--choices"); ap.add_argument("--levels"); ap.add_argument("--serve")
    return ap.parse_args(shlex.split(line) if line is not None else None)


def serve(folder, models, device):
    os.makedirs(folder, exist_ok=True)
    alive, last = os.path.join(folder, "alive"), time.time()
    for old in glob.glob(os.path.join(folder, "*.req")) + glob.glob(os.path.join(folder, "*.done")) + glob.glob(os.path.join(folder, "quit")):
        if not old.endswith(".req") or time.time() - os.path.getmtime(old) > 300:      # a fresh request may be the reason we were started
            os.remove(old)
    while time.time() - last < beautify.PLAN.preview_idle and not os.path.exists(os.path.join(folder, "quit")):
        waiting = sorted(glob.glob(os.path.join(folder, "*.req")))
        if not waiting:
            time.sleep(0.05); continue
        req = waiting[0]; lines = []
        try:
            run(arguments(open(req, encoding="utf-8").read().strip()), models, device, lines.append)
        except BaseException as ex:
            lines.append(json.dumps({"error": repr(ex)}))
        os.remove(req)
        open(req[:-4] + ".tmp", "w").write("\n".join(lines)); os.replace(req[:-4] + ".tmp", req[:-4] + ".done")
        beautify.released()          # little memory: the GPU's cache is not kept while the app waits
        last = time.time()
    _BEATING.set(); time.sleep(1.2)      # the heartbeat has stopped before its file is taken away
    for name in ("alive", "quit"):
        if os.path.exists(os.path.join(folder, name)):
            os.remove(os.path.join(folder, name))


def main():
    a = arguments()
    device = pick()
    models = beautify.load_models(device)
    if a.serve:
        with torch.inference_mode():        # the first pass through a network on the GPU is slow: get it over with
            if models[1] is not None and str(device) != "cpu":    # on the CPU it only costs time (10 s on Windows)
                models[1](torch.zeros(1, 3, 512, 512, device=device))
        return serve(a.serve, models, device)
    run(a, models, device, lambda text: print(text, flush=True), reuse=False)


_MOVED = []     # Windows: (device, models) once a CUDA error moved this process to the CPU (beautify.to_cpu)


def run(a, models, device, say, reuse=True):
    from lrcdf import people
    if _MOVED:
        device, models = _MOVED
    who = people.Choices(a.people, a.choices, a.levels)
    if a.original and a.faces and not os.path.exists(a.faces):
        bgr = imread(a.original)
        h, w = bgr.shape[:2]
        found = [d["bbox"] for d in models[0].predict_jsons(np.ascontiguousarray(bgr[..., ::-1])) if d["bbox"] and d["score"] > 0.6]
        found.sort(key=lambda b: -(b[2] - b[0]))
        json.dump([[b[0] / w, b[1] / h, b[2] / w, b[3] / h] for b in found], open(a.faces, "w"))
    for line in open(a.job, encoding="utf-8"):
        if not line.strip():
            continue
        inp, outp, *values = line.rstrip("\n").split("\t")
        auto = bool(values) and values[-1] == "auto"       # 13th column: automatic level (the values are the fallback)
        values = values[:-1] if auto else values
        opt = dict(zip(("blemish", "smooth", "undereye", "eyes", "teeth", "slim", "bigeyes", "chest", "waist", "legs", "light"), map(float, values)))
        for k, v in beauty.DEFAULTS.items():
            opt.setdefault(k, v)
        opt["who"] = who
        opt["auto"] = 1 if auto else 0
        try:
            if reuse:
                opt["_memo"] = memo_of(inp)
            bgr = imread(inp)
            try:
                res, n = beautify.process(np.ascontiguousarray(bgr[..., ::-1]), models, opt, device)
            except Exception as ex:
                if not beautify.cuda_error(ex):    # Windows only: a CUDA error has the photo done again on the CPU
                    raise
                _MOVED[:] = beautify.to_cpu(ex)
                device, models = _MOVED
                _MEMO.clear()                      # what was kept may lie on the card
                if reuse:
                    opt["_memo"] = memo_of(inp)
                res, n = beautify.process(np.ascontiguousarray(bgr[..., ::-1]), models, opt, device)
            imwrite(outp + ".tmp.jpg", res[..., ::-1], [cv2.IMWRITE_JPEG_QUALITY, 93])
            os.replace(outp + ".tmp.jpg", outp)
            say(json.dumps({"output": outp, "faces": n, "levels": opt.get("_levels") if auto else None}))
        except Exception as ex:
            say(json.dumps({"input": inp, "error": repr(ex)}))


if __name__ == "__main__":
    main()
