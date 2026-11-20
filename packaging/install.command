#!/bin/zsh
# LRCDF installer (double-click it, or run it in Terminal). No administrator password needed.
set -e
cd "$(dirname "$0")"
cat <<'T'
============ Please read before installing LRCDF ============
Privacy: LRCDF itself collects nothing and uploads none of your photos, faces or personal
         information; no account, analytics or crash reports. One exception: the Google
         MediaPipe library bundled with LRCDF sends usage statistics (no photos) to Google
         while face/body detection runs; there is no setting to turn it off, but it works
         offline. The installation itself goes online to download the Python runtime (astral.sh,
         PyPI). Full text: LRCDF/project/legal/PRIVACY.md
Models:  this package includes model weights; please read their terms first.
         Full text: LRCDF/project/legal/MODEL_LICENSES.md
Code:    Apache-2.0 licence (LRCDF/project/LICENSE, NOTICE).
=============================================================
T
printf "Press Return to agree and install; if you do not agree, close this window: "; read _
echo "1/4 Copying the program and models to ~/LRCDF ..."
mkdir -p ~/LRCDF ~/LRCDF/plugin_work
rsync -a LRCDF/ ~/LRCDF/
echo "2/4 Installing the app and the Lightroom plug-in ..."
mkdir -p ~/Applications ~/Documents
rm -rf ~/Applications/LRCDF.app; cp -R LRCDF.app ~/Applications/LRCDF.app
xattr -dr com.apple.quarantine ~/Applications/LRCDF.app 2>/dev/null || true
rsync -a --delete LRCDF/project/plugin/LRCDFAuto.lrplugin ~/Documents/
echo "3/4 Setting up Python (needs the internet, about 1.2 GB, a few minutes) ..."
export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null; then curl -LsSf https://astral.sh/uv/install.sh | sh; fi
cd ~/LRCDF/project
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements.txt
echo "4/4 Self-check ..."
.venv/bin/python -c "import torch, cv2, mediapipe, onnxruntime; print('Python OK; MPS available:', torch.backends.mps.is_available())"
echo
echo "Done. Next, in Lightroom Classic: File > Plug-in Manager > Add > choose Documents/LRCDFAuto.lrplugin"
