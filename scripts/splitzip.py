"""Read single entries out of a zip that was cut into equal binary parts (raw.zip.001 ...), without joining them."""
import glob, io, os, sys, zipfile
class Parts(io.RawIOBase):
    def __init__(self, pattern):
        self.files = sorted(glob.glob(pattern)); self.sizes = [os.path.getsize(f) for f in self.files]
        self.total = sum(self.sizes); self.pos = 0; self.open = {}
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.total + off
        return self.pos
    def readinto(self, b):
        n = 0; mv = memoryview(b)
        while n < len(b) and self.pos < self.total:
            k, off = 0, self.pos
            while off >= self.sizes[k]: off -= self.sizes[k]; k += 1
            if k not in self.open: self.open[k] = open(self.files[k], "rb")
            f = self.open[k]; f.seek(off)
            got = f.readinto(mv[n:n + min(len(b) - n, self.sizes[k] - off)])
            if not got: break
            n += got; self.pos += got
        return n
if __name__ == "__main__":
    z = zipfile.ZipFile(io.BufferedReader(Parts(sys.argv[1]), 1 << 20))
    names = z.namelist()
    if len(sys.argv) == 2:
        print(len(names)); print("\n".join(names[:8])); import collections; print(collections.Counter(os.path.splitext(n)[1].lower() for n in names))
    else:
        out = sys.argv[2]; os.makedirs(out, exist_ok=True)
        for want in sys.argv[3:]:
            hit = [n for n in names if os.path.splitext(os.path.basename(n))[0] == want]
            for n in hit:
                data = z.read(n); open(os.path.join(out, os.path.basename(n)), "wb").write(data); print(n, len(data) // 1024, "KB", flush=True)
            if not hit: print(want, "not found")
