# LRCDF for iPad (Tonewell): let an AI walk you through the install

> How to use: copy this whole document to your AI. That can be a chat AI on the web (DeepSeek, ChatGPT…) or an AI that
> can run commands on your computer (Codex, Claude Code…). Then say "please walk me through installing this".
> The Chinese version (`INSTALL_WITH_AI.md`) is the main one.

---

## For the AI: your task

Guide a **beginner** to install the open-source app Tonewell (from the LRCDF project, iPad version) on their own iPad. The app is
not on the App Store. It is signed with **their own free Apple Account** and then installed. Rules:

1. **One step at a time.**
   - Give the step: a command to copy, or one clear action in an interface.
   - Say what success looks like.
   - Stop and wait for their reply before the next step. Never paste all the steps at once.
2. **Ask two things first:**
   - Mac or Windows computer?
   - iPad model and iPadOS version (Settings → General → About)?

   On a Mac use **Route A**. On Windows only **Route B** works.
3. **Never ask for, and never type in,** any of these:
   - their Apple Account password;
   - verification codes;
   - the iPad passcode;
   - the Mac login password.

   Only they type these, directly into Apple's windows, the iPad or the Mac. For the steps under "Only you can do
   these", tell them where to tap; do not do those steps for them.
4. If you can run commands on their computer, you may run the commands yourself. Still stop for the steps that need
   them. Never run `sudo` (it needs the Mac password): give `sudo` commands to them to run.
5. When they paste an error:
   - look it up in "Common errors" first;
   - if it is not there, ask for the exact text and work it out together;
   - never suggest turning off system security features.
6. Use plain words. Put each command in its own code block, so it is easy to copy.

---

## Before you start

| | |
|---|---|
| iPad | iPadOS 27 or later (Settings → General → About → iPadOS Version) |
| Route A needs | a Mac that can install Xcode 27 from the App Store (if it can't, update macOS first), and a USB-C cable that carries data |
| Route B needs | a Mac or Windows PC that can run Sideloadly or AltStore (third-party signing tools), and a USB-C cable that carries data |
| Apple Account | a free one is enough; no paid developer membership |
| Disk space (Route A) | at least 50 GB free is advised: Xcode is a 3–4 GB download and over 10 GB installed; the iPadOS build component is about an 8 GB download; source and build files are about 2 GB |
| Downloads | Route A: Xcode and the iPadOS component (about 12 GB), source (about 100 MB), editing models (about 102 MB), XcodeGen (about 10 MB). Route B: the app package (about 105 MB) and the signing tool |
| 7-day limit | **an app signed with a free account stops opening after 7 days** (Apple's rule). Reinstall to renew it: Route A, run the script again; Route B, sign again with the tool (AltStore can do it automatically) |
| Is data kept? | Reinstalling **the same app** after 7 days installs over it, so the app's settings stay (look preferences, tethering user name and password). **Deleting the app** and installing again clears them. Finished photos are in the Photos app and are not affected. Photos imported into the app are temporary copies anyway, cleared at each start |
| Other free-account limits | at most 3 self-signed apps at a time, and at most 10 new app identifiers per 7 days |

**What is downloaded from where.** All of these are downloaded by the install itself; the app does not download them
when it runs.
- **Source**: GitHub `https://github.com/dinghao581-cyber/LRCDF` (the main-branch archive).
- **Editing models**: the same repository's release page,
  `releases/download/ipad-models-1a7b80b619719eda/LRCDF-iPad-models-1a7b80b619719eda.zip`.
  - Size: 101,833,631 bytes.
  - SHA-256: `11965296a01e6bde20365a3316127ccbd55b71e74b75cf51c9a1ec9d4c450c6f`.
- **XcodeGen 2.46.0** (an open-source tool that generates the Xcode project):
  `https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip`.
  - SHA-256: `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`.
- **Route B package**: `Tonewell-iPad-<version>.ipa` on the same release page (unsigned, about 105 MB).

The install script checks every checksum and stops if one does not match.

---

## Only you can do these (the AI cannot, and never give it your passwords)

| What | Where | Why it must be you |
|---|---|---|
| Sign in with your Apple Account and type the password and code | Xcode (Route A), or the signing tool (Route B) | it is your account |
| Tap "Trust This Computer" after plugging in, and type the iPad passcode | iPad | only on the iPad |
| Turn on Developer Mode and restart | iPad: Settings → Privacy & Security → Developer Mode | only on the iPad; it restarts, and you confirm once more after unlocking |
| After the first install, trust the developer | iPad: Settings → General → VPN & Device Management → your account under "Developer App" → Trust | only on the iPad |
| Run a command with `sudo`, if one is needed | Mac Terminal | it needs your Mac password |

---

## Route A: Mac and Xcode, from source (recommended)

### A1. Install Xcode
- **Do**: in the Mac App Store, search for **Xcode** and install it (3–4 GB). **Open Xcode once**, accept the licence,
  and wait for it to install its extra components.
- **Success**: Xcode opens to its welcome window.
- **If**:
  - "Requires a newer macOS": update macOS first.
  - Not enough space: free at least 50 GB.

### A2. Sign in to Xcode with your Apple Account (**you**)
- **Do**: Xcode menu **Xcode → Settings → Accounts → + (bottom left) → Apple Account**. Type your account, password and
  code.
- **Success**: your account is listed on the left, and under Team it shows "Your Name (Personal Team)".
- **If** no Personal Team appears: quit Xcode and open it again.

### A3. Connect the iPad and trust the Mac (**you**)
- **Do**: connect the iPad with a USB-C cable and unlock it. When it asks "Trust This Computer?", tap **Trust** and type
  the passcode.
- **Success**: the iPad appears in the Finder sidebar.
- **If** no prompt appears: try a cable that carries data (some only charge), or unplug and plug in again.

### A4. Turn on Developer Mode on the iPad (**you**)
- **Do**: on the iPad, **Settings → Privacy & Security → Developer Mode** (at the bottom) → on → **restart**. After the
  restart, unlock and confirm "Turn On".
- **Success**: the switch is green.
- **If** there is no Developer Mode entry: let Xcode see the iPad once, with Xcode menu **Window → Devices and
  Simulators**. Select the iPad, wait until it is ready, then look in Settings again.

### A5. Run the install script
- **Do**: open Terminal on the Mac (press ⌘ Space and type "Terminal"), paste this line and press Return:
  ```
  curl -fsSL https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/main/ipad/install.sh -o install.sh && zsh install.sh
  ```
- **What it does**: 8 steps, each shown as "【第 n 步】… ✓":
  1. check Xcode;
  2. find your Apple Account;
  3. find the iPad;
  4. download the source;
  5. download the models;
  6. download XcodeGen;
  7. build and sign (3–10 minutes the first time);
  8. install on the iPad.

  It never asks for your password, never uses sudo, and changes no system settings.
- **On an error** it prints "✗ 出错了 …" followed by "下一步 …" (what to do next). Do that, then run the same line again:
  finished steps are skipped.
- **Success**: it ends with "完成。" (done), and the Tonewell icon is on the iPad.
- **Common errors**:

| The script says | Do this |
|---|---|
| Xcode not found, or the Command Line Tools are in use | A1; or run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` (you type the Mac password) |
| Xcode cannot be used yet | open Xcode and accept the licence, or `sudo xcodebuild -license accept` |
| iPadOS build component missing | it is downloaded automatically (about 8 GB); if that fails, Xcode → Settings → Components → iOS |
| no Apple Account in Xcode | A2 |
| no iPad, or the iPad does not trust this Mac | A3, and keep the iPad unlocked |
| Developer Mode is off | A4 |
| download failed, or a checksum does not match | network problem: try another network. GitHub can be slow from mainland China |
| free accounts allow 3 self-signed apps | delete an unused self-signed app on the iPad, then run again |
| the app identifier cannot be used | `LRCDF_BUNDLE_ID=com.yourname.lrcdf zsh install.sh` (letters, digits and dots only) |
| sign in to Xcode again | Xcode → Settings → Accounts (you type the password) |
| the build failed | send the "last errors" lines to the AI |
| several iPads connected | it installs on the first; for another use `LRCDF_DEVICE=<its UDID> zsh install.sh` |

### A6. Trust the developer before the first start (**you**)
- **Do**: if the script says the iPad will not open the app yet: on the iPad, **Settings → General → VPN & Device
  Management → your Apple Account under "Developer App" → Trust**. Then tap Tonewell on the Home Screen.
- **Success**: the app opens and asks "今天想修哪几张？" (which photos today?).

### A7. After 7 days
When the app stops opening, connect the iPad to the same Mac and run the A5 line again. The settings are kept.

---

## Route B: ready-made package and a signing tool (Mac or Windows)

> ⚠️ **Not verified**: we have not yet completed this route with Sideloadly or AltStore. What is verified: this
> unsigned package, signed with a free account, installs on an iPad and opens (signed by hand on a Mac by the
> developer, tested on an iPad mini). The
> steps below follow the tools' own instructions; their screens may differ a little. Both tools are third-party
> software, and you type your Apple Account password into **their** windows; decide whether you trust them. A separate
> Apple Account just for signing is an option.

### B1. Download the package
- **Do**: open `https://github.com/dinghao581-cyber/LRCDF/releases`. Under the latest iPad release, download
  **Tonewell-iPad-<version>.ipa** (about 105 MB).
- **Success**: an `.ipa` file is in your Downloads folder.

### B2. Turn on Developer Mode on the iPad (**you**)
As in A4. Apps installed by signing tools need it too.

### B3 (option 1). Sign and install with Sideloadly (Mac or Windows)
1. Install Sideloadly from `https://sideloadly.io`. On Windows also install iTunes and iCloud from Apple's website
   (**not** from the Microsoft Store); Sideloadly's site links them.
2. Connect and trust the iPad (as in A3). Open Sideloadly: the iPad should show under "iDevice".
3. Drag the `.ipa` into Sideloadly, enter your Apple Account under "Apple ID", and click **Start**.
4. Type the password and code yourself when asked.
5. **Success**: Sideloadly shows Done, and Tonewell is on the iPad.
6. Trust the developer on the iPad (as in A6).
- **If**:
  - the bundle ID is unavailable: tick the option to change the bundle ID in the advanced options, then try again;
  - Windows does not see the iPad: make sure iTunes is Apple's own version and shows the iPad.
- **After 7 days**: sign the same `.ipa` again with Sideloadly.

### B3 (option 2). Sign and install with AltStore (Mac or Windows)
1. Install **AltServer** on the computer from `https://altstore.io`. Windows again needs Apple's iTunes and iCloud.
2. Connect and trust the iPad. In AltServer (Mac menu bar / Windows tray) choose **Install AltStore** → your iPad, and
   type your Apple Account password (**you**).
3. Trust the developer on the iPad (as in A6), then open AltStore.
4. Put the `.ipa` into the iPad's Files app (AirDrop or iCloud Drive).
5. In AltStore choose **My Apps → + (top left)**, then pick the `.ipa`.
6. **Success**: Tonewell is in My Apps and on the Home Screen.
- **After 7 days**: AltStore renews by itself while AltServer runs on the computer on the same Wi-Fi. "Refresh All" in
  My Apps does it by hand.
- **Note**: AltStore itself uses one of the 3 self-signed app slots.

---

## Questions

- **"Untrusted Developer" when opening the app**: A6.
- **It stopped opening after 7 days**: Route A, run the script again. Route B, sign again. Do not delete the app:
  deleting clears its settings.
- **The app says a new version exists**:
  - Route A: run the script again; it fetches the latest source.
  - Route B: download the new `.ipa` and sign it again.
- **To remove it**: press and hold the icon on the Home Screen → Remove App.
