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
cp app/AppIcon.icns LICENSE NOTICE packaging/first_run.sh "$APP/Contents/Resources/"
# the project, without what only development needs
rsync -a --exclude __pycache__ --exclude .venv --exclude .git --exclude runs --exclude .build --exclude .uv-cache \
      --exclude "legal/zh-CN" --exclude "legal/TODO_VERIFY.md" --exclude "legal/RIGHTS_WIRING.md" ./ "$PAY/project/"
cp runs/tone/tone.pt "$PAY/project/runs/tone/"
for f in retouch_model.pt critic_model.pt shadow_model.pt; do [ -f runs/$f ] && cp runs/$f "$PAY/project/runs/"; done
rsync -a --exclude __pycache__ ~/LRCDF/models "$PAY/"
rsync -a --exclude __pycache__ ~/LRCDF/legacy/mac_project/scripts ~/LRCDF/legacy/mac_project/external_models ~/LRCDF/legacy/mac_project/gen_best.pth "$PAY/legacy/mac_project/"
# Python itself (python-build-standalone: runs from wherever it is put) with the packages of the development environment
PY=$(dirname "$(sed -n 's/^home = //p' .venv/pyvenv.cfg)")
rsync -aL --exclude __pycache__ --exclude "lib/python3.12/test" --exclude "lib/python3.12/idlelib" --exclude "lib/python3.12/tkinter" "$PY/" "$PAY/python/"
rm -f "$PAY/python/lib/python3.12/EXTERNALLY-MANAGED"
rsync -a --exclude __pycache__ --exclude "piplicenses*" --exclude "pip_licenses*" .venv/lib/python3.12/site-packages/ "$PAY/python/lib/python3.12/site-packages/"
[ -e "$PAY/python/bin/python3" ] || ln -s python3.12 "$PAY/python/bin/python3"
date "+%Y%m%d-%H%M%S $(git rev-parse --short HEAD)" > "$PAY/VERSION"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: could not sign"
du -sh "$APP"; cat "$PAY/VERSION"
