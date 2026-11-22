# Installing LRCDF for Windows

For Windows x64 and Lightroom Classic. The app is available in 20 languages. The program, taskbar, desktop and Start menu all use the same LRCDF icon.

1. Choose the CPU package, or the CUDA package if you have an NVIDIA GeForce GTX 10 series or newer graphics card with a recent driver. The CUDA package's files are named `LRCDF-Windows-x64-cuda.zip` (from 0.1.6; it contains CUDA 12.8).
2. Extract the CPU package directly. For the CUDA package, first put all its parts (`.zip.001`, `.zip.002` and so on) and `Join-Bundle.ps1` in one folder and run the command below in that folder. Extract the complete ZIP it makes; a single part cannot be extracted on its own.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Join-Bundle.ps1
   ```

3. Close Lightroom Classic and the LRCDF desktop app. Open PowerShell in the extracted package folder and run

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Windows.ps1
   ```

   If LRCDF is already installed, add `-Replace` to the end of the command to update it. The installer runs under your Windows account, needs no administrator rights and does not go online.
4. Open Lightroom Classic, select your photos and choose **Library → Plug-in Extras → Start One-Click Retouch…** to open the desktop app.

The installer is not code-signed, so Windows may show a security warning after the download. Choose "Run anyway" or "Keep".

The desktop app is at `%USERPROFILE%\LRCDF\project\app\windows\LRCDF.exe` and the plug-in at `%APPDATA%\Adobe\Lightroom\Modules\LRCDFAuto.lrplugin`. You can also start the desktop app directly and wait for Lightroom Classic to send photos.

The app's language follows the Windows display language list: if Chinese is anywhere in the list, the app is in Chinese; otherwise it uses the first supported language. Noto fonts for Simplified Chinese, Japanese and Traditional Chinese come with the package.

Automatic updates are on by default; turn them off with the gear at the top right of the window. Only the parts that changed are downloaded, and anything over 60 MB asks first. A downloaded update replaces the program only when you click "Install and restart"; close Lightroom Classic before shared parts are replaced.

## Uninstalling

Close LRCDF and Lightroom Classic, then find LRCDF under "Apps & features" or "Installed apps" in Windows Settings and click Uninstall. Your retouching work files and personal settings are kept.

## Known limitations

Graphics acceleration (the CUDA package) works with NVIDIA GeForce GTX 10 series and newer (GTX 10 and 16, RTX 20, 30, 40 and 50 series) and a recent NVIDIA driver. 0.1.6 carries a newer library (PyTorch 2.8.0 with CUDA 12.8) that supports these cards; it has not yet been tested on an RTX 50-series card. With any other graphics card, or when the card or its driver cannot be used, LRCDF uses the processor by itself; results take longer. Which one it uses, and why, is written to `%USERPROFILE%\LRCDF\device.log`; please send that file when you report a problem. Only an RTX 3090 has been tested.

Graphics cards with less than 15 GiB of memory work in tiles. Previews then differ from those of larger cards by amounts the eye cannot see (on average less than 0.1 levels, single pixels up to about 12 levels); full-size results differ by at most 1 level.

The skin area is estimated by a segmentation model: skin in shadow may be missed, and small skin-coloured objects, lips, teeth and the whites of the eyes may be adjusted slightly along with it (saturation about −10 %, brightness about +1/4 stop). This is not noticeable in the final pictures.

When the same photo is analysed again in a later Lightroom Classic session, the result may differ slightly.

Not tested on Windows: photos with EXIF orientation 6 or 8.

## Building from source

Name the source folder `project` and put it next to the `models` and `legacy` folders:

```text
LRCDF/
  models/makeup/makeup_s2.pt
  legacy/mac_project/
  project/
    app/windows/fonts/           # the SC, JP and TC fonts
    packaging/Build-Windows.ps1
    runs/retouch_model.pt
```

Building needs uv, the Windows .NET Framework 4.x compiler and a network connection. Dependency versions are in `packaging\requirements-windows.txt`. In the `project` folder, build the CPU variant first, then the CUDA variant reusing the CPU launcher; give `-ReleaseVersion` the version to be released:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Windows.ps1 -Variant cpu -ReleaseVersion 0.1.7 -NewPythonIdentity
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Windows.ps1 -Variant cu124 -ReleaseVersion 0.1.7 -NewPythonIdentity -ReuseLauncherFrom '..\dist\LRCDF-Windows-x64-cpu\LRCDF\project\app\windows\LRCDF.exe'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Split-WindowsBundle.ps1 -ArchivePath '..\dist\LRCDF-Windows-x64-cuda.zip' -OutputDirectory '..\dist\CUDA-parts'
```

Without `-NewPythonIdentity` the build stops unless `python` is exactly the published runtime, given with `-ReusePythonFrom`.

The output goes to `LRCDF\dist` unless `-OutputDirectory` names another folder. Each part is at most 1,900,000,000 bytes; the complete ZIP and the parts hold the same content. Joining needs disk space for the complete ZIP, and extracting and installing need more.
