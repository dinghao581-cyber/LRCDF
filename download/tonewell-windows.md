# Tonewell for Windows

**Known issue (RTX 50-series):** On NVIDIA GeForce RTX 50-series graphics cards the picture area is reported to stay black: the bundled PyTorch build (2.6.0+cu124) has no support for these cards. Other GeForce generations are not affected. [0.3.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.3) carries a newer library (PyTorch 2.8.0 with CUDA 12.8) that supports these cards; it has not yet been tested on an RTX 50-series card.

**Known issue in 0.3 and 0.3.1:** the "Open Photos…", "Settings" and "Clear and choose again" items in the "…" menu do nothing. To open photos, use Ctrl+O or the button on the start page; there is no other way to use "Clear and choose again". Because the Settings page does not open, you also cannot switch off the automatic update check, change the language, open the in-app licence list or the full privacy policy link, or reopen the "Your rights at work" screen. The licence texts are still included in the `legal` folder inside the installation folder, and the rights notice still appears at startup. The update check still runs: it only downloads a small signed version file and sends no personal information. Because the "new version" message is also shown on the Settings page, you will not be told about updates, so please check the release page.

**Temporary workaround to turn the update check off (0.3 and 0.3.1):**
1. Quit Tonewell completely.
2. Press Win+R, type `%APPDATA%\Tonewell` and press Enter. (If the folder does not exist, create it.)
3. Open `preferences.json` in Notepad. If the file does not exist, create it.
4. Make its entire contents exactly `{"update.auto": false}`. If the file already contains other settings, add `"update.auto": false` inside the outer braces as one more entry, separated by commas.
5. Save it as **UTF-8 without BOM**. In Notepad's Save As box, choose "UTF-8", not "UTF-8 with BOM", and make sure the file name does not end in `.txt`. A file saved with a BOM is not read: Tonewell keeps checking for updates and overwrites the file, removing your setting.
6. Start Tonewell again.

Only edit this file while Tonewell is closed; the app rewrites it when it runs.

To change the language the same way, add `"app.language": "zh-CN"` (for example) to the same file. The accepted codes are zh-CN, zh-TW, en, ja, ko, de, fr, es, it, pt-BR, nl, sv, nb, pl, cs, tr, ru, id, vi, th. A complete file with both settings looks like this: `{"update.auto": false, "app.language": "zh-CN"}`.

Fixed in [0.3.2](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.2) — please update.

The standalone app from the LRCDF project. It works without Lightroom: open your photos, pick a look and a retouch level, and save the finished pictures. Everything runs on your PC.

## Easiest: the Microsoft Store

[**Get Tonewell from the Microsoft Store**](https://apps.microsoft.com/detail/9N5ZZ64N3SN0)

Windows 11, 64-bit. About 3.5 GB. This is the same Tonewell: the Store installs it, keeps it up to date and lets you uninstall it like any other app. There is no warning on first launch and nothing to extract.

## Or download it directly

**Latest version: 0.3.8** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.8)

Tonewell for Windows comes in two parts. **Download both:**

- [Tonewell-Windows-x64-0.3.8-part1.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/tonewell-win-v0.3.8/Tonewell-Windows-x64-0.3.8-part1.zip) (1,687,532,216 bytes)
- [Tonewell-Windows-x64-0.3.8-part2.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/tonewell-win-v0.3.8/Tonewell-Windows-x64-0.3.8-part2.zip) (1,803,657,181 bytes)

| File | SHA-256 |
|---|---|
| `Tonewell-Windows-x64-0.3.8-part1.zip` | `51d9385dda4cc523209b3621dd0eb12ff574f126535fd37dd1f0724edbf68abd` |
| `Tonewell-Windows-x64-0.3.8-part2.zip` | `3a1afcba41c2c277c22a584a5d1ee50058e1397377da4b796e16806639e6813b` |

## What it does

- Finds every face and retouches skin with the same models as the Mac and iPad apps: blemishes, smoothing that keeps real skin texture, under-eye, eyes and teeth.
- Fine control over face and body, and symmetry.
- Looks, stepless fine adjustment and a colour wheel.
- Saves JPEG, JPEG XL and 16-bit TIFF. Originals are never overwritten.
- 20 languages.

## Which PCs

64-bit Windows. An NVIDIA GeForce graphics card (GTX 10 series or newer) is used when present; without one, Tonewell runs on the processor, more slowly. About 6 GB of free disk space is needed for the extracted folder.

## Install

1. Download both files above.
2. Extract both into the same folder with Windows' own Extract All (right-click → Extract All…). Both contain a folder named `Tonewell-Windows-x64-0.3.8`; the two must end up as one folder.
3. Run `Tonewell.exe` in the `Tonewell-Windows-x64-0.3.8` folder. If only one part was extracted, Tonewell says so and closes.

Nothing is installed: Tonewell writes nothing to the registry or the Start menu. Settings live in `%APPDATA%\Tonewell`; to remove Tonewell, delete the Tonewell folder and that one.

## Known limits

- Graphics acceleration is meant to work with NVIDIA GeForce GTX 10 series and newer (GTX 10 and 16, RTX 20, 30, 40 and 50 series) and a recent NVIDIA driver (NVIDIA lists 570.65 or newer for CUDA 12.8; older drivers from 525 on are expected to work for GTX 10 to RTX 40 series, untested). With any other graphics card, or when the card or its driver cannot be used, Tonewell uses the processor and says so in Settings.
- Tested on one PC only (Windows 11 Pro, RTX 3090); figures without a graphics card were measured with the card hidden from the app.
- Without a dedicated graphics card, the preview of a photo with faces is shown first without skin retouching and updates by itself after about 10–20 seconds. Exports always wait for the full result. Large faces can take up to about 2.5 seconds to update after you let go of a slider, and an export takes about 8–25 seconds.
- RAW colour is matched to Tonewell for Mac, but not identical: on a few cameras (for example Sony A7R V, A6700 and A1) strongly saturated greens and reds differ in hue by about 5–7°. Lateral colour correction is not applied to Panasonic files. DNG files from phones and drones (iPhone, DJI) can look different from the Mac version.
- For a camera it does not know, Tonewell may show the camera's own preview instead of the RAW data and says so; Nikon high-efficiency compressed RAW is not supported yet.
- Body reshaping uses a different body detector from the Mac version. When legs are hidden by a long coat or skirt, or a person stands slightly sideways, the two versions can make different choices about which steps to apply or skip, and the strength of some steps differs slightly.
- "Fuller bust" is off for anyone the age model reads as under 18 and cannot be switched on for them. About 0.2–1.7 % of adults are read that way. The model often reads teenagers as older, and the software cannot verify an age you type.
- The same photo exported on different PCs can differ by a few levels out of 255 in a small share of pixels.
- Heavy acne is softened, not removed: at high settings it can still show as soft, uneven patches.
- On faces seen strongly from the side or cut off by the edge of the picture, the lips are protected only when they can be located with confidence; otherwise only eyes, lashes, nostrils and other dark details are protected.
- Results on Windows and on Mac are close but not identical for the same photo: there are small differences at the edges of faces.
- Exporting a Fujifilm X-Trans RAW file takes about 9–14 seconds longer than in 0.3.7, and opening one is about 2–5 % slower. The X-Trans fix was tested with files from the X-T4, X-T5 and X100V.
- 8-bit compressed NEF files from the Nikon Z 8 cannot be opened.
- Not in this version yet: HEIC export, per-person settings, the noise-reduction switch for JPEG photos, the tutorial.

## Updates

Tonewell checks once a day whether a new version is out (switch it off in Settings) and opens this download page; nothing is downloaded or installed by itself. Details are in [`legal/PRIVACY.md`](../legal/PRIVACY.md).

The Microsoft Store edition has no update check of its own: the Store keeps it up to date.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.3.8 | [tonewell-win-v0.3.8](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.8) | Fujifilm X-Trans RAW files give the same picture every time and no faint seams; their export takes about 9–14 s longer |
| 0.3.7 | [tonewell-win-v0.3.7](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.7) | Better blemish removal on heavy acne; eyes and lips left alone on faces seen from the side (as in Mac and iPad 0.3.2 and 0.3.3; 0.3.6 was not released separately) |
| 0.3.5 | [tonewell-win-v0.3.5](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.5) | Faster start; no empty window flashing up at start |
| 0.3.4 | [tonewell-win-v0.3.4](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.4) | Interface text no longer cut off in the 20 languages; faster first start |
| 0.3.3 | [tonewell-win-v0.3.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.3) | Newer graphics library for GeForce GTX 10 to RTX 50 series; style cards show their styles |
| 0.3.2 | [tonewell-win-v0.3.2](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.2) | Fixes the "…" menu and the Settings page |
| 0.3.1 | [tonewell-win-v0.3.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.1) |  |
| 0.3 | [tonewell-win-v0.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3) | First Windows version |

## Licences

Licence texts are attached to each release page, inside the package (`legal` and `licenses` folders, and Settings → Licences in the app), and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [LRCDF for Windows (Lightroom plug-in)](lrcdf-windows.md) · [Tonewell for Mac](tonewell-mac.md) · [Tonewell for iPad](tonewell-ipad.md)
