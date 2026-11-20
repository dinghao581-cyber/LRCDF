#!/bin/sh
# Puts the licence texts the app shows (Settings > Licences and credits) into a built app.
# Everything in legal/licenses goes in. Stops if a text is missing, or if the window's list and the folder disagree.
# Used by build.sh and packaging/make_bundle.sh.   usage: app/copy_licenses.sh <App>/Contents/Resources
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="$ROOT/app/Sources/LRCDF/Licences.swift"
mkdir -p "$1/licenses"
for f in "$ROOT"/legal/licenses/* "$ROOT/legal/MODEL_LICENSES.md" "$ROOT/legal/THIRD_PARTY_NOTICES.md" "$ROOT/NOTICE" "$ROOT/LICENSE"; do
    [ -s "$f" ] || { echo "STOP: $f is missing"; exit 1; }
    case "$(basename "$f")" in CRYPTOGRAPHY_*|OPENSSL_NOTE.txt|LGPL-3.0.txt|GPL-3.0.txt) continue;; esac      # a library only the Windows packages carry
    grep -Fq "file: \"$(basename "$f")\"" "$LIST" || { echo "STOP: $(basename "$f") is not listed in Licences.swift"; exit 1; }
    cp "$f" "$1/licenses/"
done
for name in $(sed -n 's/.*Entry(file: "\([^"]*\)".*/\1/p' "$LIST"); do
    [ -s "$1/licenses/$name" ] || { echo "STOP: Licences.swift lists $name, but there is no such text"; exit 1; }
done
