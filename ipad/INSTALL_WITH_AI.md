# 一键修图 iPad 版：交给 AI 带你安装

> 用法：把这整份文档复制给你的 AI（DeepSeek、ChatGPT 等网页聊天，或 Codex、Claude Code 等能在电脑上执行命令的 AI），
> 然后说一句“请按这份文档带我安装”。English version: `INSTALL_WITH_AI.en.md`.

---

## 写给 AI：你的任务

你要带一位**电脑新手**，把开源 App“一键修图”（LRCDF 的 iPad 版）装到他自己的 iPad 上。这个 App 不在 App Store，
要用他**自己的免费 Apple 账号**签名后安装。请遵守：

1. **每次只给一步。** 给出这一步要做的事（一条可直接复制的命令，或一个明确的界面操作），说清“成功时会看到什么”，
   然后停下来，等他回复结果再给下一步。不要一次贴出全部步骤。
2. **先问清楚两件事再开始：** 他用的是 Mac 还是 Windows 电脑；iPad 的型号和系统版本（设置 → 通用 → 关于本机）。
   Mac 优先走**路线 A**；Windows 只能走**路线 B**。
3. **绝对不要索要、也不要代填**他的 Apple 账号密码、验证码、iPad 锁屏密码、Mac 登录密码。这些只能由他本人在
   Apple 的窗口、iPad 或 Mac 上直接输入。“下面这些必须由你本人做”一节里的事，你只能告诉他在哪里点，不能替他做。
4. 如果你能在他的电脑上执行命令（Codex、Claude Code 等），可以替他运行命令；但需要他本人的那几步仍然要停下来请他做，
   并且不要运行 `sudo`（需要 Mac 密码），把带 `sudo` 的命令交给他自己运行。
5. 他贴回报错时，先在本文“常见报错”里找对应处理；找不到就让他把报错原文发给你，再一起判断。不要建议关闭系统安全功能。
6. 用他能懂的话。命令要放在单独的代码块里，方便复制。

---

## 先了解

| | |
|---|---|
| 需要的 iPad | iPadOS 27 或更新（设置 → 通用 → 关于本机 看“iPadOS 版本”） |
| 路线 A 需要 | 一台 Mac，能从 App Store 装上 Xcode 27（装不上说明 macOS 太旧，先升级系统）；一根能传数据的 USB-C 线 |
| 路线 B 需要 | 一台 Mac 或 Windows 电脑，能装 Sideloadly 或 AltStore（第三方签名工具）；一根能传数据的 USB-C 线 |
| Apple 账号 | 免费的就行，不需要付费开发者会员 |
| 磁盘空间（路线 A） | 建议 Mac 至少空出 50 GB：Xcode 约 3–4 GB 下载、装好后十几 GB；iPadOS 编译组件约 8 GB 下载；源码和编译文件约 2 GB |
| 下载量 | 路线 A：Xcode + iPadOS 组件约 12 GB，源码约 100 MB，修图模型约 102 MB，项目生成工具 XcodeGen 约 10 MB。路线 B：安装包约 105 MB + 签名工具 |
| 7 天限制 | **免费账号签的 App 7 天后就打不开了**（Apple 的规定）。到时重新走一遍“装到 iPad”那一步即可：路线 A 再运行一次脚本；路线 B 用签名工具重新签一次（AltStore 可以自动续签） |
| 数据会不会丢 | 7 天到期后重新安装**同一个 App** 会覆盖安装，App 里的设置（风格偏好、联机拍摄的用户名密码等）保留。**删除 App 再装**会清空这些设置。修好的照片存在“照片”App 里，不受影响。App 里导入的原片本来就是临时副本，每次打开会清掉 |
| 免费账号的其他限制 | 同时最多 3 个自签 App；每 7 天最多注册 10 个 App 标识 |

**会从哪里下载什么**（都是用户主动安装时下载，App 本身运行时不会下载这些）：
- 源码：GitHub `https://github.com/dinghao581-cyber/LRCDF`（主分支压缩包）
- 修图模型：同一仓库的发布页 `releases/download/ipad-models-1a7b80b619719eda/LRCDF-iPad-models-1a7b80b619719eda.zip`，
  101,833,631 字节，SHA-256 `11965296a01e6bde20365a3316127ccbd55b71e74b75cf51c9a1ec9d4c450c6f`
- XcodeGen 2.46.0（开源的 Xcode 工程生成工具）：`https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip`，
  SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`
- 路线 B 的安装包：同一仓库发布页里的 `LRCDF-iPad-<版本>.ipa`（未签名，约 105 MB）

安装脚本会自动核对校验值，对不上就停下。

---

## 下面这些必须由你本人做（AI 不能代做，也不要把密码告诉 AI）

| 事情 | 在哪里做 | 为什么必须是你 |
|---|---|---|
| 在 Xcode（路线 A）或签名工具（路线 B）里登录 Apple 账号，输入密码和验证码 | Mac / 电脑上 Apple 或签名工具的登录窗口 | 账号是你的，密码和验证码只能你本人输入 |
| iPad 插线后点“信任这台电脑”并输入 iPad 密码 | iPad 屏幕 | 只能在 iPad 上点 |
| 打开 iPad 的“开发者模式”并重启 | iPad：设置 → 隐私与安全性 → 开发者模式 | 只能在 iPad 上开，开完要重启，重启后解锁时再确认一次 |
| 第一次装好后，在 iPad 上“信任开发者” | iPad：设置 → 通用 → VPN 与设备管理 → 开发者 App 下点你的账号 → 信任 | 只能在 iPad 上点 |
| 运行带 `sudo` 的命令（如果遇到） | Mac 终端 | 需要输入 Mac 登录密码 |

---

## 路线 A：Mac + Xcode，从源码安装（推荐）

### A1. 安装 Xcode
- 操作：打开 Mac 上的 App Store，搜索 **Xcode**，点“获取 / 安装”。下载约 3–4 GB，要等一阵。装好后**打开 Xcode 一次**，
  同意许可协议，等它装完附加组件。
- 成功时：Xcode 能正常打开，看到欢迎窗口。
- 常见问题：
  - App Store 显示“需要更新的 macOS” → 先升级 macOS（系统设置 → 通用 → 软件更新）。
  - 空间不够 → 先清出至少 50 GB。

### A2. 在 Xcode 里登录你的 Apple 账号（**你本人做**）
- 操作：Xcode 顶部菜单 **Xcode → 设置（Settings）→ Accounts（账户）→ 左下角 + → Apple Account**，输入你的 Apple 账号、
  密码和验证码。
- 成功时：左边列表出现你的账号，右边“Team”一栏写着“你的名字 (Personal Team)”。
- 常见问题：
  - 没有出现 Personal Team → 关掉 Xcode 再打开一次。

### A3. 用线连接 iPad 并信任（**你本人做**）
- 操作：用 USB-C 线把 iPad 接到 Mac，解锁 iPad。iPad 弹出“要信任这台电脑吗？”时点**信任**，输入 iPad 密码。
- 成功时：Mac 的访达（Finder）左边栏里出现这台 iPad。
- 常见问题：
  - 没有弹窗 → 换一根能传数据的线（有些线只能充电），或拔掉重插。

### A4. 打开 iPad 的开发者模式（**你本人做**）
- 操作：iPad 上 **设置 → 隐私与安全性**，拉到最下面 **开发者模式** → 打开 → 按提示**重启** iPad → 重启后解锁时，
  在弹窗里再点一次“打开”。
- 成功时：开发者模式开关是绿色的。
- 常见问题：
  - 找不到“开发者模式” → 先让 Xcode 认一次这台 iPad：Xcode 菜单 **Window → Devices and Simulators**，选中这台 iPad，
    等它准备完，然后再去 iPad 设置里找。

### A5. 运行安装脚本
- 操作：打开 Mac 的“终端”（启动台 → 其他 → 终端，或按 ⌘ 空格 输入“终端”），复制下面这一行粘贴进去，按回车：
  ```
  curl -fsSL https://raw.githubusercontent.com/dinghao581-cyber/LRCDF/main/ipad/install.sh -o install.sh && zsh install.sh
  ```
- 脚本会依次做 8 步并显示“【第 n 步】… ✓”：
  1. 检查 Xcode；
  2. 找到你的 Apple 账号；
  3. 找到 iPad；
  4. 下载源码；
  5. 下载修图模型；
  6. 下载 XcodeGen；
  7. 编译签名（第一次 3–10 分钟）；
  8. 装到 iPad。
- 脚本**不会**要你的密码，不用 sudo，不改系统设置。
- 中途出错会显示“✗ 出错了：… 下一步：…”，照着做完再运行同一行命令，已完成的步骤会跳过。
- 成功时：最后显示“完成。”，iPad 上出现“一键修图”图标。
- 常见报错：

| 脚本显示 | 处理 |
|---|---|
| 没有找到 Xcode / 系统在用“命令行工具” | 做 A1；或在终端运行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`（你本人输入 Mac 密码） |
| Xcode 还不能用 | 打开 Xcode 同意许可协议；或运行 `sudo xcodebuild -license accept`（你本人输入密码） |
| 缺少 iPadOS 编译组件 | 脚本会自动下载（约 8 GB）；失败就在 Xcode → 设置 → Components 里点 iOS 下载 |
| Xcode 里还没有登录 Apple 账号 | 做 A2 |
| 没有找到 iPad / 还没有信任这台 Mac | 做 A3，保持 iPad 解锁 |
| 没有打开开发者模式 | 做 A4 |
| 下载失败 / 校验值不对 | 网络问题：换网络再运行。国内访问 GitHub 慢时可以多试几次 |
| 免费账号最多 3 个自签 App | 在 iPad 上删掉不用的自签 App 再运行 |
| App 标识不能用 | 运行 `LRCDF_BUNDLE_ID=com.你的英文名.lrcdf zsh install.sh`（只用英文字母、数字、点） |
| Xcode 里的 Apple 账号要重新登录 | 在 Xcode → 设置 → Accounts 里重新登录（你本人输入） |
| 编译没有通过 | 把“最后几条报错”原文发给 AI |
| 连着多台 iPad | 脚本先装第一台；装另一台：`LRCDF_DEVICE=那台的UDID zsh install.sh`（UDID 在脚本输出或 Xcode 设备窗口里） |

### A6. 第一次打开前信任开发者（**你本人做**）
- 操作：如果脚本最后说“iPad 还不让打开”，在 iPad 上 **设置 → 通用 → VPN 与设备管理 →“开发者 App”下点你的 Apple 账号 → 信任**，
  然后回主屏幕点“一键修图”。
- 成功时：App 打开，看到“今天想修哪几张？”。

### A7. 7 天后
App 打不开时：把 iPad 接上同一台 Mac，在终端再运行 A5 那一行命令。设置会保留。

---

## 路线 B：现成安装包 + 签名工具（Mac 或 Windows）

> ⚠️ **未验证**：我们还没有用 Sideloadly 或 AltStore 实际走通过这条路线。已验证的只有：这个未签名安装包用免费账号签名后
> 能装到 iPad（开发者在 Mac 上手动签名测试过）。下面的步骤按这两个工具的官方说明写成，界面可能和你看到的略有不同。
> 这两个工具是第三方软件，需要你把 Apple 账号密码输入**它们的窗口**，请自行判断是否信任；有顾虑可以专门注册一个
> Apple 账号用来签名。

### B1. 下载安装包
- 操作：打开 `https://github.com/dinghao581-cyber/LRCDF/releases`，在最新的 iPad 版本下载 **LRCDF-iPad-<版本>.ipa**（约 105 MB）。
- 成功时：下载文件夹里有一个 `.ipa` 文件。

### B2. 打开 iPad 的开发者模式（**你本人做**）
同 A4：签名工具装的 App 也需要它。

### B3（方法一）. 用 Sideloadly 签名安装（Mac 或 Windows）
1. 从 `https://sideloadly.io` 下载安装 Sideloadly。
   Windows 还需要从 Apple 官网（**不是** Microsoft Store）下载安装 iTunes 和 iCloud，Sideloadly 网站上有链接。
2. 用线连接 iPad 并信任（同 A3）。打开 Sideloadly，它应当在“iDevice”一栏认出你的 iPad。
3. 把 B1 下载的 `.ipa` 拖进 Sideloadly 窗口，在“Apple ID”一栏填你的 Apple 账号，点 **Start**。
4. 弹出密码和验证码窗口时**你本人输入**。
5. 成功时：Sideloadly 显示 Done，iPad 上出现“一键修图”。
6. 然后在 iPad 上信任开发者（同 A6）。
- 常见问题：
  - 提示 App 标识（bundle ID）不可用 → 在 Sideloadly 的高级选项里勾选自动修改 bundle ID 后重试。
  - Windows 认不到 iPad → 确认 iTunes 是 Apple 官网版本，并在 iTunes 里能看到 iPad。
- 7 天后：重新用 Sideloadly 签一次同一个 `.ipa`。

### B3（方法二）. 用 AltStore 签名安装（Mac 或 Windows）
1. 从 `https://altstore.io` 下载安装 **AltServer**（电脑端）。Windows 同样需要 Apple 官网版 iTunes 和 iCloud。
2. 用线连接 iPad 并信任。通过 AltServer（Mac 菜单栏图标 / Windows 托盘图标）→ **Install AltStore** → 选择你的 iPad，
   输入 Apple 账号密码（**你本人输入**）。
3. iPad 上信任开发者（同 A6），打开 AltStore。
4. 把 `.ipa` 存进 iPad 的“文件”App（例如用隔空投送或 iCloud 云盘）。
5. 在 AltStore 的 **My Apps → 左上角 +**，选这个 `.ipa`。
6. 成功时：My Apps 里出现“一键修图”，主屏幕有图标。
- 7 天后：电脑上 AltServer 开着、和 iPad 在同一个 Wi-Fi 时，AltStore 会自动续签；也可以在 My Apps 里点“Refresh All”。
- 注意：AltStore 本身也占一个自签 App 名额（免费账号共 3 个）。

---

## 常见问题

- **打开 App 时提示“无法验证开发者”** → 做 A6。
- **7 天到了打不开** → 路线 A 重新运行脚本；路线 B 重新签名。不要删除 App，删除会清掉设置。
- **App 里提示有新版本** → 路线 A：重新运行脚本即可（会下载最新源码）；路线 B：下载新的 `.ipa` 重新签名安装。
- **想卸载** → 长按 iPad 主屏幕上的图标 → 移除 App。
