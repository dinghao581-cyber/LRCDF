#!/bin/zsh
# Updates a computer that already has LRCDF to this version: replaces code, plug-in and app, keeps the Python environment. Double-click it.
set -e
cd "$(dirname "$0")"
rsync -a --exclude requirements.txt LRCDF/project/ ~/LRCDF/project/
rm -rf ~/Applications/LRCDF.app; cp -R LRCDF.app ~/Applications/LRCDF.app
xattr -dr com.apple.quarantine ~/Applications/LRCDF.app 2>/dev/null || true
rsync -a --delete LRCDF/project/plugin/LRCDFAuto.lrplugin ~/Documents/
rm -rf ~/Library/Application\ Support/LRCDF/previews      # old previews were made with the old brightness
echo "Update done. In Lightroom: File > Plug-in Manager > select LRCDF > Reload Plug-in, then open LRCDF again."
