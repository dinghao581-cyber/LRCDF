#!/bin/sh
# Puts the app's texts into a built app: brings the String Catalog in line with Strings.swift and compiles it into
# <Resources>/<language>.lproj. Used by build.sh and packaging/make_bundle.sh.
# usage: app/localize.sh <App>/Contents/Resources        (PSEUDO=1: add a made-up, 40 % wider "en" for layout checks)
set -e
cd "$(dirname "$0")"
python3 strings.py >/dev/null
CATALOG=Localizable.xcstrings
if [ -n "$PSEUDO" ]; then mkdir -p .build/pseudo; CATALOG=.build/pseudo/Localizable.xcstrings; python3 strings.py --pseudo "$CATALOG"; fi
xcrun xcstringstool compile "$CATALOG" --output-directory "$1"
