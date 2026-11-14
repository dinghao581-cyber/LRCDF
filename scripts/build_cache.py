"""Resize all source photos once into a uint8 memmap for fast training.
usage: build_cache.py <ppr10k_dir> [source_subdir=source]"""
import sys, os
import numpy as np
from concurrent.futures import ThreadPoolExecutor
from tqdm import tqdm
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from lrcdf.model import load_image, SIZE

root = sys.argv[1]; sub = sys.argv[2] if len(sys.argv) > 2 else "source"
ids = np.load(f"{root}/labels.npz")["ids"]
out = np.lib.format.open_memmap(f"{root}/cache_{sub}_{SIZE}.npy", "w+", np.uint8, (len(ids), SIZE, SIZE, 3))


def one(i):
    out[i] = (load_image(f"{root}/{sub}/{ids[i]}.tif") * 255 + 0.5).astype(np.uint8).transpose(1, 2, 0)


with ThreadPoolExecutor(8) as ex:
    list(tqdm(ex.map(one, range(len(ids))), total=len(ids)))
out.flush()
print("mean rgb", out[::50].reshape(-1, 3).mean(0))
