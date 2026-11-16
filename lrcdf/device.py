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
        return "cuda"
    return "cpu"


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
