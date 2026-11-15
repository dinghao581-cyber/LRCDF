#!/bin/zsh
# macOS build of the iPad app (ad-hoc signed) for the self-tests
cd "$(dirname "$0")"
xcodebuild -project LRCDFPad.xcodeproj -scheme LRCDFPad -destination 'platform=macOS' -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual build 2>&1 | grep -E "^/.*(error|warning): |BUILD (SUCCEEDED|FAILED)" | grep -v "Run script build phase"
