# Tonewell for iPad

The standalone app from the LRCDF project: one-click portrait retouching that runs entirely on the iPad and does not need Lightroom. Photos never leave the device.

**Latest version: 0.1** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/ipad-models-1a7b80b619719eda)

- Download: [Tonewell-iPad-0.1.ipa](https://github.com/dinghao581-cyber/LRCDF/releases/download/ipad-models-1a7b80b619719eda/Tonewell-iPad-0.1.ipa)

## Requirements

iPadOS 27 or newer.

| iPad | Recommendation |
|---|---|
| iPad Pro (M4, M5) | Best: 60 MP RAW files and large group photos with ease. |
| iPad Pro (M1, M2), iPad Air (M1 or later) | Very good for everyday portrait sessions, including RAW. |
| iPad mini (A17 Pro or later) | Good for portraits and JPEG/HEIC; fine for RAW one photo at a time. |
| iPad (A16 or later) | Works for JPEG/HEIC portraits. |

8 GB of memory or more is recommended for high-resolution RAW files.

## What it does

- Finds every face and retouches skin with the same models as the Mac version: blemishes, smoothing that keeps real skin texture, under-eye, eyes and teeth.
- Darker skin keeps its own depth; the looks' orange correction acts on skin only.
- Looks, stepless fine adjustment, full-size export.
- Noise reduction for high-ISO JPEG and HEIC photos (not for RAW).
- Photos straight from the camera over USB-C or Wi-Fi (FTP).

## Install

(not on the App Store; you sign it with your own Apple Account)
The easiest way is to let an AI assistant guide you: give it [`ipad/INSTALL_WITH_AI.md`](https://github.com/dinghao581-cyber/LRCDF/blob/main/ipad/INSTALL_WITH_AI.md).
- **Route A, from source (Mac with Xcode):** run
  `curl -fsSL https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/main/ipad/install.sh -o install.sh && zsh install.sh`
  It downloads the source and the model package from the release page, checks them and installs the app on your connected iPad.
- **Route B, ready-made app:** download `Tonewell-iPad-0.1.ipa` from this page and sign it with Sideloadly or AltStore.

Apps signed with a free Apple Account must be installed again every 7 days (run the script again, or sign the same `.ipa` again). With a paid developer account it lasts a year.

## Updates

The app tells you when a new version is out. Install it the same way as before.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.1 | [ipad-models-1a7b80b619719eda](https://github.com/dinghao581-cyber/LRCDF/releases/tag/ipad-models-1a7b80b619719eda) |  |

## Licences

Licence texts are attached to each release page and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [LRCDF for Windows (Lightroom plug-in)](lrcdf-windows.md) · [Tonewell for Mac](tonewell-mac.md)
