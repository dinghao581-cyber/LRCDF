"""Precompiled bytecode for a Windows bundle (called by Build-Windows.ps1).

Without it every cold start of the bundled Python compiles the modules it imports again: about 5 s for the beauty
preview's imports (measured 2026-11-18: 9.0 s without, 3.9 s with). The bytecode is "checked-hash": an imported .pyc
is checked against the hash of its source, so a .py replaced later (an update, a hand fix) never runs as its old
bytecode. The path written into each .pyc is the installed layout ("LRCDF\\project\\scripts\\beautify.py"), not the
build folder. Every module of python\\Lib, project and legacy is compiled again (force), so none is left in another
mode by the Python runs earlier in the build.

usage: python -s precompile_windows.py <bundle>\\LRCDF          exit status 1 when a module other than a test fails"""
import compileall
import importlib.util
import py_compile
import sys
from pathlib import Path

MODE = py_compile.PycInvalidationMode.CHECKED_HASH
FLAGS = 0b11        # .pyc header: hash-based, checked against the source


def main(payload):
    payload = payload.resolve()
    trees = [payload / "python" / "Lib", payload / "project", payload / "legacy"]
    for tree in trees:      # in parallel; a worker can fail to replace a .pyc another one has open: repaired below
        compileall.compile_dir(tree, quiet=2, force=True, workers=0, invalidation_mode=MODE,
                               stripdir=str(payload), prependdir="LRCDF")
    compiled = repaired = 0
    failed = []
    for tree in trees:      # one process: each module has its .pyc, in this mode
        for source in tree.rglob("*.py"):
            cache = Path(importlib.util.cache_from_source(str(source)))
            try:
                with open(cache, "rb") as f:
                    good = int.from_bytes(f.read(8)[4:8], "little") == FLAGS
            except OSError:
                good = False
            if good:
                compiled += 1
                continue
            try:
                py_compile.compile(str(source), cfile=str(cache), doraise=True, invalidation_mode=MODE,
                                   dfile=str(Path("LRCDF") / source.relative_to(payload)))
                compiled += 1
                repaired += 1
            except py_compile.PyCompileError as error:
                failed.append((source, error.msg.strip().splitlines()[-1]))
    serious = [(s, m) for s, m in failed if not {"test", "tests"} & {p.lower() for p in s.parts}]
    print(f"precompiled {compiled} modules ({repaired} repaired in one process); "
          f"{len(failed)} could not be compiled, {len(serious)} of them outside tests")
    for source, message in failed:
        print(f"  {source.relative_to(payload)}: {message}")
    return 1 if serious else 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
