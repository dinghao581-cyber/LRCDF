import os
import sys

import cv2
import numpy as np


def imread(path, flags=cv2.IMREAD_COLOR):
    if sys.platform == "win32" and not os.fspath(path).isascii():
        try:
            return cv2.imdecode(np.fromfile(path, dtype=np.uint8), flags)
        except OSError:
            return None
    return cv2.imread(path, flags)


def imwrite(path, image, params=()):
    if sys.platform == "win32" and not os.fspath(path).isascii():
        ok, encoded = cv2.imencode(os.path.splitext(path)[1], image, params)
        if ok:
            encoded.tofile(path)
        return ok
    return cv2.imwrite(path, image, params)
