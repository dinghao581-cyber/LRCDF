#!/bin/sh
# Puts the licence texts the app shows (Settings > Licences and credits) into a built app. Stops if one is missing.
# Used by build.sh and packaging/make_bundle.sh.   usage: app/copy_licenses.sh <App>/Contents/Resources
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$1/licenses"
for f in legal/licenses/APPLE_ML_RESEARCH_MODEL_LICENSE.txt legal/MODEL_LICENSES.md legal/THIRD_PARTY_NOTICES.md NOTICE LICENSE; do
    [ -s "$ROOT/$f" ] || { echo "STOP: $f is missing"; exit 1; }
    cp "$ROOT/$f" "$1/licenses/"
done
