# LRCDF

One-click portrait retouching for Adobe Lightroom Classic on Apple-silicon Macs. Everything runs on your own
computer; nothing is uploaded.

- **Tone**: a model predicts Lightroom develop settings per photo (several built-in looks, small nudges, and your own
  looks learnt from the photos you have edited).
- **Skin**: frequency separation. Colour and light are evened in the colour layer; pores stay in the texture layer.
  Blemishes, shine, fine lines, under-eye, eyes and teeth; body skin follows the face.
- **Per person**: every person in a shoot can have their own level; men and children start gentler.
- **Automatic level and a guard against over-retouching**: a critic trained on what professional retouchers change
  picks the strongest level that is not too much for each face.
- **Shaping** (optional): face, eyes, waist, chest, legs, by warping only.
- **Even light** (optional): side light made more even from the face's shape; cast shadows where the model can.
- **Selection help**: closed eyes, out of focus, overexposed, near-duplicates.
- A desktop app (SwiftUI) that Lightroom opens: before/after, looks, levels, one button, undo.

## Download

| Version | Download | Requires | Needs Lightroom Classic |
|---|---|---|---|
| **LRCDF for Mac** (Lightroom plug-in) | [Latest release](https://github.com/dinghao581-cyber/LRCDF/releases/latest) | Apple-silicon Mac (M1 or later), macOS 14 or newer | Yes |
| **Tonewell for Mac** (standalone app from the LRCDF project) | [Tonewell for Mac 0.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/tonewell-mac-v0.1) | macOS 14 or newer, Apple silicon or Intel | No |
| **Tonewell for iPad** (standalone app from the LRCDF project) | [Tonewell for iPad 0.1](https://github.com/dinghao581-cyber/LRCDF/releases/tag/ipad-models-1a7b80b619719eda) | iPadOS 27 or newer; installed with your own Apple Account from a Mac or PC | No |
| **LRCDF for Windows** (Lightroom plug-in) | [LRCDF for Windows 0.1.3](https://github.com/dinghao581-cyber/LRCDF/releases/tag/win-v0.1.3) | Windows 10 or 11, 64-bit; CPU package, or CUDA package for NVIDIA graphics cards | Yes |

Mirror: https://gitee.com/YMLFPV/LRCDF (the downloads themselves are on GitHub).

## Help us reach the App Store (US$99 a year)

LRCDF is free and made in spare time. To put the iPad app on the App Store, so nobody has to sideload it and
re-install it every 7 days, we need Apple's developer membership: **US$99 a year**. The same membership also lets us
sign the Mac app, so macOS no longer blocks it the first time. A sponsorship page is being set up; the link will be
added here as soon as it is open.

## Install the Mac plug-in version

The ready-to-use app (everything inside: Python, packages, models, the Lightroom plug-in) is on the
[Releases page](https://github.com/dinghao581-cyber/LRCDF/releases). Unzip, double-click `LRCDF.app`; it installs itself the first time, then open
Lightroom Classic and choose Library → Plug-in Extras → Start One-Click Retouch…. The app is not signed with an Apple developer
certificate, so macOS blocks it the first time. Click Done in the message, open System Settings → Privacy & Security,
click Open Anyway next to the note about LRCDF (enter your login password), then double-click the app again and confirm
with Open Anyway. The button only shows for about an hour after the attempt; right-click → Open no longer works since
macOS 15. You only do this once.

## Status

Research-grade software by a very small team; expect rough edges. Apple-silicon Macs with macOS 14 or newer and Lightroom Classic only.

## Model weights

The source code is Apache-2.0 (see `LICENSE`, `NOTICE`). Model weights are not kept in this repository: they come
with the ready-to-use app on the Releases page. Their terms are described in `legal/`.

## Layout

| Folder | What |
|---|---|
| `lrcdf/` | Library: tone parameters and model, skin retouching, shaping, relighting, people, shadows |
| `scripts/` | Command-line tools the plug-in calls, training and experiment scripts |
| `plugin/LRCDFAuto.lrplugin/` | The Lightroom Classic plug-in (Lua) |
| `app/` | The desktop app (Swift package) |
| `packaging/` | Installer scripts and the all-in-one app builder |
| `legal/` | Privacy policy, terms, model and third-party notices |

## Privacy

No accounts, analytics, telemetry or network use while running. See `legal/PRIVACY.md`.

## Trademarks

Adobe, Lightroom and Lightroom Classic are trademarks of Adobe Inc. This project is independent of Adobe.
