"""Predict Lightroom develop settings for photos (called by the Lightroom plugin).
usage: predict.py --ckpt tone.pt --job job.tsv --out result.lua --style a --strength 1.0
job.tsv lines: id <TAB> image path <TAB> as-shot temp <TAB> as-shot tint <TAB> 1|0 (WB is as-shot) [<TAB> capture time, seconds]
When the as-shot values are missing (0 or negative) they are read from the develop settings embedded in the preview.
--group time: photos shot within --gap minutes of each other form a shoot; --group all: one shoot; none: off.
Inside a shoot the style sliders are made identical and white balance is pulled half-way to a common value;
exposure stays per photo (measured on PPR10K: this is where per-photo prediction is better than the shoot average).
--reference ID --refsettings FILE: reference-photo mode. One photo of the job already has an approved edit (its develop
settings in FILE, lines "name <TAB> value", curves as comma lists). Every other photo gets its style sliders and its final
temperature/tint; exposure is the model's own estimate shifted by 0.75 of the model's error on the reference. Measured on
PPR10K with a random reference per shoot (val): sliders 2.49 -> 0.37, temperature 9.5% -> 3.4%, exposure 0.31 -> 0.24 EV.
The reference itself is not in the result.
--mystyles FILE adds the user's own styles (made with --learn KEY --name TITLE from the edited --reference photo, plus
--examples ID,ID,... for more edited photos of the job: the look is their average; --forget KEY deletes one).
--style all: every style at once; the result is then { style = { id = settings } } (used for the style previews).
The result is a Lua table: return { ["id"] = { Temperature = 5200, ... }, ... }"""
import argparse, glob, json, os, shlex, sys, threading, time
import math


def load_runtime():
    # --stop needs only the standard library; a server starts its heartbeat before these imports.
    global np, torch, P, pick, ToneNet, load_image, wb_feature
    import numpy as np
    import torch
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
    from lrcdf import params as P
    from lrcdf.device import pick
    from lrcdf.model import ToneNet, load_image, wb_feature


def process_started(pid, handle=None):
    """The OS start time, so a PID left after an idle exit cannot later name an unrelated process."""
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetProcessTimes.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 4
        kernel.GetProcessTimes.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        own_handle = handle is None
        if own_handle:
            handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            if ctypes.get_last_error() == 87:
                return None
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            times = [wintypes.FILETIME() for _ in range(4)]
            if not kernel.GetProcessTimes(handle, *(ctypes.byref(t) for t in times)):
                raise ctypes.WinError(ctypes.get_last_error())
            return str((times[0].dwHighDateTime << 32) | times[0].dwLowDateTime)
        finally:
            if own_handle:
                kernel.CloseHandle(handle)
    import subprocess
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True,
                            env=dict(os.environ, LC_ALL="C"), timeout=5)
    if result.returncode not in (0, 1):
        raise RuntimeError("could not read predict process start time: " + result.stderr)
    return result.stdout.strip() or None


def stop_server(folder):
    """Ask the server to quit, then confirm process exit (also when it is stuck importing or predicting)."""
    pidfile = os.path.join(folder, "pid")
    if not os.path.isdir(folder):
        return
    with open(os.path.join(folder, "quit"), "w") as f:
        f.write("quit\n")
    until = time.monotonic() + 3
    while not os.path.exists(pidfile) and os.path.exists(os.path.join(folder, "alive")):
        if time.monotonic() >= until:
            raise RuntimeError("predict is starting but has not written its PID")
        time.sleep(0.1)
    if not os.path.exists(pidfile):
        return
    with open(pidfile) as f:
        pid = int(f.readline().strip())
        started = f.readline().strip()
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)
        kernel.TerminateProcess.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenProcess(0x101001, False, pid)  # SYNCHRONIZE | TERMINATE | QUERY_LIMITED_INFORMATION
        if not handle:
            if ctypes.get_last_error() == 87:            # no process with that PID
                return
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not started:
                raise RuntimeError("predict PID has no process start time; cannot confirm its identity")
            if process_started(pid, handle) != started:
                return                                # the old process exited; this PID has been reused
            state = kernel.WaitForSingleObject(handle, 3000)
            if state == 0:
                return
            if state != 258:
                raise ctypes.WinError(ctypes.get_last_error())
            if not kernel.TerminateProcess(handle, 1):
                raise ctypes.WinError(ctypes.get_last_error())
            if kernel.WaitForSingleObject(handle, 5000) != 0:
                raise RuntimeError("predict process did not exit")
        finally:
            kernel.CloseHandle(handle)
    else:
        import signal
        current = process_started(pid)
        if current is None or (started and current != started):
            return
        if not started:
            raise RuntimeError("predict PID has no process start time; cannot confirm its identity")

        def exited():
            try:
                os.kill(pid, 0)
                return False
            except ProcessLookupError:
                return True

        def wait(seconds):
            until = time.monotonic() + seconds
            while not exited():
                if time.monotonic() >= until:
                    return False
                time.sleep(0.1)
            return True

        if wait(3):
            return
        os.kill(pid, signal.SIGTERM)
        if wait(2):
            return
        os.kill(pid, signal.SIGKILL)
        if not wait(3):
            raise RuntimeError("predict process did not exit")


def heartbeat(folder, stopped):
    while not stopped.wait(1):
        try:
            with open(os.path.join(folder, "alive"), "w") as f:
                f.write(str(os.getpid()))
        except OSError as ex:
            print("predict heartbeat:", ex, flush=True)
            return


def residency():
    # Called AFTER the first picture: plan() may adjust CPU threads on tier 8, which exits here.
    from lrcdf.device import plan
    p = plan()
    low = p.tier == 8
    if pick() == "cuda":
        vram = float(os.environ.get("LRCDF_VRAM") or torch.cuda.get_device_properties(0).total_memory / 2 ** 30)
        low = low or vram < 10
    return ("oneshot" if low else "resident"), p.preview_idle


_tasks = {}


def task(argv):
    """--task <cull|skin_keep> --log FILE --append 0|1 <the script's own arguments>: run that script's main() here,
    its output into FILE as the plug-in's shell redirection would have put it. The script module (and the models
    cull.py keeps) stay loaded for the next request."""
    import contextlib, importlib.util
    name, log, append, rest = argv[1], argv[3], argv[5] == "1", argv[6:]
    if name not in ("cull", "skin_keep"):
        raise ValueError("unknown task " + name)
    if name not in _tasks:
        spec = importlib.util.spec_from_file_location("lrcdf_task_" + name, os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _tasks[name] = module
    with open(log, "a" if append else "w", encoding="utf-8") as out, contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        _tasks[name].main(rest)


def serve(folder):
    """One request at a time; each --out is private until the plug-in accepts its successful .done."""
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "pid"), "w") as f:
        f.write(str(os.getpid()) + "\n" + process_started(os.getpid()) + "\n")
    with open(os.path.join(folder, "alive"), "w") as f:
        f.write(str(os.getpid()))
    stopped = threading.Event()
    beating = threading.Thread(target=heartbeat, args=(folder, stopped), daemon=True)
    beating.start()
    try:
        if os.path.exists(os.path.join(folder, "quit")):
            return
        load_runtime()
        loaded, checkpoint = None, None
        mode, idle, last = None, 600, time.monotonic()
        while time.monotonic() - last < idle and not os.path.exists(os.path.join(folder, "quit")):
            waiting = sorted(glob.glob(os.path.join(folder, "*.req")))
            if not waiting:
                stopped.wait(0.05)
                continue
            req = waiting[0]
            failed = False
            try:
                with open(req, encoding="utf-8") as f:
                    argv = shlex.split(f.read())
                if argv[:1] == ["--task"]:
                    # other scripts' short jobs (Tone.serviceTask): answered, never ending the service on failure
                    try:
                        task(argv)
                        reply = "ok\n" + (mode or "resident") + "\n"
                    except (Exception, SystemExit) as ex:
                        import traceback
                        traceback.print_exc()
                        reply = "error\n" + str(ex).replace("\n", " ") + "\n"
                    os.remove(req)
                    with open(req[:-4] + ".done.tmp", "w", encoding="utf-8") as f:
                        f.write(reply)
                    os.replace(req[:-4] + ".done.tmp", req[:-4] + ".done")
                    last = time.monotonic()
                    continue
                a = arguments(argv)
                if not a.forget:
                    path = os.path.abspath(a.ckpt)
                    stat = os.stat(path)
                    key = (path, stat.st_mtime_ns, stat.st_size)
                    if key != checkpoint:
                        loaded = None   # release the previous model before loading a changed checkpoint
                        loaded = load_model(a.ckpt)
                        checkpoint = key
                run(a, loaded)
                if mode is None:
                    mode, idle = residency()
                    with open(os.path.join(folder, "mode"), "w") as f:
                        f.write(mode + "\n")
                reply = "ok\n" + mode + "\n"
            except (Exception, SystemExit) as ex:
                import traceback
                traceback.print_exc()
                reply, failed = "error\n" + str(ex) + "\n", True
            os.remove(req)
            with open(req[:-4] + ".done.tmp", "w", encoding="utf-8") as f:
                f.write(reply)
            os.replace(req[:-4] + ".done.tmp", req[:-4] + ".done")
            if failed or mode == "oneshot":
                break
            last = time.monotonic()
    finally:
        stopped.set()
        beating.join()
        alive = os.path.join(folder, "alive")
        if os.path.exists(alive):
            os.remove(alive)


def lua(v):
    if isinstance(v, dict):
        return "{" + ",".join(f'["{k}"]={lua(x)}' for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ") + '"'
    return repr(v)


BRIGHT = -0.22      # exposure added to every built-in look: PPR10K's experts retouch brighter than our users want
                    # (2026-11-14: the default look was "a little too bright"; -0.14 still was, -0.28 began to look flat)


def restyle(v, recipe):
    """Add a derived style's fixed offsets to the model's prediction (slider units; curve in 0..255 levels)."""
    for name, d in recipe.get("delta", {}).items():
        if name == "TemperaturePct":
            v[0] += math.log(1 + d / 100)
        elif name == "Tint":
            v[1] += d / P.TINT_SCALE
        else:
            v[2 + P.SCALAR_NAMES.index(name)] += d
    if "curve" in recipe:
        v[2 + P.N_SCALAR:2 + P.N_SCALAR + len(P.CURVE_X)] += np.array(recipe["curve"]) / 255.0
    if "curves" in recipe:      # all four curves (master, red, green, blue): what a learned style stores
        v[2 + P.N_SCALAR:] += np.array(recipe["curves"]) / 255.0
    return v


def my_styles(path):
    return json.load(open(path, encoding="utf-8")) if path and os.path.exists(path) else {}


def save_my_styles(path, styles):
    """The user's own styles: JSON for this script, and a Lua list of the cards for the plug-in."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(styles, open(path + ".tmp", "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    os.replace(path + ".tmp", path)
    cards = ",".join("{value=%s,title=%s,note=%s}" % (lua(k), lua(v.get("title", k)), lua(v.get("note", "我的风格")))
                     for k, v in styles.items())
    open(os.path.splitext(path)[0] + ".lua", "w", encoding="utf-8").write("return {" + cards + "}\n")


def learn(examples, title):
    """A style from the user's edited photos: what they did beyond the model's style A, averaged over the photos.
    examples: [(style A's vector for the photo, its as-shot (temperature, tint), file with its develop settings)],
    the photo on screen first. Returns a recipe for restyle().
    Measured on PPR10K with experts b and c as the user (scripts/exp_style.py; error on photos of other shoots):
    1 example: sliders 5.5, exposure 0.43 EV, temperature 14.7 %; 6: 4.7 / 0.35 / 11.7; 12: 4.6 / 0.35 / 11.5 - as
    good as the model's own trained style. Weighting the examples by how alike the photos are was no better than the
    plain average (a look is the same on every photo; what differs is already in style A), and the median was better
    for sliders but worse when the examples come from one or two shoots, which is the usual case.
    Colour grading and grain are taken from the first photo. The single differences are kept ("samples")."""
    ds, extra = [], {}
    for k, (base, ref, settings) in enumerate(examples):
        temp, tint, scal, curves, more = read_settings(settings)
        temp = temp or ref[0]; tint = ref[1] if tint is None else tint
        ds.append(P.encode(temp, tint, scal, curves, *ref).astype(np.float64) - base)
        if k == 0:
            extra = more
    d = np.mean(ds, 0)
    note = "我的风格" if len(ds) == 1 else f"我的风格 · 学自 {len(ds)} 张照片"
    delta = {"TemperaturePct": round((math.exp(d[0]) - 1) * 100, 2), "Tint": round(d[1] * P.TINT_SCALE, 1)}
    for name, value in zip(P.SCALAR_NAMES, d[2:2 + P.N_SCALAR]):
        if abs(value) >= (0.02 if name == "Exposure2012" else 0.5):
            delta[name] = round(float(value), 2)
    return {"base": "a", "title": title, "note": note, "delta": delta,
            "curves": [round(float(x) * 255, 1) for x in d[2 + P.N_SCALAR:]], "extra": extra,
            "samples": [[round(float(x), 4) for x in one] for one in ds]}


def shoots(vecs, mode, gap):
    """Split predictions into shoots. Photos without a capture time are left alone in time mode."""
    if mode == "none":
        return []
    if mode == "all":
        return [vecs]
    out, cur = [], []
    for item in sorted((v for v in vecs if v[3] > 0), key=lambda v: v[3]):
        if cur and item[3] - cur[-1][3] > gap * 60:
            out.append(cur); cur = []
        cur.append(item)
    return out + [cur]


def harmonise(shoot, wb_pull=0.5):
    if len(shoot) < 2:
        return
    V = np.stack([v for _, v, _, _ in shoot])
    refs = np.array([[math.log(t), tint / P.TINT_SCALE] for _, _, (t, tint), _ in shoot])
    exposure = 2 + P.SCALAR_NAMES.index("Exposure2012")
    common = V.mean(0)
    wb_abs = (V[:, :2] + refs).mean(0)            # the shoot shares one final temperature/tint target
    for k, (_, v, _, _) in enumerate(shoot):
        keep = v[exposure]
        v[2:] = common[2:]; v[exposure] = keep
        v[:2] = (1 - wb_pull) * v[:2] + wb_pull * (wb_abs - refs[k])


def read_settings(path):
    """Develop settings written by the plug-in -> (temperature or None, tint or None, scalars, curves)."""
    raw = dict(line.rstrip("\n").split("\t", 1) for line in open(path, encoding="utf-8") if "\t" in line)
    scal = np.array([float(raw.get(n, d)) for n, d in P.SCALARS], np.float64)
    curves = np.zeros((len(P.CURVES), len(P.CURVE_X)))
    for k, tag in enumerate(P.CURVES):
        flat = [float(x) for x in raw[tag].split(",")] if raw.get(tag) else [0, 0, 255, 255]
        pts = sorted(dict(zip(flat[0::2], flat[1::2])).items())
        curves[k] = P._spline([p[0] for p in pts], [p[1] for p in pts], P.CURVE_X)
    num = lambda k: float(raw[k]) if raw.get(k) not in (None, "", "nil") else None
    extra = {k: float(raw[k]) for k in P.EXTRA if raw.get(k) not in (None, "", "nil")}
    return num("Temperature"), num("Tint"), scal, curves, extra


def follow_reference(vecs, ref_id, settings, exposure_trust=0.75):
    """Give every photo the reference's look. vecs: [id, vector, (as-shot temp, tint), time].
    Returns (vecs without the reference, the reference's colour-grading and grain settings)."""
    found = [v for v in vecs if v[0] == ref_id]
    if not found:
        raise SystemExit("the reference photo could not be analysed")
    _, model_ref, (t0, tint0), _ = found[0]
    temp, tint, scal, curves, extra = read_settings(settings)
    temp = temp or t0; tint = tint0 if tint is None else tint       # reference left on as-shot white balance
    target = P.encode(temp, tint, scal, curves).astype(np.float64)   # only [2:] is used; white balance is absolute
    exposure = 2 + P.SCALAR_NAMES.index("Exposure2012")
    shift = exposure_trust * (target[exposure] - model_ref[exposure])
    out = []
    for item in vecs:
        if item[0] == ref_id:
            continue
        v, (t, ti) = item[1], item[2]
        own = v[exposure] + shift
        v[2:] = target[2:]; v[exposure] = own
        v[0] = math.log(temp / t); v[1] = (tint - ti) / P.TINT_SCALE
        out.append(item)
    return out, extra


def embedded_wb(path):
    """As-shot temperature and tint from the develop settings Lightroom embeds in an exported preview, or None.
    The SDK itself returns nil or -999999 for photos that were never opened in Develop."""
    import re
    try:
        head = open(path, "rb").read(400000).decode("latin-1")
    except OSError:
        return None
    t = re.search(r'crs:Temperature="(\d+)"', head); ti = re.search(r'crs:Tint="([-+]?\d+)"', head)
    mode = re.search(r'crs:WhiteBalance="([^"]*)"', head)
    if t and ti and mode and mode.group(1) == "As Shot" and float(t.group(1)) > 0:
        return float(t.group(1)), float(ti.group(1))
    return None


def skin_notes(job, out, dev):
    """<out without .lua>.skin.lua / .skin.npz: the photos of the job with dark skin, and where their skin is."""
    base, found = os.path.splitext(out)[0], {}
    try:
        from lrcdf import skinkeep
        from lrcdf.image_io import imread
        for line in open(job, encoding="utf-8"):
            pid, path = line.rstrip("\n").split("\t")[:2]
            try:
                seen = skinkeep.read(np.ascontiguousarray(imread(path)[..., ::-1]), dev)
                if seen:
                    found[pid] = seen
                    print("skin depth %s: %.2f (score %.2f)" % (pid, seen["s"], seen["score"]), flush=True)
            except Exception as ex:
                print("skin depth %s not read: %s" % (pid, ex), flush=True)
        skinkeep.save(base, found)
    except Exception as ex:     # without the reading every photo simply keeps the look as the model gives it
        print("skin depth not read:", ex, flush=True)


def skin_strokes(job, dev):
    """{ id: where the skin is, as brush strokes (lrcdf/skinmask.py) } for the photos of the job that show skin."""
    found = {}
    try:
        from lrcdf import skinmask
        from lrcdf.image_io import imread
        for line in open(job, encoding="utf-8"):
            pid, path = line.rstrip("\n").split("\t")[:2]
            try:
                seen = skinmask.strokes(np.ascontiguousarray(imread(path)[..., ::-1]), dev)
                if seen:
                    found[pid] = seen
            except Exception as ex:
                print("skin of %s not found: %s" % (pid, ex), flush=True)
        print("skin mask for %d of the photos" % len(found), flush=True)
    except Exception as ex:     # without it the look's skin corrections go to the whole picture, as before
        print("skin masks not made:", ex, flush=True)
    return found


def arguments(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True); ap.add_argument("--job", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--style", default="a")
    ap.add_argument("--strength", type=float, default=1.0)
    ap.add_argument("--group", default="none", choices=["none", "time", "all"])
    ap.add_argument("--gap", type=float, default=20.0, help="minutes between shots that starts a new shoot")
    ap.add_argument("--reference", help="id of the photo whose edit the others follow"); ap.add_argument("--refsettings")
    ap.add_argument("--mystyles", help="JSON file with the user's own styles")
    ap.add_argument("--learn", help="store the edit of --reference (settings in --refsettings) as the style with this key")
    ap.add_argument("--examples", help="with --learn: ids of more edited photos (settings in reference_<id>.tsv next to --refsettings)")
    ap.add_argument("--name", default="我的风格"); ap.add_argument("--forget", help="delete the user's style with this key")
    return ap.parse_args(argv)


def load_model(path):
    ck = torch.load(path, map_location="cpu", weights_only=False)
    dev = pick()
    model = ToneNet(len(ck["styles"]), pretrained=False)
    model.load_state_dict(ck["model"]); model.to(dev).eval()
    return {"styles": ck["styles"]}, dev, model  # the CPU checkpoint tensors need not stay beside the model


def run(a, loaded=None):
    if a.forget:
        styles = my_styles(a.mystyles); styles.pop(a.forget, None); save_my_styles(a.mystyles, styles)
        open(a.out, "w").write("return {}\n")
        return
    ck, dev, model = loaded if loaded is not None else load_model(a.ckpt)
    recipes = json.load(open(os.path.join(os.path.dirname(__file__), "..", "styles.json"), encoding="utf-8"))
    builtin = set(ck["styles"]) | set(recipes)      # not the user's own looks (learnt against the model as it is)
    recipes.update(my_styles(a.mystyles))
    names = list(ck["styles"]) + list(recipes) if a.style == "all" else [a.style]
    photos, failed = [], {}
    with torch.no_grad():
        for line in open(a.job, encoding="utf-8"):
            pid, path, temp, tint, asshot, *rest = line.rstrip("\n").split("\t")
            try:
                temp, tint = float(temp), float(tint)
                known = asshot == "1" and temp > 0
                if not known:                       # ask the preview itself (see embedded_wb)
                    found = embedded_wb(path)
                    if found:
                        (temp, tint), known = found, True
                x = torch.from_numpy(load_image(path))[None].to(dev)
                wb = torch.tensor([wb_feature(temp, tint, known)], device=dev)
                feat = model.features(x)
                base = {s: (model.heads(feat, torch.tensor([k], device=dev), wb)[0] * model.t_std + model.t_mean).cpu().numpy().astype(np.float64)
                        for k, s in enumerate(ck["styles"]) if any(recipes.get(n, {}).get("base", n) == s for n in names)}
                ref = (temp, tint) if known else (P.T_DEFAULT, 0.0)
                when = float(rest[0]) if rest and rest[0] else 0.0
                photos.append((pid, base, ref, when))
            except Exception as ex:  # one bad file must not stop a batch
                failed[pid] = {"error": str(ex)}
    if a.learn:
        found = [p for p in photos if p[0] == a.reference]
        if not found:
            raise SystemExit("the photo could not be analysed")
        styles = my_styles(a.mystyles)
        examples = [(found[0][1]["a"], found[0][2], a.refsettings)]
        for pid in filter(None, (a.examples or "").split(",")):
            path = os.path.join(os.path.dirname(a.refsettings), f"reference_{pid}.tsv")
            more = [p for p in photos if p[0] == pid and pid != a.reference]
            if more and os.path.exists(path):
                examples.append((more[0][1]["a"], more[0][2], path))
        styles[a.learn] = learn(examples, a.name)
        print("examples", len(examples), flush=True)
        save_my_styles(a.mystyles, styles)
        open(a.out, "w").write("return {}\n")
        return
    if not a.reference:     # dark skin is noted for the plug-in, which then holds the look's brightening back
        skin_notes(a.job, a.out, dev)   # (lrcdf/skinkeep.py); a reference photo's edit is followed as it is
    # where the skin is, so that the look's skin corrections touch nothing else (lrcdf/skinmask.py, Tone.lua)
    strokes = {} if a.reference else skin_strokes(a.job, dev)
    out = {}
    for name in names:
        recipe = recipes.get(name, {})
        res = dict(failed)
        vecs = [[pid, restyle(base[recipe.get("base", name)].copy(), recipe), ref, when] for pid, base, ref, when in photos]
        if name in builtin and not a.reference:
            for item in vecs:
                item[1][2 + P.SCALAR_NAMES.index("Exposure2012")] += BRIGHT
        extra = P.extras(recipe.get("extra"), a.strength)
        if a.reference:
            vecs, extra = follow_reference(vecs, a.reference, a.refsettings)
            extra = P.extras(extra)
        else:
            for shoot in shoots(vecs, a.group, a.gap):
                harmonise(shoot)
        for pid, v, ref, _ in vecs:
            res[pid] = dict(P.decode(v, *ref, strength=1.0 if a.reference else a.strength), **extra)
            if pid in strokes:
                res[pid]["_skin"] = strokes[pid]
        out[name] = res
    tmp = a.out + ".tmp"
    open(tmp, "w", encoding="utf-8").write("return " + lua(out if a.style == "all" else out[a.style]) + "\n")
    os.replace(tmp, a.out)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--stop":
        stop_server(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--serve":
        serve(sys.argv[2])
    else:
        load_runtime()
        run(arguments())
