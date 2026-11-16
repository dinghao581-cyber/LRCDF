"""Where the time and the memory of a full-size retouch go: beautify.py run as usual, with its steps timed and the
process's memory watched (docs/REQUIREMENTS.md was made with this).
usage: /usr/bin/time -l python measure_run.py <result.json> --job job.tsv [any beautify.py arguments]
result.json gets, per step, the seconds spent in it and the highest memory seen while it ran (MB): `footprint` is what
macOS charges the process (Activity Monitor's "Memory", GPU memory included), `mps` what PyTorch holds on the GPU.
Steps: load (models), read, detect (faces), choose (automatic level, on a small copy), skin (skin map), blend
(corrections laid into the picture), faces and body (lrcdf.beauty), guard, shape, write; `models` is the rest of the
retouch (crops and the networks on them), `convert` the rest of process (number formats, colour space)."""
import ctypes, json, os, sys, threading, time

sys.path.insert(0, os.path.dirname(__file__)); sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_buffer = (ctypes.c_uint64 * 128)()


def footprint():
    """Bytes macOS charges this process (phys_footprint: what Activity Monitor shows and what memory pressure counts)."""
    _libproc.proc_pid_rusage(os.getpid(), 0, ctypes.byref(_buffer))
    return int(_buffer[9])          # rusage_info_v0: 16 bytes of uuid, then 64-bit fields; phys_footprint is the eighth


def main():
    result, sys.argv[1:2] = sys.argv[1], []
    import tifffile, torch
    import beautify
    from lrcdf import beauty, shape, device
    legacy = beautify.legacy
    stack, seconds, peak, mps = ["start"], {}, {}, {}
    running = [True]

    def label():
        return "choose" if "choose" in stack else stack[-1]

    def watch():
        gpu = torch.backends.mps.is_available()
        while running[0]:
            name = label()
            peak[name] = max(peak.get(name, 0), footprint())
            if gpu:
                mps[name] = max(mps.get(name, 0), torch.mps.driver_allocated_memory())
            time.sleep(0.01)

    def timed(name, f):
        def g(*a, **k):
            stack.append(name); t = time.time()
            try:
                return f(*a, **k)
            finally:
                if "choose" not in stack[:-1]:
                    seconds[name] = seconds.get(name, 0) + time.time() - t
                stack.pop()
        return g

    load = beautify.load_models

    def load_models(dev):
        models = timed("load", load)(dev)
        models[0].predict_jsons = timed("detect", models[0].predict_jsons)
        return models

    beautify.load_models = load_models
    for module, names in ((beautify, ("read", "choose", "guard", "geometry", "retouch", "process")), (legacy, ("skin_weight", "blend_float")),
                          (beauty, ("beautify", "beautify_body")), (shape, ("apply",)), (tifffile, ("imwrite",))):
        for name in names:
            setattr(module, name, timed({"skin_weight": "skin", "blend_float": "blend", "beautify": "faces", "beautify_body": "body",
                                         "apply": "shape", "geometry": "shape", "imwrite": "write"}.get(name, name), getattr(module, name)))
    threading.Thread(target=watch, daemon=True).start()
    t0 = time.time()
    beautify.main()
    running[0] = False
    total = time.time() - t0
    s = {k: round(v, 2) for k, v in seconds.items()}
    s["faces"] = round(s.get("faces", 0) - s.get("body", 0), 2)
    inner = sum(s.get(k, 0) for k in ("detect", "choose", "skin", "blend", "faces", "body", "guard"))
    s["models"] = round(s.get("retouch", 0) - inner, 2)
    s["convert"] = round(s.get("process", 0) - s.get("retouch", 0) - s.get("shape", 0), 2)
    mb = lambda d: {k: round(v / 2 ** 20) for k, v in d.items()}
    plan = getattr(device, "plan", None)
    json.dump({"seconds": s, "total": round(total, 1), "footprint": mb(peak), "mps": mb(mps),
               "peak_footprint": max(mb(peak).values()), "peak_mps": max(mb(mps).values() or [0]),
               "plan": plan().__dict__ if plan else None}, open(result, "w"), indent=1, default=str)


if __name__ == "__main__":
    main()
