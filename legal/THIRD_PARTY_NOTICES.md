# Third-party software notices

LRCDF's own code is Apache-2.0 (see `../LICENSE`). It uses the following
third-party software, each under its own licence. This list names the licence
family; the full licence texts ship with each package (in its `dist-info` folder
or source repository). Model weights are listed in `MODEL_LICENSES.md`.

| Component | Use | Licence |
|---|---|---|
| PyTorch | Neural-network runtime | BSD-3-Clause |
| torchvision | ConvNeXt backbone, image ops | BSD-3-Clause |
| NumPy | Arrays | BSD-3-Clause |
| SciPy | Filtering, image maths | BSD-3-Clause |
| OpenCV (`opencv-python-headless`, `opencv-contrib-python`) | Image processing, SFace | Apache-2.0 |
| MediaPipe (LRCDF plug-in: version 1.2.3) | Face, pose and segmentation runtime | Apache-2.0. This build sends usage statistics to Google; see `PRIVACY.md`, "Network use" |
| ONNX Runtime | Runs the age/sex model | MIT |
| Pillow | Image I/O | MIT-CMU (HPND) |
| rawpy / LibRaw | RAW decoding (where used) | rawpy: MIT; LibRaw: LGPL-2.1 or CDDL-1.0 (dynamic use) |
| pi-heif (decode-only build of pillow-heif) with libheif and libde265 | Read HEIC photos (Windows app) | pi-heif: BSD-3-Clause; libheif: LGPL-3.0; libde265: LGPL-3.0 (shipped as separate DLLs) |
| Microsoft Visual C++ runtime (`vcomp140.dll`, bundled in the rawpy wheel) | OpenMP runtime for LibRaw | Microsoft Visual C++ Redistributable terms |
| Lucide icons | Interface icons (Windows app) | ISC; portions derived from Feather: MIT (copyright notices on lucide.dev/license) |
| Qt for Python: PySide6_Essentials and shiboken6 6.8.3 (Qt 6.8.3 libraries) | Interface of the LRCDF and Tonewell apps for Windows | Used under the **LGPL-3.0** (the packages are offered under LGPL-3.0-only, GPL-2.0-only, GPL-3.0-only or a Qt commercial licence; we use the LGPL option). Texts: `licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt`. Qt itself bundles further third-party components, listed at https://doc.qt.io/qt-6/licenses-used-in-qt.html |
| cryptography 50.0.2 (statically includes OpenSSL 4.0.3) | Verify update signatures (Windows apps) | Apache-2.0 or BSD-3-Clause (texts in `licenses/CRYPTOGRAPHY_LICENSE*.txt`); OpenSSL: Apache-2.0 (`licenses/OPENSSL_NOTE.txt`) |
| tifffile | 16-bit TIFF I/O | BSD-3-Clause |
| imageio | Image I/O | BSD-2-Clause |
| albumentations | Legacy retouch pre-processing | MIT |
| einops | Tensor reshaping | MIT |
| tqdm | Progress display | MPL-2.0 and MIT |
| Python | Interpreter | PSF License |
| ModelScope skin-retouching package (RetinaFace code) | Face detection code | Apache-2.0 (RetinaFace implementation: MIT) |
| RetouchFormer model code | Blemish network code | See the RetouchFormer project (AAAI 2024) |
| `abhilash88/age-gender-prediction` (Abhilash Sahoo), `onnx-community/age-gender-prediction-ONNX`, `google/vit-base-patch16-224` | Age/sex model weights and their base | Apache-2.0 |
| ternaus/retinaface and biubug6/Pytorch_Retinaface | RetinaFace implementation and ResNet-50 weights (face detection) | MIT (texts in `licenses/`) |
| OpenCV Zoo | SFace model (also converted to Core ML for Tonewell) | Apache-2.0 |
| Google MediaPipe Pose Landmarker models (BlazePose GHUM 3D) | Body landmarks for shaping | Apache-2.0 (per the model card) |
| Google MediaPipe Face Landmarker models | Face landmarks and blendshapes, converted to Core ML for Tonewell (eye-closure check) | Apache-2.0 |
| Apple MobileCLIP2-S2 (weights, as a modified Model Derivative) | Make-up and skin-depth scorer | Apple Machine Learning Research Model License Agreement; text in `licenses/APPLE_ML_RESEARCH_MODEL_LICENSE.txt`. Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement. |
| libjxl 0.11.1 (tag v0.11.1; "the JPEG XL Project Authors") | JPEG XL export. Tonewell for Mac: statically linked. Tonewell for Windows: the official v0.11.1 release DLLs `jxl.dll`, `jxl_cms.dll`, `jxl_threads.dll` | BSD-3-Clause with the JPEG XL patent grant (`licenses_mac/LIBJXL_LICENSE.txt`, `licenses_mac/LIBJXL_PATENTS.txt`) |
| Highway 1.2.0 (commit 457c891, bundled with libjxl; "The Highway Project Authors") | SIMD support for libjxl (Tonewell for Mac; on Windows it is linked into `jxl.dll` of the official release) | Apache-2.0 or BSD-3-Clause (`licenses_mac/HIGHWAY_LICENSE.txt`, `licenses_mac/HIGHWAY_BSD3_LICENSE.txt`) |
| Brotli 1.0.9 (commit 36533a8, bundled with libjxl; "the Brotli Authors") | Compression for libjxl (Tonewell for Mac; on Windows the release's `brotlicommon.dll`, `brotlienc.dll`, `brotlidec.dll`) | MIT (`licenses_mac/BROTLI_LICENSE.txt`) |
| skcms (commit 42030a7, bundled with libjxl; Google Inc.) | Colour management for libjxl (Tonewell for Mac; on Windows it is part of `jxl_cms.dll`) | BSD-3-Clause (`licenses_mac/SKCMS_LICENSE.txt`) |
| Core ML Tools (`coremltools`) | Converts models to Core ML (build time only) | BSD-3-Clause |
| Apple system frameworks (SwiftUI, AppKit, Core ML, Vision, Core Image) | Desktop and Tonewell apps | Part of macOS; not redistributed |
| Adobe Lightroom Classic SDK | Plug-in interface | Used under Adobe's SDK terms; not redistributed |

Other packages that the ones above install as their own dependencies (checked with `pip-licenses` on the
development environment, 2026-11-14; all permissive, none under the GPL): absl-py, flatbuffers, stringzilla, simsimd,
tzdata (Apache-2.0); attrs, cattrs, annotated-types, pydantic, pydantic-core, typing-inspection, albucore, PyYAML,
filelock, fonttools, pyparsing, cffi, sounddevice (MIT / MIT-0); Jinja2, MarkupSafe, contourpy, cycler, kiwisolver,
lazy-loader, networkx, fsspec, mpmath, sympy, protobuf, pycparser, python-dateutil, scikit-image, coremltools (BSD);
packaging (Apache-2.0 or BSD-2-Clause); matplotlib (PSF-based Matplotlib licence); typing-extensions (PSF-2.0);
certifi (MPL-2.0); pyaml (public domain). Re-run `pip-licenses` on the environment that is actually shipped.

Qt for Python and Qt (LGPL-3.0): the Windows apps use them as separate dynamic
libraries (the `PySide6\*.dll`, `shiboken6\*.dll` and Python extension files in
the installation folder), without modification. You may replace them with your own
build of the same Qt / PySide6 version family; the app then runs against your
build. Source code: Qt https://download.qt.io/official_releases/qt/6.8/6.8.3/ and
Qt for Python https://code.qt.io/cgit/pyside/pyside-setup.git (tag v6.8.3). The
app's own licence does not restrict this replacement.

LGPL libraries (LibRaw, libheif, libde265) are shipped as separate dynamic libraries
that you can replace with your own build of the same version family. Their licence
texts ship with the package, and their source is available from the upstream
projects: https://github.com/LibRaw/LibRaw, https://github.com/strukturag/libheif,
https://github.com/strukturag/libde265. Do not substitute `pillow-heif`'s Windows
wheel: it additionally bundles the GPL-2.0 x265 encoder, which LRCDF does not use or ship.

Apache-2.0 and BSD/MIT notices are preserved in the packages as installed. If
you redistribute a bundled environment (for example the installer package),
include each package's licence file, which the standard installers already
place in the `dist-info` folders.
