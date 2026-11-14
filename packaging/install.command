#!/bin/zsh
# LRCDF 安装脚本（在 MacBook Air 上双击运行，或在终端里执行）。不需要管理员密码。
set -e
cd "$(dirname "$0")"
cat <<'T'
==================== LRCDF 安装前请读 ====================
隐私：LRCDF 完全在这台电脑上运行，不收集、不上传你的照片、人脸或任何个人信息，
      没有账号、统计或崩溃上报。只有这次安装会联网，用来下载 Python 运行环境
      （来自 astral.sh 和 PyPI）。全文见 LRCDF/project/legal/PRIVACY.md
模型：本包带有模型权重，
      请先阅读它们的使用条款。
      全文见 LRCDF/project/legal/MODEL_LICENSES.md
代码：Apache-2.0 许可（LRCDF/project/LICENSE、NOTICE）。
==========================================================
T
printf "同意并继续安装请按回车；不同意请直接关闭这个窗口："; read _
echo "1/4 复制程序和模型到 ~/LRCDF ..."
mkdir -p ~/LRCDF ~/LRCDF/plugin_work
rsync -a LRCDF/ ~/LRCDF/
echo "2/4 安装 App 和 Lightroom 插件 ..."
mkdir -p ~/Applications ~/Documents
rm -rf ~/Applications/LRCDF.app; cp -R LRCDF.app ~/Applications/LRCDF.app
xattr -dr com.apple.quarantine ~/Applications/LRCDF.app 2>/dev/null || true
rsync -a --delete LRCDF/project/plugin/LRCDFAuto.lrplugin ~/Documents/
echo "3/4 准备 Python 环境（需要联网，约 1.2 GB，几分钟）..."
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi
cd ~/LRCDF/project
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
echo "4/4 自检 ..."
.venv/bin/python -c "import torch, cv2, mediapipe, onnxruntime; print('Python 环境正常; MPS 可用:', torch.backends.mps.is_available())"
echo
echo "完成。接下来在 Lightroom Classic 里：文件 → 增效工具管理器 → 添加 → 选择 文稿/LRCDFAuto.lrplugin"
