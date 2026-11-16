from pathlib import Path
import sys


def base_options(factory, path):
    if sys.platform == "win32" and not path.isascii():
        return factory(model_asset_buffer=Path(path).read_bytes())
    return factory(model_asset_path=path)
