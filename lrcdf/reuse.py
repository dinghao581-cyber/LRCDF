"""Filters that are asked for again with the same picture and the same settings give back what they gave before.

A preview is made in three levels, and the automatic level tries three more on a small copy: a good part of the blurs
in lrcdf/beauty.py then work on exactly the same pixels with exactly the same settings (measured on one warm preview
pass on the Mac: 5.5 s -> 3.6 s; with OpenCV on one thread 16.7 s -> 6.3 s). The result is the same array OpenCV would compute again, so
nothing changes in the picture; the caller gets its own copy and may write into it.

What is kept is found by the input's bytes (two checksums, its size and type) and the arguments. Pictures above ONE
megabytes are not kept (full-size work has no repeats and would only fill memory); together at most LIMIT megabytes.
One preview pass makes about 3 GB of filter results, so not everything can stay: what goes first is what saves the
least time for the memory it takes (a bilateral filter of a face crop costs 25 times more per megabyte than a
dilation of the whole picture)."""
import time
import zlib

import cv2
import numpy as np

ONE = 64            # MB of input above which a call is not kept
LIMIT = 384         # MB of results kept together
_kept = {}          # key -> [result, seconds it took per megabyte]
_size = [0]
hits = [0, 0]       # calls answered from what was kept, calls computed (for measuring)


def limit(megabytes):
    """Machines with little memory keep less (lrcdf/device.py's plan decides)."""
    global LIMIT
    LIMIT = megabytes
    _trim()


def clear():
    _kept.clear()
    _size[0] = 0


def _trim():
    while _size[0] > LIMIT * 2 ** 20 and _kept:
        least = min(_kept, key=lambda k: _kept[k][1])
        _size[0] -= _kept.pop(least)[0].nbytes


def _mark(a):
    a = np.ascontiguousarray(a)
    data = memoryview(a).cast("B")
    return a.shape, a.dtype.str, zlib.crc32(data), zlib.adler32(data)


def _of(name):
    real = getattr(cv2, name)

    def call(src, *args, **kwargs):
        if not isinstance(src, np.ndarray) or src.nbytes > ONE * 2 ** 20 or "dst" in kwargs:
            return real(src, *args, **kwargs)
        try:
            key = (name, _mark(src),
                   tuple(_mark(a) if isinstance(a, np.ndarray) else a for a in args),
                   tuple(sorted((k, _mark(v) if isinstance(v, np.ndarray) else v) for k, v in kwargs.items())))
            hash(key)
        except TypeError:           # an argument that cannot be compared: compute as usual
            return real(src, *args, **kwargs)
        found = _kept.get(key)
        if found is not None:
            hits[0] += 1
            return found[0].copy()
        started = time.perf_counter()
        result = real(src, *args, **kwargs)
        worth = (time.perf_counter() - started) / max(result.nbytes, 1) * 2 ** 20 if isinstance(result, np.ndarray) else 0
        hits[1] += 1
        if isinstance(result, np.ndarray) and result.nbytes <= ONE * 2 ** 20:
            _kept[key] = [result, worth]
            _size[0] += result.nbytes
            _trim()
            if key in _kept:        # the caller may write into what it gets; what is kept must stay as it is
                return result.copy()
        return result
    return call


GaussianBlur = _of("GaussianBlur")
bilateralFilter = _of("bilateralFilter")
dilate = _of("dilate")
erode = _of("erode")
morphologyEx = _of("morphologyEx")
