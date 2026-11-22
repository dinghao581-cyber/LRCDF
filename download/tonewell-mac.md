# Tonewell for Mac

The standalone app from the LRCDF project. It works without Lightroom: open your photos, pick a look and a retouch level, and save the finished pictures. Everything runs on your Mac.

**Latest version: 0.3.2** · [release page](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-mac-v0.3.2)

- Download: [Tonewell-macOS-0.3.2.zip](https://github.com/dinghao581-cyber/LRCDF/releases/download/tonewell-mac-v0.3.2/Tonewell-macOS-0.3.2.zip)

## What it does

- Finds every face and retouches skin with the same models as the iPad app: blemishes, smoothing that keeps real skin texture, under-eye, eyes and teeth.
- Looks, stepless fine adjustment and a colour wheel; shaping; noise reduction for high-ISO JPEG and HEIC photos.
- Open photos with ⌘O or drag photos and folders onto the window; save with ⌘S as JPEG, HEIC or 16-bit TIFF. Originals are never overwritten (files are named `<name>-Tonewell`).
- Undo and redo (⌘Z / ⇧⌘Z), zoom with the mouse wheel or a pinch.
- Tells you when a new version is out.

## Which Macs

macOS 14 Sonoma or newer, on Apple silicon or Intel (not yet tested on an Intel Mac). On macOS 26 the app uses Liquid Glass; on 14 and 15 it uses plain dark panels. 8 GB should be enough but has not been tested; measured on a 48 GB Mac, a 60 MP RAW peaks at about 4.5 GB including export.

## Install

1. Download `Tonewell-macOS-0.3.2.zip`, unzip it and move `Tonewell.app` to Applications (replace an earlier Tonewell if you have it).
2. The app is not signed with an Apple developer certificate, so macOS blocks it the first time. On macOS 15 and newer: click **Done** in the message, open **System Settings → Privacy & Security**, click **Open Anyway** next to the note about Tonewell and enter your login password, then open the app again and confirm with **Open Anyway**. On macOS 14: right-click the app, choose **Open**, then **Open** again. You only do this once.

## Updates

The app tells you when a new version is out; download it from this page. The optional age and sex model (about 78 MB) is downloaded only when you choose it in Settings.

## All versions

| Version | Release page | Note |
|---|---|---|
| 0.3.2 | [tonewell-mac-v0.3.2](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-mac-v0.3.2) | Live sliders with Noise reduction on; better blemish removal on heavy acne |
| 0.3.1 | [tonewell-mac-v0.3.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-mac-v0.3.1) |  |
| 0.3 | [tonewell-mac-v0.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-mac-v0.3) |  |
| 0.1 | [tonewell-mac-v0.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-mac-v0.1) |  |

## Licences

Licence texts are attached to each release page and kept in [`legal/`](../legal/) in this repository.

Other versions: [LRCDF for Mac (Lightroom plug-in)](lrcdf-mac.md) · [LRCDF for Windows (Lightroom plug-in)](lrcdf-windows.md) · [Tonewell for iPad](tonewell-ipad.md) · [Tonewell for Windows](tonewell-windows.md)
