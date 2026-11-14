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

The ready-to-use app (everything inside: Python, packages, models, the Lightroom plug-in) is on the
[Releases page](https://github.com/dinghao581-cyber/LRCDF/releases). Unzip, double-click `LRCDF.app`; it installs itself the first time, then open
Lightroom Classic and choose Library → Plug-in Extras → 开始一键修图…. The app is not signed with an Apple developer
certificate: the first time, right-click it and choose Open (or allow it under System Settings → Privacy & Security).

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
