#!/bin/zsh
# 已经装过 LRCDF 的电脑上更新到这一版：只换代码、插件和 App，不重新下载 Python 环境。双击运行。
set -e
cd "$(dirname "$0")"
rsync -a --exclude requirements.txt LRCDF/project/ ~/LRCDF/project/
rm -rf ~/Applications/LRCDF.app; cp -R LRCDF.app ~/Applications/LRCDF.app
xattr -dr com.apple.quarantine ~/Applications/LRCDF.app 2>/dev/null || true
rsync -a --delete LRCDF/project/plugin/LRCDFAuto.lrplugin ~/Documents/
rm -rf ~/Library/Application\ Support/LRCDF/previews      # 旧预览是按旧亮度出的
echo "更新完成。请在 Lightroom 里：文件 → 增效工具管理器 → 选中 LRCDF → 重新载入增效工具，然后重新打开 LRCDF。"
