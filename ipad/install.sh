#!/bin/zsh
# Tonewell（LRCDF）iPad 版：从源码编译，用你自己的免费 Apple 账号签名，装到用 USB 线连着这台 Mac 的 iPad。
#
# 用法（在 Mac 的“终端”里）：
#   curl -fsSL https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/main/ipad/install.sh -o install.sh && zsh install.sh
# 或者在已经下载好的源码目录里：zsh ipad/install.sh
#
# 它会做：检查 Xcode → 找到你在 Xcode 里登录的 Apple 账号（团队 ID）→ 找到连着的 iPad → 下载源码、修图模型和
# 项目生成工具 XcodeGen（都核对校验值）→ 编译、签名 → 装到 iPad。哪一步出问题就停下，并用中文说下一步该做什么。
# 它不会：要你的密码或验证码、用 sudo、改系统设置、上传任何东西。
# 免费账号签的 App 7 天后打不开，到时候再运行一次本脚本即可（同一个 App 覆盖安装，App 里的设置保留）。
#
# 可选的环境变量（一般不用）：
#   LRCDF_WORK      工作目录（默认 ~/LRCDF-iPad）     LRCDF_DEVICE  指定 iPad 的 UDID（连了多台时）
#   LRCDF_TEAM      指定团队 ID                        LRCDF_BUNDLE_ID 指定 App 的标识（默认按团队 ID 生成）
#   LRCDF_SOURCE    源码：本地目录或 .tar.gz 网址       LRCDF_MODELS_URL 模型压缩包网址（可为 file://）
set -u

REPO="dinghao581-cyber/LRCDF"
SOURCE="${LRCDF_SOURCE:-https://github.com/$REPO/archive/refs/heads/main.tar.gz}"
MODELS_VERSION="1a7b80b619719eda"
MODELS_SHA256="11965296a01e6bde20365a3316127ccbd55b71e74b75cf51c9a1ec9d4c450c6f"
MODELS_URL="${LRCDF_MODELS_URL:-https://github.com/$REPO/releases/download/ipad-models-$MODELS_VERSION/LRCDF-iPad-models-$MODELS_VERSION.zip}"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
WORK="${LRCDF_WORK:-$HOME/LRCDF-iPad}"

n=0
step() { n=$((n + 1)); print -P "\n%B【第 $n 步】$1%b" }
ok()   { print "  ✓ $1" }
fail() { print -P "\n%B✗ 出错了：$1%b"; print "  下一步：$2"; print "  （做完后重新运行本脚本，已经完成的步骤会自动跳过。）"; exit 1 }
need_sha() {      # file, expected sha256
  local got; got=$(shasum -a 256 "$1" | awk '{print $1}')
  [[ "$got" == "$2" ]] || { rm -f "$1"; fail "下载的文件校验值不对（可能没下载完整或网络被替换）：$1" "检查网络后重新运行；仍不行就把这一行发给 AI 或开发者。"; }
}
fetch() {         # url, destination
  print "  下载：$1"
  curl -fL --retry 3 --progress-bar -o "$2.part" "$1" || { rm -f "$2.part"; fail "下载失败：$1" "检查网络（能否打开 github.com）。在国内网络下 GitHub 有时很慢或连不上，可以换个网络再试。"; }
  mv "$2.part" "$2"
}

print -P "%BTonewell iPad 版：从源码安装%b（工作目录 $WORK）"
mkdir -p "$WORK" || fail "无法创建工作目录 $WORK" "换一个目录：LRCDF_WORK=~/某个目录 zsh install.sh"

# ---------------------------------------------------------------------------------------------------------------
step "检查 Xcode"
[[ "$(uname -s)" == Darwin ]] || fail "这个脚本只能在 Mac 上运行" "Windows 电脑请改走文档里的路线 B（安装包 + Sideloadly）。"
XDIR=$(xcode-select -p 2>/dev/null)
if [[ -z "$XDIR" || "$XDIR" != *Xcode*.app* ]]; then
  if [[ -d /Applications/Xcode.app ]]; then
    fail "Xcode 已安装，但系统在用的是“命令行工具”而不是 Xcode" "在终端运行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer （会要你的 Mac 登录密码，这一步请你自己输入）"
  fi
  fail "没有找到 Xcode" "打开 Mac 上的 App Store，搜索 Xcode 并安装（约 3–4 GB 下载）。装好后打开 Xcode 一次，同意许可协议，等它装完附加组件。"
fi
XVER=$(xcodebuild -version 2>&1 | head -1)
[[ "$XVER" == Xcode* ]] || fail "Xcode 还不能用：$XVER" "打开 Xcode 一次，同意许可协议；或在终端运行 sudo xcodebuild -license accept（要你自己输入 Mac 密码）。"
XMAJOR=$(print "$XVER" | sed -E 's/Xcode ([0-9]+).*/\1/')
(( XMAJOR >= 27 )) || fail "Xcode 版本太旧（$XVER），这个 App 需要 Xcode 27 或更新" "在 App Store 里更新 Xcode。"
ok "$XVER"
if ! xcodebuild -showsdks 2>/dev/null | grep -q iphoneos; then
  print "  缺少 iPadOS 编译组件，现在下载（约 8 GB，要等一阵子）…"
  xcodebuild -downloadPlatform iOS || fail "iPadOS 组件下载失败" "打开 Xcode → 设置（Settings）→ Components（组件），点 iOS 旁边的下载。"
fi
ok "iPadOS 编译组件已就绪"

# ---------------------------------------------------------------------------------------------------------------
step "找到你在 Xcode 里登录的 Apple 账号"
TEAM="${LRCDF_TEAM:-}"
if [[ -z "$TEAM" ]]; then
  TEAM=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
teams = [t for v in d.get("IDEProvisioningTeamByIdentifier", {}).values() for t in v]
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam", False))   # a personal (free) team first
print(teams[0]["teamID"] if teams else "")' 2>/dev/null)
fi
[[ -n "$TEAM" ]] || fail "Xcode 里还没有登录 Apple 账号" "打开 Xcode → 菜单 Xcode → 设置（Settings）→ Accounts（账户）→ 左下角 + → Apple Account，用你自己的 Apple 账号登录。密码和验证码只在 Xcode 里由你本人输入，不要告诉任何人或 AI。登录后左边会出现你的名字和“(Personal Team)”。"
ok "团队 ID：$TEAM"
BUNDLE="${LRCDF_BUNDLE_ID:-com.ding.lrcdf.ipad.${(L)TEAM}}"      # one fixed identifier per account: reinstalling keeps the app's data
ok "App 标识：$BUNDLE"

# ---------------------------------------------------------------------------------------------------------------
step "找到连着的 iPad"
DEVJSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1
DEVINFO=$(python3 - "$DEVJSON" "${LRCDF_DEVICE:-}" <<'PY'
import json, sys
try: devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devs = []
want = sys.argv[2]
ipads = [d for d in devs if "iPad" in (d.get("hardwareProperties", {}).get("productType") or "")
         and (not want or d.get("hardwareProperties", {}).get("udid") == want)]
for d in ipads:
    c, p, h = d.get("connectionProperties", {}), d.get("deviceProperties", {}), d.get("hardwareProperties", {})
    print("|".join([h.get("udid", ""), p.get("name", "iPad"), c.get("pairingState", ""), c.get("tunnelState", ""),
                    p.get("developerModeStatus", ""), p.get("osVersionNumber", ""), h.get("marketingName", "")]))
PY
)
rm -f "$DEVJSON"
[[ -n "$DEVINFO" ]] || fail "没有找到 iPad" "用 USB-C 线把 iPad 接到这台 Mac，解锁 iPad；iPad 上弹出“要信任这台电脑吗？”时点“信任”并输入 iPad 密码（你自己输入）。"
COUNT=$(print "$DEVINFO" | wc -l | tr -d ' ')
IFS='|' read -r DEV DNAME PAIR TUNNEL DEVMODE OSV MODEL <<< "$(print "$DEVINFO" | head -1)"
(( COUNT > 1 )) && print "  连着 $COUNT 台 iPad，先装第一台（$MODEL）。要装另一台：LRCDF_DEVICE=那台的UDID zsh install.sh"
[[ "$PAIR" == paired ]] || fail "iPad 还没有信任这台 Mac（状态：$PAIR）" "解锁 iPad，在弹出的“要信任这台电脑吗？”里点“信任”并输入 iPad 密码。没有弹出就拔掉线重插。"
[[ "$DEVMODE" == enabled ]] || fail "iPad 没有打开“开发者模式”（状态：$DEVMODE）" "在 iPad 上：设置 → 隐私与安全性 → 拉到最下面“开发者模式”→ 打开 → 按提示重启 iPad，重启后解锁时再点一次“打开”。如果找不到这个开关：先让 Xcode 认一次设备（打开 Xcode → 菜单 Window → Devices and Simulators，选中这台 iPad），开关就会出现。"
OSMAJOR=${OSV%%.*}
[[ -z "$OSMAJOR" ]] || (( OSMAJOR >= 27 )) || fail "iPad 的系统太旧（iPadOS $OSV），需要 iPadOS 27 或更新" "在 iPad 上：设置 → 通用 → 软件更新。"
ok "$MODEL（iPadOS $OSV），已信任，开发者模式已打开"

# ---------------------------------------------------------------------------------------------------------------
step "准备源码"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [[ -z "${LRCDF_SOURCE:-}" && -f "$HERE/app/project.yml" ]]; then
  ROOT=$(cd "$HERE/.." && pwd); ok "使用脚本所在的源码：$ROOT"
elif [[ -d "$SOURCE" && -f "$SOURCE/ipad/app/project.yml" ]]; then
  ROOT=$(cd "$SOURCE" && pwd); ok "使用源码目录：$ROOT"
else
  ROOT="$WORK/src"
  rm -rf "$ROOT.new"; mkdir -p "$ROOT.new"
  fetch "$SOURCE" "$WORK/source.tar.gz"
  tar -xzf "$WORK/source.tar.gz" -C "$ROOT.new" --strip-components 1 || fail "源码压缩包解不开" "删掉 $WORK 后重新运行。"
  [[ -f "$ROOT.new/ipad/app/project.yml" ]] || fail "下载的源码里没有 iPad 工程" "确认网址是 Tonewell 的仓库；把这一行发给开发者。"
  if [[ -d "$ROOT/ipad/app/LRCDF/models" ]]; then mv "$ROOT/ipad/app/LRCDF/models" "$ROOT.new/ipad/app/LRCDF/models"; fi   # keep downloaded models
  rm -rf "$ROOT"; mv "$ROOT.new" "$ROOT"; rm -f "$WORK/source.tar.gz"
  ok "源码在 $ROOT"
fi
APPDIR="$ROOT/ipad/app"

# ---------------------------------------------------------------------------------------------------------------
step "准备修图模型（约 102 MB 下载，解开后约 110 MB）"
MODELS="$APPDIR/LRCDF/models"
HAVE=""; [[ -d "$MODELS" ]] && HAVE=$(python3 "$ROOT/packaging/ipad/models_version.py" "$APPDIR/LRCDF" 2>/dev/null)
if [[ "$HAVE" == "$MODELS_VERSION" ]]; then
  ok "模型已就绪（版本 $MODELS_VERSION）"
else
  ZIP="$WORK/LRCDF-iPad-models-$MODELS_VERSION.zip"
  [[ -f "$ZIP" ]] || fetch "$MODELS_URL" "$ZIP"
  need_sha "$ZIP" "$MODELS_SHA256"
  rm -rf "$MODELS"
  unzip -q "$ZIP" -d "$APPDIR/LRCDF" || fail "模型压缩包解不开" "删掉 $ZIP 后重新运行。"
  HAVE=$(python3 "$ROOT/packaging/ipad/models_version.py" "$APPDIR/LRCDF" 2>/dev/null)
  [[ "$HAVE" == "$MODELS_VERSION" ]] || fail "模型版本和这份源码要的不一致（得到 $HAVE）" "源码比模型新或旧：重新下载最新的 install.sh 再运行。"
  ok "模型已就绪（版本 $MODELS_VERSION，校验通过）"
fi

# ---------------------------------------------------------------------------------------------------------------
step "准备项目生成工具 XcodeGen"
XG="$WORK/tools/xcodegen/bin/xcodegen"
if [[ ! -x "$XG" ]]; then
  mkdir -p "$WORK/tools"; fetch "$XCODEGEN_URL" "$WORK/tools/xcodegen.zip"
  need_sha "$WORK/tools/xcodegen.zip" "$XCODEGEN_SHA256"
  unzip -qo "$WORK/tools/xcodegen.zip" -d "$WORK/tools" || fail "XcodeGen 解不开" "删掉 $WORK/tools 后重新运行。"
fi
(cd "$APPDIR" && "$XG" generate --quiet) || fail "生成 Xcode 工程失败" "把上面的报错发给 AI 或开发者。"
ok "Xcode 工程已生成"

# ---------------------------------------------------------------------------------------------------------------
step "编译并签名（第一次约 3–10 分钟）"
LOG="$WORK/build.log"
(cd "$APPDIR" && xcodebuild -project LRCDFPad.xcodeproj -scheme LRCDFPad -configuration Release -destination "id=$DEV" \
   -derivedDataPath "$WORK/build" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
   DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" build > "$LOG" 2>&1)
if [[ $? -ne 0 ]]; then
  print "  最后几条报错："; grep -E "error:" "$LOG" | sort -u | head -5 | sed 's/^/    /'
  if grep -q -i -E "maximum number of apps|app id limit" "$LOG"; then
    fail "免费账号同时最多 3 个自签 App、每 7 天最多 10 个 App 标识" "在 iPad 上删掉不用的自签 App，或等几天再试。"
  elif grep -q -i -E "is not available|cannot be registered|already (in use|taken)" "$LOG"; then
    fail "App 标识 $BUNDLE 不能用" "换一个：LRCDF_BUNDLE_ID=com.你的名字.lrcdf zsh install.sh"
  elif grep -q -i -E "No Account for Team|No accounts|sign in|session has expired" "$LOG"; then
    fail "Xcode 里的 Apple 账号要重新登录" "Xcode → 设置 → Accounts，选中你的账号，按提示重新登录（密码和验证码你自己输入）。"
  elif grep -q -i -E "locked|Developer Mode" "$LOG"; then
    fail "iPad 锁屏了或开发者模式没开" "解锁 iPad 并保持亮屏，再运行一次。"
  else
    fail "编译没有通过（完整记录在 $LOG）" "把上面的报错几行发给 AI；常见原因是 Xcode 第一次用还在装组件，等几分钟再运行。"
  fi
fi
APP=$(ls -d "$WORK/build/Build/Products/Release-iphoneos/"*.app 2>/dev/null | head -1)
[[ -n "$APP" ]] || fail "没有找到编好的 App" "把 $LOG 的最后几行发给 AI。"
ok "编译完成"

# ---------------------------------------------------------------------------------------------------------------
step "装到 iPad"
xcrun devicectl device install app --device "$DEV" "$APP" > "$WORK/install.log" 2>&1 \
  || { tail -5 "$WORK/install.log" | sed 's/^/    /'; fail "安装失败" "保持 iPad 解锁、线接好再运行；仍失败就把上面几行发给 AI。"; }
ok "已装到 $MODEL"
if xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE" > "$WORK/launch.log" 2>&1; then
  ok "已打开 App"
else
  print "  App 已装好，但 iPad 还不让打开（第一次装时正常）。请在 iPad 上："
  print "  设置 → 通用 → VPN 与设备管理 → “开发者 App”下点你的 Apple 账号 → 信任。然后在主屏幕点“Tonewell”。"
fi
print -P "\n%B完成。%b免费 Apple 账号签的 App 7 天后会打不开：到时把 iPad 接上这台 Mac，再运行一次本脚本即可（App 里的设置会保留）。"
