# LRCDF for Mac (Lightroom plug-in)

One-click portrait retouching inside Lightroom Classic, for Apple-silicon Macs. Everything is inside the app: Python, all packages, the models and the Lightroom plug-in. Photos never leave your Mac.

**Latest version: 0.1.6** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.6)

- Download: [LRCDF-macOS-arm64.zip](https://github.com/dinghao581-cyber/LRCDF/releases/latest/download/LRCDF-macOS-arm64.zip)

## What it does

- Darker skin keeps its own depth; medium skin is lifted less.
- The orange/yellow correction of the looks acts on skin only, so wood and warm clothes keep their colour; lips, teeth and eyes are left out.
- Photos handed over from Lightroom open straight in the main window with a small progress line; all photos load in the background.
- Pinch to zoom anywhere on the photo; the preview cache is kept under 3 GB.
- Stepless fine adjustment and a colour wheel.
- Automatic updates that download only the parts that changed (can be switched off in Settings; the app only reads a small public version file).
- **20 languages**: English, Simplified Chinese, Traditional Chinese, Japanese, Korean, Spanish, French, German, Brazilian Portuguese, Italian, Dutch, Russian, Swedish, Norwegian, Polish, Czech, Turkish, Thai, Vietnamese and Indonesian.

## Which Macs

Requires **macOS 14 Sonoma or newer** on a Mac with Apple silicon (M1 or later). Intel Macs are not supported.

| Mac | Chips | Recommendation |
|---|---|---|
| MacBook Air | M1, M2, M3, M4 | Good for everyday portrait sessions. 16 GB memory recommended; 8 GB works for smaller batches. |
| MacBook Pro | M1 Pro/Max through M4 Pro/Max (and M5) | Recommended for large shoots and high-resolution RAW files. |
| Mac mini | M1, M2, M2 Pro, M4, M4 Pro | Good value desktop; 16 GB or more recommended. |
| iMac | M1, M3, M4 | Good for everyday work; 16 GB recommended. |
| Mac Studio | M1 Max/Ultra and later | Best for big batches and 60 MP RAW files. |
| Mac Pro | M2 Ultra | Best for big batches and 60 MP RAW files. |

Memory matters more than the chip: 8 GB is the minimum, 16 GB is recommended, and 24 GB or more keeps large batches of high-resolution RAW files smooth. About 6 GB of free disk space is needed.

## Install

1. Download `LRCDF-macOS-arm64.zip`, unzip it, and move `LRCDF.app` to Applications.
2. Double-click it. The first time, it installs itself into `~/LRCDF` (about a minute). Updating from an older version: replace the app and open it once (or let an earlier version update itself).
3. Open Lightroom Classic (quit and reopen it if it was running), select photos in the Library, then choose Library → Plug-in Extras → Start One-Click Retouch…

The app is not signed with an Apple developer certificate, so macOS blocks it the first time. On macOS 15 and newer: click **Done** in the message (not Move to Trash), open **System Settings → Privacy & Security**, click **Open Anyway** next to the note about LRCDF and enter your login password, then double-click the app again and confirm with **Open Anyway** (the button only shows for about an hour after you tried to open the app). On macOS 14: right-click the app, choose **Open**, then **Open** again. You only do this once.

## Updates

Installed copies from 0.1.2 on update themselves: the app downloads only the parts that changed. You can switch this off in Settings.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.1.6 | [v0.1.6](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.6) |  |
| 0.1.5 | [v0.1.5](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.5) |  |
| 0.1.4 | [v0.1.4](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.4) |  |
| 0.1.3 | [v0.1.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.3) |  |
| 0.1.2 | [v0.1.2](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.2) | release notes only, download withdrawn |
| 0.1.1 | [v0.1.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.1) |  |
| 0.1.0 | [v0.1.0](https://github.com/dinghao581-cyber/LRCDF/releases/tag/v0.1.0) | withdrawn |

## Licences

Licence texts are attached to each release page and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Windows (Lightroom plug-in)](lrcdf-windows.md) · [Tonewell for Mac](tonewell-mac.md) · [Tonewell for iPad](tonewell-ipad.md)
