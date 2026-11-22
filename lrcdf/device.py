"""Which device the networks run on, and how much of the machine a retouch run may take (plan).

The retouch run was first measured on one machine only (M5 Pro, 48 GB). plan() reads the machine it runs on and
picks one of three tiers; docs/REQUIREMENTS.md has the measurements behind the numbers. Nothing here is a user
option: the tier follows from the memory of the Mac. LRCDF_TIER=8|16|32 forces a tier (tests)."""
import os
import subprocess
import sys
from dataclasses import dataclass

import torch


def pick():
    if torch.backends.mps.is_available():
        return "mps"
    if sys.platform == "win32" and torch.cuda.is_available():
        if not _WIN_CHOICE:
            _WIN_CHOICE.append(_win_cuda_check())
        return _WIN_CHOICE[0]
    if sys.platform == "win32" and torch.version.cuda and not _WIN_CHOICE:
        # the CUDA package with no card CUDA can use (none, its driver missing or too old, or hidden): say so in the log
        _WIN_CHOICE.append("cpu")
        _win_log(f"no graphics card CUDA can use (torch {torch.__version__} needs an NVIDIA card and a driver for CUDA "
                 f"{torch.version.cuda}), CPU")
    return "cpu"


# ---- Windows only (sys.platform == "win32" with an NVIDIA card; a Mac never gets here) --------------------------------
# An RTX 50 card (sm_120) under a torch built up to sm_90 said the card was available, and every kernel then failed (board
# 2026-11-21 15:51). So the card is used only when this torch carries code for it and a small trial on it gives the CPU's
# numbers; else, and after any CUDA error later in the process, the CPU. The choice and its reason go to device.log in the
# installation folder (%USERPROFILE%\LRCDF\device.log), for users to send. LRCDF_GPU_TEST simulates the failures for
# the tests: "unsupported" (the card's architecture missing from the build), "trial" (the trial fails), "midway" (the
# first photo's work raises a CUDA error once).
_WIN_CHOICE = []                 # "cuda" or "cpu", decided once per process
_WIN_USED_CUDA = []              # the card was chosen at the start (a CUDA error may have moved the process since)
_WIN_TEST = [os.environ.get("LRCDF_GPU_TEST", "")]


def _win_covered(capability, archs):
    """Whether a build with these get_arch_list() entries runs on a card of this (major, minor) capability: machine
    code sm_XY runs on X.Z for Z >= Y (sm_XYa only on X.Y); PTX compute_XY is compiled by the driver for newer cards."""
    major, minor = capability
    for arch in archs:
        kind, _, num = arch.partition("_")
        digits = num.rstrip("abcdefghijklmnopqrstuvwxyz")
        if not digits.isdigit():
            continue
        suffix, (m, s) = num[len(digits):], divmod(int(digits), 10)
        if (suffix == "a" and (m, s) == (major, minor)) or (suffix != "a" and kind == "sm" and m == major and s <= minor) \
                or (suffix == "f" and m == major and s <= minor) or (suffix == "" and kind == "compute" and (m, s) <= (major, minor)):
            return True
    return False


_WIN_DRIVER = []


def _win_driver():
    """The NVIDIA driver's version as its own library (nvml.dll, installed with the driver) gives it: also when torch
    finds no CUDA it can use, which is when it is most wanted. Asked once per process; never a reason to fail."""
    if not _WIN_DRIVER:
        text = "no NVIDIA driver"
        try:
            import ctypes
            nvml = ctypes.WinDLL("nvml.dll")
            if nvml.nvmlInit_v2() == 0:
                buffer = ctypes.create_string_buffer(96)
                if nvml.nvmlSystemGetDriverVersion(buffer, ctypes.c_uint(96)) == 0:
                    text = "NVIDIA driver " + buffer.value.decode("ascii", "replace")
                else:
                    text = "NVIDIA driver (version not readable)"
                nvml.nvmlShutdown()
            else:
                text = "NVIDIA driver (not answering)"
        except (OSError, AttributeError):
            pass
        _WIN_DRIVER.append(text)
    return _WIN_DRIVER[0]


def _win_log(text):
    try:
        import time
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "device.log")
        if os.path.exists(path) and os.path.getsize(path) > 100_000:
            os.replace(path, path + ".1")
        with open(path, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + text + f" [{_win_driver()}]\n")
    except OSError:              # the log is a help, never a reason to fail
        pass


def _win_cuda_check():
    try:
        if torch.cuda.device_count() == 0:      # CUDA works but shows no card (CUDA_VISIBLE_DEVICES leaves none)
            _win_log(f"no graphics card visible to CUDA (CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES')!r}), CPU")
            return "cpu"
        name, capability = torch.cuda.get_device_name(0), torch.cuda.get_device_capability(0)
        archs = [] if _WIN_TEST[0] == "unsupported" else torch.cuda.get_arch_list()
        what = f"{name}, sm_{capability[0]}{capability[1]}, torch {torch.__version__} built for {' '.join(archs) or '(simulated: none)'}"
        if not _win_covered(capability, archs):
            _win_log(f"{what}: not in the build, CPU")
            return "cpu"
        if _WIN_TEST[0] == "trial":
            raise RuntimeError("CUDA error: no kernel image is available for execution on the device (simulated)")
        # a little of torch's own kernels (what a build without code for the card lacks) on the card and on the CPU
        x = torch.linspace(-1, 1, 4096, dtype=torch.float32).reshape(64, 64)
        work = lambda t: torch.nn.functional.interpolate((torch.tanh(t * 1.7) + t.clamp(-0.5, 0.5))[None, None], size=(32, 32), mode="bilinear", align_corners=False).sum()     # noqa: E731
        on_card, on_cpu = float(work(x.to("cuda")).cpu()), float(work(x))
        torch.cuda.synchronize()
        if not on_card == on_card or abs(on_card - on_cpu) > 1e-3 * max(1.0, abs(on_cpu)):
            _win_log(f"{what}: trial gave other numbers than the CPU, CPU")
            return "cpu"
    except Exception as ex:      # anything the card does wrong here: the CPU
        _win_log(f"graphics card check failed ({type(ex).__name__}: {str(ex)[:300]}), CPU")
        return "cpu"
    _win_log(f"{what}: graphics card")
    _WIN_USED_CUDA.append(True)
    return "cuda"


def cuda_error(ex):
    """Windows: whether ex came from the graphics card (no kernel for it, a launch failure, out of its memory, a tensor
    left on it after the move to the CPU). Never on a process that did not choose the card, so never on a Mac."""
    if not _WIN_USED_CUDA:
        return False
    text = f"{type(ex).__name__} {ex}"
    return any(k in text for k in ("CUDA", "cuda", "CUBLAS", "cuDNN", "CUDNN", "AcceleratorError", "OutOfMemoryError"))


def fall_back(ex):
    """Windows: the rest of this process runs on the CPU after ex, a CUDA error. The caller loads its networks again
    (pick() now says "cpu") and does the photo or request again."""
    if _WIN_CHOICE and _WIN_CHOICE[0] == "cuda":
        _WIN_CHOICE[0] = "cpu"
        _win_log(f"CUDA error during work ({type(ex).__name__}: {str(ex)[:300]}): CPU for the rest of the process")


def midway_test():
    """LRCDF_GPU_TEST=midway: a CUDA error raised once, in the first photo's work on the card (tests only)."""
    if _WIN_TEST[0] == "midway" and _WIN_CHOICE and _WIN_CHOICE[0] == "cuda":
        _WIN_TEST[0] = ""
        raise RuntimeError("CUDA error: an illegal memory access was encountered (simulated)")


@dataclass(frozen=True)
class Plan:
    tier: int            # 8, 16 or 32: the class of machine (GB of memory)
    memory_gb: float     # physical memory
    chip: str
    perf_cores: int
    mps: bool            # the networks may use the GPU (unified memory: what they hold is taken from the same RAM)
    release_gpu: bool    # give the GPU's cached memory back after every network call (PyTorch keeps it otherwise)
    tiles: int           # the retouch network works on its 1024 px face crop in tiles x tiles pieces (1 = whole crop;
                         # with 128 px of overlap the result is the same, measured: max difference 0.0000 levels)
    small_face_model: bool    # RetouchFormer for faces under 300 px: 0.6 GB of weights and about 6 GB more for each
                              # 512 px run, on the GPU or the CPU alike (measured); without it those faces get the
                              # classical steps only, as when it is not installed
    work_mp: float       # colour and skin work on a copy of at most this many megapixels; only the change is enlarged
                         # and laid onto the photo's own pixels (0 = at full size, as on the machine it was built on)
    strip_rows: int      # the full-size picture is finished (change laid on, reshaping) this many rows at a time
    threads: int         # OpenCV / PyTorch CPU threads (0 = their own default)
    preview_idle: int    # seconds the preview process stays loaded with nothing to do
    preview_during_run: str    # "release": the preview process quits before a full-size run (two sets of models)
    chunk: int           # photos per retouch command from the app (beautify.py handles them one after another and
                         # frees each before the next: three 60 MP photos in one run peaked 0.25 GB above one, so
                         # the app's three, app/Sources/LRCDF/Model.swift, stand on every tier)


def _sysctl(name, default):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, timeout=5).stdout.strip() or default
    except (OSError, subprocess.SubprocessError):
        return default


def _installed_memory():
    """Installed memory in GB off the Mac, asked of the system itself (no extra package). 16 if it cannot be read.
    Graphics memory is not looked at: the tiers were measured on Macs, where the two are one."""
    try:
        if sys.platform == "win32":
            import ctypes

            class Status(ctypes.Structure):     # MEMORYSTATUSEX
                _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong)] + [
                    (name, ctypes.c_ulonglong) for name in ("total", "free", "page_total", "page_free",
                                                            "virtual_total", "virtual_free", "extended")]
            status = Status()
            status.length = ctypes.sizeof(Status)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)) and status.total:
                return status.total / 2 ** 30
        else:
            return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2 ** 30
    except (OSError, ValueError, AttributeError):
        pass
    return 16.0


def machine():
    """(memory in GB, chip name, performance cores)."""
    if sys.platform == "darwin":
        memory = int(_sysctl("hw.memsize", "0")) / 2 ** 30
        chip = _sysctl("machdep.cpu.brand_string", "")
        cores = int(_sysctl("hw.perflevel0.physicalcpu", "0") or 0) or os.cpu_count() or 4
    else:
        memory = _installed_memory()
        chip, cores = "", os.cpu_count() or 4
    return memory, chip, cores


_PLAN = None


def _fit_graphics_memory(p):
    """On a PC the graphics card has memory of its own, which the tiers (made on Macs, where it is the same memory)
    do not look at. Measured on an RTX 3090 (2026-11-16): the retouch network on its whole 1024 px crop (tiles 1)
    peaks at 10.5 GiB and PyTorch reserves 12-13.5; in 4 x 4 tiles 2.6 GiB, in 8 x 8 1.6 GiB, with nearly the same
    result (measured on the PC: full size at most 1 level apart; a 2600 px preview 0.07 levels on average, single
    pixels up to 12, scattered over the face with no visible seam - a known limit, not fixed; see Plan.tiles). So a card under 15 GiB gets tiles, and one under 10 GiB goes without the small-face model
    (about 6 GB a run). LRCDF_VRAM=<GB> pretends a card of that size (tests)."""
    if pick() != "cuda":
        return p
    from dataclasses import replace
    try:
        vram = float(os.environ.get("LRCDF_VRAM") or torch.cuda.get_device_properties(0).total_memory / 2 ** 30)
    except (RuntimeError, ValueError, AssertionError):
        return p
    if vram >= 15:
        return p
    return replace(p, release_gpu=True, tiles=max(p.tiles, 4 if vram >= 6 else 8),
                   small_face_model=p.small_face_model and vram >= 10)


def plan():
    """The plan for this machine (computed once)."""
    global _PLAN
    if _PLAN is not None:
        return _PLAN
    memory, chip, cores = machine()
    forced = os.environ.get("LRCDF_TIER", "")
    tier = int(forced) if forced in ("8", "16", "32") else 8 if memory < 12 else 16 if memory < 30 else 32
    if tier == 32:      # as measured on the 48 GB machine: everything at full size, nothing given back early
        _PLAN = Plan(tier, memory, chip, cores, mps=True, release_gpu=False, tiles=1, small_face_model=True, work_mp=0,
                     strip_rows=0, threads=0, preview_idle=600, preview_during_run="release", chunk=3)
    elif tier == 16:    # 16-24 GB: Lightroom and macOS take 6-8 GB of it
        _PLAN = Plan(tier, memory, chip, cores, mps=True, release_gpu=True, tiles=4, small_face_model=False, work_mp=24,
                     strip_rows=512, threads=0, preview_idle=300, preview_during_run="release", chunk=3)
    else:               # 8 GB: the run must stay under about 5 GB with Lightroom open
        _PLAN = Plan(tier, memory, chip, cores, mps=True, release_gpu=True, tiles=8, small_face_model=False, work_mp=12,
                     strip_rows=256, threads=min(cores, 4), preview_idle=120, preview_during_run="release", chunk=3)
    _PLAN = _fit_graphics_memory(_PLAN)
    if tier == 16 and pick() == "cpu":
        # Without a graphics card the tiles only cost time: each carries a 128 px rim, so 4 x 4 is about four times
        # the work. Measured on a 16-thread PC (2026-11-18, 8 large faces): tiles 4 / 2 / 1 = 11.3 / 6.2 / 2.8 s per
        # face, 1.7 / 3.0 / 4.2 GiB more memory at the peak, output byte-identical. So 2, and 1 from 24 GB on.
        from dataclasses import replace
        _PLAN = replace(_PLAN, tiles=1 if memory >= 24 else 2)
    if _PLAN.threads:
        try:
            import cv2
            cv2.setNumThreads(_PLAN.threads)
        except ImportError:
            pass
        torch.set_num_threads(_PLAN.threads)
    return _PLAN


if __name__ == "__main__":      # python -m lrcdf.device: what this machine gets
    import json
    print(json.dumps(plan().__dict__, ensure_ascii=False))
