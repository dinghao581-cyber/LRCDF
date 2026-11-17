#!/bin/zsh
# Tonewell (the Mac app without Lightroom; the iPad app's code built for macOS) as a zip for the release page.
# Ad-hoc signed, sandboxed, macOS 14+ (Liquid Glass from 26). Checks the BUILT app before zipping: no test hooks, no
# local paths, no working notes (the 0.1.0 lesson: grep the artefact, not only the source).
# usage: packaging/studio/make_studio.sh [output folder, default ~/LRCDF/dist/studio]  -> Tonewell-macOS-<version>.zip
set -e
cd "$(dirname "$0")/../../ipad/app"
OUT="${1:-$HOME/LRCDF/dist/studio}"; mkdir -p "$OUT"
[ -d LRCDF/models ] || { echo "STOP: ipad/app/LRCDF/models is missing (the models are not in git: docs/update/IPAD.md)"; exit 1; }
~/LRCDF/tools/xcodegen_pkg/xcodegen/bin/xcodegen generate >/dev/null
rm -rf build/studio_rel
xcodebuild -project LRCDFPad.xcodeproj -scheme LRCDFPad -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/studio_rel CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="build/studio_rel/Build/Products/Release/Tonewell.app"
[ -d "$APP" ] || { echo "STOP: no app built"; exit 1; }
EXE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.ding.lrcdf.studio ] || { echo "STOP: wrong bundle id"; exit 1; }
# debug symbols carry this machine's build paths: strip, then sign again (ad-hoc, with the entitlements it was built with)
ENT=$(mktemp); codesign -d --entitlements - --xml "$APP" > "$ENT" 2>/dev/null
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENT" >/dev/null 2>&1 || true      # a debugging permission: not in a published app
xcrun strip -S -x "$EXE"
codesign --force --sign - --entitlements "$ENT" "$APP"; rm -f "$ENT"
codesign --verify --strict "$APP" || { echo "STOP: signature"; exit 1; }
# the published app must not carry the self-test launch arguments (TESTHOOKS builds only)
if strings -a "$EXE" | grep -qE -- '--(skinlab|selftest|snapshot|loadall|profile|denoise)'; then echo "STOP: test hooks in the release build"; exit 1; fi
# no local paths anywhere in the app, no working notes
if grep -rlaE '/(Users|Volumes)/' "$APP" | grep -v '\.mlmodelc/' | head -1 | grep -q .; then
  echo "STOP: local paths in:"; grep -rlaE '/(Users|Volumes)/' "$APP" | grep -v '\.mlmodelc/' | head; exit 1
fi
if find "$APP" \( -name 'CLAUDE.md' -o -name 'HANDOVER*' -o -name '._*' -o -name '.DS_Store' \) | grep -q .; then echo "STOP: notes or Finder files inside"; exit 1; fi
[ "$(lipo -archs "$EXE")" = "x86_64 arm64" ] || echo "note: architectures $(lipo -archs "$EXE")"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow && { echo "STOP: get-task-allow still in the signature"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
ZIP="$OUT/Tonewell-macOS-$VER.zip"; rm -f "$ZIP"
# --norsrc: without it the zip carried 69 "._" files; a plain unzip then broke the seal ("a sealed resource is missing")
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
# the zip as a user gets it: plain unzip, no "._" files, the signature intact
CHK=$(mktemp -d); (cd "$CHK" && unzip -q "$ZIP")
if find "$CHK" -name "._*" | grep -q .; then echo "STOP: ._ files in the zip"; rm -rf "$CHK"; exit 1; fi
codesign --verify --deep --strict "$CHK/Tonewell.app" || { echo "STOP: the unzipped app does not verify"; rm -rf "$CHK"; exit 1; }
rm -rf "$CHK"
echo "Tonewell $VER (macOS $MIN+)"; ls -l "$ZIP" | awk '{print $5, $9}'; shasum -a 256 "$ZIP"
unzip -l "$ZIP" | tail -1
