# 安装 LRCDF Windows 版

适用于 Windows x64 和 Lightroom Classic。界面有 20 种语言。程序、任务栏、桌面和开始菜单使用同一个 LRCDF 图标。

1. 选择 CPU 包，或在 NVIDIA 显卡和驱动支持 CUDA 12.4 时选择 CUDA 包。
2. CPU 包直接解压。CUDA 分卷先把全部 `.zip.001`、`.zip.002` 等文件与 `Join-Bundle.ps1` 放在同一目录，在该目录运行下面命令。合并得到完整 ZIP 后再解压，不能单独解压某一卷。

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Join-Bundle.ps1
   ```

3. 关闭 Lightroom Classic 和 LRCDF 桌面程序。在解压后的包目录打开 PowerShell，运行

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Windows.ps1
   ```

   已安装 LRCDF 时，在命令末尾加 `-Replace` 才会更新原安装。安装使用当前 Windows 用户，无需管理员权限，安装过程不联网。
4. 打开 Lightroom Classic，选中照片，从 **图库 → 增效工具额外信息 → 开始一键修图…** 打开桌面程序。

安装包没有代码签名，下载后 Windows 可能出现安全提示，选择“仍要运行”或“保留”即可。

桌面程序在 `%USERPROFILE%\LRCDF\project\app\windows\LRCDF.exe`，插件在 `%APPDATA%\Adobe\Lightroom\Modules\LRCDFAuto.lrplugin`。也可以直接运行桌面程序，等待 Lightroom 发送照片。

界面按 Windows 显示语言列表选择语言。列表中有中文就优先使用中文，没有中文才跟随第一个支持的语言。本包自带简体中文、日语和繁体中文的 Noto 字体。

自动更新默认开启，在窗口右上角的齿轮里关闭。更新只下载变化的组件，超过 60 MB 时需先确认。更新已下载完后，点击“安装并重启”才会替换程序；替换共用组件前需关闭 Lightroom Classic。

## 卸载

在 Windows 设置的“应用和功能”或“已安装的应用”中找到 LRCDF，点击卸载。先关闭 LRCDF 和 Lightroom Classic。卸载会保留修图工作文件和个人设置。

## 已知限制

显存小于 15 GiB 的显卡走分块，预览与大显存相比有肉眼不可见的细微差别（平均 < 0.1 色阶，个别像素最多约 12 色阶），全尺寸最多 1 色阶。

皮肤范围由分割模型估计：阴影里的皮肤可能漏选，颜色接近皮肤的小物件、嘴唇、牙齿和眼白可能被一并轻微调整（饱和度约 −10 %、亮度约 +1/4 档），实际出片上不明显。

与 Mac 的已知差别：Windows 的风格名和修图卡片标题用界面字体，Mac 用宋体。

Windows 未测：EXIF 方向 6 / 8 的照片。

## 从源码构建

源码目录名用 `project`，与包含模型的 `models`、`legacy` 目录放在一起：

```text
LRCDF/
  models/makeup/makeup_s2.pt
  legacy/mac_project/
  project/
    app/windows/fonts/           # SC、JP、TC 三个字体
    packaging/Build-Windows.ps1
    runs/retouch_model.pt
```

构建需要 uv、Windows .NET Framework 4.x 编译器和网络。依赖版本见 `packaging\requirements-windows.txt`。在 `project` 目录先构建 CPU，再复用 CPU 启动器构建 CUDA，`-ReleaseVersion` 填要发布的版本号：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Windows.ps1 -Variant cpu -ReleaseVersion 0.1.2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Windows.ps1 -Variant cu124 -ReleaseVersion 0.1.2 -ReuseLauncherFrom '..\dist\LRCDF-Windows-x64-cpu\LRCDF\project\app\windows\LRCDF.exe'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Split-WindowsBundle.ps1 -ArchivePath '..\dist\LRCDF-Windows-x64-cu124.zip' -OutputDirectory '..\dist\CUDA分卷'
```

默认输出到 `LRCDF\dist`，可用 `-OutputDirectory` 指定新的输出目录。每个分卷最多 1,900,000,000 字节，完整 ZIP 和分卷内容相同。合并时需要为完整 ZIP 留出磁盘空间，解压和安装还需要额外空间。
