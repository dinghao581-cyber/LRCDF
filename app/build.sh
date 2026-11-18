#!/bin/sh
# Build LRCDF.app and install it into ~/Applications (where the Lightroom plug-in looks for it).
# usage: app/build.sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=.build/LRCDF.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LRCDF "$APP/Contents/MacOS/LRCDF"
./stamp_sdk.sh "$APP/Contents/MacOS/LRCDF"      # made for macOS 26, runs from 14 (see the script)
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ../packaging/update_install.sh "$APP/Contents/Resources/"      # the updater's installer (Updater.swift)
./localize.sh "$APP/Contents/Resources"      # the texts, in every language of Localizable.xcstrings
for f in ../LICENSE ../NOTICE; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"; done      # the licence travels with the app
./copy_licenses.sh "$APP/Contents/Resources"      # the texts shown in Settings > Licences and credits
codesign --force --sign - "$APP" >/dev/null 2>&1
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/LRCDF.app"
cp -R "$APP" "$HOME/Applications/LRCDF.app"
echo "installed $HOME/Applications/LRCDF.app"
