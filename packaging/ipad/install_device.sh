#!/bin/zsh
# Builds the iPad app and installs it on the iPad connected to this Mac, signed with the Apple ID signed in to Xcode
# (a free Personal Team is enough; such an install stops opening after 7 days: run this again).
# First time on a device: the user trusts the Mac, turns on Developer Mode and trusts the developer on the iPad.
# usage: packaging/ipad/install_device.sh [--run] [--test]   (--run: also open the app; --test: with the self-test launch
#        arguments (TESTHOOKS) - for development only; without it the install has none, like the published .ipa)
set -e
cd "$(dirname "$0")/../../ipad/app"
# the team comes from Xcode's own settings, so no personal ID is written into the (public) project
TEAM=$(plutil -p ~/Library/Preferences/com.apple.dt.Xcode.plist | grep -m1 '"teamID"' | sed 's/.*=> "\(.*\)"/\1/')
[ -n "$TEAM" ] || { echo "No Apple ID in Xcode: Xcode > Settings > Accounts > + > Apple ID, then open ipad/app/LRCDFPad.xcodeproj once."; exit 1; }
DEV=${LRCDF_DEVICE:-}; [[ -n "$DEV" ]] || DEV=$(xcrun devicectl list devices 2>/dev/null | awk '/connected/ && /iPad/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[ -n "$DEV" ] || { echo "No iPad connected (cable, unlocked, 'Trust this computer')."; exit 1; }
~/LRCDF/tools/xcodegen_pkg/xcodegen/bin/xcodegen generate >/dev/null
xcodebuild -project LRCDFPad.xcodeproj -scheme LRCDFPad -configuration Release -destination "id=$DEV" -derivedDataPath build/dev \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  ${${(M)@:#--test}:+SWIFT_ACTIVE_COMPILATION_CONDITIONS=TESTHOOKS} build > build/dev.log 2>&1 \
  || { grep -E "error:" build/dev.log | head; exit 1; }
xcrun devicectl device install app --device "$DEV" build/dev/Build/Products/Release-iphoneos/*.app | grep -E "bundleID|rror"
[[ " $* " == *" --run "* ]] && xcrun devicectl device process launch --device "$DEV" --terminate-existing com.ding.lrcdf.ipad
echo "installed on $DEV"
