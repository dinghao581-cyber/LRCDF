#!/bin/zsh
# The iPad app as an unsigned .ipa for AltStore / SideStore (they sign it with the user's own Apple ID).
# usage: packaging/ipad/make_ipa.sh [output folder, default ~/LRCDF/dist]   -> LRCDF-iPad-<version>.ipa
set -e
cd "$(dirname "$0")/../../ipad/app"      # the iPad project (models and build products are not in git: docs/update/IPAD.md)
OUT="${1:-$HOME/LRCDF/dist}"; mkdir -p "$OUT"
~/LRCDF/tools/xcodegen_pkg/xcodegen/bin/xcodegen generate >/dev/null
xcodebuild -project LRCDFPad.xcodeproj -scheme LRCDFPad -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/ipa CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=$(ls -d build/ipa/Build/Products/Release-iphoneos/*.app | head -1)
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
TMP=$(mktemp -d); mkdir "$TMP/Payload"; ditto "$APP" "$TMP/Payload/$(basename "$APP")"
find "$TMP" -name "._*" -delete
(cd "$TMP" && zip -qry "$OUT/LRCDF-iPad-$VER.ipa" Payload)
rm -rf "$TMP"
ls -la "$OUT/LRCDF-iPad-$VER.ipa"; shasum -a 256 "$OUT/LRCDF-iPad-$VER.ipa"
