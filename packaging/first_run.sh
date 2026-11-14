#!/bin/bash
# Installs LRCDF from inside the app bundle. Run by the app itself the first time it is opened (and again after an
# update): nothing is downloaded. usage: first_run.sh <Resources/LRCDF folder> <path of the app>
# Prints lines "step <text>" for the app to show; exit 0 = installed, 3 = nothing to do (a developer's checkout).
set -e
SRC="$1"; APP="$2"
[ -d "$SRC/project" ] || { echo "no payload in the app"; exit 1; }
[ -e "$HOME/LRCDF/project/.git" ] && exit 3           # the developer's own project: never written over
DATA="$HOME/Library/Application Support/LRCDF"
echo "step 正在复制程序和模型（约 2.7 GB，一两分钟）…"
mkdir -p "$HOME/LRCDF" "$HOME/LRCDF/plugin_work" "$DATA"
rsync -a "$SRC/" "$HOME/LRCDF/"
xattr -dr com.apple.quarantine "$HOME/LRCDF" 2>/dev/null || true
echo "step 正在安装 Lightroom 插件…"
PLUGIN="$HOME/LRCDF/project/plugin/LRCDFAuto.lrplugin"
if [ -d "$HOME/Documents/LRCDFAuto.lrplugin" ]; then       # added by hand before: keep that one the only copy
    rsync -a --delete "$PLUGIN" "$HOME/Documents/"
else                                                       # Lightroom Classic loads what is in this folder by itself
    MODULES="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
    mkdir -p "$MODULES"
    rsync -a --delete "$PLUGIN" "$MODULES/"
fi
printf "%s" "$APP" > "$DATA/app_path.txt"
rm -rf "$DATA/previews"                                    # made by an older version
[ -e "$DATA/beauty_server/alive" ] && touch "$DATA/beauty_server/quit"
echo "step 正在检查…"
"$HOME/LRCDF/python/bin/python3" -c "import torch, cv2, mediapipe, onnxruntime, scipy, tifffile" 
cp "$SRC/VERSION" "$HOME/LRCDF/.installed_version"
echo "step 完成"
