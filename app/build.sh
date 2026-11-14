#!/bin/sh
# Build LRCDF.app and install it into ~/Applications (where the Lightroom plug-in looks for it).
# usage: app/build.sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP=.build/LRCDF.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LRCDF "$APP/Contents/MacOS/LRCDF"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for f in ../LICENSE ../NOTICE; do [ -f "$f" ] && cp "$f" "$APP/Contents/Resources/"; done      # the licence travels with the app
codesign --force --sign - "$APP" >/dev/null 2>&1
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/LRCDF.app"
cp -R "$APP" "$HOME/Applications/LRCDF.app"
echo "installed $HOME/Applications/LRCDF.app"
