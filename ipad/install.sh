#!/bin/zsh
# Tonewell (LRCDF) for iPad: built from source, signed with your own free Apple Account, installed on the iPad connected
# to this Mac by USB.
#
# Usage (in the Mac's Terminal):
#   curl -fsSL https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/main/ipad/install.sh -o install.sh && zsh install.sh
# or, in a downloaded copy of the source: zsh ipad/install.sh
#
# What it does: checks Xcode → finds the Apple Account you signed in to Xcode with (team ID) → finds the connected iPad →
# downloads the source, the editing models and the project generator XcodeGen (checksums checked) → builds and signs →
# installs on the iPad. It stops at the first problem and says what to do next.
# It never asks for your password or a code, never uses sudo, changes no system settings and uploads nothing.
# An app signed with a free account stops opening after 7 days: run this script again then (it installs over the same
# app; the app's settings are kept).
#
# Optional environment variables (rarely needed):
#   LRCDF_WORK      working folder (default ~/LRCDF-iPad)    LRCDF_DEVICE    the iPad's UDID (when several are connected)
#   LRCDF_TEAM      team ID                                   LRCDF_BUNDLE_ID the app's identifier (default: from the team ID)
#   LRCDF_SOURCE    source: a local folder or a .tar.gz URL   LRCDF_MODELS_URL URL of the models zip (file:// works)
set -u

REPO="dinghao581-cyber/LRCDF"
SOURCE="${LRCDF_SOURCE:-https://github.com/$REPO/archive/refs/heads/main.tar.gz}"
MODELS_VERSION="1a7b80b619719eda"
MODELS_SHA256="11965296a01e6bde20365a3316127ccbd55b71e74b75cf51c9a1ec9d4c450c6f"
MODELS_URL="${LRCDF_MODELS_URL:-https://github.com/$REPO/releases/download/ipad-models-$MODELS_VERSION/LRCDF-iPad-models-$MODELS_VERSION.zip}"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
WORK="${LRCDF_WORK:-$HOME/LRCDF-iPad}"

n=0
step() { n=$((n + 1)); print -P "\n%B[Step $n] $1%b" }
ok()   { print "  ✓ $1" }
fail() { print -P "\n%B✗ Problem: $1%b"; print "  Next: $2"; print "  (Then run this script again; finished steps are skipped.)"; exit 1 }
need_sha() {      # file, expected sha256
  local got; got=$(shasum -a 256 "$1" | awk '{print $1}')
  [[ "$got" == "$2" ]] || { rm -f "$1"; fail "the downloaded file's checksum does not match (incomplete or altered download): $1" "check your network and run again; if it keeps failing, send this line to your AI or the developer."; }
}
fetch() {         # url, destination
  print "  Downloading: $1"
  curl -fL --retry 3 --progress-bar -o "$2.part" "$1" || { rm -f "$2.part"; fail "download failed: $1" "check your network (can you open github.com?). GitHub can be slow or unreachable on some networks: try another one."; }
  mv "$2.part" "$2"
}

print -P "%BTonewell for iPad: install from source%b (working folder $WORK)"
mkdir -p "$WORK" || fail "cannot create the working folder $WORK" "use another folder: LRCDF_WORK=~/some-folder zsh install.sh"

# ---------------------------------------------------------------------------------------------------------------
step "Check Xcode"
[[ "$(uname -s)" == Darwin ]] || fail "this script only runs on a Mac" "on Windows, use Route B of the guide (the ready-made package and Sideloadly)."
XDIR=$(xcode-select -p 2>/dev/null)
if [[ -z "$XDIR" || "$XDIR" != *Xcode*.app* ]]; then
  if [[ -d /Applications/Xcode.app ]]; then
    fail "Xcode is installed, but the system is using the Command Line Tools instead" "in Terminal run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer (it asks for your Mac password: type it yourself)"
  fi
  fail "Xcode not found" "open the App Store on your Mac, search for Xcode and install it (a 3-4 GB download). Then open Xcode once, accept the licence and let it install its components."
fi
XVER=$(xcodebuild -version 2>&1 | head -1)
[[ "$XVER" == Xcode* ]] || fail "Xcode cannot be used yet: $XVER" "open Xcode once and accept the licence, or run sudo xcodebuild -license accept in Terminal (type your Mac password yourself)."
XMAJOR=$(print "$XVER" | sed -E 's/Xcode ([0-9]+).*/\1/')
(( XMAJOR >= 27 )) || fail "Xcode is too old ($XVER); this app needs Xcode 27 or later" "update Xcode in the App Store."
ok "$XVER"
if ! xcodebuild -showsdks 2>/dev/null | grep -q iphoneos; then
  print "  The iPadOS build component is missing; downloading it now (about 8 GB, this takes a while)…"
  xcodebuild -downloadPlatform iOS || fail "the iPadOS component did not download" "open Xcode → Settings → Components and click the download next to iOS."
fi
ok "iPadOS build component ready"

# ---------------------------------------------------------------------------------------------------------------
step "Find the Apple Account you signed in to Xcode with"
TEAM="${LRCDF_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  TEAM=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
teams = [t for v in d.get("IDEProvisioningTeamByIdentifier", {}).values() for t in v]
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam", False))   # a personal (free) team first
print(teams[0]["teamID"] if teams else "")' 2>/dev/null)
fi
[[ -n "$TEAM" ]] || fail "no Apple Account in Xcode yet" "open Xcode → menu Xcode → Settings → Accounts → + (bottom left) → Apple Account, and sign in with your own Apple Account. Type the password and code only into Xcode, yourself; never give them to anyone or to an AI. Afterwards your name and \"(Personal Team)\" appear on the left."
ok "Team ID: $TEAM"
BUNDLE="${LRCDF_BUNDLE_ID:-com.ding.lrcdf.ipad.${(L)TEAM}}"      # one fixed identifier per account: reinstalling keeps the app's data
ok "App identifier: $BUNDLE"

# ---------------------------------------------------------------------------------------------------------------
step "Find the connected iPad"
DEVJSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1
DEVINFO=$(python3 - "$DEVJSON" "${LRCDF_DEVICE:-}" <<'PY'
import json, sys
try: devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devs = []
want = sys.argv[2]
ipads = [d for d in devs if "iPad" in (d.get("hardwareProperties", {}).get("productType") or "")
         and (not want or d.get("hardwareProperties", {}).get("udid") == want)]
for d in ipads:
    c, p, h = d.get("connectionProperties", {}), d.get("deviceProperties", {}), d.get("hardwareProperties", {})
    print("|".join([h.get("udid", ""), p.get("name", "iPad"), c.get("pairingState", ""), c.get("tunnelState", ""),
                    p.get("developerModeStatus", ""), p.get("osVersionNumber", ""), h.get("marketingName", "")]))
PY
)
rm -f "$DEVJSON"
[[ -n "$DEVINFO" ]] || fail "no iPad found" "connect the iPad to this Mac with a USB-C cable and unlock it. When it asks \"Trust This Computer?\", tap Trust and type the iPad passcode (yourself)."
COUNT=$(print "$DEVINFO" | wc -l | tr -d ' ')
IFS='|' read -r DEV DNAME PAIR TUNNEL DEVMODE OSV MODEL <<< "$(print "$DEVINFO" | head -1)"
(( COUNT > 1 )) && print "  $COUNT iPads connected; installing on the first ($MODEL). For another: LRCDF_DEVICE=<its UDID> zsh install.sh"
[[ "$PAIR" == paired ]] || fail "the iPad does not trust this Mac yet (state: $PAIR)" "unlock the iPad and tap Trust in \"Trust This Computer?\", then type the iPad passcode. If nothing appears, unplug and plug in again."
[[ "$DEVMODE" == enabled ]] || fail "Developer Mode is off on the iPad (state: $DEVMODE)" "on the iPad: Settings → Privacy & Security → Developer Mode (at the bottom) → on → restart when asked, and confirm \"Turn On\" after unlocking. If the switch is missing, let Xcode see the iPad once (Xcode → menu Window → Devices and Simulators, select the iPad) and look again."
OSMAJOR=${OSV%%.*}
[[ -z "$OSMAJOR" ]] || (( OSMAJOR >= 27 )) || fail "the iPad's system is too old (iPadOS $OSV); iPadOS 27 or later is needed" "on the iPad: Settings → General → Software Update."
ok "$MODEL (iPadOS $OSV), trusted, Developer Mode on"

# ---------------------------------------------------------------------------------------------------------------
step "Get the source"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [[ -z "${LRCDF_SOURCE:-}" && -f "$HERE/app/project.yml" ]]; then
  ROOT=$(cd "$HERE/.." && pwd); ok "using the source this script is in: $ROOT"
elif [[ -d "$SOURCE" && -f "$SOURCE/ipad/app/project.yml" ]]; then
  ROOT=$(cd "$SOURCE" && pwd); ok "using the source folder: $ROOT"
else
  ROOT="$WORK/src"
  rm -rf "$ROOT.new"; mkdir -p "$ROOT.new"
  fetch "$SOURCE" "$WORK/source.tar.gz"
  tar -xzf "$WORK/source.tar.gz" -C "$ROOT.new" --strip-components 1 || fail "the source archive cannot be unpacked" "delete $WORK and run again."
  [[ -f "$ROOT.new/ipad/app/project.yml" ]] || fail "the downloaded source has no iPad project" "check that the address is Tonewell's repository; send this line to the developer."
  if [[ -d "$ROOT/ipad/app/LRCDF/models" ]]; then mv "$ROOT/ipad/app/LRCDF/models" "$ROOT.new/ipad/app/LRCDF/models"; fi   # keep downloaded models
  rm -rf "$ROOT"; mv "$ROOT.new" "$ROOT"; rm -f "$WORK/source.tar.gz"
  ok "source in $ROOT"
fi
APPDIR="$ROOT/ipad/app"

# ---------------------------------------------------------------------------------------------------------------
step "Get the editing models (about a 102 MB download, 110 MB unpacked)"
MODELS="$APPDIR/LRCDF/models"
HAVE=""; [[ -d "$MODELS" ]] && HAVE=$(python3 "$ROOT/packaging/ipad/models_version.py" "$APPDIR/LRCDF" 2>/dev/null)
if [[ "$HAVE" == "$MODELS_VERSION" ]]; then
  ok "models ready (version $MODELS_VERSION)"
else
  ZIP="$WORK/LRCDF-iPad-models-$MODELS_VERSION.zip"
  [[ -f "$ZIP" ]] || fetch "$MODELS_URL" "$ZIP"
  need_sha "$ZIP" "$MODELS_SHA256"
  rm -rf "$MODELS"
  unzip -q "$ZIP" -d "$APPDIR/LRCDF" || fail "the models zip cannot be unpacked" "delete $ZIP and run again."
  HAVE=$(python3 "$ROOT/packaging/ipad/models_version.py" "$APPDIR/LRCDF" 2>/dev/null)
  [[ "$HAVE" == "$MODELS_VERSION" ]] || fail "the models' version does not match this source (got $HAVE)" "the source is newer or older than the models: download the latest install.sh and run it again."
  ok "models ready (version $MODELS_VERSION, checksum OK)"
fi

# ---------------------------------------------------------------------------------------------------------------
step "Get the project generator XcodeGen"
XG="$WORK/tools/xcodegen/bin/xcodegen"
if [[ ! -x "$XG" ]]; then
  mkdir -p "$WORK/tools"; fetch "$XCODEGEN_URL" "$WORK/tools/xcodegen.zip"
  need_sha "$WORK/tools/xcodegen.zip" "$XCODEGEN_SHA256"
  unzip -qo "$WORK/tools/xcodegen.zip" -d "$WORK/tools" || fail "XcodeGen cannot be unpacked" "delete $WORK/tools and run again."
fi
(cd "$APPDIR" && "$XG" generate --quiet) || fail "the Xcode project could not be generated" "send the error above to your AI or the developer."
ok "Xcode project generated"

# ---------------------------------------------------------------------------------------------------------------
step "Build and sign (3-10 minutes the first time)"
LOG="$WORK/build.log"
(cd "$APPDIR" && xcodebuild -project LRCDFPad.xcodeproj -scheme LRCDFPad -configuration Release -destination "id=$DEV" \
   -derivedDataPath "$WORK/build" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
   DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build > "$LOG" 2>&1)
if [[ $? -ne 0 ]]; then
  print "  Last errors:"; grep -E "error:" "$LOG" | sort -u | head -5 | sed 's/^/    /'
  if grep -q -i -E "maximum number of apps|app id limit" "$LOG"; then
    fail "a free account allows 3 self-signed apps at a time and 10 new app identifiers per 7 days" "delete a self-signed app you no longer use from the iPad, or wait a few days."
  elif grep -q -i -E "is not available|cannot be registered|already (in use|taken)" "$LOG"; then
    fail "the app identifier $BUNDLE cannot be used" "use another one: LRCDF_BUNDLE_ID=com.yourname.lrcdf zsh install.sh"
  elif grep -q -i -E "No Account for Team|No accounts|sign in|session has expired" "$LOG"; then
    fail "Xcode needs you to sign in to your Apple Account again" "Xcode → Settings → Accounts, select your account and sign in again (type the password and code yourself)."
  elif grep -q -i -E "locked|Developer Mode" "$LOG"; then
    fail "the iPad is locked or Developer Mode is off" "unlock the iPad, keep the screen on and run again."
  else
    fail "the build failed (full log in $LOG)" "send the error lines above to your AI. Often Xcode is still installing components on first use: wait a few minutes and run again."
  fi
fi
APP=$(ls -d "$WORK/build/Build/Products/Release-iphoneos/"*.app 2>/dev/null | head -1)
[[ -n "$APP" ]] || fail "the built app was not found" "send the last lines of $LOG to your AI."
ok "build finished"

# ---------------------------------------------------------------------------------------------------------------
step "Install on the iPad"
xcrun devicectl device install app --device "$DEV" "$APP" > "$WORK/install.log" 2>&1 \
  || { tail -5 "$WORK/install.log" | sed 's/^/    /'; fail "installation failed" "keep the iPad unlocked and connected and run again; if it still fails, send the lines above to your AI."; }
ok "installed on $MODEL"
if xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE" > "$WORK/launch.log" 2>&1; then
  ok "app opened"
else
  print "  The app is installed, but the iPad will not open it yet (normal the first time). On the iPad:"
  print "  Settings → General → VPN & Device Management → your Apple Account under \"Developer App\" → Trust. Then tap Tonewell on the Home Screen."
fi
print -P "\n%BDone.%b An app signed with a free Apple Account stops opening after 7 days: then connect the iPad to this Mac and run this script again (the app's settings are kept)."
