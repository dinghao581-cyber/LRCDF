# LRCDF for Windows (Lightroom plug-in)

One-click portrait retouching inside Lightroom Classic on Windows x64. Everything is inside the package: Python, all packages, the models, the Lightroom plug-in and the LRCDF desktop app. Photos never leave your computer.

> Note: this version bundles Google MediaPipe 1.2.3, which sends usage statistics (not your photos) to Google while face/body detection runs. See [PRIVACY.md](../legal/PRIVACY.md).

**Latest version: 0.1.4** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.4)

- Download: [LRCDF-Windows-x64-cpu.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/win-v0.1.4/LRCDF-Windows-x64-cpu.zip)
- Download: [CUDA package (three parts and Join-Bundle.ps1)](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.4)

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
| **CUDA** | PCs with an NVIDIA graphics card and a driver that supports CUDA 12.4 | `LRCDF-Windows-x64-cu124.zip.001`, `.002`, `.003` and `Join-Bundle.ps1` (4.24 GB in three parts) |

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
   This joins them into `LRCDF-Windows-x64-cu124.zip`; unzip that file. (A single part cannot be unzipped on its own.)
3. Open PowerShell in the unzipped folder and run
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Windows.ps1`
   To update an existing installation, add `-Replace` at the end of the command.
4. Open Lightroom Classic, select photos in the Library, then choose Library → Plug-in Extras → Start One-Click Retouch…. The LRCDF desktop app opens with your photos.

The package is not code-signed, so Windows may show a security warning after the download or when a script runs: choose **Keep** or **Run anyway**. Full details, uninstalling and building from source: `Windows-Install.md` inside the package.

## Known limitations

- Graphics cards with less than 15 GB of video memory process large photos in tiles. Previews then differ from those of larger cards by amounts the eye cannot see; full-size results differ by at most 1 level.
- The skin area is estimated by a segmentation model: skin in shadow may be missed, and small skin-coloured objects, lips, teeth and the whites of the eyes may be adjusted slightly along with it.
- When the same photo is analysed again in a later Lightroom Classic session, the result may differ slightly.

## Updates

Installed copies from 0.1.3 on update themselves: the app downloads only the parts that changed. You can switch this off with the gear in the top-right corner.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.1.4 | [win-v0.1.4](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.4) |  |
| 0.1.3 | [win-v0.1.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.3) |  |

## Licences

Licence texts are attached to each release page and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [Tonewell for Mac](tonewell-mac.md) · [Tonewell for iPad](tonewell-ipad.md) · [Tonewell for Windows](tonewell-windows.md)
