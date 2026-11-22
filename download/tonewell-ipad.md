# Tonewell for iPad

The standalone app from the LRCDF project: one-click portrait retouching that runs entirely on the iPad and does not need Lightroom. Photos never leave the device.

**Latest version: 0.3.4** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-ipad-v0.3.4)

- Download: [Tonewell-iPad-0.3.4.ipa](https://github.com/dinghao581-cyber/LRCDF/releases/download/tonewell-ipad-v0.3.4/Tonewell-iPad-0.3.4.ipa)

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
- Photos straight from the camera: by USB-C cable (Sony A7R V only) or over Wi-Fi with the camera's own FTP transfer (tested only with a Sony A7R V).

## Install

Not on the App Store: you sign it with your own Apple Account.
Download `Tonewell-iPad-0.3.4.ipa` from this page and sign it with AltStore, SideStore or Sideloadly. To get updates in AltStore or SideStore, add the source `https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/update/altstore.json`. The build-from-source route (`ipad/install.sh`) still installs version 0.1; the 0.3 source will follow.

Apps signed with a free Apple Account must be installed again every 7 days (sign the same `.ipa` again). With a paid developer account it lasts a year.

## Updates

The app tells you when a new version is out; if you added the AltStore source above, AltStore offers it. The optional age and sex model (about 78 MB) is downloaded only when you choose it in Settings.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.3.4 | [tonewell-ipad-v0.3.4](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-ipad-v0.3.4) | Sliders respond sooner when you start dragging |
| 0.3.3 | [tonewell-ipad-v0.3.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-ipad-v0.3.3) | Faces seen from the side: eyes and lips are no longer retouched by mistake |
| 0.3.2 | [tonewell-ipad-v0.3.2](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-ipad-v0.3.2) | Live sliders with Noise reduction on; better blemish removal on heavy acne |
| 0.3.1 | [tonewell-ipad-v0.3.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-ipad-v0.3.1) |  |
| 0.3 | [tonewell-ipad-v0.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-ipad-v0.3) |  |
| 0.1 | [ipad-models-1a7b80b619719eda](https://github.com/dinghao581-cyber/LRCDF/releases/tag/ipad-models-1a7b80b619719eda) |  |

## Licences

Licence texts are attached to each release page and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [LRCDF for Windows (Lightroom plug-in)](lrcdf-windows.md) · [Tonewell for Mac](tonewell-mac.md) · [Tonewell for Windows](tonewell-windows.md)
