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
app/copy_licenses.sh "$APP/Contents/Resources"      # the licence texts shown in Settings > Licences and credits
# the project, without what only development needs
# NOT in the package: the working notes (CLAUDE.md, docs/ - private details; release 0.1.0 carried them by mistake and
# was withdrawn), internal legal files, the briefs and scripts for our own machines, macOS's ._ companion files.
rsync -a --exclude __pycache__ --exclude .venv --exclude .git --exclude runs --exclude .build --exclude .uv-cache \
      --exclude "legal/zh-CN" --exclude "legal/TODO_VERIFY.md" --exclude "legal/RIGHTS_WIRING.md" --exclude "legal/licenses_mac" \
      --exclude "/CLAUDE.md" --exclude "/docs" --exclude "/scripts/win3090" --exclude "/packaging/windows_port" --exclude "/packaging/publish_source.sh" \
      --exclude "/ipad" --exclude "/packaging/ipad" --exclude "/app/windows" --exclude "/i18n" \
      --exclude "/packaging/*Windows*" --exclude "/packaging/*windows*" \
      --exclude "/site" --exclude "/.github" --exclude "/packaging/studio" --exclude "/packaging/check_tonewell.sh" \
      --exclude "/packaging/tonewell_timing.sh" --exclude "/packaging/make_agesex_zip.py" \
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
# onnx, onnx2torch and ml_dtypes are only for converting models on this machine: the app never imports them
rsync -a --exclude __pycache__ --exclude "piplicenses*" --exclude "pip_licenses*" \
      --exclude "/onnx" --exclude "/onnx-*" --exclude "/onnx2torch" --exclude "/onnx2torch-*" --exclude "/ml_dtypes" --exclude "/ml_dtypes-*" .venv/lib/python3.12/site-packages/ "$PAY/python/lib/python3.12/site-packages/"
[ -e "$PAY/python/bin/python3" ] || ln -s python3.12 "$PAY/python/bin/python3"
date "+%Y%m%d-%H%M%S $(git rev-parse --short HEAD)" > "$PAY/VERSION"
find "$APP" -name "._*" -delete 2>/dev/null || true
python3 packaging/make_update.py ids "$APP"      # the versions of what this app installs, component by component: the updater compares against them
# a last check: nothing of the working notes may be inside
if find "$PAY" \( -name "CLAUDE.md" -o -name "HANDOVER.md" -o -name "TODO_VERIFY.md" \) | grep -q .; then echo "STOP: internal notes in the package"; exit 1; fi
# and the licence texts must be inside, complete: the model licence requires its full text to travel with the app
for f in legal/licenses/* legal/MODEL_LICENSES.md legal/THIRD_PARTY_NOTICES.md NOTICE LICENSE; do
    case "$(basename "$f")" in CRYPTOGRAPHY_*|OPENSSL_NOTE.txt|LGPL-3.0.txt|GPL-3.0.txt) continue;; esac      # a library only the Windows packages carry
    cmp -s "$f" "$APP/Contents/Resources/licenses/$(basename "$f")" || { echo "STOP: licence text missing or different in the package: $f"; exit 1; }
done
# the RetinaFace weights travel with their two MIT licence texts, and the notices name both projects
if find "$PAY/legacy" -name "retinaface_resnet50*.pth" | grep -q .; then
    for f in legal/licenses/RETINAFACE_ternaus_LICENSE.txt legal/licenses/PYTORCH_RETINAFACE_biubug6_LICENSE.txt; do
        cmp -s "$f" "$PAY/project/$f" || { echo "STOP: RetinaFace licence text missing or different in the package: $f"; exit 1; }
    done
    for w in ternaus/retinaface biubug6/Pytorch_Retinaface; do
        grep -q "$w" "$PAY/project/legal/THIRD_PARTY_NOTICES.md" || { echo "STOP: THIRD_PARTY_NOTICES.md does not name $w"; exit 1; }
    done
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: could not sign"
du -sh "$APP"; cat "$PAY/VERSION"
