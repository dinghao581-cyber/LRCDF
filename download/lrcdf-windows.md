# LRCDF for Windows (Lightroom plug-in)

One-click portrait retouching inside Lightroom Classic on Windows x64. Everything is inside the package: Python, all packages, the models, the Lightroom plug-in and the LRCDF desktop app. Photos never leave your computer.

> Note: this version bundles Google MediaPipe 1.2.3, which sends usage statistics (not your photos) to Google while face/body detection runs. See [PRIVACY.md](../legal/PRIVACY.md).

**Known issue in 0.1.3 to 0.1.5 (RTX 50-series):** The CUDA package of these versions does not support NVIDIA GeForce RTX 50-series graphics cards (the bundled PyTorch build, 2.6.0+cu124, lacks them). On these cards please use the CPU package of these versions, or update: [0.1.6](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.6) carries a newer library (PyTorch 2.8.0 with CUDA 12.8) that supports these cards; it has not yet been tested on an RTX 50-series card.

**Latest version: 0.1.6** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.6)

- Download: [LRCDF-Windows-x64-cpu.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/win-v0.1.6/LRCDF-Windows-x64-cpu.zip)
- Download: [CUDA package (three parts and Join-Bundle.ps1)](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.6)

## What it does

- Finds every face and retouches skin with the same models as the Mac version: blemishes, smoothing that keeps real skin texture, under-eye, eyes and teeth.
- Darker skin keeps its own depth; the looks' orange correction acts on skin only.
- Looks, stepless fine adjustment with colour wheels, and full-size export straight back to Lightroom.
- Photos handed over from Lightroom open straight in the main window; all photos load in the background.
- **20 languages**: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Brazilian Portuguese, Italian, Dutch, Russian, Swedish, Norwegian, Polish, Czech, Turkish, Thai, Vietnamese and Indonesian. The language follows your Windows display languages.
- Automatic updates that download only the parts that changed (switch them off with the gear in the top-right corner).

## Which package

| Package | For | Download |
|---|---|---|
| **CPU** | Any 64-bit Windows 10 or 11 PC | `LRCDF-Windows-x64-cpu.zip` (1.91 GB) |
| **CUDA** | NVIDIA GeForce GTX 10 series or newer with a recent driver (NVIDIA lists 570.65 or newer for CUDA 12.8; older drivers from 525 on are expected to work for GTX 10 to RTX 40 series, untested) | `LRCDF-Windows-x64-cuda.zip.001`, `.002`, `.003` and `Join-Bundle.ps1` (4.75 GB in three parts) |

## Recommended PCs

| | Minimum | Recommended |
|---|---|---|
| Memory | 16 GB | 32 GB or more |
| Graphics (CUDA package) | NVIDIA RTX with 8 GB of video memory | RTX 3090 / 4080 / 4090 or later with 16 GB or more |
| Disk | 15 GB free (CPU) / 25 GB free (CUDA) | an SSD |

For reference, on a PC with 64 GB of memory and an RTX 3090, a full-size 60-megapixel photo takes about 28 seconds with the CUDA package and about 54 seconds with the CPU package.

## Install

1. Close Lightroom Classic.
2. **CPU package**: unzip `LRCDF-Windows-x64-cpu.zip`.
   **CUDA package**: put the three parts and `Join-Bundle.ps1` in one folder, open PowerShell in that folder and run
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Join-Bundle.ps1`
   This joins them into `LRCDF-Windows-x64-cuda.zip`; unzip that file. (A single part cannot be unzipped on its own.)
3. Open PowerShell in the unzipped folder and run
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Windows.ps1`
   To update an existing installation, add `-Replace` at the end of the command.
4. Open Lightroom Classic, select photos in the Library, then choose Library → Plug-in Extras → Start One-Click Retouch…. The LRCDF desktop app opens with your photos.

The package is not code-signed, so Windows may show a security warning after the download or when a script runs: choose **Keep** or **Run anyway**. Full details, uninstalling and building from source: `Windows-Install.md` inside the package.

## Known limitations

- Graphics cards with less than 15 GB of video memory process large photos in tiles. Previews then differ from those of larger cards by amounts the eye cannot see; full-size results differ by at most 1 level.
- The skin area is estimated by a segmentation model: skin in shadow may be missed, and small skin-coloured objects, lips, teeth and the whites of the eyes may be adjusted slightly along with it.
- When the same photo is analysed again in a later Lightroom Classic session, the result may differ slightly.
- Before using a graphics card, LRCDF checks that it can really compute on it; if it cannot, LRCDF switches to the processor by itself, without a message in 0.1.6. The reason is written to `%USERPROFILE%\LRCDF\device.log`. Tested only on an RTX 3090.
- On NVIDIA graphics cards, retouched pictures from 0.1.6 differ from 0.1.5 in a small number of pixels by an amount that cannot be seen (at most 11 of 255 levels, in up to 89 pixels of a 4.5-megapixel picture in our tests); this comes from the newer computing library. Results on the processor are bit-identical to 0.1.5.
- In Lightroom, the first retouch preview after starting takes about 2.4 seconds longer on NVIDIA cards than in 0.1.5 (the newer library's first-run set-up); later pictures are not affected. An improvement is planned for 0.1.7.

## Updates

Installed copies from 0.1.3 on update themselves: the app downloads only the parts that changed. You can switch this off with the gear in the top-right corner. From 0.1.5 to 0.1.6 the CPU package downloads about 25 MB; the CUDA package downloads about 3.2 GB, because its graphics library is replaced, and needs about 12 GB of free disk space while it updates.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.1.6 | [win-v0.1.6](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.6) | CUDA package supports GTX 10 to RTX 50 series |
| 0.1.5 | [win-v0.1.5](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.5) |  |
| 0.1.4 | [win-v0.1.4](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.4) |  |
| 0.1.3 | [win-v0.1.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.3) |  |

## Licences

Licence texts are attached to each release page and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [Tonewell for Mac](tonewell-mac.md) · [Tonewell for iPad](tonewell-ipad.md) · [Tonewell for Windows](tonewell-windows.md)
