#!/bin/sh
# Writes into the built app binary that it was made for macOS 26 while it still runs from macOS 14.
# SwiftPM records the SDK as the minimum version it is given (14.0 since 2026-11-17), and macOS 26 then draws the app
# in its compatibility look: other switches, other window buttons. Builds before that recorded 26.0 (minimum 26.0);
# this keeps exactly that, so the app looks on macOS 26 as it did, pixel for pixel (checked on nine screens).
# usage: app/stamp_sdk.sh <binary>
set -e
vtool -set-build-version macos 14.0 26.0 -replace -output "$1.stamped" "$1" 2>/dev/null
mv "$1.stamped" "$1"
