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

Mirror for users in China / 国内镜像: https://gitee.com/YMLFPV/LRCDF (source and release notes; the app download
itself is on GitHub, it is larger than Gitee allows).

## Help us reach the App Store (US$99 a year)

LRCDF is free and made in spare time. To put the iPad app on the App Store, so nobody has to sideload it and
re-install it every 7 days, we need Apple's developer membership: **US$99 a year**. The same membership also lets us
sign the Mac app, so macOS no longer blocks it the first time. A sponsorship page is being set up; the link will be
added here as soon as it is open.

作者没有钱买中国网盘会员，也没有钱交苹果开发者年费。我们想攒 99 美元开通苹果开发者账户，把 iPad 版上架 App Store，
大家就不用侧载、也不用每 7 天重装一次了；Mac 版也能签名，不再被系统拦。赞助通道正在开通，开通后会把链接放在这里。

## Download

The ready-to-use app (everything inside: Python, packages, models, the Lightroom plug-in) is on the
[Releases page](https://github.com/dinghao581-cyber/LRCDF/releases). Unzip, double-click `LRCDF.app`; it installs itself the first time, then open
Lightroom Classic and choose Library → Plug-in Extras → 开始一键修图…. The app is not signed with an Apple developer
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
