# Tonewell for Windows

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

A fix (0.3.2) is being prepared.

The standalone app from the LRCDF project. It works without Lightroom: open your photos, pick a look and a retouch level, and save the finished pictures. Everything runs on your PC.

**Latest version: 0.3.1** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.1)

Tonewell for Windows comes in two parts. **Download both:**

- [Tonewell-Windows-x64-0.3.1-part1.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/tonewell-win-v0.3.1/Tonewell-Windows-x64-0.3.1-part1.zip) (1,456,432,911 bytes)
- [Tonewell-Windows-x64-0.3.1-part2.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/tonewell-win-v0.3.1/Tonewell-Windows-x64-0.3.1-part2.zip) (1,580,467,204 bytes)

| File | SHA-256 |
|---|---|
| `Tonewell-Windows-x64-0.3.1-part1.zip` | `54062266b2995a7b6e86f85d3751f4fe96ae281c139ee86841534f0af1628643` |
| `Tonewell-Windows-x64-0.3.1-part2.zip` | `76d66ce38ee724e034efcbf62c51c8181588be5c82cca7f4b9315a310c21ac2b` |

## What it does

- Finds every face and retouches skin with the same models as the Mac and iPad apps: blemishes, smoothing that keeps real skin texture, under-eye, eyes and teeth.
- Fine control over face and body, and symmetry.
- Looks, stepless fine adjustment and a colour wheel.
- Saves JPEG, JPEG XL and 16-bit TIFF. Originals are never overwritten.
- 20 languages.

## Which PCs

64-bit Windows. An NVIDIA graphics card is used when present; without one, Tonewell runs on the processor, more slowly. About 5 GB of free disk space is needed for the extracted folder.

## Install

1. Download both files above.
2. Extract both into the same folder with Windows' own Extract All (right-click → Extract All…). Both contain a folder named `Tonewell-Windows-x64-0.3.1`; the two must end up as one folder.
3. Run `Tonewell.exe` in the `Tonewell-Windows-x64-0.3.1` folder. If only one part was extracted, Tonewell says so and closes.

Nothing is installed: Tonewell writes nothing to the registry or the Start menu. Settings live in `%APPDATA%\Tonewell`; to remove Tonewell, delete the Tonewell folder and that one.

## Known limits

- Tested on one PC only (Windows 11 Pro, RTX 3090); figures without a graphics card were measured with the card hidden from the app.
- Without a dedicated graphics card, the preview of a photo with faces is shown first without skin retouching and updates by itself after about 10–20 seconds. Exports always wait for the full result. Large faces can take up to about 2.5 seconds to update after you let go of a slider, and an export takes about 8–25 seconds.
- RAW colour is matched to Tonewell for Mac, but not identical: on a few cameras (for example Sony A7R V, A6700 and A1) strongly saturated greens and reds differ in hue by about 5–7°. Lateral colour correction is not applied to Panasonic files. DNG files from phones and drones (iPhone, DJI) can look different from the Mac version.
- For a camera it does not know, Tonewell may show the camera's own preview instead of the RAW data and says so; Nikon high-efficiency compressed RAW is not supported yet.
- Body reshaping uses a different body detector from the Mac version. When legs are hidden by a long coat or skirt, or a person stands slightly sideways, the two versions can make different choices about which steps to apply or skip, and the strength of some steps differs slightly.
- "Fuller bust" is off for anyone the age model reads as under 18 and cannot be switched on for them. About 0.2–1.7 % of adults are read that way. The model often reads teenagers as older, and the software cannot verify an age you type.
- The same photo exported on different PCs can differ by a few levels out of 255 in a small share of pixels.
- Not in this version yet: HEIC export, per-person settings, the noise-reduction switch for JPEG photos, the tutorial.

## Updates

Tonewell checks once a day whether a new version is out (switch it off in Settings) and opens this download page; nothing is downloaded or installed by itself. Details are in [`legal/PRIVACY.md`](../legal/PRIVACY.md).

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.3.1 | [tonewell-win-v0.3.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3.1) |  |
| 0.3 | [tonewell-win-v0.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-win-v0.3) | First Windows version |

## Licences

Licence texts are attached to each release page, inside the package (`legal` and `licenses` folders, and Settings → Licences in the app), and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [LRCDF for Windows (Lightroom plug-in)](lrcdf-windows.md) · [Tonewell for Mac](tonewell-mac.md) · [Tonewell for iPad](tonewell-ipad.md)
