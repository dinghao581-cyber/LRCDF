#!/bin/zsh
# Builds the all-in-one app: LRCDF.app with Python, every package, the models and the plug-in inside. The user
# double-clicks it; the app installs itself (packaging/first_run.sh). Apple-silicon Macs only.
# usage: packaging/make_bundle.sh [output folder, default ~/LRCDF/dist]
set -e
cd "$(dirname "$0")/.."
OUT="${1:-$HOME/LRCDF/dist}"; APP="$OUT/LRCDF.app"; PAY="$APP/Contents/Resources/LRCDF"
(cd app && swift build -c release)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$PAY/project/runs/tone" "$PAY/legacy/mac_project"
cp app/.build/release/LRCDF "$APP/Contents/MacOS/LRCDF"; cp app/Info.plist "$APP/Contents/Info.plist"
app/stamp_sdk.sh "$APP/Contents/MacOS/LRCDF"      # made for macOS 26, runs from 14 (app/stamp_sdk.sh)
cp app/AppIcon.icns LICENSE NOTICE packaging/first_run.sh packaging/update_install.sh "$APP/Contents/Resources/"
app/localize.sh "$APP/Contents/Resources"      # the app's texts, in every language of the String Catalog
# the project, without what only development needs
# NOT in the package: the working notes (CLAUDE.md, docs/ - private details; release 0.1.0 carried them by mistake and
# was withdrawn), internal legal files, the briefs and scripts for our own machines, macOS's ._ companion files.
rsync -a --exclude __pycache__ --exclude .venv --exclude .git --exclude runs --exclude .build --exclude .uv-cache \
      --exclude "legal/zh-CN" --exclude "legal/TODO_VERIFY.md" --exclude "legal/RIGHTS_WIRING.md" \
      --exclude "/CLAUDE.md" --exclude "/docs" --exclude "/scripts/win3090" --exclude "/packaging/windows_port" --exclude "/packaging/publish_source.sh" \
      --exclude "/ipad" --exclude "/packaging/ipad" --exclude "/app/windows" --exclude "/i18n" \
      --exclude "/packaging/*Windows*" --exclude "/packaging/*windows*" \
      --exclude "._*" --exclude ".DS_Store" ./ "$PAY/project/"
cp runs/tone/tone.pt "$PAY/project/runs/tone/"
for f in retouch_model.pt critic_model.pt shadow_model.pt; do [ -f runs/$f ] && cp runs/$f "$PAY/project/runs/"; done
mkdir -p "$PAY/models"         # only the models the pipeline loads (other sessions keep unrelated downloads in ~/LRCDF/models)
rsync -a --exclude __pycache__ --exclude "._*" ~/LRCDF/models/mediapipe ~/LRCDF/models/sface ~/LRCDF/models/agegender ~/LRCDF/models/makeup "$PAY/models/"   # makeup: scripts/export_makeup.py
rsync -a --exclude __pycache__ --exclude "._*" ~/LRCDF/legacy/mac_project/scripts ~/LRCDF/legacy/mac_project/external_models ~/LRCDF/legacy/mac_project/gen_best.pth "$PAY/legacy/mac_project/"
# Python itself (python-build-standalone: runs from wherever it is put) with the packages of the development environment
PY=$(dirname "$(sed -n 's/^home = //p' .venv/pyvenv.cfg)")
rsync -aL --exclude __pycache__ --exclude "lib/python3.12/test" --exclude "lib/python3.12/idlelib" --exclude "lib/python3.12/tkinter" "$PY/" "$PAY/python/"
rm -f "$PAY/python/lib/python3.12/EXTERNALLY-MANAGED"
rsync -a --exclude __pycache__ --exclude "piplicenses*" --exclude "pip_licenses*" .venv/lib/python3.12/site-packages/ "$PAY/python/lib/python3.12/site-packages/"
[ -e "$PAY/python/bin/python3" ] || ln -s python3.12 "$PAY/python/bin/python3"
date "+%Y%m%d-%H%M%S $(git rev-parse --short HEAD)" > "$PAY/VERSION"
find "$APP" -name "._*" -delete 2>/dev/null || true
python3 packaging/make_update.py ids "$APP"      # the versions of what this app installs, component by component: the updater compares against them
# a last check: nothing of the working notes may be inside
if find "$PAY" \( -name "CLAUDE.md" -o -name "HANDOVER.md" -o -name "TODO_VERIFY.md" \) | grep -q .; then echo "STOP: internal notes in the package"; exit 1; fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: could not sign"
du -sh "$APP"; cat "$PAY/VERSION"
